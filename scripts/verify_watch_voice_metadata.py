"""Validate extracted App Intents metadata without depending on private JSON keys."""
import argparse
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("metadata", type=Path)
args = parser.parse_args()
files = list(args.metadata.rglob("*"))
payloads = [path.read_bytes() for path in files if path.is_file() and path.stat().st_size < 5_000_000]
for name in (b"TalkWatchAssistantIntent", b"EndWatchVoiceIntent", b"StartRecordingIntent", b"StopRecordingIntent",
             b"ResumeWatchRecordingIntent", b"RetryWatchUploadIntent", b"OpenScribePilotIntent",
             b"StartWatchRecordingIntent", b"StopWatchRecordingIntent", b"VoiceAssistantEntity"):
    if not any(name in value for value in payloads):
        raise SystemExit("Missing shared App Intent metadata: " + name.decode())
print("Shared phone/Watch voice, recording, assistant selection and compatibility App Intents verified")
