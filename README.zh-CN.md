<div align="center">

<img src="docs/images/icon.png" width="128" height="128" alt="Yochi 图标" />

# Yochi

**把你的编程 Agent 装进口袋。**

原生 iPhone App，查看和操作 Herdr 在你 Mac 上（以及它经 ssh 连到的机器上）运行的 Claude Code、Codex、pi 会话。

![iOS 18+](https://img.shields.io/badge/iOS-18%2B-000000?logo=apple&logoColor=white)
![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)
![Rust 2024](https://img.shields.io/badge/Rust-2024-000000?logo=rust&logoColor=white)
![Terminal: libghostty](https://img.shields.io/badge/terminal-libghostty-3551F3)
![Encryption: Noise IKpsk2](https://img.shields.io/badge/relay-Noise%20IKpsk2-2E7D32)

[English](./README.md) | 简体中文

</div>

---

Yochi 不是远程桌面。主 Mac 上跑一个小小的 Gateway（`yochi`），读取 herdr-core 已经在管理的会话（包括远端机器上的），换成适合手机的形态交给 App：

- 等你处理的 Agent 排在最前面；
- 对话显示成消息和工具卡片，不用眯着眼看终端；
- Claude Code 的权限提问变成原生按钮；
- 真要用终端时，它是真正的终端：Ghostty 的。

手机经你的 **tailnet** 连到 Gateway；不在 tailnet 上时，经**你自己部署的 Relay**。Relay 只转发端到端加密后的数据。

<div align="center">
<table>
  <tr>
    <td align="center"><img src="docs/images/home.png" width="260" alt="主页：需要你处理的 Agent 在前，随后是各个 Space" /></td>
    <td align="center"><img src="docs/images/conversation.png" width="260" alt="对话页：消息、改动、子任务和待办" /></td>
  </tr>
  <tr>
    <td align="center"><sub><b>主页</b>：谁在等你，然后是每个 Space</sub></td>
    <td align="center"><sub><b>对话页</b>：改动、子任务、待办</sub></td>
  </tr>
</table>
</div>

## 目录

- [功能](#功能)
- [整体结构](#整体结构)
- [连接方式](#连接方式)
- [快速开始](#快速开始)
- [CLI 参考](#cli-参考)
- [安全模型](#安全模型)
- [开发](#开发)
- [目录结构](#目录结构)
- [致谢](#致谢)

## 功能

- **需要你的先看到。** 卡在提问或权限确认上的 Agent，不管在哪个 Space、哪台机器，都排在主页顶部。
- **原生对话页。** 对 Claude Code，Gateway 读取 Agent 自己的对话记录。App 把它显示成消息、带增删行数的文件改动、子任务、待办和会话间消息。
- **点一下就能作答。** App 从屏幕上读出 Claude Code 的对话框（权限确认、选择器、提示），换成带按钮的卡片。
- **发消息不用接管。** 消息经 herdr-core 投递，等终端空闲才送进去，手机上打字不会和桌前的人抢键盘。
- **需要时是真正的终端。** 终端由 libghostty 渲染。
  - 旁观是只读的，不改变桌面端的尺寸。
  - 一打字就接管，终端按手机宽度重排，桌面端再次操作时收回。
  - 全屏程序可以用手指翻看它自己的历史。
  - 长按可选取复制。
- **按 Herdr 的方式组织。**
  - Space 是可折叠的分组。
  - 子 Agent 排在父 Agent 下面，置顶的在前，普通 shell 折叠起来。
  - 远端 Space 带机器标记。
- **只读查看改动。** 查看会话在 git 仓库里改了什么，含 diff。手机从不指定路径，也不能指定命令。
- **新建会话。** 从最近用过的目录启动 Agent，自动归入对应的 Space。
- **两条路径，互不依赖。** tailnet 和 Relay 可以只开一条，也可以都开。经 Relay 配对的手机，在 Mac 接入 tailnet 后会自动改走 tailnet。
- **中文和英文。** 界面跟随 iPhone 的系统语言。Gateway 自己生成的文字（部分提示和错误信息）目前仍是中文。

## 整体结构

<p align="center">
  <img src="docs/diagrams/yochi-architecture.svg" alt="Yochi 架构：手机 App、tailnet 与 Relay 两条路径、主 Mac 上的 Gateway、herdr-core 和远端机器" />
</p>

| 组件 | 运行位置 | 作用 |
| --- | --- | --- |
| **Yochi App**（`ios/`） | iPhone | SwiftUI + libghostty。会话列表、对话页、终端页、配对。 |
| **Gateway**（`gateway/`） | 主 Mac | Rust 写的 `yochi`。认证已配对的手机，暴露一组窄而有版本的接口（`/v0/…`），替它们调用 herdr-core。以 LaunchAgent 常驻。 |
| **herdr-core** | 主 Mac | Herdr 的会话运行时，经 `hc` 访问。终端归它所有，远端机器也由它经 ssh 连接。Yochi 不另建第二套会话系统。 |
| **Relay**（`relay/`） | 你的 Cloudflare 账号，或任何能跑 Docker 的主机 | 可选。Gateway 主动外连的 WebSocket 中转，不需要开放入站端口。只转发密文。 |

远端机器什么都不用装，全部经主 Mac 的 herdr-core 访问。主 Mac 睡眠时，手机访问不到任何会话，包括远端机器上的。

### 会话如何显示

<p align="center">
  <img src="docs/diagrams/yochi-sessions.svg" alt="Herdr 的 Host、Space、Tab、Pane、Terminal 层级如何对应到 Yochi 主页" />
</p>

Herdr 的层级是 Host → Space → Tab → Pane → Terminal。手机上用不了这么多层：

- **Space** 是分组。**Host** 是远端 Space 上的机器标记。
- **Tab** 不成一层，有名字的 Tab 显示为行内的一行字。
- **Pane** 只决定排序。一个 **Terminal** 是一行。

点开后进哪一页，取决于终端里跑的程序：已知的 Agent 进对话页，其余进终端页。

## 连接方式

| | Tailnet | Relay |
| --- | --- | --- |
| 地址 | `ws://<Mac 的 tailnet IPv4>:7420` | `https://<你的 relay>` |
| 加密 | WireGuard（Tailscale） | Noise IKpsk2，App 与 Gateway 之间端到端 |
| 手机需要 | Tailscale | 不需要额外的东西 |
| Mac 需要 | Tailscale | 能连出去 |
| 开关 | `yochi tailnet on\|off` | `yochi relay setup` / `use` / `off` |

Gateway 从不监听局域网或 localhost。两条路径都通时优先走 tailnet。能连上 Gateway 不等于有权限：每个连接都要带已配对设备的 token。

## 快速开始

目前没有 App Store 版本，App 需要从源码构建。

**准备**

- 一台运行 Herdr 的 Mac，`hc` 在 `PATH` 里
- Rust（stable），用于 Gateway；Xcode（Swift 6）和 [XcodeGen](https://github.com/yonaskolb/XcodeGen)，用于 App
- Mac 和手机上装 Tailscale，**或者**用 Node.js 和 Cloudflare 账号部署 Relay

**1. 安装 Gateway 并常驻**

```sh
cargo install --path gateway   # 装到 ~/.cargo/bin
yochi service install          # LaunchAgent：随登录启动，崩溃后自动重启
yochi service status
```

**2. 可选：部署 Relay**，手机不在 tailnet 上也能用

```sh
yochi relay setup                              # 部署到 *.workers.dev
yochi relay setup --domain relay.example.com   # 或挂到你 Cloudflare 上的域名
```

**3. 构建 App**

```sh
cd ios
scripts/fetch-libghostty.sh
xcodegen generate
open Companion.xcodeproj
```

真机运行前，在 `ios/Local.xcconfig`（不进 git）里填签名团队。免费的 Personal Team 还需要加一个 bundle ID 后缀：

```
DEVELOPMENT_TEAM = ABCDE12345
BUNDLE_ID_SUFFIX = .yourname
```

**4. 配对**

```sh
yochi pair
```

用 iPhone 相机扫二维码，它会在 App 里打开一个 `yochi://pair` 链接。也可以在 App 里手动填 Mac 的 tailnet 地址和 8 位配对码。配对码单次有效，5 分钟后过期。

## CLI 参考

```text
yochi [OPTIONS] [COMMAND]
```

| 命令 | 作用 |
| --- | --- |
| `yochi` / `yochi serve` | 在前台运行 Gateway（默认） |
| `yochi pair` | 显示单次有效的配对码和二维码，5 分钟内有效 |
| `yochi devices` | 列出已配对的设备 |
| `yochi revoke <ID>` | 取消某台设备的配对，它已建立的连接几秒内关闭 |
| `yochi tailnet on` | Mac 在 tailnet 上时就在 tailnet 上监听（默认） |
| `yochi tailnet off` | 不在 tailnet 上监听，并关闭已有的 tailnet 连接，手机只能经 Relay 连接 |
| `yochi tailnet status` | tailnet 是否开着、本机地址、Gateway 是否在监听 |
| `yochi relay setup [--domain <host>] [--name <worker>]` | 部署 Relay 到你的 Cloudflare 账号（Workers 免费套餐）并启用。需要 Node.js，第一次会让 wrangler 登录 |
| `yochi relay use <URL> [--key <KEY>]` | 使用你已经部署的 Relay，运行中的 Gateway 几秒内连上 |
| `yochi relay status` | 正在用的 Relay、Gateway 是否已连上、多少台手机能用它 |
| `yochi relay rotate` | 给 Gateway 换一个 Relay 上的地址。旧地址和带着它的配对链接随之失效 |
| `yochi relay off` | 停用 Relay |
| `yochi service install` | 安装或更新 LaunchAgent 并启动，沿用当前的设置 |
| `yochi service status` | LaunchAgent 是否装了、是否在运行、监听地址、日志位置 |
| `yochi service uninstall` | 停止并移除 LaunchAgent |

| 选项 | 环境变量 | 默认值 |
| --- | --- | --- |
| `--listen <ADDR>` | `YOCHI_LISTEN` | 本机 tailnet IPv4，端口 `7420` |
| `--hc <PATH>` | `YOCHI_HC` | `hc` |
| `--state-dir <DIR>` | `YOCHI_STATE_DIR` | `~/Library/Application Support/Yochi` |
| `--key <KEY>`（`relay use`） | `YOCHI_RELAY_KEY` | 无 |

<details>
<summary><b>常驻运行的细节</b></summary>

- `service install` 会记下 `hc` 和 `tailscale`（装了的话）的绝对路径，因为 launchd 不继承 shell 的 `PATH`。显式传入的 `--listen`、`--state-dir` 也会记下。
- 已有 Gateway 占着端口时，安装会拒绝，先停掉它。
- 日志在 `~/Library/Logs/Yochi/gateway.log`。
- Mac 上的 Tailscale 没开或没装时，Gateway 不退出，照常经 Relay 服务。它每 5 秒找一次 tailnet 地址，找到后再在 tailnet 上监听。
- tailnet 关着时，`yochi pair` 的链接只带 Relay 信息，手机不需要装 Tailscale。tailnet 恢复后，Gateway 把地址告诉已配对的手机，手机自动改走 tailnet。
- 从改名前的版本（`companion-gateway`）升级：
  - `yochi service install` 会先移除旧的 `dev.companion.gateway`。
  - 配对记录从 `~/Library/Application Support/Companion Gateway` 迁过来。
  - iOS 的 bundle ID 改成了 `dev.yochi.app`，手机上会装成一个新 App，需要重新配对，旧 App 可以删掉。

</details>

## 安全模型

- **只认已配对的设备。** 除 `/v0/pair` 外，所有接口都要带设备 token。配对码单次有效、5 分钟过期、输错 5 次作废。`yochi revoke` 几秒内切断设备。
- **窄接口，不是代理。** Gateway 只放行几个 herdr-core 方法（`events.subscribe`、`terminal.*`、`file.read`、`machine.exec`）。后两个只在内部使用：读 Agent 对话记录，跑一组固定的只读 git 命令。手机从不指定文件路径或命令。
- **终端终究是终端。** 已配对的手机可以在它看到的会话里打字，而 shell 能做你账号能做的任何事。配对等于交出一台没锁屏的电脑，手机不在手上了就撤销它。
- **Relay 看不到内容。**
  - App 与 Gateway 之间跑 Noise IKpsk2 端到端加密。
  - 配对链接带着 Gateway 的静态公钥和一次性密钥。
  - Relay 只转发不透明的帧，需要的只是你自己生成的注册密钥，部署在你自己的账号里。

这些取舍的来龙去脉见 [`docs/adr/`](docs/adr)，协议见 [`protocol/README.md`](protocol/README.md)，术语见 [`GLOSSARY.md`](GLOSSARY.md)。

## 开发

```sh
# Gateway
cd gateway
cargo run              # 运行 Gateway
cargo run -- pair      # 另开一个终端
cargo test

# Relay
cd relay
npm install
npm test                  # Node 版
npm run test:cloudflare   # Worker 版（wrangler dev --local）

# iOS：单元测试在 Xcode 里跑（⌘U）。UI 测试在模拟器里跑，用的是临时 Gateway
# （端口 7421）和本地 Relay，不影响 7420 上的 Gateway。
cd ios
scripts/ui-test.sh
TESTS="testFullScreenScrollsHistory testPairObserveAndUnpair" scripts/ui-test.sh
scripts/perf-test.sh   # 帧率、首屏时间、主线程卡顿
```

代号：仓库和 Xcode 工程仍叫 **Companion**，产品、CLI 和 bundle ID 叫 **Yochi**。

## 目录结构

```
gateway/        Rust Gateway 与 `yochi` CLI
ios/            SwiftUI App（XcodeGen 工程，libghostty 由脚本下载）
relay/          可自部署的 Relay：Cloudflare Worker 或 Node + Docker
protocol/       App ↔ Gateway 的有版本接口
docs/adr/       架构决策记录
docs/diagrams/  上面两张图的 Excalidraw 源文件
GLOSSARY.md     项目术语：Terminal、Agent、Space、Takeover……
```

## 致谢

- [Ghostty](https://ghostty.org)：App 里的每个终端都由 libghostty 渲染。
- [Heeler](https://github.com/ZingerLittleBee/Heeler)（Apache-2.0）：ANSI 屏幕模型和 Claude Code 对话框解析移植自它。
- [Alma Relay](https://github.com/yetone/alma-relay)（MIT）：`relay/` fork 自它，只保留了 WebSocket 隧道，见 [`relay/LICENSE`](relay/LICENSE)。
- Herdr：Yochi 是 herdr-core 的客户端，依赖它的会话运行时。
