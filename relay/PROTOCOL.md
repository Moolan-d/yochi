# Yochi Relay 隧道协议

版本 1。中继只转发字节，不解读内容：手机和 Gateway 之间的 Noise 握手与加密见 ADR 0006 和 `protocol/README.md`。

```
Gateway ──WSS /gateway?route=<hash>──▶ 中继 ◀──WSS /c/<路由 token>── 手机
```

- **路由 token**：Gateway 生成的 256 位随机数，base64url 编码，放在配对链接里。
- **hash**：路由 token 的 SHA-256（小写十六进制）。中继只看到手机 URL 里的路由 token，内存里只按 hash 找 Gateway，不落盘、不记日志。

## Gateway 一侧

1. 连 `WSS /gateway?route=<hash>`。
2. 10 秒内发第一帧（文本）：

   ```json
   {"t":"register","v":1,"key":"<注册密钥，中继没设就省略>"}
   ```

3. 中继回 `{"t":"registered","v":1}`。失败时回 `{"t":"error","message":"…"}` 并关闭连接：

   | 关闭码 | 含义 |
   | --- | --- |
   | 4003 | 注册密钥不对 |
   | 4002 | route 不是合法的 hash |
   | 1013 | 中继已满 |

同一个 hash 再次注册时，新连接替换旧连接：旧连接以 4000 关闭，旧连接上的手机流全部以 1012 关闭。

注册之后，帧分两种：

- **文本帧（控制）**
  - 中继 → Gateway：`{"t":"open","id":"s1"}`，表示来了一条新的手机流。`id` 由中继分配，在这条 Gateway 连接上唯一。
  - 双向：`{"t":"close","id":"s1","code":1000,"reason":""}`，表示这条流结束了。Gateway 发出时，中继按这个关闭码关闭手机连接；手机断开时，中继发给 Gateway。未知 `id` 一律忽略。
- **二进制帧（数据）**：`[kind:u8][idLen:u8][id:utf8][payload]`，`kind` 为 1（DATA），`payload` 是手机那条 WebSocket 上的一条二进制消息，原样转发。

中继每 30 秒 ping 一次 Gateway。Gateway 也应自己发 ping，超时就重连。

## 手机一侧

- 连 `WSS /c/<路由 token>`，不需要任何密钥。Gateway 不在线时，升级请求以 HTTP 502 拒绝；这个 Gateway 的流太多时以 503 拒绝。
- 只发二进制消息，单条最大 128 KiB（一条 Noise 消息最多 65535 字节）。收到文本消息即以 1003 关闭。
- 消息在 `open` 之后按顺序到达 Gateway，不需要等 Gateway 确认。

## 其他端点

- `GET /healthz`：`{"ok":true,"edition":"node"|"cloudflare","version":"…","protocol":1}`
- `GET /`：一行说明文字。

## 限制

| 项 | 默认值 |
| --- | --- |
| 单条手机消息 | 128 KiB |
| 每个 Gateway 同时打开的流（`MAX_STREAMS`） | 64 |
| 同时在线的 Gateway（`MAX_GATEWAYS`，仅 Node 版） | 1000 |
| 流控（仅 Node 版） | 缓冲超过 4 MiB 时暂停读对端，降到 512 KiB 以下再继续；手机 60 秒（`STALL_TIMEOUT_S`）一点都不读就断开 |
