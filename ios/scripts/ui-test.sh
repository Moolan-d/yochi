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
GATEWAY=../gateway/target/debug/yochi
RESULTS=build/ui-test-results
SHOTS=build/ui-test-shots

(cd ../gateway && cargo build -q)
xcodegen generate -q

state=$(mktemp -d)
export YOCHI_STATE_DIR="$state"
export YOCHI_LISTEN="$(tailscale ip -4 | head -1):7421"
"$GATEWAY" > "$state/gateway.log" 2>&1 &
gateway=$!
pairing=
# Cleanup by the unique name, not by parsed ids: a bad parse must not leak the
# terminal. UI-test messages only ever go to this terminal.
test_terminal=companion-uitest
test_session=
trap 'kill $gateway $pairing 2>/dev/null; hc kill companion-uitest >/dev/null 2>&1 || true; hc kill companion-uitest-alt >/dev/null 2>&1 || true; hc kill companion-uitest-history >/dev/null 2>&1 || true; hc kill companion-uitest-dialog >/dev/null 2>&1 || true; hc kill companion-uitest-picker >/dev/null 2>&1 || true; hc kill companion-uitest-perf >/dev/null 2>&1 || true; rm -rf "$state" "${dialog_dir:-}"' EXIT

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

# A terminal on the alternate screen, for the full-screen test: its absolute
# cursor positions are what a phone-width reflow cannot keep. It prints its
# rows and columns, one per line, whenever its size changes.
start_alt_session() {
    hc run --bg --rm --no-parent --no-notify --name companion-uitest-alt --json \
        -- /bin/sh -c 'tput smcup; size() { clear; stty size | tr " " "\n"; }; trap size WINCH; size; while :; do sleep 0.2; done' |
        python3 -c 'import json,sys; d=json.load(sys.stdin); t=d.get("terminal",d.get("address",d.get("id"))); print(t.get("address") if isinstance(t,dict) else t)'
}

# A terminal with more output than one screen, for the history test.
start_history_session() {
    hc run --bg --rm --no-parent --no-notify --name companion-uitest-history --json \
        -- /bin/sh -c 'seq 1 400; exec /bin/cat' > /dev/null
}

# A terminal with a long history that keeps printing, for the perf tests:
# scrolling while output arrives is what the frame meter measures.
start_perf_session() {
    hc run --bg --rm --no-parent --no-notify --name companion-uitest-perf --json \
        -- /bin/sh -c 'seq 1 1000; while :; do date; sleep 0.05; done' > /dev/null
}

# Claude Code in a new, empty folder, for the dialog test: it opens on the
# folder trust dialog, which the test declines, so nothing is saved.
start_dialog_session() {
    dialog_dir=$(mktemp -d)
    hc run --bg --rm --no-parent --no-notify --name companion-uitest-dialog --cwd "$dialog_dir" --json \
        -- "$(command -v claude)" > /dev/null
}

# Claude Code in this repository, a folder it already trusts, for the picker
# test: it opens /model from the phone and closes it with Esc.
start_picker_session() {
    hc run --bg --rm --no-parent --no-notify --name companion-uitest-picker --cwd "$(cd .. && pwd)" --json \
        -- "$(command -v claude)" > /dev/null
}

# Claude Code under the build folder, for the queue, image and slash tests:
# it inherits the repository's trust, and the turns it runs stay out of the
# repository's own Claude Code history. One project command for completion.
# A repository left by testChangesPage would make the folder a project of
# its own, untrusted, so it goes first.
start_agent_session() {
    rm -rf build/uitest-agent/.git build/uitest-agent/notes.md
    mkdir -p build/uitest-agent/.claude/commands
    printf -- '---\ndescription: Say hello from the UI test\n---\nSay hello.\n' \
        > build/uitest-agent/.claude/commands/uitest-hello.md
    hc run --bg --rm --no-parent --no-notify --name companion-uitest-picker --cwd "$(pwd)/build/uitest-agent" --json \
        -- "$(command -v claude)" > /dev/null
}

# A git repository in the Agent's directory with one change and one new
# file, for testChangesPage. It sits under the git-ignored build directory.
start_changes_repo() {
    dir=build/uitest-agent
    rm -rf "$dir/.git" "$dir/notes.md"
    seq 1 10 | sed 's/^/line /' > "$dir/app.txt"
    git -C "$dir" init -q
    git -C "$dir" add -A
    git -C "$dir" -c user.name=uitest -c user.email=uitest@example.invalid commit -qm base
    sed -i '' 's/^line 5$/line five changed/' "$dir/app.txt"
    printf 'A new note\n' > "$dir/notes.md"
}

# TESTS="testA testB" runs a subset; testDialogFromScreen,
# testPickerFromScreen, testPermissionModeFromScreen and
# testMessageQueuedWhileWorking, testImageSentToAgent, testSlashCompletion and
# testChangesPage run only when named, as do testTabMenu and the testPerf*
# measurements (scripts/perf-test.sh).
for test in ${TESTS:-testPairObserveAndUnpair testInviteLinkReplacesPairing testAgentMessageIsAccepted testTerminalKeysArePressed testAgentMessageDraftSurvivesNavigation testNewSessionSheet testFullScreenShownAsDrawn testTerminalScrollsHistory testConversationCards testHomeSample}; do
    "$GATEWAY" pair > "$state/pair.log" 2>&1 &
    pairing=$!
    until grep -q "Code " "$state/pair.log"; do sleep 0.2; done
    code=$(awk '/Code /{print $2}' "$state/pair.log")

    echo "== $test"
    extra=
    if [ "$test" = testFullScreenShownAsDrawn ]; then
        alt_session=$(start_alt_session)
        extra="TEST_RUNNER_COMPANION_ALT_SESSION_NAME=companion-uitest-alt"
    fi
    if [ "$test" = testTerminalScrollsHistory ]; then
        # HISTORY_SESSION_NAME points it at an existing session instead, read-only.
        [ -n "${HISTORY_SESSION_NAME:-}" ] || start_history_session
        extra="TEST_RUNNER_COMPANION_HISTORY_SESSION_NAME=${HISTORY_SESSION_NAME:-companion-uitest-history}"
    fi
    case "$test" in testPerf*)
        start_perf_session
        extra="TEST_RUNNER_COMPANION_PERF_SESSION_NAME=companion-uitest-perf TEST_RUNNER_COMPANION_CONVERSATION_SESSION=${CONVERSATION_SESSION:-}"
    esac
    if [ "$test" = testTabMenu ]; then
        # An existing session whose Herdr tab holds more, opened read only: TAB_SESSION=<id>.
        extra="TEST_RUNNER_COMPANION_TAB_SESSION=${TAB_SESSION:-}"
    fi
    if [ "$test" = testConversationScrollsToLatest ]; then
        # An existing session with a transcript, read only: CONVERSATION_SESSION=<id>.
        extra="TEST_RUNNER_COMPANION_CONVERSATION_SESSION=${CONVERSATION_SESSION:-}"
    fi
    if [ "$test" = testDialogFromScreen ]; then
        start_dialog_session
        extra="TEST_RUNNER_COMPANION_DIALOG_SESSION_NAME=companion-uitest-dialog"
    fi
    if [ "$test" = testPickerFromScreen ] || [ "$test" = testNoticeFromScreen ] || [ "$test" = testPermissionModeFromScreen ] ; then
        start_picker_session
        extra="TEST_RUNNER_COMPANION_PICKER_SESSION_NAME=companion-uitest-picker"
    fi
    if [ "$test" = testMessageQueuedWhileWorking ] || [ "$test" = testImageSentToAgent ] || [ "$test" = testSlashCompletion ] || [ "$test" = testChangesPage ]; then
        start_agent_session
        [ "$test" != testChangesPage ] || start_changes_repo
        extra="TEST_RUNNER_COMPANION_PICKER_SESSION_NAME=companion-uitest-picker"
    fi
    env $extra \
        TEST_RUNNER_COMPANION_HOST="$YOCHI_LISTEN" TEST_RUNNER_COMPANION_CODE="$code" \
        TEST_RUNNER_COMPANION_SESSION="$test_session" \
        xcodebuild -project Companion.xcodeproj -scheme Companion -destination "$DESTINATION" \
        -derivedDataPath build -quiet test-without-building \
        -only-testing:"CompanionUITests/CompanionUITests/$test" \
        -resultBundlePath "$RESULTS/$test.xcresult" || failed=1
    hc kill companion-uitest-history >/dev/null 2>&1 || true
    hc kill companion-uitest-dialog >/dev/null 2>&1 || true
    hc kill companion-uitest-picker >/dev/null 2>&1 || true
    hc kill companion-uitest-perf >/dev/null 2>&1 || true
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
