#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen is not installed. Run scripts/mac/bootstrap-mac.sh first."
  exit 1
fi

xcodegen generate
echo "Generated $ROOT_DIR/CodexWatch.xcodeproj"
