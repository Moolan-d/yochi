# Yochi API

The versioned interface the Gateway exposes to the Yochi app.

English | [简体中文](./README.zh-CN.md)

## v0

The transport and authentication choices are in ADR 0003.

- **Connection:** every endpoint is a WebSocket at `ws://<main Mac's tailnet IPv4>:7420/v0/…`. The Gateway listens on the tailnet address only, never on the LAN or localhost.
- **Authentication:** every endpoint except pairing needs the HTTP header `Authorization: Bearer <device token>`. An invalid token or a revoked device returns `401`. Once a device is revoked, its open connections close within seconds.
- **Encryption:** plain WebSocket, encrypted by the Tailscale (WireGuard) link. Through the Relay, see “Connecting through the Relay” below.
- **Language:** the app adds `lang=<BCP 47 language tag>` to every `/v0/…` URL (the language of its interface, e.g. `en`, `zh-Hans`), and the Relay forwards it with `path`. Text the Gateway writes itself (failure reasons, a conversation's “interrupted”, “[Image]”, “(N more lines)”) follows it: anything starting with `zh` gets Chinese, everything else English. An old app that sends no `lang` gets Chinese. Text written by herdr-core, by git and by Agents is passed through, not translated. An old Gateway ignores `lang` and still sends Chinese.

### Device pairing

`ws://<host>:7420/v0/pair`, no authentication. The code comes from `yochi pair` on the main Mac: 8 characters, valid for five minutes, single use, void after five wrong tries. It also shows the QR code `yochi://pair?host=<host:port>&code=<code>`. Codes compare ignoring case, `-` and spaces, with O read as 0 and I and L as 1.

```jsonc
// App → Gateway, sent within 10 seconds of connecting
{"type": "pair", "code": "ABCD-EFGH", "name": "iPhone"}
// Gateway → App, then closes the connection
{"type": "paired", "device": "8653add4", "token": "<64 hex digits>"}
{"type": "rejected"}  // wrong, expired or already used code
```

With a Relay configured (`yochi relay use`) the QR code becomes link v2, so a phone that isn't on the tailnet can pair through the Relay:

```
yochi://pair?v=2&host=<host:port>&code=<code>&key=<Gateway public key>&relay=<relay URL, percent-encoded>&route=<route token>&secret=<link secret>
```

- `key` and `secret` are 32 bytes, base64url without padding; `route` is base64url too.
- `secret` belongs to the same pairing as the code: single use, valid for five minutes. The code is used on the tailnet only and `secret` through the Relay only; using either one ends this pairing.
- When the tailnet is off (`yochi tailnet off`) or the Mac isn't on it, the link carries no `host` and no `code`: the phone pairs and connects through the Relay only, and the `tailnet` message below fills in the tailnet address afterwards.

### Session list

`ws://<host>:7420/v0/ws`. The Gateway pushes JSON text frames to the app:

```jsonc
// The first frame after connecting
{"type": "hello", "api": 0, "gateway": "0.1.0"}

// Sent right after, and again in full whenever the list changes
{"type": "sessions", "core": "my-mac", "connected": true, "sessions": [
  {"id": "vps-us/t1", "machine": "vps-us", "title": "claude", "program": "claude", "command": "claude",
   "cwd": "/root/app", "turn": 7, "status_ms": 1762156800000, "parent": "vps-us/t0",
   "pinned": true, "seen": 6, "repo": {"name": "app", "worktree": "fix-login"},
   "todo": {"text": "Writing the tests", "done": 3, "total": 7},
   "status": {"state": "blocked", "app": "claude", "message": "Run ls?", "kind": "permission"}}
]}
```

- `id`: the core's address, opaque to the app. `machine`: the remote machine's name, `null` for the main Mac.
- `program`: the program running in the terminal now; `command`: the command the terminal itself started, unchanged when the program changes inside the shell, omitted when it was started with the default shell. Both are the command name; for a script run by an interpreter, the script's name (`node …/gemini.js` is `gemini`). The app picks the session's form from `command`: `claude` opens the conversation page, anything else the terminal page; `program` and `status` say whether it is an Agent. An old Gateway sends no `command`.
- `status`: the status the Agent reports, `state` one of idle / working / done / blocked / error; `null` when it reports none.
- `status_ms`: when the status last changed (the Mac's clock, in milliseconds); the app shows “working · 12s” from it. Omitted when absent.
- `parent`: the terminal that started it (a child Agent's parent); omitted when absent.
- `title`: the terminal's title, where Claude Code writes its session title; the spinner characters at its start are stripped.
- `pinned`: pinned in Herdr (the `herdr.pinned` label); omitted when absent. `seen`: the turn seen in Herdr's desktop app (`herdr.seen`); omitted when absent.
- `repo`: the git repository the directory is in; `name` is the main checkout's folder name, `worktree` the linked worktree's folder name (omitted outside a worktree); omitted when it isn't a repository or isn't known yet.
- `todo`: the in-progress item of the newest to-do list while the Agent works (`text`, using `activeForm`) and how far the list is, `done` of `total`; only while Claude Code is `working`.
- `turn`: the last completed Agent turn recorded by core; the Gateway returns `0` when the field is absent. It increases when the status leaves `working`.
- `connected: false` means the Gateway cannot reach this Mac's herdr-core for now, and `sessions` is then empty.
- Only live sessions are included; finished ones are not returned.
- `cols` / `rows`: the terminal's current grid size (omitted in the examples).
- `spaces`: Herdr's Spaces and Tabs, in Herdr's order, this Mac first; omitted in the examples. An old Gateway doesn't send it, and the app treats it as empty.

```jsonc
"spaces": [
  {"id": "vps-us/sp1", "machine": "vps-us", "name": "infra", "folder": "/root/infra", "tabs": [
    {"id": "vps-us/tb1", "name": "1", "sessions": ["vps-us/t1"]}
  ]}
]
```

- `id` is opaque to the app. `name` is already the name to show: a Space nobody named uses the name Herdr gave it, a Tab nobody named its position.
- `folder`: the directory Herdr starts terminals in for this Space, possibly empty; the app preselects the Space for a new session with it. An old Gateway doesn't send it.
- `sessions`: the live session ids in that Tab, in pane order; Agents started by an Agent aren't in the layout but follow the terminal that started them (and that terminal's earlier child Agents).
- `layout`: the Tab's split tree, which the app draws a thumbnail from. A node is either a split — `split` is `row` (side by side) or `column` (stacked), `children` the child nodes — or a pane: `session` is the live session it shows, and a pane without one shows something else (a file browser) or a finished terminal. `weight` is the node's share of its split, equal shares when absent. Child Agents aren't in the tree. An old Gateway doesn't send it.

```jsonc
"layout": {"split": "row", "children": [
  {"weight": 0.6, "session": "t3"},
  {"weight": 0.4, "split": "column", "children": [{"session": "t4"}, {}]}
]}
```

- Only Spaces and Tabs holding live sessions are listed. Sessions in no Space don't appear here; the app lists them per machine.
- The data comes from the layout document Herdr's desktop app keeps in each machine's herdr-core, which the Gateway only reads. When a machine's layout can't be read (offline, the desktop app never used there, core without `doc.get`), none of its sessions appear in `spaces`.

The app may also send `{"type": "unpair"}` on this connection. The Gateway then deletes this device and closes the connection.

Paired devices enrol with the Relay on this connection (ADR 0006). The app enrols once each time it connects over the tailnet, and so learns the current relay address and psk:

```jsonc
// App → Gateway; static_key is the app's Noise static public key (32 bytes, base64url)
{"type": "relay_enroll", "static_key": "…"}
// Gateway → App
{"type": "relay", "available": true, "url": "https://relay.example.com", "route": "…", "gateway_key": "…", "psk": "…"}
{"type": "relay", "available": false}  // no Relay configured; on error it also carries "error"
```

Enrolling again with the same static key returns the same psk; a new static key gets a new psk and the old one stops working at once. One static key belongs to one device only.

After `hello`, and whenever the tailnet address changes, the Gateway tells the app where it is on the tailnet. A connection over the tailnet and one over the Relay both get it, so the app updates the address it stored and doesn't need to scan the code again:

```jsonc
// Gateway → App
{"type": "tailnet", "host": "100.64.0.1:7420"}
{"type": "tailnet", "host": null}  // tailnet off (`yochi tailnet off`), Relay only
```

When the Mac isn't on the tailnet for now nothing is sent, and the app keeps the address it has. When the tailnet is turned off, the Gateway closes the connections over the tailnet; connections through the Relay are unaffected.

### Agent Message

Send a whole message on the same `/v0/ws` connection; no Takeover needed:

```jsonc
// App → Gateway; the id is made by the client, force defaults to false
{"type": "send", "id": "<made by the client>", "session": "vps-us/t1",
 "text": "Please implement this task", "force": false}

// Gateway → App
{"type": "sent", "id": "<made by the client>", "turn": 7, "status": "working", "started": true}
{"type": "send_failed", "id": "<made by the client>", "kind": "blocked",
 "message": "waiting for permission"}
```

The Gateway checks that the session still exists and is live, and that the text isn't empty and is at most 16 KiB of UTF-8. Each send uses its own plain-mode `hc connect`; after `hello` it calls herdr-core's `terminal.send` without holding up the session list. core waits until the terminal has had no input for about three seconds, then pastes and presses Return; the Gateway waits up to 30 seconds for a reply.

`send_failed.kind` includes core's `not_found`, `machine_unknown`, `finished`, `unavailable`, `blocked`, `status_mismatch`, `invalid_params` and `config`, plus the Gateway's `too_long`, `unknown` and `timeout`. `blocked` means the Agent is waiting for permission or an answer; the app must have the user confirm before sending again with `force: true`.

`sent.status` is the status when the message went in, and `sent.started` whether it entered `working` within a few seconds of that; both may be `null` when the program reports no status. With `started == false` the app shows “the Agent hasn't started on this yet”, but the message still counts as sent, not failed.

`sent` only means the backend accepted it, not that the Agent read it. If `status != "working"` at that moment, `turn > sent.turn` afterwards can show “the Agent has replied”. If it was `working`, the end of that turn also increases `turn`, but the message may be queued for the next one, so the app first shows “Sent · Agent busy”, and `turn > sent.turn` only shows “the Agent finished a turn”: it can't claim a reply, and doesn't wait for another turn.

A connection lost after the request was written, an invalid reply or a timeout all leave the outcome unknown; the app shows “Outcome unknown, it may have been sent”, keeps the draft and doesn't retry by itself.

### Keys

Press named keys on the same `/v0/ws` connection, for an Agent's pickers, confirmations and mode switches (ADR 0004):

```jsonc
// App → Gateway; keys are core's key names, at most 8, pressed in order
{"type": "keys", "id": "<made by the client>", "session": "vps-us/t1", "keys": ["down", "enter"]}

// Gateway → App
{"type": "keys_sent", "id": "<made by the client>"}
{"type": "keys_failed", "id": "<made by the client>", "kind": "finished", "message": "finished"}
```

The Gateway calls core's `terminal.keys` over its own plain-mode `hc connect`. It doesn't attach, so this is not a Takeover and doesn't change the terminal's size; core again waits until the terminal has had no input for about three seconds. `kind` is as for Agent Message, plus the Gateway's `invalid_params` (no keys, more than 8, or no such session), `unknown` and `timeout`. When the outcome is unknown the app doesn't press again by itself. The app sends in order: taps made while an earlier request is unanswered are folded into the next request.

### Interrupt

End the Agent's current turn on the same `/v0/ws` connection:

```jsonc
// App → Gateway
{"type": "interrupt", "id": "<made by the client>", "session": "vps-us/t1"}
// Gateway → App
{"type": "interrupted", "id": "<made by the client>", "outcome": "stopped"}
{"type": "interrupt_failed", "id": "<made by the client>", "kind": "finished", "message": "finished"}
```

The Gateway calls core's `terminal.interrupt` over its own plain-mode `hc connect` (watching for five seconds): a program that reports status gets Esc, anything else Ctrl+C, pressed once and never escalating. It doesn't attach, so it isn't a Takeover.

- `outcome`: `stopped` (it left `working`), `exited`, `still_working` (nothing changed in five seconds), `unknown` (the program reports no status).
- `kind` is as for Agent Message, plus the Gateway's `not_found`, `unknown` and `timeout`. When the outcome is unknown the app doesn't press again by itself.
- The app offers stop only while the Agent is `working`; when it is `blocked`, Esc would cancel the dialog, which the dialog card handles.

### Image attachment

Put a file next to the terminal and reply with its path on the machine that terminal is on. The app fills the path into the draft and sends it with an Agent Message; Claude Code reads the image when it sees the path:

```jsonc
// App → Gateway; data is base64, at most 8 MB once decoded
{"type": "put", "id": "<made by the client>", "session": "vps-us/t1", "name": "image-20261103-192759-1.jpg", "data": "<base64>"}
// Gateway → App
{"type": "put_done", "id": "<made by the client>", "path": "/Users/me/.local/state/herdr-core/default/files/t1/image-20261103-192759-1.jpg"}
{"type": "put_failed", "id": "<made by the client>", "kind": "too_large", "message": "the image is over 8 MB"}
```

- The Gateway calls core's `terminal.put` over its own plain-mode `hc connect`; it doesn't attach, so it isn't a Takeover.
- `name` may contain only ASCII letters, digits and `.-_`, must not start with `.`, and is at most 100 characters, otherwise `kind: "invalid"`. No such session is `not_found`, too big is `too_large`; the rest is as for Agent Message, plus `unknown` and `timeout`.
- The app first shrinks the image's long side to 2048 pixels and encodes it as JPEG; at most 4 images per message.

### Slash commands

List the custom slash commands and skills a session has, for the app to complete from; built-in commands ship with the app:

```jsonc
// App → Gateway
{"type": "commands", "id": "<made by the client>", "session": "vps-us/t1"}
// Gateway → App; names carry the slash and are sorted by name
{"type": "command_list", "id": "<made by the client>", "commands": [{"name": "/research", "description": "Investigate a question", "source": "skill"}]}
{"type": "commands_failed", "id": "<made by the client>", "kind": "unreachable", "message": "no answer from any machine"}
```

- The Gateway runs a fixed read-only script over core's `machine.exec`, on the machine the session is on and in the session's working directory (10-second timeout); it lists the headers of the project's and the user's `.claude/commands/*.md` and `.claude/skills/*/SKILL.md`, then reads `name` and `description` from the frontmatter.
- `source`: `project`, `user`, `skill`. The project's wins on a duplicate name. At most 200 entries, descriptions clipped to 120 characters. Those that plugins bring aren't listed.
- `kind`: `not_found` when there is no such session; otherwise core's error kinds, `unavailable` or `timeout`. It is read-only, so a failure can simply be retried.

### Changes

The changes relative to HEAD in the git repository the session's working directory is in, untracked files included; read-only:

```jsonc
// App → Gateway
{"type": "changes", "id": "<made by the client>", "session": "vps-us/t1"}
// Gateway → App; sorted by path, at most 1000
{"type": "changes", "id": "<made by the client>", "repo": "app", "truncated": false, "files": [
  {"path": "ios/A.swift", "status": "M", "added": 12, "deleted": 3},
  {"path": "new.txt", "old_path": "old.txt", "status": "R", "added": 0, "deleted": 0},
  {"path": "logo.png", "status": "?"}
]}
{"type": "changes_failed", "id": "<made by the client>", "kind": "not_git", "message": "not a git repository"}

// One file; path must be one this session's latest changes listed
{"type": "change_diff", "id": "<made by the client>", "session": "vps-us/t1", "path": "ios/A.swift"}
{"type": "change_diff", "id": "<made by the client>", "patch": "diff --git a/ios/A.swift b/ios/A.swift\n…", "truncated": false}
{"type": "change_diff_failed", "id": "<made by the client>", "kind": "changed", "message": "these changes have changed, please refresh"}
```

- The Gateway runs fixed read-only git commands over core's `machine.exec`, on the machine the session is on: first it finds the repository root from the session's directory, then it runs in that root. All of them carry `--no-optional-locks -c core.fsmonitor=false -c diff.autoRefreshIndex=false` so they never write the index; diffs carry `--no-ext-diff --no-textconv`. A repository without commits is compared against the empty tree.
- `status`: `M` modified, `A` added, `D` deleted, `R` renamed (with `old_path`), `T` type change, `U` conflict, `?` untracked. Binary files have no `added` or `deleted`. A file whose timestamp alone changed (a modification with 0 added and 0 deleted) isn't listed.
- `patch` is the unified diff itself, at most 5000 lines and 512 KB; beyond that `truncated: true`. Untracked files are compared against `/dev/null`.
- `kind`: `not_found` (no such session), `not_git`, `changed` (the path isn't in the latest list, or the Gateway restarted), `timeout`, `unavailable`, and core's error kinds. It is read-only, so a failure can simply be retried.

### Answering an Agent

Answer the approval or single-choice question an Agent is waiting on, also on `/v0/ws`:

```jsonc
// App → Gateway; expect is the pending.message the app is showing
{"type": "answer", "id": "<made by the client>", "session": "t3", "choice": "allow", "expect": "approve Bash: date > stamp.txt"}
// Gateway → App: as for Keys
{"type": "keys_sent", "id": "<made by the client>"}
{"type": "keys_failed", "id": "<made by the client>", "kind": "changed", "message": "what the Agent waits for has changed"}
```

- `choice`: `allow` or `deny` for a permission request; `1`–`9` for a question (in the order of `options` in the transcript), or `deny` to cancel.
- The Gateway first checks that the session is still `blocked` and that `status.message` equals `expect`, and otherwise returns `kind: "changed"` (someone at the desk answered, say). Once that holds it presses keys: `1` for `allow`, Esc for `deny`, and the digit itself for a number (ADR 0004, experiment 0001).
- Between the check and the key presses core still waits about three seconds for input, and an answer at the desk during that window can't be ruled out; the app doesn't retry by itself.
- Multiple questions, multiple choices and free text aren't supported; the app sends the user to the terminal for those.

### New session

Have the Gateway start a new terminal through core on the same `/v0/ws` connection:

```jsonc
// App → Gateway; machine null means the main Mac; an empty cwd uses core's default;
// an empty argv starts that machine's shell; space comes from the spaces list and must be on the same machine, omitted means a new Space
{"type": "run", "id": "<made by the client>", "machine": "vps-us", "cwd": "/root/app", "argv": ["claude"], "space": "vps-us/sp1"}

// Gateway → App
{"type": "run_created", "id": "<made by the client>", "session": "vps-us/t25"}
{"type": "run_failed", "id": "<made by the client>", "kind": "machine_unknown", "message": "no such machine"}
```

The Gateway calls core's `terminal.run` over its own plain-mode `hc connect`, with `no_parent` and `no_notify`: the Gateway isn't a terminal, so the new terminal doesn't hang under it and gets no prompt written to any parent terminal. It doesn't attach, so it isn't a Takeover.

- `argv` isn't handed to core to start directly: the Gateway first starts that machine's shell (the login shell on macOS) and then types the command line built from `argv` (single-quoted where needed) into it with `terminal.send`, as Herdr's desktop app does. core starts programs with its own environment, and when launchd starts it, `PATH` lacks directories such as `~/.local/bin` that only the user's shell adds, so starting directly would fail with `spawn_failed`. The terminal stays in the shell once the program exits. When typing fails it still returns `run_created` and the app opens that shell. An old Gateway starts `argv` directly.
- `session` is already the id in the session list (with the machine's prefix for a remote one); the Gateway lists the new terminal in a `sessions` push, and the app opens it from that.
- `kind` is as for Agent Message, commonly `machine_unknown`, `spawn_failed`, `name_taken` and `invalid_params`.
- A connection lost after the request was written, or a timeout, both return `unknown`: the terminal may already exist, so the app tells the user to check the list and doesn't retry by itself.
- The new terminal carries the `herdr.space` label (the Space id on that machine) and no `herdr.tab`: Herdr's desktop app opens a new Tab in that Space and takes it in without splitting an existing pane; without `space` the Gateway makes up a new Space id, and the desktop app creates the Space and names it after the directory. The Gateway doesn't write the layout document.
- When the desktop app isn't running or can't reach that machine, the new terminal is in no Space for now and the app lists it per machine; the desktop app takes it in when it opens.
- The app only offers remote machines that have appeared in the session list; the Gateway passes `machine` to core as it is.

### Conversation history

`ws://<host>:7420/v0/conversation?session=<id>`, with authentication and `404` as for the Observer. The Gateway reads the Agent Transcript of the Agent in the terminal's foreground and turns it into items for the app. The first supported Agent is Claude Code: the foreground process's pid → `~/.claude/sessions/<pid>.json` (the current sessionId and startup directory, updated after `/clear`) → `~/.claude/projects/<directory key>/<sessionId>.jsonl`, both read through core's `file.read`; the same works on remote machines with nothing installed there.

```jsonc
// At the start, and whenever the conversation changes (/clear, Agent restart): the whole thing
{"type": "conversation", "supported": true, "items": [ … ]}
// The foreground isn't an Agent that can be read: the app offers only the terminal view; if Claude Code starts later, supported: true follows
{"type": "conversation", "supported": false, "items": []}
// Items added or changed, replacing by id
{"type": "items", "items": [ … ]}
// What the Agent is waiting for; null when it no longer waits
{"type": "pending", "pending": {"kind": "permission", "message": "approve Bash: date > stamp.txt", "tool": "toolu_01…"}}
// The permission mode, from the newest transcript message that recorded one; sent when it changes and after every conversation
{"type": "mode", "mode": "acceptEdits"}
// The session ended or couldn't be read
{"type": "closed", "reason": "finished"}
```

Items, told apart by `kind`:

```jsonc
{"kind": "user", "id": "…", "text": "Please continue"}
{"kind": "agent", "id": "…", "text": "Markdown body"}
{"kind": "tool", "id": "toolu_01…", "name": "Bash", "summary": "date > stamp.txt",
 "state": "running", "output": "the first 40 lines, up to 2000 bytes"}
// Edit, MultiEdit and Write carry edit once they succeed: patch is the unified diff's hunks (no file header), at most 200 lines and 16 KB
{"kind": "tool", "id": "toolu_03…", "name": "Edit", "summary": "/x/A.swift", "state": "done",
 "edit": {"path": "/x/A.swift", "added": 2, "deleted": 1, "patch": "@@ -3,3 +3,4 @@\n keep\n-old\n…", "truncated": false}}
// Write creating a file has "created": true, and a patch of the whole file as + lines
// Agent (formerly Task) carries agent; a background one is still running when its result arrives, and becomes done / error when the task-notification does
{"kind": "tool", "id": "toolu_04…", "name": "Agent", "summary": "Find roadmap items", "state": "running",
 "agent": {"name": "Find roadmap items", "type": "Explore", "started_ms": 1762156800000, "background": true}}
{"kind": "tool", "id": "toolu_02…", "name": "AskUserQuestion", "summary": "Cats or Dogs?", "state": "done",
 "questions": [{"question": "Cats or Dogs?", "header": "Pet", "multi_select": false,
                "options": [{"label": "Cats", "description": "…"}, {"label": "Dogs", "description": "…"}]}],
 "answers": {"Cats or Dogs?": "Cats"}}
{"kind": "command", "id": "…", "name": "/model haiku", "output": "Set model to haiku"}
{"kind": "notice", "id": "…", "text": "Context compacted", "code": "compacted"}   // also "Interrupted" and API errors
// A subagent's or a background task's completion report: Claude Code records it as a user message, but the user didn't type it
{"kind": "task", "id": "…", "summary": "Agent \"Find roadmap items\" finished", "state": "done",
 "text": "the subagent's report (Markdown; background commands have none)"}
// The to-do list: TaskCreate, TaskUpdate and TodoWrite are no longer tool items but the whole list at that moment
{"kind": "todos", "id": "toolu_05…", "items": [{"text": "Fix the watermark", "active": "Fixing the watermark", "status": "in_progress"}]}
// Messages between Agents: those sent (SendMessage) and those received from another Agent; name is omitted when unknown
{"kind": "peer", "id": "…", "direction": "received", "name": "static-workorder-2a", "text": "Fixed it…", "state": "done"}
```

- Only the fields the display needs are sent; thinking, usage, request records and attachments don't leave the Gateway. Images show as “[Image]”.
- A first connection gets the newest 300 items only, reading back at most the transcript's last 2000 lines.
- `tool.state` is `running` / `done` / `error`; when the result arrives, the item with the same `id` is replaced.
- `agent.started_ms` is the moment the transcript recorded; a synchronous subtask has `duration_ms` when it finishes, and a background one gets it when the notification arrives.
- `todos.items[].status` is `pending` / `in_progress` / `completed`; deleted items no longer appear. Several consecutive updates with no other item in between replace the same item; otherwise a new item starts.
- `peer.direction` is `sent` / `received`. A sent one's `state` is `running` first, then `done` or `error` when the result arrives. `name` is the subtask's description, or for a `uds:` address the name the peer gave in messages received from it.
- An old app doesn't know `todos` and `peer` items and skips them; new fields are ignored.
- `notice.code` says which notice it is: `interrupted`, `compacted`, and possibly new values later; API errors and the like have no `code`. The app shows a `code` it knows in its own words and everything else as `text` (already in the language chosen by `lang`). An old Gateway sends no `code`.
- `pending.tool` is the tool item being asked about; it may be `null` for a moment when the status changed before the transcript, and is filled in on the next read.
- `mode` passes Claude Code's value through (`default` / `acceptEdits` / `plan` / `auto` / `bypassPermissions`, possibly new values later). The transcript records the mode only when a message is sent: there is no `mode` before the first message, and a switch made in the terminal shows only with the next message. The app prefers the mode hint at the bottom of the screen, and switches by sending `shift+tab` as Keys, one at a time (ADR 0005).
- Claude Code writes its replies by content block, not word by word; the session's status says the Agent is working.
- The `drafts=1` parameter and the `draft` message that used to exist are gone: the Gateway ignores the parameter, so an old app that sends it works as before and simply gets no drafts.
- The Gateway reads only while an app is subscribed: once a second while the Agent works or waits, and for a few seconds after the status changes, otherwise every 4 seconds. core's `file.read` reads the whole file each time, and a transcript over 64 MB fails to read.

### Watching a terminal (Observer)

`ws://<host>:7420/v0/observe?session=<id>`, with authentication as above; `404` when there is no such session. The Gateway runs its own `hc connect` and attaches for each watching connection. By default it attaches in `observe` mode, which doesn't change the terminal's size, and the phone can't type into the terminal through this connection.

**Takeover at the phone's size.** With `takeover=1&cols=<columns>&rows=<rows>` it attaches in a non-observe mode, core resizes the terminal to that grid, and `attached` and the first screen follow it; a missing column or row count, or one outside 1…1000, returns `400`. While watching, the terminal at the desk shrinks too; when the connection closes, core restores the size of the desktop window still attached to it, or the base size when there is none. On a takeover connection the app may send `{"type": "resize", "cols": 49, "rows": 30}` (keyboard up or down, rotation), and the Gateway passes it on as core's RESIZE frame; such messages are ignored on a read-only connection. A full-screen program (Claude Code, say) keeps its own history and scrolls by mouse wheel, so the terminal has no scrollback to swipe: on a takeover connection the app sends the wheel reports its terminal made for a drag as they are, `{"type": "wheel", "data": "\u001b[<64;10;5M"}`, and the Gateway writes them to the program over the attach channel. `data` may only be made of SGR wheel reports (`ESC [ < b ; x ; y M`, b from 64 to 67, optionally with the shift/meta/ctrl bits) and the cursor up and down keys on the alt screen (`ESC [ A`/`B`, `ESC O A`/`B`), at most 4096 bytes, otherwise the whole message is dropped; taps, movement and typing never reach the terminal this way. When the desktop touches the terminal again its size goes back to the desktop's, reported in a `size` frame, and the app switches back to the read-only display (the 2026-11-04 revision of ADR 0001).

**Typing directly during a takeover.** On a takeover connection `attached` also carries `"input": true`, meaning the app may type at the terminal's cursor: it sends the bytes its terminal made for the keys as they are, `{"type": "input", "data": "ls\t"}`, and the Gateway writes them to the program over the attach channel, just as typing at the desk would (Tab completion, arrow keys and Ctrl combinations are all in there). `data` must not be empty and is at most 64 KiB (one paste), otherwise the whole message is dropped; `input` is always ignored on a read-only connection. The app sends only what the user pressed, not its terminal's answers to queries (DA, DSR, OSC color and so on), which core has already answered. An old Gateway's `attached` has no `input`, so the app doesn't offer direct typing and keys still go through `terminal.keys`; an old app doesn't know the field and works as before (the 2026-11-09 revision of ADR 0001).

- **Text frames** (control):
  ```jsonc
  {"type": "attached", "cols": 200, "rows": 120}  // the start; the app takes the first screen at this size (and reflows it when read-only)
  {"type": "attached", "cols": 49, "rows": 45, "resume": "9f2c…", "keep_ms": 30000}  // with resumable=1
  {"type": "attached", "cols": 49, "rows": 45, "input": true}  // during a takeover: input may be sent
  {"type": "resumed", "resume": "41ab…", "keep_ms": 30000}  // back again; binary frames continue from offset
  {"type": "size", "cols": 160, "rows": 48}       // the terminal's size changed (another client, or this takeover's resize)
  {"type": "closed", "reason": {"reason": "exited", "exit_code": 0, "signal": null}}
  {"type": "closed", "reason": "no terminal t9"}  // a string when the attach failed
  ```
- **Binary frames**: the terminal's raw VT bytes. First the first screen (the current screen and up to 1000 lines of history), then the program's output. The first screen is drawn at core's `cols × rows`: the app takes it on a surface of that size first, then scales the surface to the phone's width and lets Ghostty reflow it, which gives a terminal at the phone's size; writing the first screen at any other size would misplace it. Full-screen TUIs position the cursor absolutely and the reflow would misalign them: when the app sees a full-screen interface (the `ESC[?1049h` switch and the like in the first screen) it doesn't reflow but shows core's grid as it is, scaled to the phone's width, with pinch to zoom; it attaches afresh when the program enters or leaves full screen.
- **Flow control**: the Gateway gives credit back to core only after the bytes have gone out to the WebSocket. When the phone reads slowly, core sends a full redraw instead of letting the buffer grow without bound.

**Resuming a dropped stream.** With `resumable=1`, `attached` also carries `resume` (a token) and `keep_ms`. If the connection then closes for any reason other than the app sending `{"type": "detach"}` (a lost network, the app going to the background, a closed connection), the Gateway doesn't end core's attach but keeps it for `keep_ms` (30 seconds): the takeover size stays, core's output is recorded for replay, and its credit is held back. The app comes back with `/v0/observe?session=<id>&resume=<token>&offset=<binary bytes received>` (without `takeover` and the like), the Gateway replies `resumed` (with a new token; the old one is void), sends from byte `offset` on and then follows along; a size change during the hold sends a `size` right after. It may also come back while the old connection is still open (the tailnet switching to the Relay), and the old connection closes with it. The token is good for the original device and session only; a token it doesn't know, an expired one, or an `offset` beyond the bytes sent or no longer in the buffer (the last 4 MiB) returns `410` (close code 4410 through the Relay), and the app attaches afresh. A connection without `resumable=1` lets go as soon as it closes, as before. When the app leaves the terminal page it sends `{"type": "detach"}` before closing, and the Gateway lets go at once; every connection accepts this message.

**Heartbeat.** The Gateway pings every 15 seconds on `/v0/observe` and treats 45 seconds without any message from the app (pongs included) as a dropped connection: a resumable stream goes into its hold, any other is let go.

### Reading the screen

`ws://<host>:7420/v0/screen?session=<id>`, with authentication as above; `404` when there is no such session. For the conversation page to recognize Claude Code's dialogs (ADR 0005): the Gateway attaches in `observe` mode (no history), keeps the screen with `vt100` and sends text frames only:

```jsonc
// Sent once the screen has been quiet for 150 ms; not sent when nothing changed, nor while the Agent Status is working
{"type": "screen", "cols": 200, "rows": 50, "text": "…", "cursor": [49, 2]}
{"type": "closed", "reason": {"reason": "exited", "exit_code": 0, "signal": null}}
```

- `text`: the visible `rows` rows, with `\r\n` between them; every style change writes an SGR starting from a reset (`ESC[0;…m`, carrying only bold, dim, italic, reverse and foreground/background colors), and trailing spaces with no background are trimmed.
- `cursor`: `[row, column]`, from 0; `null` while the cursor is hidden.
- The screen is rebuilt at the new size when the terminal's size changes. Recognizing a dialog and the keys that answer it are both in the app; answering still goes through Keys.

### Connecting through the Relay

When the phone isn't on the tailnet it connects through the Relay (ADR 0006). The relay protocol is in `relay/PROTOCOL.md`; the relay forwards binary frames only and never sees plaintext.

1. **Connect**: the app opens `wss://<relay>/c/<route token>`. When the relay can't find this Gateway (offline, or the wrong route) it returns `502`.
2. **Handshake**: Noise `Noise_IKpsk2_25519_ChaChaPoly_SHA256`, prologue `yochi-relay-v1`, the psk in position 2. The app is the initiator and knows the Gateway's static public key in advance (`key` / `gateway_key`). Each handshake message is one binary WebSocket message with an empty payload.
   - A device that has enrolled uses the psk it got then; a phone in the middle of pairing uses link v2's `secret`.
   - After reading the first handshake message, the Gateway picks the psk by the app's static public key: first a device, then a waiting pairing. With neither it closes, with close code `4401`.
   - With the wrong psk the app can't read the second handshake message and should close the connection.
3. **Request**: the first message after the handshake is JSON text saying what it wants:
   ```jsonc
   {"path": "/v0/observe?session=t1&takeover=1&cols=49&rows=45"}  // a paired device: any /v0/ endpoint but /v0/pair
   {"path": "/v0/pair", "name": "iPhone"}                        // pairing with a secret
   ```
   When pairing, the Gateway answers with one text message and closes with `1000`. The device token is for the tailnet only; the psk is for later connections through the Relay:
   ```jsonc
   {"type": "paired", "device": "8653add4", "token": "<64 hex digits>", "psk": "…"}
   {"type": "rejected"}
   ```
4. **After that**: messages are exactly those of the endpoint of the same name on the tailnet, with the handshake doing the authentication and no Bearer token. An endpoint refusing closes with `4000 + HTTP status`, `4404` for a session that doesn't exist, say. An invalid request is `4400`.

**Fragmentation**: each WebSocket message is encrypted as one or more Noise messages, each sent as its own binary WebSocket message. The plaintext is `[flags][payload]`: bit 0 set means a binary message (text otherwise), bit 1 set means more fragments follow. A Noise message carries at most 65535 bytes, so each fragment carries at most 65518 payload bytes; a reassembled message is at most 64 MiB. Noise messages can't be replayed or reordered, and a failed decryption ends the connection.

### Many streams on one connection (`/v0/mux`)

A page doesn't need a connection of its own: the app may connect to `/v0/mux` once and open any number of streams on it, each equal to connecting to that endpoint by itself (ADR 0007). Through the Relay this saves the relay connection and the Noise handshake round trips for every page entered; on the tailnet it saves a TCP handshake. Authentication is as for the other endpoints: the Bearer token on the tailnet, the handshake through the Relay, with streams inheriting the mux's authentication. An old Gateway has no such endpoint and returns `404` (`4404` through the Relay), and the app connects separately as before.

Each WebSocket message is one binary frame: `[stream id: u32][kind: u8][payload]`, little endian.

| kind | direction | payload |
| --- | --- | --- |
| 0 OPEN | App → Gateway | the endpoint's path and query, UTF-8, e.g. `/v0/observe?session=t1&resumable=1` |
| 1 TEXT | both | one text message on this stream |
| 2 BINARY | both | one binary message on this stream |
| 3 CLOSE | both | `[code: u16][reason]`, this stream ends |

- **Stream id** is assigned by the app, never 0, and never reused on the same mux. 0 is the mux's own: once it accepts the connection, the Gateway sends TEXT `{"type": "mux", "v": 1}` on it.
- **After OPEN** the app needn't wait for a reply and may send this stream's messages right away. The endpoint's first message is the reply.
- **Ending**: an endpoint refusing closes with `4000 + HTTP status` (as through the Relay, e.g. `4404`, `4410`). An endpoint closing by itself carries its own close code. Endpoints that can't be opened (`/v0/pair`, `/v0/mux`) are `4400`. An app CLOSE is the same as closing that connection, which for a terminal stream is a drop and can be resumed; leaving still sends `detach` first.
- **Limits**: a mux carries at most 32 streams; an OPEN beyond that closes with `1013`. The Gateway buffers 64 messages from the app per stream, and a stream whose endpoint falls behind closes with `1013` without affecting the others.
- **Heartbeat**: the Gateway pings every 15 seconds and closes the mux after 45 seconds without hearing from the app, dropping all its streams with it.
