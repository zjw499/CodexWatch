"""Validate extracted App Intents metadata without depending on private JSON keys."""
import argparse
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("metadata", type=Path)
args = parser.parse_args()
files = list(args.metadata.rglob("*"))
payloads = [path.read_bytes() for path in files if path.is_file() and path.stat().st_size < 5_000_000]
for name in (b"TalkWatchAssistantIntent", b"EndWatchVoiceIntent", b"StartWatchRecordingIntent"):
    if not any(name in value for value in payloads):
        raise SystemExit("Missing Watch App Intent metadata: " + name.decode())
print("Watch voice and recording App Intents metadata verified")
