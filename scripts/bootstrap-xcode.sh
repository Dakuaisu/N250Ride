#!/usr/bin/env bash
# One-shot setup after Xcode is installed and its licence accepted:
#   sudo xcode-select -s /Applications/Xcode.app && sudo xcodebuild -license accept && sudo xcodebuild -runFirstLaunch   (owner, once)
#   scripts/bootstrap-xcode.sh
#
# Uses DEVELOPER_DIR instead of `sudo xcode-select`, installs the iOS simulator
# platform if missing, generates the project, resolves packages and runs all tests.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
XCODE="${XCODE_APP:-/Applications/Xcode.app}"
export DEVELOPER_DIR="$XCODE/Contents/Developer"
EVIDENCE="$ROOT/.omo/evidence/n250-ios-navigation"

if ! xcodebuild -checkFirstLaunchStatus; then
  echo "Xcode first-launch tasks pending. Run once: sudo xcode-select -s /Applications/Xcode.app && sudo xcodebuild -license accept && sudo xcodebuild -runFirstLaunch" >&2
  exit 2
fi

xcodebuild -version
if ! xcrun simctl list runtimes | grep -q "iOS"; then
  echo "Installing iOS simulator platform..."
  xcodebuild -downloadPlatform iOS
fi

(cd "$ROOT" && xcodegen generate --quiet)
xcodebuild -resolvePackageDependencies -project "$ROOT/N250Ride.xcodeproj" -scheme N250Ride

"$ROOT/scripts/test.sh" core
RESULT_BUNDLE="$EVIDENCE/app-tests-$(date +%Y%m%d-%H%M%S).xcresult" "$ROOT/scripts/test.sh" app
