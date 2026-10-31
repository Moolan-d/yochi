# Companion

原生 iOS App，经 Tailscale 连接主 Mac 上的 Gateway，查看和操作 herdr-core 管理的 Agent 会话（含 core 已连接的远端机器）。

- `gateway/`：主 Mac 上的 Gateway 服务与 CLI（Rust）
- `ios/`：iOS App（SwiftUI，工程由 XcodeGen 生成）
- `protocol/`：Companion API 定义
- `GLOSSARY.md`、`docs/adr/`：领域术语与架构决策

## 开发

```sh
# Gateway
cd gateway && cargo run

# iOS
cd ios && scripts/fetch-libghostty.sh && xcodegen generate && open Companion.xcodeproj
```
