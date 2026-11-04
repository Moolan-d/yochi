#!/bin/sh
# Measures the app in the simulator: runs the testPerf* UI tests through
# ui-test.sh while the app's perf log streams, then prints its lines.
#   frames scroll …  frame pacing while the terminal scrolls (FrameMeter)
#   shown …          time from opening a page to its content (Perf.shown)
#   hang ms=…        a main-thread pass longer than 50 ms (HangMeter)
#   perf-first …     the first search and terminals after a cold launch
# CONVERSATION_SESSION=<id> adds an Agent's conversation, opened read only.
set -eu
cd "$(dirname "$0")/.."
out=${PERF_OUT:-build/perf-$(date +%Y%m%d-%H%M%S).log}
mkdir -p build
SIM=${SIM:-iPhone 17 Pro}
sim_id=$(xcrun simctl list devices available | grep -m1 "    $SIM (" | grep -oE '[0-9A-F-]{36}')
xcrun simctl spawn "$sim_id" log stream --style compact --level info \
    --predicate 'subsystem == "dev.yochi.perf"' > "$out" 2>&1 &
stream=$!
trap 'kill $stream 2>/dev/null || true' EXIT
status=0
TESTS=${TESTS:-testPerfTerminalScroll testPerfReenter testPerfReenterConversation testPerfFirstUse} SIM="$SIM" sh scripts/ui-test.sh > "$out.ui" 2>&1 || status=$?
sleep 1
echo "perf log: $out (ui-test output: $out.ui, exit $status)"
grep -E "frames scroll|shown |hang ms=" "$out" | sed -E 's/^([0-9:.-]+ [0-9:.]+).*(frames scroll|shown |hang ms=)/\1 \2/' || true
grep -h "perf-first" "$out.ui" | grep -v "^Test" || true
exit $status
