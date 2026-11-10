#!/bin/sh
# Installs the `yochi` Gateway CLI on a Mac.
#
#   curl -fsSL https://raw.githubusercontent.com/Moolan-d/yochi/main/scripts/install.sh | sh
#
# Takes the release built for this Mac's architecture and checks its SHA-256.
# A tagged version without a build for this Mac is built from that tag with
# cargo (needs Rust and the Xcode command line tools). Nothing else on the machine is touched; the Gateway's
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

# Prints the HTTP status; fails only when GitHub could not be reached.
fetch() {
    curl --silent --show-error --location --retry 3 \
        --output "$work/$1" --write-out '%{http_code}' "$base/$1"
}

status=$(fetch "$archive") || die "could not reach GitHub to download $archive."
if [ "$status" = 200 ]; then
    say "Downloading $base/$archive"
    [ "$(fetch "$archive.sha256")" = 200 ] || die "the release has no checksum for $archive."
    # The checksum file names the archive, so check it where it was saved.
    ( cd "$work" && shasum -a 256 --check "$archive.sha256" >/dev/null 2>&1 ) \
        || die "checksum mismatch for $archive"
    mkdir "$work/dist"
    tar -xzf "$work/$archive" -C "$work/dist"
    [ -f "$work/dist/yochi" ] || die "$archive has no yochi binary"
    binary="$work/dist/yochi"
elif [ "$status" != 404 ]; then
    die "downloading $archive failed with HTTP $status."
elif [ "$VERSION" = latest ]; then
    # Building main here would install code no release has shipped.
    die "no release is published yet. Pick a tagged version with YOCHI_VERSION=v…,
or build from source:
  git clone https://github.com/$REPO && cd ${REPO#*/} && cargo install --path gateway"
else
    # A tag without binaries for this Mac: build that tag.
    command -v cargo >/dev/null 2>&1 && command -v git >/dev/null 2>&1 || die \
        "$VERSION has no build for $target, and building it needs git and cargo.
Install Rust (https://rustup.rs) and run this again."
    say "$VERSION has no build for $target; building it from source with cargo."
    clone=$work/src
    git clone --quiet --depth 1 --branch "$VERSION" "https://github.com/$REPO.git" "$clone"
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
