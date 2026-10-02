import asyncio
import io
import struct
import wave

import pytest

from server_workspace.audio import AudioError, AudioPreparer, BYTES_PER_SECOND, wav_audio
from server_workspace.workspace import OpenAIProvider, WorkspaceConfig
from server_workspace.tests.test_workspace import process_body, setup, upload


def test_short_watch_parts_join_and_long_files_cover_every_sample_in_order():
    # Distinct samples allow an exact no-drop/no-duplication check across every boundary.
    pcm = b"".join(struct.pack("<h", n % 20000 + 1000) for n in range(245 * 16000))
    async def parts():
        # Simulate a whole phone file followed by separate Watch-sized parts.
        for start, end in [(0, 130), (130, 160), (160, 190), (190, 220), (220, 245)]:
            yield wav_audio(pcm[start * BYTES_PER_SECOND:end * BYTES_PER_SECOND])
    async def prepared():
        return [segment async for segment in AudioPreparer().segments(parts())]
    segments = asyncio.run(prepared())
    restored = bytearray()
    end = 0
    for segment in segments:
        assert segment.start == end
        assert 0 < segment.end - segment.start <= 120
        assert len(segment.audio) < 25_000_000
        with wave.open(io.BytesIO(segment.audio), "rb") as reader:
            restored.extend(reader.readframes(reader.getnframes()))
        end = segment.end
    assert bytes(restored) == pcm
    assert end == 245


def test_quiet_boundaries_and_tiny_final_tail_are_preserved():
    pcm = b"\0\0" * (240 * 16000 + 1)
    async def parts():
        yield wav_audio(pcm)
    async def prepared():
        return [segment async for segment in AudioPreparer().segments(parts())]
    segments = asyncio.run(prepared())
    assert segments[-1].end == 240 + 1/16000
    assert sum(round((s.end - s.start) * 16000) for s in segments) == 240 * 16000 + 1


def test_truncated_audio_fails_instead_of_claiming_completion():
    audio = wav_audio(b"\0\0" * 16000)[:-1000]
    async def parts():
        yield audio
    async def prepared():
        return [segment async for segment in AudioPreparer().segments(parts())]
    with pytest.raises(AudioError):
        asyncio.run(prepared())


def test_saved_old_checkpoints_are_replaced_and_explicit_retranscription_works(setup):
    w, c, p, _, (_, a), _ = setup
    upload(c, a, parts=2)
    with w.db() as db:
        row = db.execute("SELECT * FROM recordings").fetchone()
        data = w.decode(row["content"])
        data.update({"transcription_version": 1, "transcription_model": "gpt-4o-mini-transcribe", "checkpoints": {"0": "Old incomplete text"}})
        db.execute("UPDATE recordings SET content=?", (w.encode(data),))
    body = process_body(c, a)
    body["transcription_context"] = "OpenAI, Scribe Pilot"
    assert c.post("/api/recordings/recording-1/process", headers=a, json=body).status_code == 200
    asyncio.run(w.run_next())
    result = c.get("/api/recordings/recording-1", headers=a).json()
    assert "Old incomplete" not in result["transcript"]
    assert result["transcription_complete"] and result["transcribed_seconds"] == 60
    assert "transcription_context" not in result and "checkpoint_audio_hashes" not in result
    count = sum(call[0] == "transcribe" for call in p.calls)
    assert c.post("/api/recordings/recording-1/process", headers=a, json=body).status_code == 200
    asyncio.run(w.run_next())
    assert sum(call[0] == "transcribe" for call in p.calls) == count
    body["retranscribe"] = True
    c.post("/api/recordings/recording-1/process", headers=a, json=body)
    asyncio.run(w.run_next())
    assert sum(call[0] == "transcribe" for call in p.calls) == count + 2


def test_full_transcript_survives_result_generation_failure(setup):
    w, c, p, _, (_, a), _ = setup
    upload(c, a, parts=2)
    async def fail(*args):
        raise RuntimeError("Synthetic generation failure")
    p.generate = fail
    c.post("/api/recordings/recording-1/process", headers=a, json=process_body(c, a))
    asyncio.run(w.run_next())
    result = c.get("/api/recordings/recording-1", headers=a).json()
    assert result["state"] == "failed"
    assert result["transcript"].count("Alex") == 2
    assert result["transcription_complete"] is True


def test_missing_final_upload_is_rejected_before_any_provider_call(setup):
    _, c, p, _, (_, a), _ = setup
    c.put("/api/recordings/incomplete", headers=a, json={"title": "Incomplete", "source": "Apple Watch", "expected_parts": 3})
    for index in (0, 2):
        c.put(f"/api/recordings/incomplete/parts/{index}", headers=a, content=b"audio")
    assert c.post("/api/recordings/incomplete/process", headers=a, json=process_body(c, a)).status_code == 409
    assert p.calls == []


def test_provider_discards_capped_output_and_recovers_both_halves(tmp_path, monkeypatch):
    import httpx
    original = httpx.AsyncClient
    calls = []
    def response(request):
        body = request.read()
        calls.append(body)
        number = len(calls)
        return httpx.Response(200, json={"text": ["Capped partial response", "First half", "Final half"][number - 1],
            "usage": {"output_tokens": 2000 if number == 1 else 10}})
    monkeypatch.setattr(httpx, "AsyncClient", lambda **kwargs: original(transport=httpx.MockTransport(response), **kwargs))
    provider = OpenAIProvider(WorkspaceConfig(tmp_path, tmp_path / "unused"))
    monkeypatch.setattr(provider, "headers", lambda: {})
    text = asyncio.run(provider.transcribe(wav_audio(b"\0\0" * (20 * 16000)), "gpt-4o-transcribe", "Verbatim speech"))
    assert text == "First half\nFinal half"
    assert len(calls) == 3
    assert all(b"recording.wav" in call and b"Verbatim speech" in call for call in calls)
