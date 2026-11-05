<div align="center">

<img src="docs/images/icon.png" width="128" height="128" alt="Yochi app icon" />

# Yochi

**Your coding agents, in your pocket.**

A native iPhone app for the Claude Code, Codex and pi sessions that Herdr runs on your Mac and the machines it reaches over ssh.

![iOS 18+](https://img.shields.io/badge/iOS-18%2B-000000?logo=apple&logoColor=white)
![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)
![Rust 2024](https://img.shields.io/badge/Rust-2024-000000?logo=rust&logoColor=white)
![Terminal: libghostty](https://img.shields.io/badge/terminal-libghostty-3551F3)
![Encryption: Noise IKpsk2](https://img.shields.io/badge/relay-Noise%20IKpsk2-2E7D32)

English | [简体中文](./README.zh-CN.md)

</div>

---

Yochi is not a remote desktop. A small Gateway on your Mac, `yochi`, reads the sessions herdr-core already manages, including those on remote machines, and serves them to the phone in a shape a phone is good at. Agents waiting on you come first. Conversations are rendered as messages and tool cards rather than a squinted-at terminal. Claude Code's permission prompts become native buttons. When you do need the terminal, it is a real one: Ghostty's.

The phone reaches the Gateway over your **tailnet** or, when it isn't on one, through a **Relay you deploy yourself** that only ever sees end-to-end encrypted bytes.

<div align="center">
<table>
  <tr>
    <td align="center"><img src="docs/images/home.png" width="260" alt="Home: agents that need you, then each Space" /></td>
    <td align="center"><img src="docs/images/conversation.png" width="260" alt="Conversation: messages, edits, sub-tasks and todos" /></td>
  </tr>
  <tr>
    <td align="center"><sub><b>Home</b>: who needs you, then every Space</sub></td>
    <td align="center"><sub><b>Conversation</b>: edits, sub-tasks, todos</sub></td>
  </tr>
</table>
</div>

## Contents

- [Features](#features)
- [How it fits together](#how-it-fits-together)
- [How it connects](#how-it-connects)
- [Quick start](#quick-start)
- [CLI reference](#cli-reference)
- [Security model](#security-model)
- [Development](#development)
- [Repository layout](#repository-layout)
- [Acknowledgements](#acknowledgements)

## Features

- **Needs you, first.** Agents blocked on a question or a permission prompt rise to the top of the home page, across every Space and machine.
- **Native conversations.** For Claude Code, the Gateway reads the agent's own transcript and the app shows it as messages, file edits with line counts, sub-tasks, todos and messages between sessions.
- **Answer prompts with a tap.** The app reads Claude Code's dialogs off the screen (permission prompts, pickers, notices) and turns them into a card with real buttons.
- **Send without taking over.** Messages go in through herdr-core and wait for the terminal to be idle, so typing on the phone never fights the person at the desk.
- **A real terminal when you need one.** Terminals render with libghostty. Watching is read-only and keeps the desktop's size. Typing takes over, and the terminal re-lays itself out at phone width until the desktop takes it back. Full-screen programs scroll their own history under your finger. Long-press selects and copies.
- **Organized the way Herdr is.** Spaces become collapsible groups. Child agents sit under their parent. Pinned agents lead. Plain shells fold away. Remote Spaces carry their machine's badge.
- **Read-only changes.** See what a session has changed in its git repository, diffs included, without the phone ever naming a path or running a command.
- **Start new sessions.** Start an agent from a recent directory, filed into the right Space.
- **Two ways in, neither required.** Tailnet and Relay are independent. Run either or both. A phone paired over the Relay moves to the tailnet on its own once the Mac joins one.
- **English and Chinese.** The app follows the iPhone's language. Text the Gateway writes itself, such as some notices and errors, is still in Chinese for now.

## How it fits together

<p align="center">
  <img src="docs/diagrams/yochi-architecture.svg" alt="Yochi architecture: the phone app, tailnet and relay paths, the Gateway on the main Mac, herdr-core and remote machines" />
</p>

| Piece | Where it runs | What it does |
| --- | --- | --- |
| **Yochi app** (`ios/`) | iPhone | SwiftUI and libghostty. Session list, conversation page, terminal page and pairing. |
| **Gateway** (`gateway/`) | Your main Mac | The `yochi` binary, in Rust. Authenticates paired phones, exposes a narrow, versioned API (`/v0/…`) and calls herdr-core for them. Runs as a LaunchAgent. |
| **herdr-core** | Your main Mac | Herdr's session runtime, reached through `hc`. It owns the terminals, and the remote machines it reaches over ssh. Yochi creates no second session system. |
| **Relay** (`relay/`) | Your Cloudflare account, or any host with Docker | Optional. A WebSocket rendezvous that the Gateway dials out to, so no inbound port is opened. Forwards ciphertext only. |

Remote machines need nothing installed. Everything goes through the main Mac's herdr-core. When that Mac sleeps, the phone can't reach any session, remote ones included.

### How sessions are shown

<p align="center">
  <img src="docs/diagrams/yochi-sessions.svg" alt="How Herdr's Host, Space, Tab, Pane and Terminal levels map onto the Yochi home page" />
</p>

Herdr nests Host → Space → Tab → Pane → Terminal. A phone needs fewer levels:

- A **Space** becomes a group. A **Host** becomes a badge on remote Spaces.
- A **Tab** isn't a level. A named Tab shows as a line on its rows.
- A **Pane** only sets the order. One **Terminal** is one row.

What opens on a tap depends on what runs in the terminal. A known agent opens the conversation page. Anything else opens the terminal page.

## How it connects

| | Tailnet | Relay |
| --- | --- | --- |
| Address | `ws://<Mac's tailnet IPv4>:7420` | `https://<your relay>` |
| Encryption | WireGuard (Tailscale) | Noise IKpsk2, end to end between app and Gateway |
| Phone needs | Tailscale | Nothing extra |
| Mac needs | Tailscale | An outbound connection |
| Turn on or off | `yochi tailnet on\|off` | `yochi relay setup` / `use` / `off` |

The Gateway never listens on the LAN or localhost, and the tailnet is preferred whenever both are up. Being able to reach the Gateway isn't authorization: every connection still needs a paired device's token.

## Quick start

There is no App Store build yet. You build the app from source.

**Requirements**

- A Mac running Herdr, with `hc` on your `PATH`
- Rust (stable) for the Gateway, and Xcode with Swift 6 and [XcodeGen](https://github.com/yonaskolb/XcodeGen) for the app
- Tailscale on the Mac and the phone, **or** Node.js and a Cloudflare account for a Relay

**1. Install the Gateway and keep it running**

```sh
cargo install --path gateway   # installs `yochi` into ~/.cargo/bin
yochi service install          # LaunchAgent: starts at login, restarts if it crashes
yochi service status
```

**2. Optional: deploy a Relay** so the phone works off the tailnet

```sh
yochi relay setup                              # Worker on *.workers.dev
yochi relay setup --domain relay.example.com   # or on a hostname in your Cloudflare zone
```

**3. Build the app**

```sh
cd ios
scripts/fetch-libghostty.sh
xcodegen generate
open Companion.xcodeproj
```

To run on a device, put your signing team in `ios/Local.xcconfig` (not in git). A free Personal Team also needs a bundle ID suffix:

```
DEVELOPMENT_TEAM = ABCDE12345
BUNDLE_ID_SUFFIX = .yourname
```

**4. Pair**

```sh
yochi pair
```

Scan the QR code with the iPhone camera. It opens a `yochi://pair` link in the app. You can also type the Mac's tailnet address and the 8-character code into the app. The code works once and expires after five minutes.

## CLI reference

```text
yochi [OPTIONS] [COMMAND]
```

| Command | What it does |
| --- | --- |
| `yochi` / `yochi serve` | Run the Gateway in the foreground (the default) |
| `yochi pair` | Show a single-use pairing code and QR code, valid for five minutes |
| `yochi devices` | List paired devices |
| `yochi revoke <ID>` | Unpair a device. Its open connections close within seconds |
| `yochi tailnet on` | Listen on the tailnet whenever this Mac is on it (the default) |
| `yochi tailnet off` | Stop listening on the tailnet and close its connections. Phones then come in only through the Relay |
| `yochi tailnet status` | Whether the tailnet is on, this Mac's address and whether the Gateway is listening there |
| `yochi relay setup [--domain <host>] [--name <worker>]` | Deploy a Relay to your Cloudflare account (Workers, free plan) and use it. Needs Node.js. wrangler asks you to log in the first time |
| `yochi relay use <URL> [--key <KEY>]` | Use a Relay you already run. The running Gateway connects within seconds |
| `yochi relay status` | The Relay in use, whether the Gateway is connected and how many phones can use it |
| `yochi relay rotate` | Move this Gateway to a new address on the Relay. The old one, and pairing links that carry it, stop working |
| `yochi relay off` | Stop using the Relay |
| `yochi service install` | Install or update the LaunchAgent and start it, with the current settings |
| `yochi service status` | Whether the LaunchAgent is installed and running, where it listens and where it logs |
| `yochi service uninstall` | Stop the LaunchAgent and remove it |

| Option | Environment | Default |
| --- | --- | --- |
| `--listen <ADDR>` | `YOCHI_LISTEN` | This Mac's tailnet IPv4, port `7420` |
| `--hc <PATH>` | `YOCHI_HC` | `hc` |
| `--state-dir <DIR>` | `YOCHI_STATE_DIR` | `~/Library/Application Support/Yochi` |
| `--key <KEY>` (`relay use`) | `YOCHI_RELAY_KEY` | none |

<details>
<summary><b>Notes on running it as a service</b></summary>

- `service install` records the absolute paths of `hc` and `tailscale`, since launchd doesn't inherit your shell's `PATH`, along with any `--listen` and `--state-dir` you pass.
- It refuses to install while another Gateway holds the port, so stop that one first.
- Logs go to `~/Library/Logs/Yochi/gateway.log`.
- If Tailscale is off or missing, the Gateway keeps serving through the Relay. It looks for a tailnet address every 5 seconds and starts listening there once one appears.
- With the tailnet off, `yochi pair` puts only Relay details in its link, so the phone doesn't need Tailscale. When the tailnet comes back, already-paired phones learn its address and switch over on their own.
- Upgrading from `companion-gateway`: `yochi service install` removes the old `dev.companion.gateway` agent, and pairings move from `~/Library/Application Support/Companion Gateway`. The iOS bundle ID is now `dev.yochi.app`, so the app installs as a new app and you'll need to pair again.

</details>

## Security model

- **Paired devices only.** Every endpoint except `/v0/pair` needs a device token. Pairing codes are single-use, last five minutes and are void after five wrong tries. `yochi revoke` cuts a device off within seconds.
- **A narrow API, not a proxy.** The Gateway allows a short list of herdr-core methods (`events.subscribe`, `terminal.*`, `file.read`, `machine.exec`) and uses the last two only internally: to read agent transcripts and to run a fixed set of read-only git commands. The phone never names a file path or a command.
- **The terminal is still a terminal.** A paired phone can type into the sessions it sees, and a shell can do anything your account can. Treat pairing like handing over an unlocked laptop, and revoke devices you no longer hold.
- **The Relay can't read your traffic.** App and Gateway run Noise IKpsk2 end to end. The pairing link carries the Gateway's static key and a one-time secret. The Relay forwards opaque frames and needs only a registration key, which you generate. It runs in your own account.

The design decisions behind all this are in [`docs/adr/`](docs/adr). The wire protocol is in [`protocol/README.md`](protocol/README.md).

## Development

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

# iOS: unit tests run in Xcode (⌘U). UI tests drive the simulator against a
# throwaway Gateway on port 7421 and a local Relay, so a Gateway on 7420 is left alone.
cd ios
scripts/ui-test.sh
TESTS="testFullScreenScrollsHistory testPairObserveAndUnpair" scripts/ui-test.sh
scripts/perf-test.sh   # frame pacing, time to first content, main-thread hangs
```

Code names: the repository and Xcode project are still called **Companion**. The product, CLI and bundle ID are **Yochi**.

## Repository layout

```
gateway/    Rust Gateway and the `yochi` CLI
ios/        SwiftUI app (XcodeGen project, libghostty fetched by script)
relay/      Self-hostable Relay: Cloudflare Worker or Node + Docker
protocol/   The versioned app ↔ Gateway API
docs/adr/   Architecture decision records
docs/diagrams/  Excalidraw sources for the diagrams above
GLOSSARY.md The project's vocabulary: Terminal, Agent, Space, Takeover…
```

## Acknowledgements

- [Ghostty](https://ghostty.org): libghostty renders every terminal in the app.
- [Heeler](https://github.com/ZingerLittleBee/Heeler) (Apache-2.0): the ANSI screen model and the Claude Code dialog reader are ported from it.
- [Alma Relay](https://github.com/yetone/alma-relay) (MIT): `relay/` is a fork, cut down to the WebSocket tunnel. See [`relay/LICENSE`](relay/LICENSE).
- Herdr: Yochi is a client of herdr-core and depends on its session runtime.
