import asyncio
import base64

import pytest

from server_workspace.voice_stream import PacedVoiceEvents, VoiceStreamOverflow


def test_fast_reply_burst_is_paced_in_small_packets_without_catchup():
    async def prove():
        now = [0.0]
        stream = PacedVoiceEvents(clock=lambda: now[0])
        # Six seconds generated at once exceeded the previous four-second limit.
        source = bytes(range(256)) * 1125
        stream.put("audio", item_id="answer", audio=base64.b64encode(source).decode())
        received = bytearray()
        for index in range(30):
            event = await asyncio.wait_for(stream.get(), 0.1)
            data = base64.b64decode(event["audio"])
            assert len(data) == 9600
            received.extend(data)
            assert stream.next_audio_at == pytest.approx(now[0] + 0.2)
            now[0] = stream.next_audio_at
            if index == 4:
                now[0] += 5  # A transport stall does not release a catch-up burst.
        assert received == source
        assert stream.audio_bytes == 0
    asyncio.run(prove())


def test_captions_coalesce_and_interrupt_bypasses_pacing_and_discards_unheard_audio():
    async def prove():
        stream = PacedVoiceEvents()
        stream.put("audio", item_id="old", audio=base64.b64encode(bytes(48000)).decode())
        for index in range(400):
            stream.put("turn", turn={"id": "turn", "text": str(index)})
        assert len(stream.controls) == 1
        assert (await stream.get())["turn"]["text"] == "399"
        assert (await stream.get())["type"] == "audio"
        waiting = asyncio.create_task(stream.get())
        await asyncio.sleep(0)
        stream.discard_audio("old")
        stream.put("interrupt", item_id="old")
        assert (await asyncio.wait_for(waiting, 0.1))["type"] == "interrupt"
        assert stream.audio_bytes == 0
        stream.put("audio", item_id="new", audio=base64.b64encode(bytes(9600)).decode())
        assert (await asyncio.wait_for(stream.get(), 0.1))["item_id"] == "new"
    asyncio.run(prove())


def test_audio_memory_is_bounded_and_end_clears_buffered_reply():
    async def prove():
        stream = PacedVoiceEvents()
        stream.put("audio", item_id="answer", audio=base64.b64encode(bytes(stream.audio_limit)).decode())
        with pytest.raises(VoiceStreamOverflow):
            stream.put("audio", item_id="answer", audio=base64.b64encode(bytes(2)).decode())
        assert stream.audio_bytes == stream.audio_limit
        stream.clear()
        stream.put("ended", message="Saved")
        assert (await stream.get())["type"] == "ended"
        assert stream.audio_bytes == 0 and not stream.audio
    asyncio.run(prove())


def test_provider_completion_waits_for_buffered_audio_but_interrupt_does_not():
    async def prove():
        now = [0.0]
        stream = PacedVoiceEvents(clock=lambda: now[0])
        stream.put("state", state="speaking")
        stream.put("audio", item_id="answer", audio=base64.b64encode(bytes(19200)).decode())
        stream.put("state", state="listening")
        assert (await stream.get())["state"] == "speaking"
        assert (await stream.get())["type"] == "audio"
        now[0] = 0.2
        assert (await stream.get())["type"] == "audio"
        assert (await stream.get())["state"] == "listening"
    asyncio.run(prove())


def test_each_reply_completion_follows_its_pcm_before_the_next_tool_reply():
    async def prove():
        now = [0.0]
        stream = PacedVoiceEvents(clock=lambda: now[0])
        for item in ('preamble', 'answer'):
            stream.put('audio', item_id=item, audio=base64.b64encode(bytes(19200)).decode())
            stream.put('audio_done', item_id=item)
        received = []
        for _ in range(6):
            event = await asyncio.wait_for(stream.get(), 0.1)
            received.append((event['type'], event['item_id']))
            now[0] = stream.next_audio_at
        assert received == [('audio', 'preamble'), ('audio', 'preamble'), ('audio_done', 'preamble'),
                            ('audio', 'answer'), ('audio', 'answer'), ('audio_done', 'answer')]
    asyncio.run(prove())


def test_interrupt_removes_a_buffered_reply_completion_too():
    async def prove():
        stream = PacedVoiceEvents()
        stream.put('audio', item_id='old', audio=base64.b64encode(bytes(9600)).decode())
        stream.put('audio_done', item_id='old')
        assert stream.discard_audio('old') == 9600
        stream.put('interrupt', item_id='old')
        assert (await stream.get())['type'] == 'interrupt'
        assert not stream.audio and not stream.controls
    asyncio.run(prove())
