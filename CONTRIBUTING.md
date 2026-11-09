# Contributing to Yochi

Thanks for helping. This page covers building, testing and where things live. [AGENTS.md](AGENTS.md) holds the project's rules in full; the ones that matter most are summed up at the end.

## Repository layout

```
gateway/    The Gateway and the `yochi` CLI, in Rust
ios/        The iPhone app: SwiftUI, an XcodeGen project, libghostty fetched by a script
relay/      The self-hostable Relay: a Cloudflare Worker, or Node and Docker
protocol/   The versioned app ↔ Gateway API
```

The repository and the Xcode project are still called **Companion**. The product, the CLI and the bundle ID are **Yochi**.

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
xcodebuild test -project Companion.xcodeproj -scheme Companion \
  -destination 'platform=iOS Simulator,name=<simulator>' -only-testing:CompanionTests

# iOS UI tests drive the simulator against a throwaway Gateway on port 7421 and
# a local Relay, so a Gateway on 7420 is left alone.
scripts/ui-test.sh
TESTS="testPairObserveAndUnpair testShellCommandsRun" scripts/ui-test.sh
scripts/perf-test.sh   # frame pacing, time to first content, main-thread hangs
```

`scripts/ui-test.sh` needs `cargo`, `node`, `tailscale` and `hc` on your `PATH`. Put personal signing in `ios/Local.xcconfig`, which git ignores; `ios/Signing.xcconfig` shows the keys.

## Ground rules

- **Leave other sessions alone.** UI tests only create, type into and close terminals named `companion-uitest*`.
- **Keep the protocol backward compatible.** Older apps and older Gateways must keep working. Document every change in [`protocol/README.md`](protocol/README.md) in the same commit as the code.
- **Localize.** UI text is written in English and translated to Simplified Chinese in `ios/Companion/Localizable.xcstrings` in the same change.
- **Follow Apple's Human Interface Guidelines.** Use system controls and 44 pt touch targets, and check changes with a simulator screenshot.
- **Commit with Conventional Commits** (`type(scope): subject`, in English, one intent per commit).
