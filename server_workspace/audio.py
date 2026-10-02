"""Decode and join source audio in memory; never write unencrypted media to disk."""
from __future__ import annotations

import asyncio
from contextlib import aclosing
from dataclasses import dataclass
import io
import shutil
import struct
from typing import AsyncIterator
import wave


TRANSCRIPTION_VERSION = 2
SAMPLE_RATE = 16000
BYTES_PER_SECOND = SAMPLE_RATE * 2
# A compressed file can fit the upload limit while exceeding a model's output limit.
# Two minutes leaves room for fast speech and supplies context across Watch files.
MAX_SEGMENT_SECONDS = 120


class AudioError(RuntimeError):
    pass


@dataclass(frozen=True)
class AudioSegment:
    index: int
    start: float
    end: float
    audio: bytes


def wav_audio(pcm: bytes) -> bytes:
    with io.BytesIO() as output:
        with wave.open(output, "wb") as writer:
            writer.setnchannels(1)
            writer.setsampwidth(2)
            writer.setframerate(SAMPLE_RATE)
            writer.writeframes(pcm)
        return output.getvalue()


def split_position(pcm: bytes) -> int:
    """Prefer a quiet 200 ms boundary near the end; retain every sample exactly once."""
    limit = MAX_SEGMENT_SECONDS * BYTES_PER_SECOND
    window = BYTES_PER_SECOND // 5
    # Quiet boundaries need no overlapping audio or text deduplication that could drop words.
    candidates = range(limit - 8 * BYTES_PER_SECOND, limit - window + 1, window)
    for start in reversed(list(candidates)):
        samples = struct.unpack("<" + "h" * (window // 2), pcm[start:start + window])
        if sum(sample * sample for sample in samples) / len(samples) < 330 ** 2:
            return start + window // 2
    return limit


class AudioPreparer:
    def __init__(self, decoder: str | None = None):
        self.decoder = decoder

    async def decode(self, audio: bytes) -> AsyncIterator[bytes]:
        if audio.startswith(b"RIFF") and audio[8:12] == b"WAVE":
            with wave.open(io.BytesIO(audio), "rb") as reader:
                if reader.getnchannels() == 1 and reader.getsampwidth() == 2 and reader.getframerate() == SAMPLE_RATE:
                    expected = reader.getnframes() * 2
                    received = 0
                    while data := reader.readframes(128 * 1024):
                        received += len(data)
                        yield data
                    if received == 0 or received != expected:
                        raise AudioError("A source audio part could not be decoded completely")
                    return
        ffmpeg = self.decoder or shutil.which("ffmpeg")
        if not ffmpeg:
            raise AudioError("Audio decoder is unavailable on the PC")
        process = await asyncio.create_subprocess_exec(
            ffmpeg, "-nostdin", "-v", "error", "-i", "pipe:0", "-vn",
            "-ac", "1", "-ar", str(SAMPLE_RATE), "-f", "s16le", "pipe:1",
            stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL,
        )

        async def feed():
            try:
                process.stdin.write(audio)
                await process.stdin.drain()
            except (BrokenPipeError, ConnectionResetError):
                pass
            finally:
                process.stdin.close()

        writer = asyncio.create_task(feed())
        received = 0
        try:
            while data := await process.stdout.read(256 * 1024):
                received += len(data)
                if received > 4 * 3600 * BYTES_PER_SECOND:
                    raise AudioError("An audio file exceeds the supported duration")
                yield data
            await writer
            if await process.wait() != 0 or received == 0 or received % 2:
                raise AudioError("A source audio part could not be decoded completely")
        finally:
            writer.cancel()
            if process.returncode is None:
                process.kill()
            await process.wait()
            await asyncio.gather(writer, return_exceptions=True)

    async def segments(self, parts: AsyncIterator[bytes]) -> AsyncIterator[AudioSegment]:
        pending = bytearray()
        offset = 0
        index = 0
        limit = MAX_SEGMENT_SECONDS * BYTES_PER_SECOND
        async for audio in parts:
            async with aclosing(self.decode(audio)) as decoded:
                async for pcm in decoded:
                    pending.extend(pcm)
                    while len(pending) >= limit:
                        cut = split_position(pending)
                        yield AudioSegment(index, offset / BYTES_PER_SECOND,
                            (offset + cut) / BYTES_PER_SECOND, wav_audio(bytes(pending[:cut])))
                        del pending[:cut]
                        offset += cut
                        index += 1
        if pending:
            if len(pending) % 2:
                raise AudioError("Audio ended with an incomplete sample")
            yield AudioSegment(index, offset / BYTES_PER_SECOND,
                (offset + len(pending)) / BYTES_PER_SECOND, wav_audio(bytes(pending)))
