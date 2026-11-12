#!/usr/bin/env bash
# Regenerates RideCore's golden packet vectors from the pinned Ride Relay encoder.
# Development-only oracle: Java is never an app/runtime dependency.
#
#   scripts/oracle/generate-vectors.sh            # write the vectors file
#   scripts/oracle/generate-vectors.sh --check    # regenerate and diff, exit 1 on drift
#
# Env: RIDE_RELAY_DIR (existing checkout, else cloned to scripts/oracle/.upstream),
#      JAVA_HOME (defaults to Homebrew openjdk when present).
set -euo pipefail

PIN=530632e4ae116645a16710a15f73e492159a7699
REPO_URL=https://github.com/manov-ik/ride-relay.git
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ORACLE="$ROOT/scripts/oracle"
OUT="$ROOT/Packages/RideCore/Tests/RideCoreTests/Resources/golden-vectors.json"
UPSTREAM="${RIDE_RELAY_DIR:-$ORACLE/.upstream}"

if [[ -z "${JAVA_HOME:-}" && -x /opt/homebrew/opt/openjdk/bin/java ]]; then
  JAVA_HOME=/opt/homebrew/opt/openjdk
fi
JAVA="${JAVA_HOME:+$JAVA_HOME/bin/}java"
JAVAC="${JAVA_HOME:+$JAVA_HOME/bin/}javac"

if [[ ! -d "$UPSTREAM/.git" ]]; then
  git clone --quiet "$REPO_URL" "$UPSTREAM"
fi
git -C "$UPSTREAM" checkout --quiet "$PIN"
HEAD="$(git -C "$UPSTREAM" rev-parse HEAD)"
if [[ "$HEAD" != "$PIN" ]]; then
  echo "upstream HEAD $HEAD does not match pin $PIN" >&2
  exit 1
fi

SRC="$UPSTREAM/app/src/com/bajajnav/relay"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

"$JAVAC" -nowarn -encoding UTF-8 -d "$BUILD" \
  "$SRC/TbtFrame.java" "$SRC/Pack.java" "$SRC/GeneralPacket.java" \
  "$ORACLE/stubs/android/os/Build.java" "$ORACLE/stubs/com/bajajnav/relay/PhoneBridge.java" \
  "$ORACLE/VectorGen.java"
"$JAVA" -cp "$BUILD" com.bajajnav.relay.VectorGen "$PIN" > "$BUILD/vectors.json"

echo "upstream commit: $HEAD"
shasum -a 256 "$SRC/TbtFrame.java" "$SRC/Pack.java" "$SRC/GeneralPacket.java" | sed "s|$UPSTREAM/||"
"$JAVA" -version 2>&1 | head -1

if [[ "${1:-}" == "--check" ]]; then
  if diff -q "$OUT" "$BUILD/vectors.json" > /dev/null; then
    echo "vectors match: $(shasum -a 256 "$OUT" | cut -d' ' -f1)"
  else
    echo "vectors DRIFTED from $OUT" >&2
    exit 1
  fi
else
  cp "$BUILD/vectors.json" "$OUT"
  echo "wrote $OUT: $(shasum -a 256 "$OUT" | cut -d' ' -f1)"
fi
