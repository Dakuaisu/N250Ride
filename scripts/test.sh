#!/usr/bin/env bash
# Reproducible test entry point.
#
#   scripts/test.sh core   # RideCore package tests (works with Command Line Tools only)
#   scripts/test.sh app    # iOS app tests on a simulator (needs full Xcode)
#   scripts/test.sh all
#
# Env for `app`: SIMULATOR_UDID (default: first available iPhone simulator),
#                RESULT_BUNDLE (default: fresh path under the evidence root).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EVIDENCE="${EVIDENCE_DIR:-$ROOT/.omo/evidence/n250-ios-navigation}"
CLT_FRAMEWORKS=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
CLT_LIBS=/Library/Developer/CommandLineTools/Library/Developer/usr/lib

# Prefer an installed, licence-accepted Xcode without needing `sudo xcode-select`.
XCODE_DEV=/Applications/Xcode.app/Contents/Developer
if [[ -z "${DEVELOPER_DIR:-}" && "$(xcode-select -p)" == *CommandLineTools* ]] \
  && DEVELOPER_DIR="$XCODE_DEV" xcodebuild -showsdks > /dev/null 2>&1; then
  export DEVELOPER_DIR="$XCODE_DEV"
fi

has_xcode() {
  xcodebuild -showsdks > /dev/null 2>&1
}

core() {
  if has_xcode; then
    swift test --package-path "$ROOT/Packages/RideCore"
  else
    # Command Line Tools ship Swift Testing but SwiftPM does not find it on its own,
    # and the default build system cannot initialise without Xcode.
    swift test --package-path "$ROOT/Packages/RideCore" --build-system native \
      -Xswiftc -F"$CLT_FRAMEWORKS" -Xlinker -F"$CLT_FRAMEWORKS" \
      -Xlinker -rpath -Xlinker "$CLT_FRAMEWORKS" -Xlinker -rpath -Xlinker "$CLT_LIBS"
  fi
}

app() {
  if ! has_xcode; then
    echo "BLOCKED: full Xcode is not installed/selected (xcode-select -p: $(xcode-select -p))." >&2
    echo "Install Xcode from the App Store, then: sudo xcode-select -s /Applications/Xcode.app" >&2
    exit 2
  fi
  command -v xcodegen > /dev/null || { echo "BLOCKED: xcodegen missing (brew install xcodegen)" >&2; exit 2; }
  (cd "$ROOT" && xcodegen generate --quiet)
  local udid="${SIMULATOR_UDID:-$(xcrun simctl list devices available -j \
    | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin)["devices"]; print(next(x["udid"] for r in d for x in d[r] if x["name"].startswith("iPhone")))')}"
  local bundle="${RESULT_BUNDLE:-$EVIDENCE/app-tests-$(date +%Y%m%d-%H%M%S).xcresult}"
  # A granted location permission makes the map's live position dot animate
  # nonstop, and XCUITest then waits ~60 s for the app to go idle before every tap.
  xcrun simctl privacy "$udid" reset location > /dev/null 2>&1 || true
  echo "simulator: $udid"
  echo "result bundle: $bundle"
  xcodebuild test -project "$ROOT/N250Ride.xcodeproj" -scheme N250Ride \
    -destination "platform=iOS Simulator,id=$udid" -resultBundlePath "$bundle"
}

case "${1:-core}" in
  core) core ;;
  app) app ;;
  all) core && app ;;
  *) echo "usage: $0 [core|app|all]" >&2; exit 64 ;;
esac
