import asyncio
import hashlib
import io
import json
import sys
import zipfile

import pytest

from server_workspace import knowledge
from server_workspace.knowledge import ExtractionError, KnowledgeStore, extract
from server_workspace.tests.test_workspace import setup
from server_workspace.tests.test_voice import voice, start, push
from server_workspace.voice import VoicePolicy, VoiceStore
from server_workspace.voice_tools import CONVERSATION_INSTRUCTIONS, definitions, VoiceTools
from server_workspace.workspace import Workspace, create_app
from fastapi.testclient import TestClient


def begin(client, headers, aid, fid, raw, filename="reference.txt"):
    return client.put(f"/api/assistants/{aid}/knowledge/{fid}", headers=headers,
                      json={"filename": filename, "bytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest()})


def upload(client, headers, aid, fid="file-1", raw=b"Orbit policy: the launch word is violet.", filename="reference.txt"):
    response = begin(client, headers, aid, fid, raw, filename)
    assert response.status_code == 200, response.text
    response = client.put(f"/api/assistants/{aid}/knowledge/{fid}/content", headers=headers, content=raw)
    assert response.status_code == 200, response.text
    return response.json()


def aid_for(client, headers):
    return client.get("/api/assistants", headers=headers).json()["assistants"][0]["id"]


def pdf(text="Orbit launch word is violet."):
    from pypdf import PdfWriter
    from pypdf.generic import NameObject, DictionaryObject, DecodedStreamObject
    writer = PdfWriter()
    page = writer.add_blank_page(width=300, height=300)
    font = DictionaryObject({NameObject("/Type"): NameObject("/Font"), NameObject("/Subtype"): NameObject("/Type1"), NameObject("/BaseFont"): NameObject("/Helvetica")})
    page[NameObject("/Resources")] = DictionaryObject({NameObject("/Font"): DictionaryObject({NameObject("/F1"): font})})
    stream = DecodedStreamObject()
    stream.set_data(f"BT /F1 12 Tf 10 100 Td ({text}) Tj ET".encode())
    page[NameObject("/Contents")] = stream
    result = io.BytesIO(); writer.write(result)
    return result.getvalue()


def docx(xml=None):
    result = io.BytesIO()
    with zipfile.ZipFile(result, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("word/document.xml", xml or '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>Orbit launch word is violet.</w:t></w:r></w:p><w:tbl><w:tr><w:tc><w:p><w:r><w:t>The backup word is indigo.</w:t></w:r></w:p></w:tc></w:tr></w:tbl></w:body></w:document>')
    return result.getvalue()


def send_chunks(client, headers, path, raw, start=0):
    size = knowledge.UPLOAD_CHUNK_BYTES
    for offset in range(start, len(raw), size):
        response = client.put(path + f"/chunks/{offset // size}", headers=headers, content=raw[offset:offset + size])
        assert response.status_code == 200, response.text
        assert response.json()["uploaded_bytes"] == min(offset + size, len(raw))


def test_pdf_reader_recovers_viewer_readable_cross_reference_defects():
    import re
    from pypdf import PdfReader
    from pypdf.errors import PdfReadError
    raw = pdf()
    raw = re.sub(rb"startxref\n(\d+)", lambda m: b"startxref\n" + str(int(m[1]) + 1).encode(), raw)
    with pytest.raises(PdfReadError):
        PdfReader(io.BytesIO(raw), strict=True)
    assert "violet" in json.dumps(extract(raw, ".pdf"))


def secured_pdf(password, algorithm):
    from pypdf import PdfReader, PdfWriter
    writer = PdfWriter(clone_from=PdfReader(io.BytesIO(pdf())))
    writer.encrypt(password, owner_password="synthetic-owner-password", algorithm=algorithm)
    result = io.BytesIO()
    writer.write(result)
    return result.getvalue()


@pytest.mark.parametrize("algorithm", ["RC4-128", "AES-128", "AES-256-R5", "AES-256"])
def test_pdf_that_opens_without_password_is_read_in_isolated_worker(algorithm):
    # These remain is_encrypted even though a viewer can open them without a prompt.
    raw = secured_pdf("", algorithm)
    result = asyncio.run(knowledge.extract_isolated(raw, ".pdf"))
    assert "violet" in json.dumps(result)
    assert result["sections"][0]["location"] == "Page 1"


@pytest.mark.parametrize("algorithm", ["RC4-128", "AES-128", "AES-256-R5", "AES-256"])
def test_pdf_that_requires_password_keeps_actionable_error(algorithm):
    raw = secured_pdf("synthetic-user-password", algorithm)
    with pytest.raises(ExtractionError) as raised:
        asyncio.run(knowledge.extract_isolated(raw, ".pdf"))
    assert raised.value.code == "PDF_PASSWORD"
    assert "synthetic" not in str(raised.value)


def test_missing_pdf_crypto_support_reports_pc_fault_without_parser_payload(monkeypatch):
    import pypdf
    from pypdf.errors import DependencyError
    def unavailable(*args, **kwargs):
        raise DependencyError("SENSITIVE_PARSER_PAYLOAD")
    monkeypatch.setattr(pypdf, "PdfReader", unavailable)
    with pytest.raises(ExtractionError) as raised:
        extract(pdf(), ".pdf")
    assert raised.value.code == "FILE_READER_UNAVAILABLE"
    assert "PC" in str(raised.value) and "saved" in str(raised.value)
    assert "SENSITIVE_PARSER_PAYLOAD" not in str(raised.value)


def test_pdf_reader_unavailable_preserves_upload_for_retry(setup, monkeypatch):
    w, client, _, _, (_, a), _ = setup
    aid = aid_for(client, a)
    raw = pdf()
    path = f"/api/assistants/{aid}/knowledge/crypto-unavailable"
    assert begin(client, a, aid, "crypto-unavailable", raw, "Reference.pdf").status_code == 200
    send_chunks(client, a, path, raw)
    original = knowledge.extract_isolated
    async def unavailable(*args):
        raise ExtractionError("The PC's PDF reader needs encryption support. Your upload is saved", "FILE_READER_UNAVAILABLE")
    monkeypatch.setattr(knowledge, "extract_isolated", unavailable)
    assert client.post(path + "/complete", headers=a).status_code == 503
    file = client.get(path, headers=a).json()["file"]
    assert file["error_code"] == "FILE_READER_UNAVAILABLE" and file["uploaded_bytes"] == len(raw)
    with w.db() as db:
        assert db.execute("SELECT COUNT(*) FROM assistant_knowledge_chunks WHERE file_id='crypto-unavailable'").fetchone()[0] == 1
    monkeypatch.setattr(knowledge, "extract_isolated", original)
    assert client.post(path + "/complete", headers=a).json()["state"] == "ready"


def test_upload_batches_resume_after_restart_and_lost_acknowledgement(setup):
    w, client, _, _, (_, a), (_, b) = setup
    aid = aid_for(client, a)
    raw = pdf() + b"\n" * (2 * knowledge.UPLOAD_CHUNK_BYTES)
    path = f"/api/assistants/{aid}/knowledge/resume"
    assert begin(client, a, aid, "resume", raw, "Large.pdf").json()["upload_version"] == 1
    first = raw[:knowledge.UPLOAD_CHUNK_BYTES]
    assert client.put(path + "/chunks/0", headers=a, content=first).status_code == 200
    # Pretend that response never arrived: the identical batch is acknowledged once.
    assert client.put(path + "/chunks/0", headers=a, content=first).json()["uploaded_bytes"] == len(first)
    assert client.put(path + "/chunks/0", headers=a, content=b"x" * len(first)).status_code == 409
    assert client.put(path + "/chunks/2", headers=a, content=raw[2 * len(first):]).status_code == 409
    assert client.post(path + "/complete", headers=a).status_code == 409
    assert client.put(path + "/chunks/0", headers=b, content=first).status_code == 404
    assert client.post(path + "/complete", headers=b).status_code == 404
    with w.db() as db:
        part = db.execute("SELECT content,hash FROM assistant_knowledge_chunks WHERE file_id='resume'").fetchone()
        assert part[0] != first and w.cipher.open(part[0]) == first
        assert part[1] == hashlib.sha256(part[0]).hexdigest()  # No plaintext fingerprint.
        db.execute("INSERT INTO recordings VALUES('untouched','owner','processing',0,0,1,1,?)", (w.encode({}),))
    restarted = Workspace(w.config, w.cipher, w.provider, w.audio_preparer, recover_jobs=False)
    client = TestClient(create_app(restarted, run_worker=False))
    assert begin(client, a, aid, "resume", raw, "Large.pdf").json()["uploaded_bytes"] == len(first)
    send_chunks(client, a, path, raw, len(first))
    assert client.post(path + "/complete", headers=a).json()["state"] == "ready"
    assert client.post(path + "/complete", headers=a).json()["state"] == "ready"
    assert "violet" in client.get(path, headers=a).json()["text"]
    with w.db() as db:
        assert db.execute("SELECT COUNT(*) FROM assistant_knowledge_chunks WHERE file_id='resume'").fetchone()[0] == 0
        assert db.execute("SELECT state FROM recordings WHERE id='untouched'").fetchone()[0] == "processing"


def test_interrupted_batch_preserves_prior_progress_and_saves_safe_reason(setup):
    w, client, _, _, (_, a), _ = setup
    aid = aid_for(client, a)
    raw = pdf() + b"\n" * knowledge.UPLOAD_CHUNK_BYTES
    path = f"/api/assistants/{aid}/knowledge/disconnected"
    begin(client, a, aid, "disconnected", raw, "Large.pdf")
    send_chunks(client, a, path, raw[:knowledge.UPLOAD_CHUNK_BYTES])
    async def disconnect():
        calls = 0
        async def receive():
            nonlocal calls
            calls += 1
            if calls == 1:
                return {"type": "http.request", "body": b"partial", "more_body": True}
            return {"type": "http.disconnect"}
        async def send(message):
            pass
        scope = {"type": "http", "asgi": {"version": "3.0"}, "http_version": "1.1", "method": "PUT",
                 "scheme": "http", "path": path + "/chunks/1", "raw_path": (path + "/chunks/1").encode(),
                 "query_string": b"", "root_path": "", "client": ("synthetic", 123), "server": ("testserver", 80),
                 "headers": [(b"authorization", a["Authorization"].encode())]}
        await client.app(scope, receive, send)
    asyncio.run(disconnect())
    file = client.get(path, headers=a).json()["file"]
    assert file["error_code"] == "UPLOAD_DISCONNECTED" and file["uploaded_bytes"] == knowledge.UPLOAD_CHUNK_BYTES
    assert "Resume" not in file["error_message"] or "same file" in file["error_message"]
    send_chunks(client, a, path, raw, knowledge.UPLOAD_CHUNK_BYTES)
    assert client.post(path + "/complete", headers=a).json()["state"] == "ready"


@pytest.mark.parametrize("change,status", [("remove", 410), ("signout", 401), ("assistant", 404)])
def test_batch_finalization_rechecks_session_and_deletion(setup, monkeypatch, change, status):
    w, client, _, _, (_, a), _ = setup
    aid = aid_for(client, a)
    raw = b"Synthetic reference text"
    path = f"/api/assistants/{aid}/knowledge/inflight-batch"
    begin(client, a, aid, "inflight-batch", raw)
    send_chunks(client, a, path, raw)
    async def delayed(content, extension):
        if change == "signout":
            with w.db() as db: db.execute("DELETE FROM sessions")
        elif change == "assistant":
            client.delete(f"/api/assistants/{aid}", headers=a)
        else:
            client.delete(path, headers=a)
        return extract(content, extension)
    monkeypatch.setattr(knowledge, "extract_isolated", delayed)
    assert client.post(path + "/complete", headers=a).status_code == status
    with w.db() as db:
        assert db.execute("SELECT file FROM assistant_knowledge WHERE id='inflight-batch'").fetchone()[0] is None
        if change != "signout":
            assert db.execute("SELECT COUNT(*) FROM assistant_knowledge_chunks WHERE file_id='inflight-batch'").fetchone()[0] == 0


def test_read_failure_is_saved_without_payload_and_retry_reuses_uploaded_bytes(setup, monkeypatch):
    w, client, _, _, (_, a), _ = setup
    aid = aid_for(client, a)
    raw = pdf()
    path = f"/api/assistants/{aid}/knowledge/reader"
    begin(client, a, aid, "reader", raw, "Reference.pdf")
    send_chunks(client, a, path, raw)
    async def faulty(*args):
        raise OSError("private-document-text-never-forwarded")
    with monkeypatch.context() as patch:
        patch.setattr(knowledge, "extract_isolated", faulty)
        response = client.post(path + "/complete", headers=a)
        assert response.status_code == 503 and "private-document-text" not in response.text
    file = begin(client, a, aid, "reader", raw, "Reference.pdf").json()
    assert file["error_code"] == "FILE_READER_UNAVAILABLE" and file["uploaded_bytes"] == len(raw)
    assert client.post(path + "/complete", headers=a).json()["state"] == "ready"
    assert client.get(path, headers=a).json()["file"]["error_code"] is None


def test_deleted_upload_cannot_restore_encrypted_batches(setup):
    w, client, _, _, (_, a), _ = setup
    aid = aid_for(client, a)
    raw = b"Synthetic reference"
    path = f"/api/assistants/{aid}/knowledge/deleted-batch"
    begin(client, a, aid, "deleted-batch", raw)
    assert client.put(path + "/chunks/-1", headers=a, content=raw).status_code == 422
    assert client.put(path + "/chunks/0", headers=a, content=raw + b"x").status_code == 413
    send_chunks(client, a, path, raw)
    assert client.delete(path, headers=a).status_code == 200
    assert client.put(path + "/chunks/0", headers=a, content=raw).status_code == 410
    assert client.post(path + "/complete", headers=a).status_code == 410
    with w.db() as db:
        assert db.execute("SELECT COUNT(*) FROM assistant_knowledge_chunks WHERE file_id='deleted-batch'").fetchone()[0] == 0


@pytest.mark.parametrize("extension,raw,locator", [
    (".txt", b"Orbit launch word is violet.", "Lines"),
    (".md", b"# Orbit policy\n\nLaunch word is violet.", "Lines"),
    (".csv", b"policy,value\nOrbit launch word,violet\n", "Row"),
    (".docx", None, "Paragraph"), (".pdf", None, "Page")])
def test_supported_files_extract_text_and_stable_sources(extension, raw, locator):
    result = extract(raw or (docx() if extension == ".docx" else pdf()), extension)
    assert "violet" in json.dumps(result)
    assert result["chunks"][0]["location"].startswith(locator)
    assert result["characters"] > 10
    if extension == ".docx":
        assert "indigo" in json.dumps(result)  # Include table cells.


def test_isolated_worker_returns_sanitized_helpful_errors():
    with pytest.raises(ExtractionError, match="No readable text"):
        asyncio.run(knowledge.extract_isolated(pdf(""), ".pdf"))
    assert asyncio.run(knowledge.extract_isolated(b"Safe text", ".txt"))["characters"] == 9


@pytest.mark.parametrize("raw,extension", [(b"private-broken-payload", ".pdf"), (b"private-broken-payload", ".docx"),
                                         (b"\x00\x00binary", ".txt"), (b"\xff\x00", ".txt"), (b"image", ".png")])
def test_damaged_and_binary_files_do_not_expose_parser_payloads(raw, extension):
    with pytest.raises(ExtractionError) as error:
        extract(raw, extension)
    assert "private-broken-payload" not in str(error.value)


def test_limits_and_xml_entity_references_are_rejected():
    with pytest.raises(ExtractionError, match="too much text"):
        extract(b"x" * (knowledge.MAX_CHARACTERS + 1), ".txt")
    with pytest.raises(ExtractionError, match="could not be read"):
        extract(docx('<!DOCTYPE x [<!ENTITY secret SYSTEM "file:///private">]><x>&secret;</x>'), ".docx")
    with pytest.raises(ExtractionError, match="too much content"):
        extract(docx(" " * (knowledge.MAX_DOCX_XML_BYTES + 1)), ".docx")
    with pytest.raises(ExtractionError, match="100 MB"):
        extract(b"x" * (knowledge.MAX_BYTES + 1), ".txt")


def test_owner_upload_preview_and_idempotent_retries(setup):
    w, client, _, _, (alice, a), (_, b) = setup
    aid = aid_for(client, a)
    raw = b"Orbit policy: launch word is violet."
    first = upload(client, a, aid, raw=raw)
    assert first["state"] == "ready"
    assert upload(client, a, aid, raw=raw)["id"] == first["id"]
    files = client.get(f"/api/assistants/{aid}/knowledge", headers=a).json()["files"]
    assert len(files) == 1
    assert "violet" in client.get(f"/api/assistants/{aid}/knowledge/file-1", headers=a).json()["text"]
    assert begin(client, a, aid, "file-1", b"different").status_code == 409
    assert client.get("/api/assistants", headers=a).json()["assistants"][0]["knowledge_file_count"] == 1
    assert client.get(f"/api/assistants/{aid}/knowledge", headers=b).status_code == 404
    # Content, names, hashes and excerpts live inside the protected blob, never audit columns.
    with w.db() as db:
        events = [dict(r) for r in db.execute("SELECT * FROM audit WHERE action LIKE 'knowledge-%'")]
    assert len([e for e in events if e["action"] == "knowledge-upload-completed"]) == 1
    assert "violet" not in json.dumps(events) and "reference.txt" not in json.dumps(events)


def test_foreign_and_administrator_access_is_not_implicit(setup):
    _, client, _, (_, ah), (_, a), (_, b) = setup
    aid = aid_for(client, a)
    upload(client, a, aid)
    for headers in (b, ah):
        for method, suffix in (("GET", ""), ("GET", "/file-1"), ("DELETE", "/file-1")):
            assert client.request(method, f"/api/assistants/{aid}/knowledge{suffix}", headers=headers).status_code == 404
        assert begin(client, headers, aid, "foreign", b"text").status_code == 404


def test_tombstones_block_delayed_uploads_and_assistant_recreation(setup):
    w, client, _, _, (_, a), _ = setup
    aid = aid_for(client, a)
    raw = b"Orbit policy: launch word is violet."
    upload(client, a, aid, raw=raw)
    path = f"/api/assistants/{aid}/knowledge/file-1"
    assert client.delete(path, headers=a).status_code == 200
    assert client.delete(path, headers=a).status_code == 200
    assert begin(client, a, aid, "file-1", raw).status_code == 410
    assert client.put(path + "/content", headers=a, content=raw).status_code == 410
    with w.db() as db:
        row = db.execute("SELECT * FROM assistant_knowledge WHERE id='file-1'").fetchone()
        assert row["file"] is None and w.decode(row["content"]) == {}
    upload(client, a, aid, "file-2")
    assistant = client.get("/api/assistants", headers=a).json()["assistants"][0]
    assert client.delete(f"/api/assistants/{aid}", headers=a).status_code == 200
    client.put(f"/api/assistants/{aid}", headers=a, json=assistant)
    assert client.get(f"/api/assistants/{aid}/knowledge", headers=a).json()["files"] == []
    assert begin(client, a, aid, "file-2", raw).status_code == 410


@pytest.mark.parametrize("change,status", [("remove", 410), ("signout", 401), ("assistant", 404)])
def test_authorization_and_deletion_rechecked_after_extraction(setup, monkeypatch, change, status):
    w, client, _, _, (_, a), _ = setup
    aid = aid_for(client, a)
    raw = b"Orbit launch word is violet."
    assert begin(client, a, aid, "inflight", raw).status_code == 200
    async def delayed(content, extension):
        with w.db() as db:
            if change == "signout":
                db.execute("DELETE FROM sessions")
            elif change == "assistant":
                db.execute("DELETE FROM assistants WHERE id=?", (aid,))
            else:
                owner = db.execute("SELECT owner FROM assistants WHERE id=?", (aid,)).fetchone()[0]
                KnowledgeStore(w).remove(db, owner, aid, "inflight")
        return extract(content, extension)
    monkeypatch.setattr(knowledge, "extract_isolated", delayed)
    assert client.put(f"/api/assistants/{aid}/knowledge/inflight/content", headers=a, content=raw).status_code == status
    with w.db() as db:
        assert db.execute("SELECT file FROM assistant_knowledge WHERE id='inflight'").fetchone()[0] is None


def test_file_size_hash_type_and_quota_are_checked_before_extraction(setup):
    _, client, _, _, (_, a), _ = setup
    aid = aid_for(client, a)
    assert begin(client, a, aid, "bad-type", b"text", "image.png").status_code == 422
    assert begin(client, a, aid, "bad-name", b"text", "../secret.txt").status_code == 422
    assert begin(client, a, aid, "partial", b"text").status_code == 200
    path = f"/api/assistants/{aid}/knowledge/partial/content"
    assert client.put(path, headers=a, content=b"tex").status_code == 422
    assert client.put(path, headers=a, content=b"nope").status_code == 422
    assert client.put(path, headers=a, content=b"text-too-long").status_code == 413
    for index in range(19):
        assert begin(client, a, aid, f"reserve-{index}", b"text").status_code == 200
    assert begin(client, a, aid, "over-quota", b"text").status_code == 409


def test_hundred_mb_file_and_five_hundred_mb_total_reservations_are_enforced(setup):
    _, client, _, _, (_, a), _ = setup
    aid = aid_for(client, a)
    path = f"/api/assistants/{aid}/knowledge"
    limits = client.get(path, headers=a).json()
    assert limits["max_bytes"] == 100 * 1024 * 1024
    assert limits["max_total_bytes"] == 500 * 1024 * 1024
    assert limits["max_characters"] == 2_000_000 and limits["max_pdf_pages"] == 1000
    metadata = {"filename": "Large.pdf", "bytes": limits["max_bytes"], "sha256": "0" * 64}
    assert client.put(path + "/too-large", headers=a, json={**metadata, "bytes": metadata["bytes"] + 1}).status_code == 422
    for index in range(5):
        assert client.put(path + f"/reserve-{index}", headers=a, json=metadata).status_code == 200
    response = client.put(path + "/above-total", headers=a, json={**metadata, "bytes": 1})
    assert response.status_code == 409 and "500 MB" in response.json()["detail"]
    assert client.delete(path + "/reserve-0", headers=a).status_code == 200
    assert client.put(path + "/after-removal", headers=a, json=metadata).status_code == 200


def test_file_larger_than_old_limit_uploads_extracts_and_remains_encrypted(setup):
    w, client, _, _, (_, a), _ = setup
    aid = aid_for(client, a)
    # Image-heavy PDFs can be large with little text. Padding keeps this fixture synthetic.
    raw = pdf() + b"\n" * (11 * 1024 * 1024)
    value = upload(client, a, aid, "large-pdf", raw, "Large.pdf")
    assert value["state"] == "ready" and value["bytes"] == len(raw)
    assert "violet" in client.get(f"/api/assistants/{aid}/knowledge/large-pdf", headers=a).json()["text"]
    with w.db() as db:
        row = db.execute("SELECT file FROM assistant_knowledge WHERE id='large-pdf'").fetchone()
        assert row[0] != raw and w.cipher.open(row[0]) == raw


def test_retrieval_is_scoped_ranked_bounded_and_cites_passages(setup):
    w, client, _, _, (alice, a), (_, b) = setup
    aid = aid_for(client, a)
    upload(client, a, aid, "orbit", b"Orbit launch policy: the launch word is violet.", "Orbit.md")
    upload(client, a, aid, "other", b"Aubergine garden recipes and compost.", "Garden.txt")
    store = KnowledgeStore(w)
    ids, _ = store.snapshot(alice["user"]["id"], aid)
    result = store.search(alice["user"]["id"], aid, ids, "What is the Orbit launch word?")
    assert len(result["passages"]) == 1 and "violet" in result["passages"][0]["text"]
    assert result["sources"][0]["url"].startswith("knowledge://orbit#")
    assert result["sources"][0]["location"].startswith("Lines")
    assert "never instructions" in result["notice"] and "never instructions" in CONVERSATION_INSTRUCTIONS
    assert store.search(alice["user"]["id"], aid, ids, "unrelated zoological topic")["passages"] == []
    assert "error" in asyncio.run(VoiceTools(w).execute("search_knowledge", {"query": "Orbit", "owner": "bobby"}, knowledge_context=(alice["user"]["id"], aid, ids)))


def multiple_page_pdf(*texts):
    from pypdf import PdfReader, PdfWriter
    writer = PdfWriter()
    for text in texts:
        writer.append(PdfReader(io.BytesIO(pdf(text))))
    output = io.BytesIO()
    writer.write(output)
    return output.getvalue()


def test_adjacent_pdf_pages_can_both_supply_reference_facts(setup):
    w, client, _, _, (alice, headers), _ = setup
    aid = aid_for(client, headers)
    upload(client, headers, aid, "pages", multiple_page_pdf(
        "Orbital safety: the start word is violet.",
        "Orbital safety: the stop word is cedar."), "Safety.pdf")
    result = KnowledgeStore(w).search(alice["user"]["id"], aid, ["pages"], "orbital safety")
    assert {p["location"] for p in result["passages"]} == {"Page 1", "Page 2"}
    assert "violet" in result["passages"][0]["text"]
    assert any("cedar" in p["text"] for p in result["passages"])


def test_native_pdf_text_and_adjacent_ocr_can_both_supply_reference_facts(setup):
    w, client, _, _, (alice, headers), _ = setup
    aid = aid_for(client, headers)
    upload(client, headers, aid, "ocr", pdf("Orbital safety: start with violet."), "Safety.pdf")
    with w.db() as db:
        row = KnowledgeStore(w).row(db, alice["user"]["id"], aid, "ocr")
        data = w.decode(row["content"])
        data["chunks"].append({"text": "Orbital safety diagram: stop with cedar.", "location": "Page 1 (OCR)"})
        db.execute("UPDATE assistant_knowledge SET content=? WHERE id='ocr'", (w.encode(data),))
    result = KnowledgeStore(w).search(alice["user"]["id"], aid, ["ocr"], "orbital safety")
    assert {p["location"] for p in result["passages"]} == {"Page 1", "Page 1 (OCR)"}


def test_overlapping_chunks_from_same_pdf_page_still_collapse(setup):
    w, client, _, _, (alice, headers), _ = setup
    aid = aid_for(client, headers)
    upload(client, headers, aid, "overlap", multiple_page_pdf(
        "Orbital safety violet. " * 110,
        "Orbital safety cedar."), "Safety.pdf")
    result = KnowledgeStore(w).search(alice["user"]["id"], aid, ["overlap"], "orbital safety")
    assert [p["location"] for p in result["passages"]].count("Page 1") == 1
    assert any(p["location"] == "Page 2" for p in result["passages"])
    assert len(result["passages"]) == 2


def test_source_heading_and_limit_across_chunk_boundary_are_returned_together(setup):
    w, client, _, _, (alice, headers), _ = setup
    aid = aid_for(client, headers)
    body = "A1 Orbital launch\nFull-size vehicle\n" + "Complete the preflight inspection. " * 48
    body += "\nLaunch ignition attempts: maximum three attempts."
    upload(client, headers, aid, "limits", multiple_page_pdf(
        body, "A2 Post orbital launch: ignition retries for a small vehicle are unrestricted."), "Limits.pdf")
    result = KnowledgeStore(w).search(alice["user"]["id"], aid, ["limits"], "orbital launch ignition maximum attempts full-size vehicle")
    passage = next(p for p in result["passages"] if p["location"] == "Page 1")
    assert "A1 Orbital launch" in passage["text"] and "maximum three attempts" in passage["text"]
    assert passage["complete"] and passage["next_offset"] is None
    assert passage["source"] == "knowledge://limits#0"
    assert "not an exhaustive review" in result["notice"]


def test_combined_topic_outranks_unrelated_repeated_terms(setup):
    w, client, _, _, (alice, headers), _ = setup
    aid = aid_for(client, headers)
    upload(client, headers, aid, "rank", multiple_page_pdf(
        "Contents\nOrbit\nLaunch\nIgnition\nVehicle\nGarden\nCooking",
        "A1 Orbital launch\nFull-size vehicle ignition: maximum three attempts.",
        "Gardening\n" + "Maximum maximum maximum attempts attempts attempts. " * 30), "Limits.pdf")
    result = KnowledgeStore(w).search(alice["user"]["id"], aid, ["rank"], "orbital launch ignition maximum attempts vehicle")
    assert result["passages"][0]["location"] == "Page 2"


def test_long_source_can_be_read_past_search_excerpt_with_stable_citation(setup):
    w, client, _, _, (alice, headers), _ = setup
    aid = aid_for(client, headers)
    text = "A1 Orbital launch\n" + "Check the ignition equipment. " * 230 + "\nException: maximum three attempts."
    upload(client, headers, aid, "long", pdf(text), "Limits.pdf")
    store = KnowledgeStore(w)
    owner = alice["user"]["id"]
    result = store.search(owner, aid, ["long"], "orbital launch ignition")
    passage = result["passages"][0]
    assert not passage["complete"] and len(passage["text"]) == knowledge.PASSAGE_CHARACTERS
    assert sum(len(p["text"]) for p in result["passages"]) <= knowledge.SEARCH_CHARACTERS
    continuation = asyncio.run(VoiceTools(w).execute("read_knowledge", {"source": passage["source"], "offset": passage["next_offset"]}, knowledge_context=(owner, aid, ["long"])))
    assert "maximum three attempts" in continuation["passages"][0]["text"]
    assert continuation["passages"][0]["next_offset"] is None
    assert continuation["sources"] == result["sources"]
    assert continuation["passages"][0]["offset"] == knowledge.PASSAGE_CHARACTERS
    assert not continuation["passages"][0]["complete"]
    with w.db() as db:
        data = w.decode(store.row(db, owner, aid, "long")["content"])
    # Legacy links to later chunks still resolve to the same complete page.
    assert store.read(owner, aid, ["long"], "knowledge://long#1")["passages"][0]["text"] == passage["text"]
    data.pop("sections")
    assert knowledge.reference_locations(data)[0]["text"] == text


def test_read_source_enforces_snapshot_owner_and_deleted_file_boundaries(setup):
    w, client, _, _, (alice, headers), (bob, _) = setup
    aid = aid_for(client, headers)
    upload(client, headers, aid, "source")
    store = KnowledgeStore(w)
    owner = alice["user"]["id"]
    for source, offset in [("https://example.com", 0), ("knowledge://source#999", 0),
                           ("knowledge://source#0", -1), ("knowledge://source#0", True),
                           ("knowledge://source#0", 10000)]:
        assert "error" in store.read(owner, aid, ["source"], source, offset)
    assert "error" in store.read(owner, aid, [], "knowledge://source#0")
    assert "error" in asyncio.run(VoiceTools(w).execute("read_knowledge", {"source": "knowledge://source#0", "owner": owner}, knowledge_context=(owner, aid, ["source"])))
    from fastapi import HTTPException
    with pytest.raises(HTTPException) as foreign:
        store.read(bob["user"]["id"], aid, ["source"], "knowledge://source#0")
    assert foreign.value.status_code == 404
    client.delete(f"/api/assistants/{aid}/knowledge/source", headers=headers)
    with pytest.raises(HTTPException) as deleted:
        store.read(owner, aid, ["source"], "knowledge://source#0")
    assert deleted.value.status_code == 410


def test_knowledge_is_independent_of_calculator_and_private_web_is_paused():
    policy = VoicePolicy(public_web_search_enabled=True)
    private = {"knowledge_file_count": 1, "web_search": True}
    assert {d["name"] for d in definitions(private, policy)} == {"calculate", "current_time", "search_knowledge", "read_knowledge"}
    assert {d["name"] for d in definitions({**private, "tools_enabled": False}, policy)} == {"search_knowledge", "read_knowledge"}
    assert "search_web" in {d["name"] for d in definitions({**private, "knowledge_public": True}, policy)}
    assert "search_web" not in {d["name"] for d in definitions({**private, "knowledge_public": True, "context_private": True}, policy)}


def test_old_client_saves_preserve_public_setting_and_attachments(setup):
    _, client, _, _, (_, a), _ = setup
    aid = aid_for(client, a)
    upload(client, a, aid)
    assistant = client.get("/api/assistants", headers=a).json()["assistants"][0]
    assistant["voice"] = {"enabled": True, "knowledge_public": True}
    assert client.put(f"/api/assistants/{aid}", headers=a, json=assistant).status_code == 200
    assistant["voice"] = {"enabled": True, "voice": "cedar"}
    assert client.put(f"/api/assistants/{aid}", headers=a, json=assistant).json()["voice"]["knowledge_public"] is True
    assistant.pop("voice")
    assert client.put(f"/api/assistants/{aid}", headers=a, json=assistant).json()["voice"]["knowledge_public"] is True
    assert len(client.get(f"/api/assistants/{aid}/knowledge", headers=a).json()["files"]) == 1


def test_voice_retrieves_files_and_continues_spoken_reply_with_history_source(voice):
    w, private, public, people, assistant, _, _, peers = voice
    a = people["alice"][1]
    upload(private, a, assistant["id"])
    s = start(voice)
    session = public.app.state.voice.sessions[s["id"]]
    assert "search_knowledge" in {t["name"] for t in peers[-1].sent[0]["session"]["tools"]}
    push(voice, {"type": "response.done", "response": {"id": "r1", "status": "completed", "output": [
        {"type": "function_call", "name": "search_knowledge", "call_id": "k1", "arguments": '{"query":"Orbit launch word"}'}]}})
    public.portal.call(asyncio.sleep, 0.1)
    outputs = [e["item"] for e in peers[-1].sent if e["type"] == "conversation.item.create"]
    assert "violet" in outputs[-1]["output"] and outputs[-1]["call_id"] == "k1"
    assert peers[-1].sent[-1]["type"] == "response.create"
    push(voice, {"type": "response.output_audio_transcript.done", "item_id": "answer", "transcript": "The launch word is violet, according to reference.txt."})
    conversation = VoiceStore(w).conversation(s["conversation_id"], people["alice"][0]["user"]["id"])
    assert conversation["turns"][-1]["sources"][0]["kind"] == "knowledge"
    assert conversation["private_knowledge"] is True
    assert public.get(f"/api/assistants/{assistant['id']}/knowledge", headers=voice[6]).status_code == 404
    assert private.get(f"/api/assistants/{assistant['id']}/knowledge", headers=voice[6]).status_code == 401
    push(voice, {"type": "response.created", "response": {"id": "r2"}})
    push(voice, {"type": "response.done", "response": {"id": "r2", "status": "completed", "output": [
        {"type": "function_call", "name": "read_knowledge", "call_id": "k2", "arguments": '{"source":"knowledge://file-1#0"}'}]}})
    public.portal.call(asyncio.sleep, 0.1)
    outputs = [e["item"] for e in peers[-1].sent if e["type"] == "conversation.item.create"]
    assert "violet" in outputs[-1]["output"] and outputs[-1]["call_id"] == "k2"
    assert peers[-1].sent[-1]["type"] == "response.create"


def test_removal_ends_active_voice_and_resume_keeps_private_context(voice):
    _, private, public, people, assistant, _, vh, _ = voice
    a = people["alice"][1]
    upload(private, a, assistant["id"])
    s = start(voice)
    session = public.app.state.voice.sessions[s["id"]]
    private.delete(f"/api/assistants/{assistant['id']}/knowledge/file-1", headers=a)
    public.portal.call(asyncio.sleep, 1.1)
    assert session.state == "ended"
    resumed = start(voice, "resume", conversation_id=s["conversation_id"])
    assert public.app.state.voice.sessions[resumed["id"]].profile["context_private"] is True


@pytest.mark.skipif(sys.platform != "win32", reason="Production DPAPI requires Windows")
def test_uploaded_names_original_and_text_are_encrypted_on_disk(setup):
    from server_workspace.workspace import WindowsCipher
    w, client, _, _, (_, a), _ = setup
    aid = aid_for(client, a)
    # Existing fixture assistants use TestCipher; switch only while creating/reading knowledge.
    old = w.cipher
    with w.db() as db:
        data = w.decode(db.execute("SELECT content FROM assistants WHERE id=?", (aid,)).fetchone()[0])
    w.cipher = WindowsCipher()
    with w.db() as db:
        db.execute("UPDATE assistants SET content=? WHERE id=?", (w.encode(data), aid))
    upload(client, a, aid, raw=b"secret-synthetic-knowledge-marker", filename="secret-synthetic-filename.txt")
    disk = w.database.read_bytes()
    assert b"secret-synthetic-knowledge-marker" not in disk and b"secret-synthetic-filename" not in disk
    w.cipher = old
