# Companion

原生 iOS App，经 Tailscale 连接主 Mac 上的 Gateway，查看和操作 herdr-core 管理的 Agent 会话（含 core 已连接的远端机器）。

- `gateway/`：主 Mac 上的 Gateway 服务与 CLI（Rust）
- `ios/`：iOS App（SwiftUI，工程由 XcodeGen 生成）
- `protocol/`：Companion API 定义
- `GLOSSARY.md`、`docs/adr/`：领域术语与架构决策

## 开发

```sh
# Gateway（另开一个终端运行 `cargo run -- pair` 配对手机）
cd gateway && cargo run

# iOS
cd ios && scripts/fetch-libghostty.sh && xcodegen generate && open Companion.xcodeproj
```

真机运行前，在 `ios/Local.xcconfig`（不进 git）里填签名团队；免费 Personal Team 还需要加一个 bundle ID 后缀：

```
DEVELOPMENT_TEAM = ABCDE12345
BUNDLE_ID_SUFFIX = .yourname
```

## 常驻运行

日常使用时让 Gateway 随登录启动，崩溃时由 launchd 每 10 秒重试。Mac 上的 Tailscale 没开时 Gateway 不退出：配了中继就照常经中继服务，同时每 5 秒找一次 tailnet 地址，找到后再在 tailnet 上监听。

```sh
cargo install --path gateway        # 装到 ~/.cargo/bin，不随 cargo build 变化
yochi service install               # 写入 ~/Library/LaunchAgents/dev.yochi.gateway.plist 并启动
yochi service status                # 是否在运行、监听地址、日志位置
yochi service uninstall
```

安装时会记下当前 `hc` 和 `tailscale` 的绝对路径（launchd 不继承 shell 的 PATH），以及显式传入的 `--listen`、`--state-dir`。日志在 `~/Library/Logs/Yochi/gateway.log`。已有 Gateway 占着端口时安装会拒绝，先停掉它。

从改名前的版本（`companion-gateway`）升级：`yochi service install` 会先停掉并移除旧的 `dev.companion.gateway`，配对记录随后从 `~/Library/Application Support/Companion Gateway` 迁到 `~/Library/Application Support/Yochi`。iOS 的 bundle ID 也改成了 `dev.yochi.app`，手机上会装成一个新 App，需要重新配对，旧 App 可以删掉。
