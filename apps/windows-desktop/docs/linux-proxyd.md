# Linux Proxyd

`codex-tools-proxyd` 是从桌面端本地反代里拆出来的独立代理进程，目标是给后续“远程 Linux 服务器部署 + 桌面端管理”打基础。

当前阶段已经支持：

- 独立启动 `/v1` 代理
- 复用现有 Codex 上游转发逻辑
- 复用 `accounts.json` 和固定 `api-proxy.key` 持久化
- 启动时可选自动把当前 `~/.codex/auth.json` 导入到账号池

当前阶段还没有接入：

- 桌面端里的远程服务器管理 UI
- SSH 一键部署
- systemd 自动安装

## 编译

```bash
cargo build --manifest-path src-tauri/proxyd/Cargo.toml
```

## 启动

```bash
./src-tauri/proxyd/target/debug/codex-tools-proxyd serve \
  --data-dir ~/.codex-tools-proxyd \
  --host 0.0.0.0 \
  --port 8787
```

默认值：

- `--data-dir ~/.codex-tools-proxyd`
- `--host 0.0.0.0`
- `--port 8787`
- 请求体大小上限默认 `512 MiB`

如果你不希望启动时自动把当前 `~/.codex/auth.json` 写入账号池，可以加：

```bash
--no-sync-current-auth
```

如果需要覆盖默认请求体大小上限，可以在启动前设置环境变量：

```bash
CODEX_TOOLS_PROXY_MAX_BODY_MIB=1024 ./src-tauri/proxyd/target/debug/codex-tools-proxyd serve \
  --data-dir ~/.codex-tools-proxyd \
  --host 0.0.0.0 \
  --port 8787
```

## 数据目录

daemon 会在 `data-dir` 下维护：

- `accounts.json`
- `api-proxy.key`

其中：

- `accounts.json` 用法和桌面端一致
- `api-proxy.key` 会固定保存本地代理 API Key，除非手动刷新

## 启动输出

启动成功后会打印：

- `data_dir=...`
- `listen=http://HOST:PORT/v1`
- `api_key=sk-...`

## 停止

- 前台运行时可直接 `Ctrl+C`
- 在 Linux 上也支持 `SIGTERM`

## 说明

这个 daemon 目前只是把现有本地代理核心拆成了一个可独立运行的服务。
下一步才是在桌面端增加“远程服务器”配置、SSH 部署和状态管理。
