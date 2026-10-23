import asyncio
import time

from fastapi.testclient import TestClient

import server_workspace.workspace as module
from server_workspace.workspace import create_app
from server_workspace.tests.test_workspace import setup, upload, process_body, FixtureAudioPreparer


def test_provider_deadline_preserves_checkpoints_and_retry_resumes_only_missing_audio(setup, monkeypatch):
    w, c, p, _, (_, headers), _ = setup
    upload(c, headers, parts=2)
    body = process_body(c, headers)
    c.post('/api/recordings/recording-1/process', headers=headers, json=body)
    monkeypatch.setattr(module, 'TRANSCRIPTION_TIMEOUT_SECONDS', 0.01)
    calls = []

    async def transcribe(audio, *args):
        calls.append(audio)
        if len(calls) == 1:
            return 'First section, saved.'
        await asyncio.Event().wait()

    p.transcribe = transcribe
    asyncio.run(w.run_next())
    result = c.get('/api/recordings/recording-1', headers=headers).json()
    assert result['state'] == 'failed' and 'timed out' in result['error']
    assert result['transcribed_seconds'] == 30 and not result['transcription_complete']
    with w.db() as db:
        row = db.execute('SELECT content FROM recordings').fetchone()
        assert w.decode(row[0])['checkpoints'] == {'0': 'First section, saved.'}
        assert db.execute('SELECT COUNT(*) FROM parts').fetchone()[0] == 2

    async def recovered(audio, *args):
        calls.append(audio)
        return 'Second section, recovered.'

    p.transcribe = recovered
    c.post('/api/recordings/recording-1/process', headers=headers, json=body)
    asyncio.run(w.run_next())
    result = c.get('/api/recordings/recording-1', headers=headers).json()
    assert result['state'] == 'ready' and result['transcription_complete']
    assert result['transcribed_seconds'] == 60 and result['processing_stage'] == 'complete'
    assert result['transcript'] == 'First section, saved.\n\nSecond section, recovered.'
    assert calls.count(b'audio0') == 1 and calls.count(b'audio1') == 3


def test_decoder_deadline_does_not_leave_a_recording_processing_forever(setup, monkeypatch):
    w, c, p, _, (_, headers), _ = setup
    upload(c, headers)
    c.post('/api/recordings/recording-1/process', headers=headers, json=process_body(c, headers))

    class StalledDecoder(FixtureAudioPreparer):
        async def segments(self, parts):
            await asyncio.Event().wait()
            yield  # Keep this an async iterator.

    w.audio_preparer = StalledDecoder()
    monkeypatch.setattr(module, 'DECODE_TIMEOUT_SECONDS', 0.01)
    asyncio.run(w.run_next())
    result = c.get('/api/recordings/recording-1', headers=headers).json()
    assert result['state'] == 'failed' and 'timed out' in result['error']
    assert not result.get('transcription_complete') and p.calls == []


def test_health_detects_a_stalled_job_without_resetting_it_in_other_gateways(setup):
    w, c, _, _, (_, headers), _ = setup
    upload(c, headers)
    with w.db() as db:
        db.execute("UPDATE recordings SET state='processing',updated=?", (time.time() - module.PROCESSING_STALL_SECONDS - 10,))
    assert c.get('/api/health').status_code == 200  # A gateway runs no worker.
    with TestClient(create_app(w)) as worker:
        assert worker.get('/api/health').status_code == 503
        with w.db() as db:
            assert db.execute('SELECT state FROM recordings').fetchone()[0] == 'processing'


def test_summary_stage_keeps_full_transcript_when_generation_times_out(setup, monkeypatch):
    w, c, p, _, (_, headers), _ = setup
    upload(c, headers)
    c.post('/api/recordings/recording-1/process', headers=headers, json=process_body(c, headers))
    monkeypatch.setattr(module, 'GENERATION_TIMEOUT_SECONDS', 0.01)
    seen = []

    async def generate(*args):
        value = c.get('/api/recordings/recording-1', headers=headers).json()
        seen.append(value['processing_stage'])
        assert value['transcription_complete'] and value['transcribed_seconds'] == 30
        await asyncio.Event().wait()

    p.generate = generate
    asyncio.run(w.run_next())
    result = c.get('/api/recordings/recording-1', headers=headers).json()
    assert result['state'] == 'failed' and result['transcription_complete']
    assert 'Alex' in result['transcript'] and seen == ['summarizing', 'retrying']
