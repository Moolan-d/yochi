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
# Cleanup by the unique name, not by parsed ids: a bad parse must not leak the
# terminal. UI-test messages only ever go to this terminal.
test_terminal=companion-uitest
test_session=
trap 'kill $gateway $pairing 2>/dev/null; hc kill companion-uitest >/dev/null 2>&1 || true; hc kill companion-uitest-alt >/dev/null 2>&1 || true; rm -rf "$state"' EXIT

run_output=$(hc run --bg --rm --no-parent --no-notify --name "$test_terminal" --json -- /bin/cat)
test_session=$(printf '%s' "$run_output" | python3 -c 'import json,sys; d=json.load(sys.stdin); t=d.get("terminal",d.get("address",d.get("id"))); print(t.get("address") if isinstance(t,dict) else t)')

rm -rf "$RESULTS" "$SHOTS"
mkdir -p "$RESULTS" "$SHOTS"
xcrun simctl bootstatus "$sim_id" -b > /dev/null
xcodebuild -project Companion.xcodeproj -scheme Companion -destination "$DESTINATION" \
    -derivedDataPath build -quiet build-for-testing

failed=0
xcodebuild -project Companion.xcodeproj -scheme Companion -destination "$DESTINATION" \
    -derivedDataPath build -quiet test-without-building \
    -only-testing:CompanionTests \
    -resultBundlePath "$RESULTS/unit-tests.xcresult" || failed=1

# A terminal on the alternate screen, for the takeover test: its absolute
# cursor positions are what a phone-width reflow cannot keep.
start_alt_session() {
    hc run --bg --rm --no-parent --no-notify --name companion-uitest-alt --json \
        -- /bin/sh -c 'tput smcup; exec /bin/cat' |
        python3 -c 'import json,sys; d=json.load(sys.stdin); t=d.get("terminal",d.get("address",d.get("id"))); print(t.get("address") if isinstance(t,dict) else t)'
}

# TESTS="testA testB" runs a subset.
for test in ${TESTS:-testPairObserveAndUnpair testInviteLinkReplacesPairing testAgentMessageIsAccepted testTerminalKeysArePressed testAgentMessageDraftSurvivesNavigation testNewSessionSheet testTakeOverFullScreen}; do
    "$GATEWAY" pair > "$state/pair.log" 2>&1 &
    pairing=$!
    until grep -q "Code " "$state/pair.log"; do sleep 0.2; done
    code=$(awk '/Code /{print $2}' "$state/pair.log")

    echo "== $test"
    extra=
    if [ "$test" = testTakeOverFullScreen ]; then
        alt_session=$(start_alt_session)
        extra="TEST_RUNNER_COMPANION_ALT_SESSION_NAME=companion-uitest-alt"
    fi
    env $extra \
        TEST_RUNNER_COMPANION_HOST="$COMPANION_LISTEN" TEST_RUNNER_COMPANION_CODE="$code" \
        TEST_RUNNER_COMPANION_SESSION="$test_session" \
        xcodebuild -project Companion.xcodeproj -scheme Companion -destination "$DESTINATION" \
        -derivedDataPath build -quiet test-without-building \
        -only-testing:"CompanionUITests/CompanionUITests/$test" \
        -resultBundlePath "$RESULTS/$test.xcresult" || failed=1
    if [ -n "${alt_session:-}" ]; then
        hc kill companion-uitest-alt >/dev/null 2>&1 || true
        alt_session=
    fi
    xcrun xcresulttool export attachments --path "$RESULTS/$test.xcresult" \
        --output-path "$SHOTS/$test" > /dev/null || true
    # The UI test only saw "已发送"; confirm the message really reached the terminal.
    if [ "$test" = testAgentMessageIsAccepted ]; then
        if [ -z "$test_session" ] || ! hc read "$test_session" | grep -q "Companion UI test"; then
            echo "test terminal did not receive the Agent Message" >&2
            failed=1
        fi
    fi
    # Likewise for keys: cat echoes the pressed "2", then prints it again after Enter.
    if [ "$test" = testTerminalKeysArePressed ]; then
        if [ -z "$test_session" ] || [ "$(hc read "$test_session" | grep -c '^2$')" -lt 2 ]; then
            echo "test terminal did not receive the pressed keys" >&2
            failed=1
        fi
    fi
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
