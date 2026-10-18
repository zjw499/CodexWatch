"""Validate shared App Intents and Siri description restrictions before delivery."""
import argparse
from pathlib import Path
import re

INTENTS = ("TalkWatchAssistantIntent", "EndWatchVoiceIntent", "StartRecordingIntent", "StopRecordingIntent",
           "ResumeWatchRecordingIntent", "RetryWatchUploadIntent", "OpenScribePilotIntent",
           "StartWatchRecordingIntent", "StopWatchRecordingIntent", "VoiceAssistantEntity")


def validate_descriptions(source):
    # App Store processing rejects these device names in Siri descriptions
    # (ITMS-90626), even when Xcode accepts the archive. Ordinary UI copy is fine.
    for match in re.finditer(r'IntentDescription\s*\(\s*"((?:\\.|[^"\\])*)"', source, re.DOTALL):
        if re.search(r"\b(?:apple|iphone)\b", match.group(1), re.IGNORECASE):
            raise ValueError("Siri descriptions must use neutral device names (ITMS-90626)")


def validate_metadata(path):
    payloads = [p.read_bytes() for p in path.rglob("*") if p.is_file() and p.stat().st_size < 5_000_000]
    for name in INTENTS:
        if not any(name.encode() in value for value in payloads):
            raise ValueError("Missing shared App Intent metadata: " + name)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("metadata", type=Path, nargs="?")
    parser.add_argument("--source-only", action="store_true")
    args = parser.parse_args()
    if not args.source_only and args.metadata is None:
        parser.error("Pass extracted metadata or --source-only")
    root = Path(__file__).resolve().parent.parent
    try:
        for folder in ("ios", "watchos", "shared"):
            for source in (root / folder).rglob("*.swift"):
                validate_descriptions(source.read_text(encoding="utf-8"))
        if args.metadata is not None:
            validate_metadata(args.metadata)
    except ValueError as error:
        raise SystemExit(str(error)) from None
    print("Shared phone/Watch Siri descriptions, voice, recording and compatibility metadata verified")


if __name__ == "__main__":
    main()
