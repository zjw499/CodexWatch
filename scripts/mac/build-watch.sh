#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

CONFIGURATION="${CONFIGURATION:-Debug}"
DESTINATION="${DESTINATION:-generic/platform=watchOS}"
ALLOW_PROVISIONING="${ALLOW_PROVISIONING:-YES}"

if [[ ! -d "$ROOT_DIR/CodexWatch.xcodeproj" ]]; then
  echo "CodexWatch.xcodeproj is missing. Run scripts/mac/generate-project.sh first."
  exit 1
fi

CMD=(
  xcodebuild
  -project "$ROOT_DIR/CodexWatch.xcodeproj"
  -scheme CodexWatch
  -configuration "$CONFIGURATION"
  -destination "$DESTINATION"
  build
)

if [[ "$ALLOW_PROVISIONING" == "YES" ]]; then
  CMD+=(-allowProvisioningUpdates)
fi

"${CMD[@]}"
