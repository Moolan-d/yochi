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
# install (the Mac asleep, the iPhone away) is retried the next day.
set -eu
cd "$(dirname "$0")/.."

repo=$(git rev-parse --show-toplevel)
state="$HOME/Library/Caches/dev.yochi"
label=dev.yochi.renew
agent="$HOME/Library/LaunchAgents/$label.plist"
domain="gui/$(id -u)"

case "${1:-}" in
--enable)
    mkdir -p "$(dirname "$agent")"
    cat > "$agent" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$label</string>
    <key>ProgramArguments</key>
    <array><string>/bin/sh</string><string>$(pwd)/scripts/renew-device.sh</string></array>
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
    rm -f "$agent"
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
