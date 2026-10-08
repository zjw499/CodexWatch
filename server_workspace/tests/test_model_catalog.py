import asyncio
import json

import httpx
import pytest

from server_workspace.workspace import OpenAIProvider, WorkspaceConfig
from server_workspace.tests.test_workspace import setup, upload, process_body


def provider(tmp_path, monkeypatch, handler):
    original = httpx.AsyncClient
    monkeypatch.setattr(httpx, "AsyncClient", lambda **kwargs: original(transport=httpx.MockTransport(handler), **kwargs))
    value = OpenAIProvider(WorkspaceConfig(tmp_path, tmp_path / "unused"))
    monkeypatch.setattr(value, "headers", lambda: {})
    return value


@pytest.mark.parametrize("model", ["gpt-4.1-mini", "gpt-6-astra", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5", "gpt-5.4-mini", "gpt-5.4-nano"])
def test_generation_preserves_privacy_and_gives_reasoning_room_for_a_final_answer(tmp_path, monkeypatch, model):
    def response(request):
        body = json.loads(request.read())
        assert body["model"] == model and body["store"] is False
        assert "tools" not in body and body["input"][0]["role"] == "user"
        if model.startswith(("gpt-5", "gpt-6")):
            assert body["reasoning"] == {"effort": "low"} and body["max_output_tokens"] >= 12000
        else:
            assert "reasoning" not in body and body["max_output_tokens"] == 4000
        return httpx.Response(200, json={"status": "completed", "output": [
            {"type": "reasoning", "summary": []}, {"content": [{"type": "output_text", "text": "Friday follow-up"}]}]})
    value = provider(tmp_path, monkeypatch, response)
    assert asyncio.run(value.generate(model, "Make notes", "Agenda Friday", [])) == "Friday follow-up"


def test_reasoning_budget_exhaustion_never_saves_a_partial_answer(tmp_path, monkeypatch):
    value = provider(tmp_path, monkeypatch, lambda _: httpx.Response(200, json={
        "status": "incomplete", "output": [{"content": [{"type": "output_text", "text": "Partial"}]}]}))
    with pytest.raises(RuntimeError, match="No result"):
        asyncio.run(value.generate("gpt-6-astra", "Make notes", "Agenda Friday", []))


@pytest.mark.parametrize("model", ["gpt-transcribe", "whisper-1", "gpt-4o-transcribe-diarize"])
def test_transcription_uses_model_supported_fields_and_preserves_speaker_labels(tmp_path, monkeypatch, model):
    def response(request):
        body = request.read()
        assert model.encode() in body and b"recording.wav" in body
        if model == "gpt-4o-transcribe-diarize":
            assert b"diarized_json" in body and b"auto" in body
            assert b'name="prompt"' not in body and b'name="temperature"' not in body
            return httpx.Response(200, json={"text": "Agenda Friday. Review Monday.", "segments": [
                {"speaker": "A", "text": "Agenda Friday."}, {"speaker": "B", "text": "Review Monday."}]})
        assert b"Recognition context" in body
        assert (b'name="temperature"' in body) == (model == "whisper-1")
        return httpx.Response(200, json={"text": "Agenda Friday."})
    value = provider(tmp_path, monkeypatch, response)
    text = asyncio.run(value.transcribe(b"synthetic-audio", model, "Recognition context"))
    assert "Agenda Friday." in text
    if model == "gpt-4o-transcribe-diarize":
        assert text == "Speaker A: Agenda Friday.\nSpeaker B: Review Monday."


def test_approved_models_reach_processing_and_unknown_models_are_rejected(setup):
    w, client, p, _, (_, a), _ = setup
    me = client.get("/api/me", headers=a).json()
    assert "gpt-6-astra" in me["generation_models"] and "gpt-transcribe" in me["transcription_models"]
    assistant = client.get("/api/assistants", headers=a).json()["assistants"][0]
    assistant["model"] = "gpt-6-astra"
    path = "/api/assistants/" + assistant["id"]
    assert client.put(path, headers=a, json=assistant).status_code == 200
    assert client.put(path, headers=a, json={**assistant, "model": "unapproved"}).status_code == 422
    upload(client, a, parts=2)
    body = {**process_body(client, a), "transcription_model": "gpt-4o-transcribe-diarize"}
    assert client.post("/api/recordings/recording-1/process", headers=a, json=body).status_code == 200
    asyncio.run(w.run_next())
    record = client.get("/api/recordings/recording-1", headers=a).json()
    assert record["state"] == "ready" and record["transcription_complete"]
    assert "Audio segment 1" in record["transcript"] and "Audio segment 2" in record["transcript"]
    assert any(call[0] == "generate" and call[1] == "gpt-6-astra" for call in p.calls)
    assert client.post("/api/recordings/recording-1/process", headers=a, json={**body, "transcription_model": "unapproved"}).status_code == 422
