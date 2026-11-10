# Contributing to Yochi

Thanks for helping. This page covers building, testing and where things live. [AGENTS.md](AGENTS.md) holds the project's rules in full; the ones that matter most are summed up at the end.

## Repository layout

```
gateway/    The Gateway and the `yochi` CLI, in Rust
ios/        The iPhone app: SwiftUI, an XcodeGen project, libghostty fetched by a script
relay/      The self-hostable Relay: a Cloudflare Worker, or Node and Docker
protocol/   The versioned app ↔ Gateway API
```

The repository, the Xcode project and the product are all **Yochi**; the CLI is `yochi` and the bundle ID `dev.yochi.app`.

How the pieces fit together, how the phone connects and the full CLI reference are in the [Gateway guide](gateway/README.md).

## Build and test

```sh
# Gateway
cd gateway
cargo run              # serve
cargo run -- pair      # in another terminal
cargo test

# Relay
cd relay
npm install
npm test                  # Node version
npm run test:cloudflare   # Worker version, via wrangler dev --local

# iOS: generate the project first; it is not checked in
cd ios
scripts/fetch-libghostty.sh
xcodegen generate
xcodebuild test -project Yochi.xcodeproj -scheme Yochi \
  -destination 'platform=iOS Simulator,name=<simulator>' -only-testing:YochiTests

# iOS UI tests drive the simulator against a throwaway Gateway on port 7421 and
# a local Relay, so a Gateway on 7420 is left alone.
scripts/ui-test.sh
TESTS="testPairObserveAndUnpair testShellCommandsRun" scripts/ui-test.sh
scripts/perf-test.sh   # frame pacing, time to first content, main-thread hangs
```

`scripts/ui-test.sh` needs `cargo`, `node`, `tailscale` and `hc` on your `PATH`. Put personal signing in `ios/Local.xcconfig`, which git ignores; `ios/Signing.xcconfig` shows the keys.

## Continuous integration

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) runs on every push to `main` and every pull request:

- **Gateway**: `cargo test` and `cargo clippy --all-targets -- -D warnings`, on macOS, since the Gateway is macOS-only.
- **Relay**: `npm test`.
- **iOS**: the unit tests (`-only-testing:YochiTests`) in the simulator.

Formatting isn't enforced: the Rust sources are hand-formatted and `cargo fmt` would rewrite several hundred lines, so match the surrounding style instead. The UI suite needs Herdr, Tailscale and Claude Code and stays a local check; run it before a change that spans screens.

Pushing a `v*` tag runs [`.github/workflows/release.yml`](.github/workflows/release.yml), which builds `yochi` for both Mac architectures, attaches them to the GitHub release and checks that [`scripts/install.sh`](scripts/install.sh) installs from it.

## Ground rules

- **Leave other sessions alone.** UI tests only create, type into and close terminals named `yochi-uitest*`.
- **Keep the protocol backward compatible.** Older apps and older Gateways must keep working. Document every change in [`protocol/README.md`](protocol/README.md) and its translation [`protocol/README.zh-CN.md`](protocol/README.zh-CN.md) in the same commit as the code. The English page is authoritative.
- **Localize.** UI text is written in English and translated to Simplified Chinese in `ios/Yochi/Localizable.xcstrings` in the same change.
- **Follow Apple's Human Interface Guidelines.** Use system controls and 44 pt touch targets, and check changes with a simulator screenshot.
- **Commit with Conventional Commits** (`type(scope): subject`, in English, one intent per commit).
