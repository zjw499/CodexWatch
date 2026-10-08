"""Bounded in-memory reply buffering with paced PCM delivery and prompt controls."""
from collections import deque
import asyncio
import base64
import time


class VoiceStreamOverflow(Exception):
    pass


class PacedVoiceEvents:
    # Provider generation can run ahead of playback. Keep at most 30 seconds on
    # the PC, and send 200 ms at a time without catching up after a network stall.
    audio_limit = 30 * 48000
    packet_bytes = 9600
    control_limit = 128

    def __init__(self, clock=time.monotonic):
        self.clock = clock
        self.controls = deque()
        self.audio = deque()
        self.audio_bytes = 0
        self.peak_audio_bytes = 0
        self.next_audio_at = 0.0
        self.wake = asyncio.Event()

    def put(self, kind, **fields):
        if kind == "audio":
            data = base64.b64decode(fields["audio"], validate=True)
            if not data or len(data) % 2:
                raise ValueError("PCM16 reply required")
            if self.audio_bytes + len(data) > self.audio_limit:
                raise VoiceStreamOverflow()
            self.audio.append((fields["item_id"], data))
            self.audio_bytes += len(data)
            self.peak_audio_bytes = max(self.peak_audio_bytes, self.audio_bytes)
        else:
            # Captions/state are snapshots. Superseded deltas must not consume
            # the bounded control queue while a generated answer is buffered.
            for index, event in enumerate(self.controls):
                if (kind == "state" and event["type"] == "state" and event["state"] == fields["state"]) or (
                    kind == "turn" and event["type"] == "turn" and event["turn"]["id"] == fields["turn"]["id"]
                ):
                    # Retain the first placeholder's position so late input
                    # transcription cannot put an answer before its question.
                    self.controls[index] = {"type": kind, **fields}
                    self.wake.set()
                    return
            if len(self.controls) >= self.control_limit:
                raise VoiceStreamOverflow()
            self.controls.append({"type": kind, **fields})
        self.wake.set()

    def discard_audio(self, item):
        discarded = sum(len(data) for key, data in self.audio if key == item)
        self.audio = deque((key, data) for key, data in self.audio if key != item)
        self.controls = deque(event for event in self.controls
                              if not (event['type'] == 'audio_done' and event['item_id'] == item))
        self.audio_bytes = sum(len(data) for _, data in self.audio)
        self.next_audio_at = self.clock()
        self.wake.set()
        return discarded

    def clear(self):
        self.controls.clear()
        self.audio.clear()
        self.audio_bytes = 0
        self.next_audio_at = self.clock()
        self.wake.set()

    async def get(self):
        while True:
            for index, event in enumerate(self.controls):
                # Provider completion is earlier than playback completion. Keep
                # listening behind queued audio so older clients do not send a
                # new playback acknowledgement for every 200 ms fragment.
                if event["type"] == "state" and event["state"] == "listening" and self.audio:
                    continue
                # Completion belongs behind its own PCM, even when another
                # reply/tool continuation is already queued.
                if event["type"] == "audio_done" and any(key == event["item_id"] for key, _ in self.audio):
                    continue
                del self.controls[index]
                return event
            now = self.clock()
            if self.audio and now >= self.next_audio_at:
                item, data = self.audio.popleft()
                packet, remaining = data[:self.packet_bytes], data[self.packet_bytes:]
                if remaining:
                    self.audio.appendleft((item, remaining))
                self.audio_bytes -= len(packet)
                self.next_audio_at = now + len(packet) / 48000
                return {"type": "audio", "item_id": item, "audio": base64.b64encode(packet).decode()}
            self.wake.clear()
            # No await occurs between checking queues and clearing the wake flag.
            if self.audio:
                try:
                    await asyncio.wait_for(self.wake.wait(), max(0, self.next_audio_at - now))
                except asyncio.TimeoutError:
                    pass
            else:
                await self.wake.wait()
