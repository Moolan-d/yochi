# Companion API

Gateway 向 Companion App 暴露的有版本接口（见 `GLOSSARY.md`）。

## v0（临时）

仅用于打通第一条链路，Device Pairing 落地后由 v1 取代，届时以 ADR 0003 记录传输与认证决定。

- **连接**：`ws://<主 Mac 的 tailnet IPv4>:7420/v0/ws`。Gateway 只监听 tailnet 地址，不监听 LAN 或 localhost。
- **认证**：HTTP 头 `Authorization: Bearer <token>`，token 来自 Gateway 启动参数 `COMPANION_TOKEN`（未设置时随机生成并打印）。不匹配时返回 `401`。所有设备共用一个 token，无法单独撤销，这是 v0 的已知缺口。
- **加密**：明文 WebSocket，依赖 Tailscale（WireGuard）加密链路。
- **消息**：Gateway → App 的 JSON 文本帧，App 暂不发送任何消息。

```jsonc
// 连接建立后第一条
{"type": "hello", "api": 0, "gateway": "0.1.0"}

// 随后立即发送，并在会话列表变化时整表重发
{"type": "sessions", "core": "my-mac", "connected": true, "sessions": [
  {"id": "vps-us/t1", "machine": "vps-us", "title": "claude", "program": "claude",
   "cwd": "/root/app",
   "status": {"state": "blocked", "app": "claude", "message": "Run ls?", "kind": "permission"}}
]}
```

- `id`：core 的地址，对 App 不透明。`machine`：远端机器名，主 Mac 本机为 `null`。
- `status`：Agent 自报状态，`state` 为 idle / working / done / blocked / error；未上报时为 `null`。
- `connected: false` 表示 Gateway 暂时连不上本机 herdr-core，此时 `sessions` 为空。
- 只包含 live 会话，finished 的不返回。
- `cols` / `rows`：终端当前网格尺寸（上例省略）。

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
