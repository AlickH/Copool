# Copool Windows

Windows desktop client for Copool, built with React + Tauri + Rust.

## Scope

Windows v1 focuses on the core desktop workflow:

- import, refresh, switch, and delete Codex or ChatGPT auth accounts
- persist Copool-compatible account data and current selection
- local `/v1` OpenAI-compatible proxy
- cloudflared tunnel management
- remote Linux proxy deployment and control over SSH
- tray integration and launch at startup

## Not In Windows v1

- CloudKit or iCloud sync
- automatic editor restart after account switch
- Apple-only menu bar or entitlement behavior

## Commands

```bash
npm install
npm run build
npm run tauri dev
```

Backend verification:

```bash
cd src-tauri
cargo test
```
