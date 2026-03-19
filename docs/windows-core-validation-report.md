# Copool Windows Core Validation Report

Date: 2026-03-19

## Scope

This validation pass focused on "core workflow usable" for the Windows app in `apps/windows-desktop/`.

In scope:

- app startup on Windows
- store creation and reload
- importing or recognizing the current Codex auth
- usage refresh persistence
- local proxy startup and basic request handling
- unsupported-feature gating for Windows v1

Out of scope for this pass:

- `cloudflared`
- remote Linux proxy
- multi-account switch with two real accounts
- full UI automation

## Environment

- Workspace: `E:\CODEX\Copool windows版`
- Windows app: `E:\CODEX\Copool windows版\apps\windows-desktop`
- Codex auth path: `C:\Users\Administrator\.codex\auth.json`
- Windows app data path: `C:\Users\Administrator\AppData\Roaming\com.alick.copool.windows`
- Codex CLI detected at `C:\Users\Administrator\AppData\Roaming\npm\codex.ps1`
- `ssh.exe` available at `C:\Windows\System32\OpenSSH\ssh.exe`
- `cloudflared` not present in `PATH`

## Preconditions

- `C:\Users\Administrator\.codex\auth.json` was initially `{}`.
- A valid backup auth existed at `C:\Users\Administrator\.codex\auth.json.bak`.
- Validation temporarily restored `auth.json` from that backup, tested both valid-auth and empty-auth startup, then restored the valid auth again at the end.

## Results

### Passed

- `npm run build` succeeds in `apps/windows-desktop`
- `cargo test` succeeds in `apps/windows-desktop/src-tauri`
- Tauri dev app launches without blank screen, startup panic, or immediate backend crash
- Windows app creates and reads `accounts.json` in the app-data directory
- startup import recognizes the current Codex account from `.codex/auth.json`
- persisted store includes Copool-compatible fields:
  - `accounts[]`
  - `current_selection`
  - `settings.autoSmartSwitch`
  - `settings.launchCodexAfterSwitch`
  - `teamName`
  - `teamAlias`
- usage refresh data is persisted in the store
- app still launches when `.codex/auth.json` is empty, so invalid-auth startup is non-fatal
- local proxy can be started with the app store as its data source
- local proxy responds successfully on:
  - `GET /health`
  - `GET /v1/models` with the generated proxy API key
- local proxy process can be stopped and the port is released

### Partially validated

- account switching code path is implemented and persists `current_selection`, but full end-to-end switching could not be proven with only one real account available locally
- Windows-disabled features were verified at code level through `get_runtime_capabilities` and Settings UI gating, but not through automated click-through

### Deferred

- `cloudflared`
- remote Linux proxy
- multi-account smart-switch behavior with a better candidate account
- "launch Codex after switch" with a real second account switch event

## Evidence

### Launch validation

- `npm run tauri dev` was started from `apps/windows-desktop`
- the running process was observed as `copool-windows.exe`
- the app window title appeared as `Copool Windows`

### Store validation

The following file was created and populated:

- `C:\Users\Administrator\AppData\Roaming\com.alick.copool.windows\accounts.json`

Observed persisted values included:

- one imported account for `tifeiyangyang@gmail.com`
- `accountId` = `1e8049ac-814c-4dd4-9e39-c6dca611b193`
- `planType` = `team`
- `current_selection.accountId` populated
- `settings.autoSmartSwitch` present and deserializable
- `settings.launchCodexAfterSwitch` present and deserializable
- `usage.fiveHour.usedPercent` and `usage.oneWeek.usedPercent` populated

### Invalid-auth startup

- `C:\Users\Administrator\.codex\auth.json` was temporarily set to `{}`
- the app still launched successfully
- this confirms empty or invalid auth does not hard-crash startup

### Proxy validation

The standalone proxy daemon was built and used for runtime validation:

- binary: `apps/windows-desktop/src-tauri/target/debug/codex-tools-proxyd.exe`
- command shape verified with `--help`
- daemon launched against `C:\Users\Administrator\AppData\Roaming\com.alick.copool.windows`
- TCP check on `127.0.0.1:8899` succeeded
- `GET http://127.0.0.1:8899/health` returned `200` with `{"ok":true}`
- `GET http://127.0.0.1:8899/v1/models` returned `200` and a model list after reading the generated proxy key from the app-data store
- after stopping the daemon, port `8899` was no longer reachable

## Code-level confirmation

Relevant Windows v1 behavior is wired in:

- `apps/windows-desktop/src-tauri/src/lib.rs`
  - `get_runtime_capabilities`
  - `switch_account_and_launch`
  - `start_api_proxy`
  - `stop_api_proxy`
  - `refresh_api_proxy_key`
- `apps/windows-desktop/src-tauri/src/store.rs`
  - startup sync and store persistence
- `apps/windows-desktop/src-tauri/src/models.rs`
  - Copool-compatible store contracts
- `apps/windows-desktop/src/components/SettingsPanel.tsx`
  - disabled reasons for unsupported Windows v1 features

Targeted test suites also passed:

- `cargo test store::tests -- --nocapture`
- `cargo test proxy_service::tests -- --nocapture`
- `cargo test account_service::tests -- --nocapture`

## Known limits after this pass

- Full switch-account validation still needs a second real account import
- Proxy stop was validated through the standalone daemon process lifecycle, not by UI click automation
- `cloudflared` and remote proxy remain intentionally unvalidated in this round

## Conclusion

The Windows app is validated as a usable core build for:

- startup
- auth recognition
- local store persistence
- usage persistence
- local proxy startup and basic request handling

It is not yet fully validated as a complete production release because the following still need a later pass:

- real multi-account switching
- `cloudflared`
- remote Linux proxy
- broader UI-driven acceptance testing
