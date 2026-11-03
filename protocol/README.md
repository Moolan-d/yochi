# Companion API

Gateway 向 Companion App 暴露的有版本接口（见 `GLOSSARY.md`）。

## v0

传输与认证的取舍见 ADR 0003。

- **连接**：所有接口都是 WebSocket，地址为 `ws://<主 Mac 的 tailnet IPv4>:7420/v0/…`。Gateway 只监听 tailnet 地址，不监听 LAN 或 localhost。
- **认证**：除配对外，都需带 HTTP 头 `Authorization: Bearer <设备 token>`。token 无效或设备已被撤销时返回 `401`。设备被撤销后，它已建立的连接会在几秒内被关闭。
- **加密**：明文 WebSocket，依赖 Tailscale（WireGuard）加密链路。

### 配对（Device Pairing）

`ws://<host>:7420/v0/pair`，不需要认证。配对码由主 Mac 上的 `companion-gateway pair` 生成：8 位，5 分钟内有效，单次使用，输错 5 次即作废。生成时同时显示二维码 `companion://pair?host=<host:port>&code=<code>`。比对配对码时不区分大小写，忽略 `-` 和空格，并把 O 视为 0、I 和 L 视为 1。

```jsonc
// App → Gateway，连接后 10 秒内发送
{"type": "pair", "code": "ABCD-EFGH", "name": "iPhone"}
// Gateway → App，随后关闭连接
{"type": "paired", "device": "8653add4", "token": "<64 位十六进制>"}
{"type": "rejected"}  // 配对码错误、过期或已作废
```

### 会话列表

`ws://<host>:7420/v0/ws`。Gateway 向 App 推送 JSON 文本帧：

```jsonc
// 连接建立后第一条
{"type": "hello", "api": 0, "gateway": "0.1.0"}

// 随后立即发送，并在会话列表变化时整表重发
{"type": "sessions", "core": "my-mac", "connected": true, "sessions": [
  {"id": "vps-us/t1", "machine": "vps-us", "title": "claude", "program": "claude",
   "cwd": "/root/app", "turn": 7,
   "status": {"state": "blocked", "app": "claude", "message": "Run ls?", "kind": "permission"}}
]}
```

- `id`：core 的地址，对 App 不透明。`machine`：远端机器名，主 Mac 本机为 `null`。
- `status`：Agent 自报状态，`state` 为 idle / working / done / blocked / error；未上报时为 `null`。
- `turn`：core 记录的最后已完成 Agent 轮次；没有该字段时 Gateway 返回 `0`。它会在状态离开 `working` 时增加。
- `connected: false` 表示 Gateway 暂时连不上本机 herdr-core，此时 `sessions` 为空。
- 只包含 live 会话，finished 的不返回。
- `cols` / `rows`：终端当前网格尺寸（上例省略）。
- `spaces`：Herdr 的 Space 与 Tab（见 GLOSSARY），按 Herdr 中的顺序，本机在前；上例省略。旧版 Gateway 不发送此字段，App 按缺省为空处理。

```jsonc
"spaces": [
  {"id": "vps-us/sp1", "machine": "vps-us", "name": "infra", "folder": "/root/infra", "tabs": [
    {"id": "vps-us/tb1", "name": "1", "sessions": ["vps-us/t1"]}
  ]}
]
```

- `id` 对 App 不透明。`name` 已是要显示的名字：没人命名的 Space 用 Herdr 自动起的名字，没人命名的 Tab 用位置序号。
- `folder`：Herdr 在这个 Space 里启动终端的目录，可能为空；App 用它为新建会话预选 Space。旧版 Gateway 不发送此字段。
- `sessions`：该 Tab 里的 live 会话 id，按分屏顺序；由 Agent 启动的子 Agent 排在后面，跟随启动它的终端。
- 只列出含 live 会话的 Space 和 Tab。不在任何 Space 中的会话不出现在这里，App 按机器单独列出。
- 数据来自各机器 herdr-core 中 Herdr 桌面端的布局文档，Gateway 只读不写。某台机器读不到布局（离线、没用过 Herdr 桌面端、core 不支持 `doc.get`）时，它的会话都不在 `spaces` 中。

App 也可以在这个连接上发送 `{"type": "unpair"}`。Gateway 收到后删除这台设备并关闭连接。

### Agent Message

在同一个 `/v0/ws` 连接上发送一整段消息，不需要 Takeover：

```jsonc
// App → Gateway；id 由客户端生成，force 默认为 false
{"type": "send", "id": "<客户端生成>", "session": "vps-us/t1",
 "text": "请继续实现这个任务", "force": false}

// Gateway → App
{"type": "sent", "id": "<客户端生成>", "turn": 7, "status": "working", "started": true}
{"type": "send_failed", "id": "<客户端生成>", "kind": "blocked",
 "message": "waiting for permission"}
```

Gateway 校验会话仍存在且 live、文本非空且 UTF-8 不超过 16 KiB。每次发送使用独立的 plain 模式 `hc connect`，经 `hello` 后调用 herdr-core 的 `terminal.send`，不阻塞会话列表推送。core 会等待终端约 3 秒无人输入后再粘贴并回车；Gateway 等待回复最多 30 秒。

`send_failed.kind` 包括 core 返回的 `not_found`、`machine_unknown`、`finished`、`unavailable`、`blocked`、`status_mismatch`、`invalid_params`、`config`，以及 Gateway 的 `too_long`、`unknown`、`timeout`。`blocked` 表示 Agent 正在等待权限或回答；App 必须让用户确认后才以 `force: true` 重发。

`sent.status` 是消息送入时的状态，`sent.started` 表示送入后几秒内是否进入 `working`；程序不上报状态时它们可以为 `null`。`started == false` 时 App 显示「Agent 尚未开始处理」，但仍属于已发送，不是失败。

`sent` 只表示 backend 已接受，不表示 Agent 已阅读。若送入时 `status != "working"`，此后会话 `turn > sent.turn` 可显示「Agent 已回应」。若送入时是 `working`，当前这一轮结束也会使 `turn` 增加，但消息可能排在下一轮，因此先显示「已发送 · Agent 正忙」，`turn > sent.turn` 时只显示「Agent 已结束一轮」，不能断言 Agent 已回应，也不要求再等一轮。

发送请求写出后的连接中断、无效回复或超时都使结果不明；App 显示「结果未知，可能已发送」，保留 Draft，不自动重试。

### 按键

在同一个 `/v0/ws` 连接上按命名按键，用于 Agent 的选择框、确认框和模式切换（ADR 0004）：

```jsonc
// App → Gateway；keys 为 core 的按键名，最多 8 个，按顺序按下
{"type": "keys", "id": "<客户端生成>", "session": "vps-us/t1", "keys": ["down", "enter"]}

// Gateway → App
{"type": "keys_sent", "id": "<客户端生成>"}
{"type": "keys_failed", "id": "<客户端生成>", "kind": "finished", "message": "finished"}
```

Gateway 经独立的 plain 模式 `hc connect` 调用 core 的 `terminal.keys`。它不 attach，因此不是 Takeover，不改变终端尺寸；core 同样等终端约 3 秒无人输入后再按。`kind` 同 Agent Message，另有 Gateway 的 `invalid_params`（按键为空、超过 8 个或会话不存在）、`unknown`、`timeout`。结果不明时 App 不自动重按。App 依次发送：上一个请求未返回时的点按合并进下一个请求，保证顺序。

### 作答（Agent Question）

回答 Agent 正在等待的批准或单选提问，同样在 `/v0/ws` 上：

```jsonc
// App → Gateway；expect 为 App 展示的 pending.message
{"type": "answer", "id": "<客户端生成>", "session": "t3", "choice": "allow", "expect": "approve Bash: date > stamp.txt"}
// Gateway → App：与按键相同
{"type": "keys_sent", "id": "<客户端生成>"}
{"type": "keys_failed", "id": "<客户端生成>", "kind": "changed", "message": "Agent 等待的内容已变化"}
```

- `choice`：权限请求为 `allow` 或 `deny`；提问为选项序号 `1`–`9`（按 transcript 中 `options` 的顺序），或 `deny` 取消。
- Gateway 先核对会话状态仍为 `blocked`、`status.message` 等于 `expect`，否则返回 `kind: "changed"`（例如桌面上已有人作答）。核对通过后按键：`allow` 按 `1`，`deny` 按 Esc，序号按对应数字（ADR 0004、实验 0001）。
- 核对与按键之间 core 仍要等约 3 秒无人输入，这段时间内桌面作答的竞争无法排除；App 不自动重试。
- 多题、多选和自由输入不支持，App 引导用户到终端作答。

### 新建会话

在同一个 `/v0/ws` 连接上让 Gateway 经 core 启动一个新终端：

```jsonc
// App → Gateway；machine 为 null 表示主 Mac；cwd 留空用 core 的默认目录；
// argv 为空时启动该机器的 shell；space 取自 spaces 列表、须在同一台机器上，省略表示新 Space
{"type": "run", "id": "<客户端生成>", "machine": "vps-us", "cwd": "/root/app", "argv": ["claude"], "space": "vps-us/sp1"}

// Gateway → App
{"type": "run_created", "id": "<客户端生成>", "session": "vps-us/t25"}
{"type": "run_failed", "id": "<客户端生成>", "kind": "machine_unknown", "message": "no such machine"}
```

Gateway 经独立的 plain 模式 `hc connect` 调用 core 的 `terminal.run`，带 `no_parent` 与 `no_notify`：Gateway 不是终端，新终端不会挂在它下面，也不会向任何父终端写入提示。它不 attach，因此不是 Takeover。

- `session` 已是会话列表里的 id（远端带机器前缀）；Gateway 通过 `sessions` 推送把新终端列出来，App 据此打开它。
- `kind` 同 Agent Message，常见为 `machine_unknown`、`spawn_failed`、`name_taken`、`invalid_params`。
- 请求写出后连接中断或超时，都返回 `unknown`：终端可能已经创建，App 提示到列表确认，不自动重试。
- 新终端带 `herdr.space` 标签（该机器上的 Space id），不带 `herdr.tab`：Herdr 桌面端在这个 Space 里新开一个 Tab 收进它，不会拆分已有的分屏；省略 `space` 时 Gateway 生成一个新 Space id，桌面端新建 Space 并按目录自动命名。Gateway 不写布局文档。
- 桌面端没开或连不上那台机器时，新终端暂不在任何 Space 中，App 按机器列出；桌面端之后打开时会收进去。
- App 只提供会话列表中出现过的远端机器；Gateway 本身把 `machine` 原样交给 core。

### 对话（Conversation History）

`ws://<host>:7420/v0/conversation?session=<id>`，认证和 `404` 同 Observer。Gateway 读取终端前台 Agent 的 Agent Transcript，转成条目推给 App。首个支持的 Agent 是 Claude Code：前台进程 pid → `~/.claude/sessions/<pid>.json`（当前 sessionId 和启动目录，`/clear` 后更新）→ `~/.claude/projects/<目录键>/<sessionId>.jsonl`，都经 core 的 `file.read` 读取，远端机器同样适用，不需要安装。

```jsonc
// 开始时、以及换了对话（/clear、Agent 重启）时：整份替换
{"type": "conversation", "supported": true, "items": [ … ]}
// 前台不是可解读的 Agent：App 只提供终端视图；之后若启动了 Claude Code 会再发 supported: true
{"type": "conversation", "supported": false, "items": []}
// 新增或变化的条目，按 id 覆盖
{"type": "items", "items": [ … ]}
// Agent 在等什么；不再等待时为 null
{"type": "pending", "pending": {"kind": "permission", "message": "approve Bash: date > stamp.txt", "tool": "toolu_01…"}}
// 会话结束或读取失败
{"type": "closed", "reason": "finished"}
```

条目（`kind` 区分）：

```jsonc
{"kind": "user", "id": "…", "text": "请继续"}
{"kind": "agent", "id": "…", "text": "Markdown 正文"}
{"kind": "tool", "id": "toolu_01…", "name": "Bash", "summary": "date > stamp.txt",
 "state": "running", "output": "前 40 行、2000 字节以内"}
{"kind": "tool", "id": "toolu_02…", "name": "AskUserQuestion", "summary": "Cats or Dogs?", "state": "done",
 "questions": [{"question": "Cats or Dogs?", "header": "Pet", "multi_select": false,
                "options": [{"label": "Cats", "description": "…"}, {"label": "Dogs", "description": "…"}]}],
 "answers": {"Cats or Dogs?": "Cats"}}
{"kind": "command", "id": "…", "name": "/model haiku", "output": "Set model to haiku"}
{"kind": "notice", "id": "…", "text": "上下文已压缩"}   // 也用于「已中断」和 API 错误
// 子代理或后台任务的完成汇报：Claude Code 把它记成一条 user 消息，但不是用户输入的
{"kind": "task", "id": "…", "summary": "Agent \"Find roadmap items\" finished", "state": "done",
 "text": "子代理的汇报（Markdown，后台命令没有）"}
```

- 只发显示所需的字段；thinking、用量、请求记录和附件不离开 Gateway。图片显示为「［图片］」。
- 首次只发最近 300 条，最多回溯 transcript 的最后 2000 行。
- `tool.state` 为 `running` / `done` / `error`；结果到达时同一 `id` 的条目被替换。
- `pending.tool` 是被询问的工具条目；状态先于 transcript 变化时可能暂为 `null`，下次读取后补上。
- Claude Code 的回复按内容块写入，没有逐字流式；Agent 工作中由会话状态表示。
- Gateway 在有 App 订阅时才读取：Agent 工作或等待时、以及状态变化后几秒内每秒一次，其余每 4 秒。core 的 `file.read` 每次读取整个文件，超过 64 MB 的 transcript 读取失败。

### 只读查看终端（Observer）

`ws://<host>:7420/v0/observe?session=<id>`，认证同上；会话不存在时返回 `404`。Gateway 为每个查看连接单独执行 `hc connect` 并以 `observe` 模式 attach，因此手机不会向终端输入，也不会改变终端尺寸。

- **文本帧**（控制）：
  ```jsonc
  {"type": "attached", "cols": 200, "rows": 120}  // 开始；App 按此尺寸收下首屏后再重排
  {"type": "size", "cols": 160, "rows": 48}       // 其他客户端改变了终端尺寸
  {"type": "closed", "reason": {"reason": "exited", "exit_code": 0, "signal": null}}
  {"type": "closed", "reason": "no terminal t9"}  // attach 失败时为字符串
  ```
- **二进制帧**：终端原始 VT 字节。先是首屏（当前屏幕和最多 1000 行历史），之后是程序输出。首屏按 core 的 `cols × rows` 绘制：App 先在同样大小的表面收下它，再把表面缩放到手机宽度让 Ghostty 重排，即可得到手机尺寸的终端；直接按别的大小写入首屏会错位。全屏 TUI 用绝对光标定位，重排后会错位——App 检测到全屏界面（首屏里的 `ESC[?1049h` 等切换）时不重排，按 core 的网格原样显示并缩放到手机宽度，可双指放大；程序进入或退出全屏时重新 attach。
- **流控**：Gateway 在字节发到 WebSocket 之后才向 core 归还 credit。手机读得慢时，core 会改发一次完整重绘，不会无限积压。

### 读屏（Screen）

`ws://<host>:7420/v0/screen?session=<id>`，认证同上；会话不存在时返回 `404`。供对话页识别 Claude Code 的对话框（ADR 0005）：Gateway 以 `observe` 模式 attach（不要历史），用 `vt100` 维护屏幕，只发文本帧：

```jsonc
// 屏幕安静 150 ms 后发；内容没变不发；Agent Status 为 working 时不发
{"type": "screen", "cols": 200, "rows": 50, "text": "…", "cursor": [49, 2]}
{"type": "closed", "reason": {"reason": "exited", "exit_code": 0, "signal": null}}
```

- `text`：可见的 `rows` 行，行间 `\r\n`；每次样式变化写一个从复位开始的 SGR（`ESC[0;…m`，只含粗体、暗色、斜体、反色和前景/背景色），行尾无背景的空白去掉。
- `cursor`：`[行, 列]`，从 0 开始；光标隐藏时为 `null`。
- 终端尺寸变化时按新尺寸重建屏幕。对话框的识别和作答按键都在 App 里，作答仍走「按键」消息。
