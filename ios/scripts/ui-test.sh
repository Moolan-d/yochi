#!/bin/sh
# Runs the UI tests in the simulator against a throwaway Gateway: its own port
# (7421) and state dir, so a Gateway already running on 7420 is left alone.
# Each test gets a fresh pairing code. Screenshots land in build/ui-test-shots/.
set -eu
cd "$(dirname "$0")/.."

SIM=${SIM:-iPhone 18 Pro}
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
# A local Relay, for the phone off the tailnet; every test pairs with it in
# use, so each one also enrolls through the tailnet.
relay_port=${RELAY_PORT:-7431}
relay_key=uitest-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
PORT=$relay_port HOST=127.0.0.1 RELAY_REGISTRATION_KEY=$relay_key node ../relay/index.mjs > "$state/relay.log" 2>&1 &
relay=$!
# Another relay left on the port would answer the health check with another key.
until grep -q "listening on" "$state/relay.log"; do
    kill -0 $relay 2>/dev/null || { echo "the relay did not start:" >&2; cat "$state/relay.log" >&2; exit 1; }
    sleep 0.2
done
YOCHI_RELAY_KEY=$relay_key "$GATEWAY" relay use "http://127.0.0.1:$relay_port" > /dev/null
pairing=
# Cleanup by the unique name, not by parsed ids: a bad parse must not leak the
# terminal. UI-test messages only ever go to this terminal.
test_terminal=companion-uitest
test_session=
trap 'kill $gateway $relay $pairing 2>/dev/null; hc kill companion-uitest >/dev/null 2>&1 || true; hc kill companion-uitest-alt >/dev/null 2>&1 || true; hc kill companion-uitest-history >/dev/null 2>&1 || true; hc kill companion-uitest-wheel >/dev/null 2>&1 || true; hc kill companion-uitest-dialog >/dev/null 2>&1 || true; hc kill companion-uitest-picker >/dev/null 2>&1 || true; hc kill companion-uitest-perf >/dev/null 2>&1 || true; hc kill companion-uitest-shell >/dev/null 2>&1 || true; hc kill companion-uitest-pane-a >/dev/null 2>&1 || true; hc kill companion-uitest-pane-b >/dev/null 2>&1 || true; rm -rf "$state" "${dialog_dir:-}"' EXIT

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

# A terminal on the alternate screen, for the full-screen test: taken over,
# it must draw at the phone's grid. It prints its rows and columns, one per
# line, whenever its size changes.
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

# A full-screen program with its own history, for the full-screen history
# test: like Claude Code it scrolls only on mouse wheel reports.
start_wheel_session() {
    hc run --bg --rm --no-parent --no-notify --name companion-uitest-wheel --json \
        -- /usr/bin/python3 "$(pwd)/scripts/wheel-tui.py" > /dev/null
}

# A plain shell, for the shell command test. In the throwaway state
# directory, so nothing it runs touches the repository.
start_shell_session() {
    hc run --bg --rm --no-parent --no-notify --name companion-uitest-shell --cwd "$state" --json \
        -- /bin/sh > /dev/null
}

# A terminal with a long history that keeps printing, for the perf tests:
# scrolling while output arrives is what the frame meter measures.
start_perf_session() {
    hc run --bg --rm --no-parent --no-notify --name companion-uitest-perf --json \
        -- /bin/sh -c 'seq 1 1000; while :; do date; sleep 0.05; done' > /dev/null
}

# Two terminals that each print a word of their own, for the pane switch
# test, which makes them up into one Herdr tab. Prints their ids.
start_pane_session() {
    hc run --bg --rm --no-parent --no-notify --name "companion-uitest-pane-$1" --json \
        -- /bin/sh -c "echo $2-pane; exec /bin/cat" |
        python3 -c 'import json,sys; d=json.load(sys.stdin); t=d.get("terminal",d.get("address",d.get("id"))); print(t.get("address") if isinstance(t,dict) else t)'
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
# testChangesPage run only when named, as do testTabMenu, testClaudeStartedInTerminal
# (starts Claude Code without sending it anything) and the testPerf*
# measurements (scripts/perf-test.sh).
for test in ${TESTS:-testPairObserveAndUnpair testPairAndObserveOverRelay testInviteLinkReplacesPairing testAgentMessageIsAccepted testShellCommandsRun testAgentMessageDraftSurvivesNavigation testNewSessionSheet testFullScreenDrawsForThePhone testTerminalScrollsHistory testFullScreenScrollsHistory testConversationCards testHomeSample testSwipeSwitchesPanes}; do
    if [ "$test" = testPairAndObserveOverRelay ]; then
        # With the tailnet off the link has only the Relay, so the phone pairs
        # and connects through it. Once it has, the tailnet comes back on and
        # the phone learns its address over the Relay.
        tries=0
        until grep -q '"connected":true' "$state/relay-status.json" 2>/dev/null; do
            tries=$((tries + 1))
            [ $tries -lt 150 ] || { echo "the Gateway never reached the relay:" >&2; cat "$state/relay-status.json" >&2; exit 1; }
            sleep 0.2
        done
        "$GATEWAY" tailnet off > /dev/null
        tries=0
        while nc -z "${YOCHI_LISTEN%:*}" "${YOCHI_LISTEN##*:}" 2>/dev/null; do
            tries=$((tries + 1))
            [ $tries -lt 50 ] || { echo "the Gateway kept listening on the tailnet" >&2; exit 1; }
            sleep 0.2
        done
        "$GATEWAY" pair --link > "$state/pair.log" 2>&1 &
        ( until grep -q "^Paired" "$state/pair.log"; do sleep 0.2; done
          # Time to check the Relay and watch the terminal through it.
          sleep 15
          "$GATEWAY" tailnet on > /dev/null ) &
        tailnet_back=$!
    else
        "$GATEWAY" pair > "$state/pair.log" 2>&1 &
    fi
    pairing=$!
    until grep -q "Link \|Code " "$state/pair.log" && { [ "$test" != testPairAndObserveOverRelay ] || grep -q "Link " "$state/pair.log"; }; do sleep 0.2; done
    code=$(awk '/Code /{print $2}' "$state/pair.log")
    link=$(awk '/Link /{print $2}' "$state/pair.log")

    echo "== $test"
    extra=
    if [ "$test" = testFullScreenDrawsForThePhone ]; then
        alt_session=$(start_alt_session)
        extra="TEST_RUNNER_COMPANION_ALT_SESSION_NAME=companion-uitest-alt"
    fi
    if [ "$test" = testShellCommandsRun ] || [ "$test" = testClaudeStartedInTerminal ] || [ "$test" = testTypesIntoTheTerminal ]; then
        start_shell_session
        extra="TEST_RUNNER_COMPANION_SHELL_SESSION_NAME=companion-uitest-shell"
    fi
    if [ "$test" = testClaudeStartedInTerminal ]; then
        # What runs in the terminal and at which width, every half second.
        ( while :; do
            hc get companion-uitest-shell --json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); f=d.get("foreground") or {}; a=f.get("argv") or [f.get("name")]; print(str(a[0]).rsplit("/",1)[-1], d["cols"])' || true
            sleep 0.5
        done ) > "$state/claude-sizes.log" &
        sampler=$!
    fi
    if [ "$test" = testTerminalScrollsHistory ]; then
        # HISTORY_SESSION_NAME points it at an existing session instead; opening
        # it takes that terminal over at the phone's grid while the test runs.
        [ -n "${HISTORY_SESSION_NAME:-}" ] || start_history_session
        extra="TEST_RUNNER_COMPANION_HISTORY_SESSION_NAME=${HISTORY_SESSION_NAME:-companion-uitest-history}"
    fi
    if [ "$test" = testFullScreenScrollsHistory ]; then
        start_wheel_session
        extra="TEST_RUNNER_COMPANION_WHEEL_SESSION_NAME=companion-uitest-wheel"
    fi
    case "$test" in testPerf*)
        start_perf_session
        extra="TEST_RUNNER_COMPANION_PERF_SESSION_NAME=companion-uitest-perf TEST_RUNNER_COMPANION_CONVERSATION_SESSION=${CONVERSATION_SESSION:-}"
    esac
    if [ "$test" = testSwipeSwitchesPanes ]; then
        pane_a=$(start_pane_session a alpha)
        pane_b=$(start_pane_session b beta)
        extra="TEST_RUNNER_COMPANION_PANE_A=$pane_a TEST_RUNNER_COMPANION_PANE_B=$pane_b"
    fi
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
        TEST_RUNNER_COMPANION_LINK="$link" \
        TEST_RUNNER_COMPANION_SESSION="$test_session" \
        xcodebuild -project Companion.xcodeproj -scheme Companion -destination "$DESTINATION" \
        -derivedDataPath build -quiet test-without-building \
        -only-testing:"CompanionUITests/CompanionUITests/$test" \
        -resultBundlePath "$RESULTS/$test.xcresult" || failed=1
    if [ "$test" = testPairAndObserveOverRelay ]; then
        kill $tailnet_back 2>/dev/null || true
        "$GATEWAY" tailnet on > /dev/null
        until nc -z "${YOCHI_LISTEN%:*}" "${YOCHI_LISTEN##*:}" 2>/dev/null; do sleep 0.2; done
    fi
    # Typed on the phone's own keyboard, then Return from the key bar.
    if [ "$test" = testTypesIntoTheTerminal ]; then
        screen=$(hc read companion-uitest-shell 2>/dev/null || true)
        if ! printf '%s\n' "$screen" | grep -q '^typed$' || ! printf '%s\n' "$screen" | grep -q '^bar$'; then
            echo "the shell did not run what was typed:" >&2
            printf '%s\n' "$screen" | tail -20 >&2
            failed=1
        fi
        hc kill companion-uitest-shell >/dev/null 2>&1 || true
    fi
    # The UI test only saw "已送达"; the shell must have run each command:
    # the echo twice (sent, then ↑ ⏎), and the last one only after Ctrl+C.
    if [ "$test" = testShellCommandsRun ]; then
        screen=$(hc read companion-uitest-shell 2>/dev/null || true)
        if [ "$(printf '%s\n' "$screen" | grep -c '^yochi-42$')" -lt 2 ] || ! printf '%s\n' "$screen" | grep -q '^stopped-2$'; then
            echo "the shell did not run the commands and keys:" >&2
            printf '%s\n' "$screen" | tail -20 >&2
            failed=1
        fi
        # Opening the terminal took it over at the phone's grid (`stty size`
        # prints rows then columns); leaving gave the base size back.
        phone_cols=$(printf '%s\n' "$screen" | grep -E '^[0-9]+ [0-9]+$' | tail -1 | cut -d' ' -f2)
        if [ -z "$phone_cols" ] || [ "$phone_cols" -gt 100 ]; then
            echo "the terminal was not taken over at the phone's grid (stty saw ${phone_cols:-nothing} columns)" >&2
            failed=1
        fi
        sleep 1
        base=$(hc get companion-uitest-shell --json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["cols"])' || true)
        if [ "${base:-0}" -le 100 ]; then
            echo "leaving the terminal did not give its size back (${base:-?} columns)" >&2
            failed=1
        fi
        hc kill companion-uitest-shell >/dev/null 2>&1 || true
    fi
    if [ "$test" = testClaudeStartedInTerminal ]; then
        # Claude Code ran at the phone's grid on the terminal page, and
        # carries on at the desktop's width once the page left.
        kill "$sampler" 2>/dev/null || true
        sleep 1
        hc read companion-uitest-shell > "$SHOTS/claude-terminal.txt" 2>/dev/null || true
        if ! grep -qE '^claude [0-9]+$' "$state/claude-sizes.log"; then
            echo "Claude Code never ran in the terminal:" >&2
            tail -5 "$state/claude-sizes.log" >&2
            failed=1
        elif ! grep -E '^claude [0-9]+$' "$state/claude-sizes.log" | awk '$2 <= 100 { found = 1 } END { exit !found }'; then
            echo "Claude Code never ran at the phone's grid:" >&2
            uniq "$state/claude-sizes.log" >&2
            failed=1
        elif [ "$(grep -E '^claude [0-9]+$' "$state/claude-sizes.log" | tail -1 | cut -d' ' -f2)" -le 100 ]; then
            echo "Claude Code was left at the phone's grid:" >&2
            uniq "$state/claude-sizes.log" >&2
            failed=1
        fi
        echo "terminal sizes while Claude Code started:"; uniq "$state/claude-sizes.log" | sed 's/^/  /'
        hc kill companion-uitest-shell >/dev/null 2>&1 || true
    fi
    hc kill companion-uitest-history >/dev/null 2>&1 || true
    hc kill companion-uitest-wheel >/dev/null 2>&1 || true
    hc kill companion-uitest-dialog >/dev/null 2>&1 || true
    hc kill companion-uitest-picker >/dev/null 2>&1 || true
    hc kill companion-uitest-perf >/dev/null 2>&1 || true
    hc kill companion-uitest-pane-a >/dev/null 2>&1 || true
    hc kill companion-uitest-pane-b >/dev/null 2>&1 || true
    if [ -n "${alt_session:-}" ]; then
        # Leaving the page gave the base size back.
        sleep 1
        base=$(hc get companion-uitest-alt --json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["cols"])' || true)
        if [ "${base:-0}" -le 100 ]; then
            echo "leaving the full-screen terminal did not give its size back (${base:-?} columns)" >&2
            failed=1
        fi
        hc kill companion-uitest-alt >/dev/null 2>&1 || true
        alt_session=
    fi
    xcrun xcresulttool export attachments --path "$RESULTS/$test.xcresult" \
        --output-path "$SHOTS/$test" > /dev/null || true
    # The UI test only saw "已送达"; confirm the command really reached the terminal.
    if [ "$test" = testAgentMessageIsAccepted ]; then
        if [ -z "$test_session" ] || ! hc read "$test_session" | grep -q "Companion UI test"; then
            echo "test terminal did not receive the Agent Message" >&2
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
echo "Relay log:"; sed 's/^/  /' "$state/relay.log"
exit $failed
