#!/bin/sh
# Re-records the JSON parse results for the captured Claude Code screens.
# Run from anywhere; SIM selects the simulator (default: iPhone 18 Pro).
set -eu
cd "$(dirname "$0")/.."

SIM=${SIM:-iPhone 18 Pro}
sim_id=$(xcrun simctl list devices available | grep -m1 "    $SIM (" | grep -oE '[0-9A-F-]{36}') || {
    echo "no simulator named $SIM" >&2
    exit 1
}

# The test reads this marker through #filePath, so recording does not depend
# on xcodebuild forwarding an environment variable to the test host.
marker=YochiTests/Fixtures/snapshots/.record
trap 'rm -f "$marker"' EXIT HUP INT TERM
mkdir -p "$(dirname "$marker")"
: > "$marker"

xcodegen generate -q
xcodebuild test \
    -project Yochi.xcodeproj \
    -scheme Yochi \
    -destination "id=$sim_id" \
    -derivedDataPath build \
    -only-testing:YochiTests/DialogFixtureTests

echo "Recorded YochiTests/Fixtures/snapshots/claude/*.json; review the diff before committing."
