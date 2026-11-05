#!/bin/sh
# Fetches libghostty-spm at a pinned revision into ios/Vendor/, downloading its
# prebuilt GhosttyKit.xcframework with curl and checking the package's checksum.
# Xcode's own binary-target download can hang indefinitely, so the vendored
# package refers to the framework by path instead.
set -eu

REVISION=7e45d27160f9b34aca9ca5c9820e9207482f9f04
ARTIFACT_URL=https://github.com/Lakr233/libghostty-spm/releases/download/upstream.82938b633ba6/GhosttyKit.xcframework.zip
CHECKSUM=2d9a26e80c3836c450f03ea2cf9d191841d9093d4f61c1cea466d2fc8e215dbb

cd "$(dirname "$0")/.."
dest=Vendor/libghostty-spm

if [ -f "$dest/.revision" ] && [ "$(cat "$dest/.revision")" = "$REVISION" ] && [ -d "$dest/GhosttyKit.xcframework" ]; then
    echo "libghostty-spm $REVISION already present"
    exit 0
fi

rm -rf "$dest"
mkdir -p Vendor
git clone --quiet https://github.com/Lakr233/libghostty-spm.git "$dest"
git -C "$dest" -c advice.detachedHead=false checkout --quiet "$REVISION"

zip="$dest/GhosttyKit.xcframework.zip"
curl --fail --location --silent --show-error --output "$zip" "$ARTIFACT_URL"
actual=$(shasum -a 256 "$zip" | cut -d' ' -f1)
if [ "$actual" != "$CHECKSUM" ]; then
    echo "checksum mismatch: expected $CHECKSUM, got $actual" >&2
    exit 1
fi
unzip -q "$zip" -d "$dest"
rm "$zip"

# Point the binary target at the verified local framework.
python3 -I - "$dest/Package.swift" <<'EOF'
import re, sys
path = sys.argv[1]
text = open(path).read()
patched, count = re.subn(
    r'\.binaryTarget\(\s*name: "libghostty",\s*url: "[^"]+",\s*checksum: "[^"]+"\s*\)',
    '.binaryTarget(name: "libghostty", path: "GhosttyKit.xcframework")',
    text)
if count != 1:
    sys.exit("could not find the libghostty binary target in Package.swift")
open(path, "w").write(patched)
EOF

echo "$REVISION" > "$dest/.revision"
echo "libghostty-spm $REVISION ready in $dest"
