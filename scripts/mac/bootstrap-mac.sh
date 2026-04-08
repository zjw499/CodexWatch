#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

echo "==> Checking Xcode"
if ! xcodebuild -version >/dev/null 2>&1; then
  echo "Xcode is not installed or not configured. Install Xcode from the App Store, open it once, and rerun this script."
  exit 1
fi

echo "==> Selecting Xcode"
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer

echo "==> Running first-launch setup"
sudo xcodebuild -runFirstLaunch

echo "==> Checking Homebrew"
if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew is missing."
  echo "Install it with:"
  echo '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
  exit 1
fi

echo "==> Checking XcodeGen"
if ! command -v xcodegen >/dev/null 2>&1; then
  brew install xcodegen
fi

if [[ ! -f "$ROOT_DIR/macos/CodexWatch/Config/Local.xcconfig" ]]; then
  cp "$ROOT_DIR/macos/CodexWatch/Config/Local.example.xcconfig" "$ROOT_DIR/macos/CodexWatch/Config/Local.xcconfig"
  echo "Created macos/CodexWatch/Config/Local.xcconfig from template."
fi

echo "Bootstrap complete."
echo "Next:"
echo "  1. Fill in macos/CodexWatch/Config/Local.xcconfig"
echo "  2. Run scripts/mac/generate-project.sh"
echo "  3. Open the generated Xcode project and set the signing team"
