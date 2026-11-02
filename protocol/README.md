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
  {"id": "vps-us/sp1", "machine": "vps-us", "name": "infra", "tabs": [
    {"id": "vps-us/tb1", "name": "1", "sessions": ["vps-us/t1"]}
  ]}
]
```

- `id` 对 App 不透明。`name` 已是要显示的名字：没人命名的 Space 用 Herdr 自动起的名字，没人命名的 Tab 用位置序号。
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

### 只读查看终端（Observer）

`ws://<host>:7420/v0/observe?session=<id>`，认证同上；会话不存在时返回 `404`。Gateway 为每个查看连接单独执行 `hc connect` 并以 `observe` 模式 attach，因此手机不会向终端输入，也不会改变终端尺寸。

- **文本帧**（控制）：
  ```jsonc
  {"type": "attached", "cols": 200, "rows": 120}  // 开始；App 按此尺寸渲染网格
  {"type": "size", "cols": 160, "rows": 48}       // 其他客户端改变了终端尺寸
  {"type": "closed", "reason": {"reason": "exited", "exit_code": 0, "signal": null}}
  {"type": "closed", "reason": "no terminal t9"}  // attach 失败时为字符串
  ```
- **二进制帧**：终端原始 VT 字节。先是首屏（当前屏幕和最多 1000 行历史），之后是程序输出。App 必须先把网格调整为 `cols × rows` 再写入这些字节。
- **流控**：Gateway 在字节发到 WebSocket 之后才向 core 归还 credit。手机读得慢时，core 会改发一次完整重绘，不会无限积压。
