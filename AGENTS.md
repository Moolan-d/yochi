# AGENTS.md

Guidance for coding agents working in this repository. The user-facing overview is in [README.md](README.md).

## What this is

Yochi watches and drives a Mac's Herdr terminals and coding agents from an iPhone. The repository and Xcode project are still called **Companion**; the product, CLI and bundle ID are **Yochi**.

| Path | What | Stack |
| --- | --- | --- |
| `gateway/` | Gateway that runs on the Mac, plus the `yochi` CLI | Rust (stable) |
| `ios/` | iPhone app | SwiftUI, Swift 6, XcodeGen, libghostty |
| `relay/` | Self-hostable Relay that forwards opaque WebSocket frames (fork of Alma Relay, MIT) | Node ≥ 20 or Cloudflare Worker |
| `protocol/` | The versioned app ↔ Gateway API | Markdown |

The Gateway talks to herdr-core through `hc`. The phone reaches the Gateway over Tailscale or through a Relay, end-to-end encrypted with Noise IKpsk2.

If `GLOSSARY.md` and `docs/adr/` exist in your checkout, read them first. They are git-ignored local notes holding the project's vocabulary (Terminal, Agent, Space, Takeover…) and its design decisions.

## Build and test

```sh
# Gateway
cd gateway && cargo test

# Relay
cd relay && npm install && npm test

# iOS: generate the project first; it is not checked in
cd ios
scripts/fetch-libghostty.sh       # once, into ios/Vendor
xcodegen generate
xcodebuild test -project Companion.xcodeproj -scheme Companion \
  -destination 'platform=iOS Simulator,name=<simulator>' -only-testing:CompanionTests

# iOS UI tests: build the Gateway, start a throwaway one on port 7421 and a Relay on 7431
scripts/ui-test.sh
TESTS="testPairObserveAndUnpair testShellCommandsRun" scripts/ui-test.sh
```

- `scripts/ui-test.sh` needs `cargo`, `node`, `tailscale` and `hc` on `PATH`.
- Personal signing goes in `ios/Local.xcconfig`, which is git-ignored. `ios/Signing.xcconfig` shows the keys.
- Run the targeted tests for what you changed. Run the full UI suite when a change spans several screens.

## Rules

- **Leave the user's own sessions alone.** UI tests create, type into and kill only terminals named `companion-uitest*`. Never attach to, type into or close any other Herdr terminal. Never restart a Gateway on port 7420; that one is the user's.
- **Protocol changes stay backward compatible.** Older apps and older Gateways must keep working. Document every change in `protocol/README.md`, in the same commit as the code.
- **Localization.**
  - English is the development language. Chinese (`zh-Hans`) is a full translation in `ios/Companion/Localizable.xcstrings`.
  - New UI text goes in as English. Wrap it in `String(localized:)` wherever the type is `String` rather than `LocalizedStringKey`.
  - Add the zh-Hans translation in the same change, with plural variations where a count can be 1.
  - Text the Gateway generates follows the language the phone sends when it connects. Prefer codes that the app localizes over free text.
- **UI follows Apple's Human Interface Guidelines.** Use system controls and 44 pt touch targets, and check changes with a simulator screenshot.
- **Commits.**
  - Use Conventional Commits (`type(scope): subject`), with scopes such as `ios`, `gateway`, `relay` and `readme`.
  - Write commit messages (subject and body) in English, with an imperative subject.
  - One intent per commit.
  - Stage explicit paths. Do not commit `docs/`, `GLOSSARY.md`, build output or anything with secrets.
