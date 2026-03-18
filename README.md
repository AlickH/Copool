# Copool

<img src="./Copool.png" alt="Copool Icon" width="160" />

Copool is a macOS SwiftUI app for managing Codex/ChatGPT auth accounts, usage-based smart switching, and local/remote API proxy workflows.

Copool 是一个 macOS SwiftUI 应用，用于管理 Codex/ChatGPT 授权账号、按用量智能切换，以及本地/远程 API 代理工作流。

## Screenshots / 截图

<img src="./Screenshot%202026-03-12%20at%2018.27.00.png" alt="Accounts" width="720" />
<img src="./Screenshot%202026-03-12%20at%2018.27.16.png" alt="Proxy" width="720" />
<img src="./Screenshot%202026-03-12%20at%2018.27.22.png" alt="Settings" width="720" />

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
- Menu bar integration (MenuBarExtra)
- 菜单栏集成（MenuBarExtra）

## Requirements / 环境要求

- macOS 14+
- Xcode 16+
- Swift 6 toolchain

## Build & Run / 构建与运行

```bash
cd Copool
swift test
xcodebuild -project Copool.xcodeproj -scheme Copool -configuration Debug -destination 'platform=macOS' build
```

Open `Copool.xcodeproj` in Xcode and run the `Copool` scheme.

使用 Xcode 打开 `Copool.xcodeproj`，运行 `Copool` scheme。

## Helper Scripts / 辅助脚本

The repository also includes a standalone batch checker for the public endpoints used by `team.654301.xyz`.

仓库还包含一个独立的批量查询脚本，可封装 `team.654301.xyz` 当前公开前端所调用的接口。

```bash
python3 scripts/team654301_batch_check.py status --file scripts/team654301_codes.example.txt
python3 scripts/team654301_batch_check.py warranty --code Z-EXAMPLECODE0001 --format json
python3 scripts/team654301_batch_check.py status <<'EOF'
Z-EXAMPLECODE0001
Z-EXAMPLECODE0002
EOF
```

Notes:
- The site currently exposes single-code endpoints only; this script batches by looping locally.
- `status` calls `/api/status/`, and `warranty` calls `/api/warranty/activate/`.
- Prefer small delays between requests to avoid hammering the upstream service.

说明：
- 站点当前公开的是单卡密接口；此脚本通过本地循环实现批量查询。
- `status` 对应 `/api/status/`，`warranty` 对应 `/api/warranty/activate/`。
- 建议保留少量请求间隔，避免对上游服务造成压力。

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
