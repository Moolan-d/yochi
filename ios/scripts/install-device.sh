#!/bin/sh
# Builds Yochi, signs it with the team in Local.xcconfig and installs it on a
# paired iPhone, over the cable or Wi-Fi. Xcode must be signed in to that
# Apple ID once (Settings > Apple Accounts); after that no Xcode UI is needed.
#
#   scripts/install-device.sh                 # the first paired iPhone
#   DEVICE="My iPhone" scripts/install-device.sh
#
# A free Personal Team's profile lasts seven days; run this again to renew it.
set -eu
cd "$(dirname "$0")/.."

CONFIGURATION=${CONFIGURATION:-Release}
DERIVED=build/device

if [ -z "${DEVICE:-}" ]; then
    devices=$(mktemp)
    trap 'rm -f "$devices"' EXIT
    xcrun devicectl list devices --quiet --json-output "$devices" > /dev/null
    DEVICE=$(python3 -I - "$devices" <<'EOF'
import json, sys
for d in json.load(open(sys.argv[1]))["result"]["devices"]:
    hw, conn = d["hardwareProperties"], d["connectionProperties"]
    if hw.get("platform") == "iOS" and hw.get("reality") == "physical" \
            and conn.get("pairingState") == "paired":
        print(hw["udid"])
        break
EOF
)
    [ -n "$DEVICE" ] || { echo "no paired iPhone; pair one in Xcode > Devices and Simulators first" >&2; exit 1; }
fi

scripts/fetch-libghostty.sh > /dev/null
xcodegen generate -q

# Xcode keeps signing with a cached profile until it lapses, so building again
# does not renew it. Drop Yochi's cached profiles that expire within three days
# and -allowProvisioningUpdates fetches a fresh one.
python3 -I - "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" <<'EOF'
import datetime, glob, os, plistlib, subprocess, sys
soon = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=3)
for path in glob.glob(os.path.join(sys.argv[1], "*.mobileprovision")):
    raw = subprocess.run(["security", "cms", "-D", "-i", path],
                         capture_output=True, check=True).stdout
    profile = plistlib.loads(raw)
    app_id = profile.get("Entitlements", {}).get("application-identifier", "")
    if app_id.split(".", 1)[-1].startswith("dev.yochi.app") \
            and profile["ExpirationDate"].replace(tzinfo=datetime.timezone.utc) < soon:
        os.remove(path)
        print(f"renewing {profile['Name']}, which expires {profile['ExpirationDate']:%Y-%m-%d %H:%M} UTC")
EOF

xcodebuild build -quiet -project Yochi.xcodeproj -scheme Yochi \
    -configuration "$CONFIGURATION" -destination 'generic/platform=iOS' \
    -derivedDataPath "$DERIVED" \
    -allowProvisioningUpdates -allowProvisioningDeviceRegistration

app="$DERIVED/Build/Products/$CONFIGURATION-iphoneos/Yochi.app"
xcrun devicectl device install app --quiet --device "$DEVICE" "$app"

expires=$(security cms -D -i "$app/embedded.mobileprovision" | plutil -extract ExpirationDate raw -o - -)
echo "Installed $(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Info.plist"); its profile expires $expires"
