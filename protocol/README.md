# Companion API

Gateway 向 Companion App 暴露的有版本接口（见 `GLOSSARY.md`）。

## v0

传输与认证的取舍见 ADR 0003。

- **连接**：所有接口都是 WebSocket，地址为 `ws://<主 Mac 的 tailnet IPv4>:7420/v0/…`。Gateway 只监听 tailnet 地址，不监听 LAN 或 localhost。
- **认证**：除配对外，都需带 HTTP 头 `Authorization: Bearer <设备 token>`。token 无效或设备已被撤销时返回 `401`。设备被撤销后，它已建立的连接会在几秒内被关闭。
- **加密**：明文 WebSocket，依赖 Tailscale（WireGuard）加密链路。经 Relay 时见下文「经 Relay 连接」。
- **语言**：App 在每个 `/v0/…` 地址后带查询参数 `lang=<BCP 47 语言标签>`（App 界面当前的语言，如 `en`、`zh-Hans`），经 Relay 时随 `path` 一起转发。Gateway 自己写的文字（失败原因、对话里的「已中断」「［图片］」「（另有 N 行）」等）按它选语言：`zh` 开头为中文，其余为英文。不带 `lang` 的旧 App 得到中文。herdr-core、git 和 Agent 写的内容原样转发，不翻译。旧版 Gateway 忽略 `lang`，仍发中文。

### 配对（Device Pairing）

`ws://<host>:7420/v0/pair`，不需要认证。配对码由主 Mac 上的 `yochi pair` 生成：8 位，5 分钟内有效，单次使用，输错 5 次即作废。生成时同时显示二维码 `yochi://pair?host=<host:port>&code=<code>`。比对配对码时不区分大小写，忽略 `-` 和空格，并把 O 视为 0、I 和 L 视为 1。

```jsonc
// App → Gateway，连接后 10 秒内发送
{"type": "pair", "code": "ABCD-EFGH", "name": "iPhone"}
// Gateway → App，随后关闭连接
{"type": "paired", "device": "8653add4", "token": "<64 位十六进制>"}
{"type": "rejected"}  // 配对码错误、过期或已作废
```

配置了 Relay（`yochi relay use`）时，二维码改为 link v2，App 不在 tailnet 上也能经 Relay 配对：

```
yochi://pair?v=2&host=<host:port>&code=<code>&key=<Gateway 公钥>&relay=<中继地址，百分号编码>&route=<route token>&secret=<link secret>
```

- `key`、`secret` 都是 32 字节，base64url 不带填充；`route` 也是 base64url。
- `secret` 与配对码属于同一次配对：单次使用，5 分钟内有效。配对码只在 tailnet 上用，`secret` 只在 Relay 上用，用掉任一个这次配对就结束。
- Gateway 的 tailnet 关着（`yochi tailnet off`）或 Mac 不在 tailnet 上时，链接不带 `host` 和 `code`，手机只经 Relay 配对和连接，之后由下面的 `tailnet` 消息补上 tailnet 地址。

### 会话列表

`ws://<host>:7420/v0/ws`。Gateway 向 App 推送 JSON 文本帧：

```jsonc
// 连接建立后第一条
{"type": "hello", "api": 0, "gateway": "0.1.0"}

// 随后立即发送，并在会话列表变化时整表重发
{"type": "sessions", "core": "my-mac", "connected": true, "sessions": [
  {"id": "vps-us/t1", "machine": "vps-us", "title": "claude", "program": "claude", "command": "claude",
   "cwd": "/root/app", "turn": 7, "status_ms": 1762156800000, "parent": "vps-us/t0",
   "pinned": true, "seen": 6, "repo": {"name": "app", "worktree": "fix-login"},
   "todo": {"text": "写测试中", "done": 3, "total": 7},
   "status": {"state": "blocked", "app": "claude", "message": "Run ls?", "kind": "permission"}}
]}
```

- `id`：core 的地址，对 App 不透明。`machine`：远端机器名，主 Mac 本机为 `null`。
- `program`：终端里现在跑的程序；`command`：终端本身启动的命令，在 shell 里换程序时不变，用默认 shell 启动时省略。两者都取命令名，解释器跑的脚本取脚本名（`node …/gemini.js` 为 `gemini`）。App 据 `command` 定会话形式：`claude` 走对话页，其余走终端页；据 `program` 和 `status` 判断是不是 Agent。旧版 Gateway 不发送 `command`。
- `status`：Agent 自报状态，`state` 为 idle / working / done / blocked / error；未上报时为 `null`。
- `status_ms`：状态上次变化的时刻（Mac 的时钟，毫秒）；App 据此显示「工作中 · 12s」。没有时省略。
- `parent`：启动它的终端（子 Agent 的父 Agent）；没有时省略。
- `title`：终端标题，Claude Code 在这里写它的会话标题；开头的转圈字符已去掉。
- `pinned`：在 Herdr 里置顶（`herdr.pinned` 标签）；没有时省略。`seen`：Herdr 桌面端看过的轮次（`herdr.seen`）；没有时省略。
- `repo`：目录所在的 git 仓库，`name` 是主检出的文件夹名，`worktree` 是链接 worktree 的文件夹名（不在 worktree 里时省略）；不是仓库或还没查到时省略。
- `todo`：Agent 工作时最新待办清单里进行中的那项（`text`，用 `activeForm`）和完成数 `done` / 总数 `total`；只有 Claude Code 在 `working` 时才有。
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
- `sessions`：该 Tab 里的 live 会话 id，按分屏顺序；由 Agent 启动的子 Agent 不在布局里，紧跟在启动它的终端（和它之前的子 Agent）后面。
- 只列出含 live 会话的 Space 和 Tab。不在任何 Space 中的会话不出现在这里，App 按机器单独列出。
- 数据来自各机器 herdr-core 中 Herdr 桌面端的布局文档，Gateway 只读不写。某台机器读不到布局（离线、没用过 Herdr 桌面端、core 不支持 `doc.get`）时，它的会话都不在 `spaces` 中。

App 也可以在这个连接上发送 `{"type": "unpair"}`。Gateway 收到后删除这台设备并关闭连接。

已配对的设备在这个连接上登记 Relay（ADR 0006）。App 每次在 tailnet 上连上时登记一次，从而拿到当前的中继地址和 psk：

```jsonc
// App → Gateway；static_key 是 App 的 Noise 静态公钥（32 字节，base64url）
{"type": "relay_enroll", "static_key": "…"}
// Gateway → App
{"type": "relay", "available": true, "url": "https://relay.example.com", "route": "…", "gateway_key": "…", "psk": "…"}
{"type": "relay", "available": false}  // 没配置 Relay；出错时另带 "error"
```

静态公钥不变时，重复登记拿到同一个 psk；换了静态公钥会得到新 psk，旧的立即失效。同一个静态公钥只属于一台设备。

Gateway 在 hello 之后、以及 tailnet 地址变化时，告诉 App 它在 tailnet 上的地址。经 tailnet 或经 Relay 连上都会收到，App 据此更新保存的地址，不必重新扫码：

```jsonc
// Gateway → App
{"type": "tailnet", "host": "100.64.0.1:7420"}
{"type": "tailnet", "host": null}  // tailnet 已关（`yochi tailnet off`），只经 Relay
```

Mac 暂时不在 tailnet 上时不发，App 保留原来的地址。tailnet 关掉时，Gateway 关闭经 tailnet 的连接，经 Relay 的连接不受影响。

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

### 停止

在同一个 `/v0/ws` 连接上结束 Agent 当前这一轮：

```jsonc
// App → Gateway
{"type": "interrupt", "id": "<客户端生成>", "session": "vps-us/t1"}
// Gateway → App
{"type": "interrupted", "id": "<客户端生成>", "outcome": "stopped"}
{"type": "interrupt_failed", "id": "<客户端生成>", "kind": "finished", "message": "finished"}
```

Gateway 经独立的 plain 模式 `hc connect` 调用 core 的 `terminal.interrupt`（观察 5 秒）：会上报状态的程序按 Esc，否则按 Ctrl+C，只按一次，不升级。它不 attach，不是 Takeover。

- `outcome`：`stopped`（离开了 working）、`exited`、`still_working`（5 秒内没变化）、`unknown`（程序不上报状态）。
- `kind` 同 Agent Message，另有 Gateway 的 `not_found`、`unknown`、`timeout`。结果不明时 App 不自动再按。
- App 只在 Agent 为 `working` 时提供停止；`blocked` 时 Esc 会取消对话框，由对话框卡片处理。

### 附图片

把一个文件放到终端旁边，回复它在终端那台机器上的路径。App 把路径填进草稿，随 Agent Message 发出，Claude Code 看到路径会自己读这张图：

```jsonc
// App → Gateway；data 为 base64，解码后不超过 8 MB
{"type": "put", "id": "<客户端生成>", "session": "vps-us/t1", "name": "image-20261103-192759-1.jpg", "data": "<base64>"}
// Gateway → App
{"type": "put_done", "id": "<客户端生成>", "path": "/Users/me/.local/state/herdr-core/default/files/t1/image-20261103-192759-1.jpg"}
{"type": "put_failed", "id": "<客户端生成>", "kind": "too_large", "message": "图片超过 8 MB"}
```

- Gateway 经独立的 plain 模式 `hc connect` 调用 core 的 `terminal.put`，不 attach，不是 Takeover。
- `name` 只能含 ASCII 字母数字和 `.-_`，不以 `.` 开头，最长 100 字符，否则 `kind: "invalid"`。会话不存在为 `not_found`，过大为 `too_large`；其余同 Agent Message，另有 `unknown`、`timeout`。
- App 先把图片长边缩到 2048 像素、编成 JPEG，一条消息最多 4 张。

### 斜杠命令

列出会话可用的自定义斜杠命令和 skill，供 App 补全；内置命令由 App 自带：

```jsonc
// App → Gateway
{"type": "commands", "id": "<客户端生成>", "session": "vps-us/t1"}
// Gateway → App；name 带斜杠，按名字排序
{"type": "command_list", "id": "<客户端生成>", "commands": [{"name": "/research", "description": "Investigate a question", "source": "skill"}]}
{"type": "commands_failed", "id": "<客户端生成>", "kind": "unreachable", "message": "no answer from any machine"}
```

- Gateway 经 core 的 `machine.exec`，在会话所在机器、会话的工作目录里跑一段写死的只读脚本（10 秒超时），列出项目和个人的 `.claude/commands/*.md`、`.claude/skills/*/SKILL.md` 的文件头，再读 frontmatter 的 `name`、`description`。
- `source`：`project`、`user`、`skill`。同名时项目的优先。最多 200 项，说明截到 120 字。插件带来的不列。
- `kind`：会话不存在为 `not_found`，其余为 core 的错误类型、`unavailable` 或 `timeout`。只读，失败可直接重试。

### 改动（Changes）

会话工作目录所在 git 仓库相对 HEAD 的改动，含未跟踪文件；只读：

```jsonc
// App → Gateway
{"type": "changes", "id": "<客户端生成>", "session": "vps-us/t1"}
// Gateway → App；按路径排序，最多 1000 个
{"type": "changes", "id": "<客户端生成>", "repo": "companion", "truncated": false, "files": [
  {"path": "ios/A.swift", "status": "M", "added": 12, "deleted": 3},
  {"path": "new.txt", "old_path": "old.txt", "status": "R", "added": 0, "deleted": 0},
  {"path": "logo.png", "status": "?"}
]}
{"type": "changes_failed", "id": "<客户端生成>", "kind": "not_git", "message": "不是 git 仓库"}

// 单个文件，path 必须是这个会话最近一次 changes 列出的
{"type": "change_diff", "id": "<客户端生成>", "session": "vps-us/t1", "path": "ios/A.swift"}
{"type": "change_diff", "id": "<客户端生成>", "patch": "diff --git a/ios/A.swift b/ios/A.swift\n…", "truncated": false}
{"type": "change_diff_failed", "id": "<客户端生成>", "kind": "changed", "message": "改动已变化，请刷新"}
```

- Gateway 经 core 的 `machine.exec` 在会话所在机器跑固定的只读 git 命令：先在会话目录找仓库根，之后在根目录里跑。都带 `--no-optional-locks -c core.fsmonitor=false -c diff.autoRefreshIndex=false`，不写 index；diff 带 `--no-ext-diff --no-textconv`。还没有提交的仓库相对空树比较。
- `status`：`M` 修改、`A` 新增、`D` 删除、`R` 改名（带 `old_path`）、`T` 类型变化、`U` 冲突、`?` 未跟踪。二进制文件没有 `added`、`deleted`。只是时间戳变了的文件（增删都是 0 的修改）不列。
- `patch` 是统一 diff 原文，最多 5000 行、512 KB，超出时 `truncated: true`。未跟踪文件相对 `/dev/null` 比较。
- `kind`：`not_found`（会话不在）、`not_git`、`changed`（路径不在最近的列表里，或 Gateway 重启过）、`timeout`、`unavailable`，以及 core 的错误类型。只读，失败可直接重试。

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
// 权限模式，取 transcript 最近一条消息记下的；变化时、以及每次 conversation 之后发
{"type": "mode", "mode": "acceptEdits"}
// 会话结束或读取失败
{"type": "closed", "reason": "finished"}
```

条目（`kind` 区分）：

```jsonc
{"kind": "user", "id": "…", "text": "请继续"}
{"kind": "agent", "id": "…", "text": "Markdown 正文"}
{"kind": "tool", "id": "toolu_01…", "name": "Bash", "summary": "date > stamp.txt",
 "state": "running", "output": "前 40 行、2000 字节以内"}
// Edit、MultiEdit、Write 成功后带 edit：patch 是统一 diff 的块（无文件头），最多 200 行、16 KB
{"kind": "tool", "id": "toolu_03…", "name": "Edit", "summary": "/x/A.swift", "state": "done",
 "edit": {"path": "/x/A.swift", "added": 2, "deleted": 1, "patch": "@@ -3,3 +3,4 @@\n keep\n-old\n…", "truncated": false}}
// Write 新建文件时 "created": true，patch 是全文的 + 行
// Agent（旧名 Task）带 agent；后台的结果回来后仍是 running，task-notification 到达时变成 done / error
{"kind": "tool", "id": "toolu_04…", "name": "Agent", "summary": "Find roadmap items", "state": "running",
 "agent": {"name": "Find roadmap items", "type": "Explore", "started_ms": 1762156800000, "background": true}}
{"kind": "tool", "id": "toolu_02…", "name": "AskUserQuestion", "summary": "Cats or Dogs?", "state": "done",
 "questions": [{"question": "Cats or Dogs?", "header": "Pet", "multi_select": false,
                "options": [{"label": "Cats", "description": "…"}, {"label": "Dogs", "description": "…"}]}],
 "answers": {"Cats or Dogs?": "Cats"}}
{"kind": "command", "id": "…", "name": "/model haiku", "output": "Set model to haiku"}
{"kind": "notice", "id": "…", "text": "上下文已压缩", "code": "compacted"}   // 也用于「已中断」（interrupted）和 API 错误
// 子代理或后台任务的完成汇报：Claude Code 把它记成一条 user 消息，但不是用户输入的
{"kind": "task", "id": "…", "summary": "Agent \"Find roadmap items\" finished", "state": "done",
 "text": "子代理的汇报（Markdown，后台命令没有）"}
// 待办清单：TaskCreate、TaskUpdate、TodoWrite 不再是工具条目，换成那一刻的整张清单
{"kind": "todos", "id": "toolu_05…", "items": [{"text": "修复水印", "active": "修复水印中", "status": "in_progress"}]}
// Agent 之间的消息：发出的（SendMessage）和其他 Agent 发来的；name 查不到时省略
{"kind": "peer", "id": "…", "direction": "received", "name": "static-workorder-2a", "text": "已改好…", "state": "done"}
```

- 只发显示所需的字段；thinking、用量、请求记录和附件不离开 Gateway。图片显示为「［图片］」。
- 首次只发最近 300 条，最多回溯 transcript 的最后 2000 行。
- `tool.state` 为 `running` / `done` / `error`；结果到达时同一 `id` 的条目被替换。
- `agent.started_ms` 取 transcript 记录的时刻；同步的子任务跑完时有 `duration_ms`，后台的在通知到达时补上。
- `todos.items[].status` 为 `pending` / `in_progress` / `completed`，删掉的项不再出现。中间没有别的条目的连续几次更新替换同一个条目，否则新起一个条目。
- `peer.direction` 为 `sent` / `received`。发出的 `state` 先是 `running`，结果到达后为 `done` 或 `error`。`name` 对子任务是它的描述，对 `uds:` 地址是从该地址收到过的消息里对方报的名字。
- 旧 App 不认识 `todos`、`peer` 条目，跳过；新字段忽略。
- `notice.code` 标明是哪种提示：`interrupted`、`compacted`，以后可能有新值；API 错误等没有 `code`。App 认识的 `code` 用自己的文字显示，其余显示 `text`（已按 `lang` 选好语言）。旧版 Gateway 不发送 `code`。
- `pending.tool` 是被询问的工具条目；状态先于 transcript 变化时可能暂为 `null`，下次读取后补上。
- `mode` 原样转发 Claude Code 的值（`default` / `acceptEdits` / `plan` / `auto` / `bypassPermissions`，以后可能有新值）。transcript 只在发消息时记模式：第一条消息之前没有 `mode`，在终端里切换后要到下一条消息才更新。App 优先显示屏幕底部的模式提示，切换按「按键」逐次发 `shift+tab`（ADR 0005）。
- Claude Code 的回复按内容块写入，没有逐字流式；Agent 工作中由会话状态表示。
- Gateway 在有 App 订阅时才读取：Agent 工作或等待时、以及状态变化后几秒内每秒一次，其余每 4 秒。core 的 `file.read` 每次读取整个文件，超过 64 MB 的 transcript 读取失败。

### 查看终端（Observer）

`ws://<host>:7420/v0/observe?session=<id>`，认证同上；会话不存在时返回 `404`。Gateway 为每个查看连接单独执行 `hc connect` 并 attach，手机从不经这个连接向终端输入。默认以 `observe` 模式 attach，不改变终端尺寸。

**按手机尺寸接管。** 加 `takeover=1&cols=<列>&rows=<行>` 时改以非 observe 的方式 attach，core 把终端改成这个网格，`attached` 和首屏都按它；列数、行数缺少或不在 1…1000 之内时返回 `400`。查看期间桌面上的终端跟着变小；连接断开后 core 把尺寸还原成仍在 attach 的桌面窗口的大小，没有窗口时还原成基础尺寸。接管的连接上 App 可以发 `{"type": "resize", "cols": 49, "rows": 30}`（键盘弹出收起、转屏），Gateway 转成 core 的 RESIZE 帧；只读连接上的这类消息被忽略。全屏程序（如 Claude Code）自己保存历史、靠鼠标滚轮翻看，终端里没有回滚可滑：接管的连接上 App 把手机终端为拖动编出的滚轮上报原样发来，`{"type": "wheel", "data": "\u001b[<64;10;5M"}`，Gateway 经 attach 通道写给程序。`data` 只能由 SGR 滚轮上报（`ESC [ < b ; x ; y M`，b 为 64–67，可带 shift/meta/ctrl 位）和 alt screen 上的光标上下键（`ESC [ A`/`B`、`ESC O A`/`B`）组成，最长 4096 字节，否则整条丢弃；点按、移动和打字都不会经这里送到终端。桌面再次操作这个终端时尺寸回到桌面的，`size` 帧会报出来，App 据此改回只读显示（ADR 0001 的 2026-11-04 修订）。

- **文本帧**（控制）：
  ```jsonc
  {"type": "attached", "cols": 200, "rows": 120}  // 开始；App 按此尺寸收下首屏（只读时再重排）
  {"type": "size", "cols": 160, "rows": 48}       // 终端尺寸变了（其他客户端，或接管后自己的 resize）
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

### 经 Relay 连接

手机不在 tailnet 上时，经 Relay 连接（ADR 0006）。中继协议见 `relay/PROTOCOL.md`，中继只转发二进制帧，看不到明文。

1. **连接**：App 打开 `wss://<中继>/c/<route token>`。中继找不到这个 Gateway（不在线或 route 不对）时返回 `502`。
2. **握手**：Noise `Noise_IKpsk2_25519_ChaChaPoly_SHA256`，prologue 为 `yochi-relay-v1`，psk 放在第 2 个位置。App 是发起方，事先知道 Gateway 的静态公钥（`key` / `gateway_key`）。每条握手消息是一个二进制 WebSocket 消息，payload 为空。
   - 已登记的设备用登记时拿到的 psk；正在配对的手机用 link v2 的 `secret`。
   - Gateway 读完第一条握手消息后，按 App 的静态公钥选 psk：先找设备，再找正在等待的配对。都没有时关闭，close code `4401`。
   - psk 不对时，App 读不了第二条握手消息，应当关闭连接。
3. **请求**：握手后的第一条消息是 JSON 文本，说明要什么：
   ```jsonc
   {"path": "/v0/observe?session=t1&takeover=1&cols=49&rows=45"}  // 已配对设备：任一 /v0/ 接口，/v0/pair 除外
   {"path": "/v0/pair", "name": "iPhone"}                        // 用 secret 配对
   ```
   配对时 Gateway 回一条文本消息后以 `1000` 关闭。设备 token 只在 tailnet 上用，psk 用于以后经 Relay 连接：
   ```jsonc
   {"type": "paired", "device": "8653add4", "token": "<64 位十六进制>", "psk": "…"}
   {"type": "rejected"}
   ```
4. **之后**：消息与 tailnet 上的同名接口完全相同，认证由握手完成，不带 Bearer token。接口拒绝时 close code 为 `4000 + HTTP 状态`，例如会话不存在为 `4404`。请求无效时为 `4400`。

**分片**：每个 WebSocket 消息加密为一条或多条 Noise 消息，每条单独作为一个二进制 WebSocket 消息发送。明文是 `[flags][payload]`：bit 0 置位表示二进制消息（否则为文本），bit 1 置位表示后面还有分片。每条 Noise 消息最多 65535 字节，所以每片 payload 最多 65518 字节；重组后的消息最多 64 MiB。Noise 消息不能重放、不能乱序，解密失败就结束连接。

