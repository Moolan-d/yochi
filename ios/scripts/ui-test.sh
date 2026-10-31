#!/bin/sh
# Runs the UI tests in the simulator against a throwaway Gateway: its own port
# (7421) and state dir, so a Gateway already running on 7420 is left alone.
# Each test gets a fresh pairing code. Screenshots land in build/ui-test-shots/.
set -eu
cd "$(dirname "$0")/.."

SIM=${SIM:-iPhone 17 Pro}
# By name alone xcodebuild wants the newest OS, which may not have this model.
sim_id=$(xcrun simctl list devices available | grep -m1 "    $SIM (" | grep -oE '[0-9A-F-]{36}') || {
    echo "no simulator named $SIM" >&2; exit 1; }
DESTINATION="id=$sim_id"
GATEWAY=../gateway/target/debug/companion-gateway
RESULTS=build/ui-test-results
SHOTS=build/ui-test-shots

(cd ../gateway && cargo build -q)
xcodegen generate -q

state=$(mktemp -d)
export COMPANION_STATE_DIR="$state"
export COMPANION_LISTEN="$(tailscale ip -4 | head -1):7421"
"$GATEWAY" > "$state/gateway.log" 2>&1 &
gateway=$!
pairing=
trap 'kill $gateway $pairing 2>/dev/null; rm -rf "$state"' EXIT

rm -rf "$RESULTS" "$SHOTS"
mkdir -p "$RESULTS" "$SHOTS"
xcodebuild -project Companion.xcodeproj -scheme Companion -destination "$DESTINATION" \
    -derivedDataPath build -quiet build-for-testing

failed=0
for test in testPairObserveAndUnpair testInviteLinkReplacesPairing; do
    "$GATEWAY" pair > "$state/pair.log" 2>&1 &
    pairing=$!
    until grep -q "Code " "$state/pair.log"; do sleep 0.2; done
    code=$(awk '/Code /{print $2}' "$state/pair.log")

    echo "== $test"
    TEST_RUNNER_COMPANION_HOST="$COMPANION_LISTEN" TEST_RUNNER_COMPANION_CODE="$code" \
        xcodebuild -project Companion.xcodeproj -scheme Companion -destination "$DESTINATION" \
        -derivedDataPath build -quiet test-without-building \
        -only-testing:"CompanionUITests/CompanionUITests/$test" \
        -resultBundlePath "$RESULTS/$test.xcresult" || failed=1
    xcrun xcresulttool export attachments --path "$RESULTS/$test.xcresult" \
        --output-path "$SHOTS/$test" > /dev/null || true
    kill "$pairing" 2>/dev/null || true
done

# Every test ends unpaired; a device left behind means unpairing broke.
if ! "$GATEWAY" devices | grep -q "No paired devices"; then
    echo "devices left paired:" >&2
    "$GATEWAY" devices >&2
    failed=1
fi
echo "Gateway log:"; sed 's/^/  /' "$state/gateway.log"
exit $failed
