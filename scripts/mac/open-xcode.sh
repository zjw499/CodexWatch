#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJECT_PATH="$ROOT_DIR/CodexWatch.xcodeproj"

if [[ ! -d "$PROJECT_PATH" ]]; then
  echo "CodexWatch.xcodeproj is missing. Run scripts/mac/generate-project.sh first."
  exit 1
fi

open "$PROJECT_PATH"
