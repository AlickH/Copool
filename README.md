# Copool

<p align="center">
  <img src="./Copool.png" alt="Copool Icon" width="160" />
</p>

Copool is a SwiftUI app for macOS that manages Codex/ChatGPT auth accounts, usage-based smart switching, and local/remote API proxy workflows.

Copool 是一个面向 macOS 和 iOS 的 SwiftUI 应用，用于管理 Codex/ChatGPT 授权账号、按用量智能切换，以及本地/远程 API 代理工作流。

## Screenshots / 截图

<img src="./account.png" alt="Accounts Overview" width="560" />
<img src="./account_2.png" alt="Accounts Detail" width="560" />
<img src="./proxy.png" alt="Proxy" width="560" />
<img src="./setting.png" alt="Settings" width="560" />

## Features / 功能

- Native SwiftUI architecture with layered design (`App`, `Features`, `UI`, `Behavior`, `Infrastructure`, `Domain`, `Layout`)
- 纯 SwiftUI 分层架构（`App`、`Features`、`UI`、`Behavior`、`Infrastructure`、`Domain`、`Layout`）
- Account import/switch/delete and usage refresh (5h / 1week)
- 账号导入/切换/删除与用量刷新（5h / 1week）
- Smart switch based on remaining quota score
- 基于剩余额度评分的智能切换
- Local API proxy runtime (Swift native server) with model compatibility mapping
- 本地 API 代理运行时（Swift 原生服务）与模型兼容映射
- Cloudflared public tunnel management
- Cloudflared 公网隧道管理
- Remote Linux deployment/start/stop/logs for proxy nodes over SSH
- 远程 Linux 代理节点 SSH 部署/启停/日志
- ChatGPT OAuth import plus editor restart / launch integration on account switch
- ChatGPT OAuth 导入，以及切换账号时的编辑器重启 / 拉起集成
- Menu bar integration (MenuBarExtra)
- 菜单栏集成（MenuBarExtra）

## Requirements / 环境要求

- macOS 14+
- Xcode 17+
- Swift 6 toolchain

## Build & Run / 构建与运行

```bash
cd Copool
xcodebuild test -project Copool.xcodeproj -scheme Copool -destination 'platform=macOS'
xcodebuild -project Copool.xcodeproj -scheme Copool -configuration Debug -destination 'platform=macOS' build
```

Open `Copool.xcodeproj` in Xcode and run `Copool`.

使用 Xcode 打开 `Copool.xcodeproj`，运行 `Copool` scheme。

## Release Channels / 发布渠道

- macOS release artifacts are published through GitHub Releases.
- macOS 发布产物通过 GitHub Releases 分发。
- See [`docs/release-macos.md`](docs/release-macos.md) for the Developer ID signing and notarization flow.
- macOS 的 Developer ID 签名与公证流程见 `docs/release-macos.md`。

## Project Structure / 项目结构

- `Sources/Copool/App`: scene composition and app bootstrap
- `Sources/Copool/Features`: page-level composition and bindings
- `Sources/Copool/UI`: reusable visual primitives
- `Sources/Copool/Behavior`: coordinators and behavior modules
- `Sources/Copool/Infrastructure`: IO/network/process integrations
- `Sources/Copool/Domain`: models and protocols (single source of truth)
- `Sources/Copool/Layout`: centralized layout rules

## Reference Project / 参考项目

- [170-carry/codex-tools](https://github.com/170-carry/codex-tools)

This project is a Swift-native migration and redesign inspired by the original Tauri-based implementation.

本项目是对原 Tauri 版本的 Swift 原生迁移与重构。

## Acknowledgements / 致谢

- Thanks to the original authors and contributors of `170-carry/codex-tools`.
- 感谢 `170-carry/codex-tools` 的原作者与贡献者。
- Thanks to all users who provided migration feedback and UI/UX suggestions.
- 感谢所有提供迁移反馈与界面建议的用户。

## License / 许可证

Please follow the upstream license and your organization’s compliance requirements when reusing code from referenced projects.

复用参考项目代码时，请遵循上游许可证与所在组织的合规要求。
