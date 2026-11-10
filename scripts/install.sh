#!/bin/sh
# Installs the `yochi` Gateway CLI on a Mac.
#
#   curl -fsSL https://raw.githubusercontent.com/Moolan-d/yochi/main/scripts/install.sh | sh
#
# Takes the release built for this Mac's architecture when one is published,
# and otherwise builds from source with cargo (needs Rust and the Xcode
# command line tools). Nothing else on the machine is touched; the Gateway's
# own state lives under ~/Library/Application Support/Yochi.
#
#   YOCHI_VERSION=v0.1.0   install a given release instead of the latest
#   YOCHI_BIN=~/bin        install the binary somewhere other than ~/.local/bin
#   YOCHI_REPO=you/yochi   install from a fork
set -eu

REPO=${YOCHI_REPO:-Moolan-d/yochi}
VERSION=${YOCHI_VERSION:-latest}
BIN_DIR=${YOCHI_BIN:-$HOME/.local/bin}

say() { printf '%s\n' "$*"; }
die() { printf 'install: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || die "Yochi runs on macOS; this is $(uname -s)."

case $(uname -m) in
    arm64) target=aarch64-apple-darwin ;;
    x86_64) target=x86_64-apple-darwin ;;
    *) die "no build for $(uname -m)" ;;
esac

command -v curl >/dev/null 2>&1 || die "curl is required."

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

if [ "$VERSION" = latest ]; then
    base="https://github.com/$REPO/releases/latest/download"
else
    case $VERSION in v*) ;; *) VERSION="v$VERSION" ;; esac
    base="https://github.com/$REPO/releases/download/$VERSION"
fi
archive="yochi-$target.tar.gz"

download() {
    curl --fail --silent --show-error --location --retry 3 \
        --output "$work/$1" "$base/$1" 2>/dev/null
}

if download "$archive"; then
    say "Downloading $base/$archive"
    if download "$archive.sha256"; then
        # The checksum file names the archive, so check it where it was saved.
        ( cd "$work" && shasum -a 256 --check "$archive.sha256" >/dev/null 2>&1 ) \
            || die "checksum mismatch for $archive"
    else
        say "No checksum published for $VERSION; skipping the check."
    fi
    mkdir "$work/dist"
    tar -xzf "$work/$archive" -C "$work/dist"
    [ -f "$work/dist/yochi" ] || die "$archive has no yochi binary"
    binary="$work/dist/yochi"
else
    command -v cargo >/dev/null 2>&1 || die \
        "no release for $VERSION and no cargo to build one.
Install Rust (https://rustup.rs) and run this again, or build by hand:
  git clone https://github.com/$REPO && cd ${REPO#*/} && cargo install --path gateway"
    say "No release for $VERSION; building from source with cargo."
    command -v git >/dev/null 2>&1 || die "git and cargo are both needed to build from source."
    clone=$work/src
    if [ "$VERSION" = latest ]; then
        git clone --quiet --depth 1 "https://github.com/$REPO.git" "$clone"
    else
        git clone --quiet --depth 1 --branch "$VERSION" "https://github.com/$REPO.git" "$clone"
    fi
    cargo install --quiet --locked --path "$clone/gateway" --root "$work/cargo"
    binary=$work/cargo/bin/yochi
fi

mkdir -p "$BIN_DIR"
install -m 0755 "$binary" "$BIN_DIR/yochi"
say "Installed $("$BIN_DIR/yochi" --version 2>/dev/null || echo yochi) to $BIN_DIR/yochi"

case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *)
        say ""
        say "$BIN_DIR is not on your PATH. Add it with:"
        say "  echo 'export PATH=\"$BIN_DIR:\$PATH\"' >> ~/.zshrc && exec zsh"
        ;;
esac

say ""
say "Next, start the Gateway at login and pair your phone:"
say "  yochi service install"
say "  yochi pair"
say ""
say "The Gateway guide: https://github.com/$REPO/blob/main/gateway/README.md"
