#!/bin/sh
# Keeps the app on the paired iPhone signed. When the installed build's profile
# has under three days left, it builds the latest commit on main in a worktree
# of its own, so unfinished edits in this checkout never reach the phone, and
# installs it with install-device.sh. Otherwise it does nothing.
#
#   scripts/renew-device.sh             # check once now
#   scripts/renew-device.sh --enable    # check daily at noon, or on waking after it
#   scripts/renew-device.sh --disable
#
# The daily check logs to ~/Library/Logs/yochi-renew.log. A day it cannot
# install (the Mac asleep, the iPhone away, Xcode signed out) is retried the
# next day, and the phone hears why through `yochi push send` (Bark) if
# notifications are on.
set -eu
cd "$(dirname "$0")/.."

repo=$(git rev-parse --show-toplevel)
state="$HOME/Library/Caches/dev.yochi"
label=dev.yochi.renew
agent="$HOME/Library/LaunchAgents/$label.plist"
# System Settings > General > Login Items lists the agent by its executable's
# name, so it runs this launcher rather than /bin/sh.
launcher="$HOME/Library/Application Support/dev.yochi/Yochi Renew"
domain="gui/$(id -u)"

case "${1:-}" in
--enable)
    mkdir -p "$(dirname "$agent")" "$(dirname "$launcher")"
    printf '#!/bin/sh\nexec /bin/sh "%s/scripts/renew-device.sh"\n' "$(pwd)" > "$launcher"
    chmod +x "$launcher"
    cat > "$agent" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$label</string>
    <key>ProgramArguments</key>
    <array><string>$launcher</string></array>
    <key>EnvironmentVariables</key>
    <dict><key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string></dict>
    <key>StartCalendarInterval</key>
    <dict><key>Hour</key><integer>12</integer><key>Minute</key><integer>0</integer></dict>
    <key>StandardOutPath</key><string>$HOME/Library/Logs/yochi-renew.log</string>
    <key>StandardErrorPath</key><string>$HOME/Library/Logs/yochi-renew.log</string>
</dict>
</plist>
EOF
    launchctl bootout "$domain/$label" 2>/dev/null || true
    launchctl bootstrap "$domain" "$agent"
    echo "renewing daily; log in ~/Library/Logs/yochi-renew.log"
    exit 0
    ;;
--disable)
    launchctl bootout "$domain/$label" 2>/dev/null || true
    rm -f "$agent" "$launcher"
    echo "daily renewal off"
    exit 0
    ;;
"") ;;
*)
    echo "usage: $0 [--enable | --disable]" >&2
    exit 2
    ;;
esac

stamp() { date '+%Y-%m-%d %H:%M'; }

until=$(cat "$state/installed-until" 2>/dev/null || true)
if [ -n "$until" ]; then
    left=$(( $(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$until" +%s) - $(date +%s) ))
    if [ "$left" -gt $((3 * 24 * 3600)) ]; then
        echo "$(stamp) signed until $until; nothing to do"
        exit 0
    fi
fi

# Nobody reads the log until the app stops opening, so a failure goes to the
# phone too: what went wrong and when the signing runs out. The run goes to a
# file first so the notification can quote it.
log=$(mktemp)
trap 'rm -f "$log"' EXIT
set +e
(
    set -e
    worktree="$state/worktree"
    git -C "$repo" worktree prune
    if [ -d "$worktree" ]; then
        git -C "$worktree" checkout --quiet --detach main
    else
        git -C "$repo" worktree add --quiet --detach "$worktree" main
    fi
    cp "$repo/ios/Local.xcconfig" "$worktree/ios/"

    echo "$(stamp) installing $(git -C "$worktree" log -1 --format='%h %s')"
    "$worktree/ios/scripts/install-device.sh"
) > "$log" 2>&1
status=$?
set -e
cat "$log"
[ "$status" -eq 0 ] && exit 0

# devicectl's reason (the iPhone locked, away), else xcodebuild's first real
# error, else the last line.
reason=$(sed -n 's/^ *NSLocalizedFailureReason = //p' "$log" | head -1)
[ -n "$reason" ] || reason=$(sed -n 's/.*error: //p' "$log" | grep -v 'produced no further output' | sed 's/ (in target .*//' | head -1)
[ -n "$reason" ] || reason=$(grep -v '^\*\* ' "$log" | grep . | tail -1)
ends=""
[ -n "$until" ] && ends=$(date -r "$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$until" +%s)" '+%m-%d %H:%M')
case $(defaults read -g AppleLanguages 2>/dev/null | sed -n 2p) in
*zh*) title="Yochi 续签失败"; body="${ends:+签名到 $ends 为止。}$reason" ;;
*) title="Yochi renewal failed"; body="${ends:+Signed until $ends. }$reason" ;;
esac
yochi=$(command -v yochi || echo "$HOME/.cargo/bin/yochi")
"$yochi" push send --title "$title" "$body" || echo "$(stamp) the failure notification wasn't sent"
exit "$status"
