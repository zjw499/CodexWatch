#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

if [[ ! -d "$ROOT_DIR/CodexWatch.xcodeproj" ]]; then
  echo "CodexWatch.xcodeproj is missing. Run scripts/mac/generate-project.sh first."
  exit 1
fi

xcodebuild \
  -project "$ROOT_DIR/CodexWatch.xcodeproj" \
  -scheme CodexWatch \
  -showdestinations
