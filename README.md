# Copool

<img src="./Copool.png" alt="Copool Icon" width="160" />

Copool manages Codex/ChatGPT accounts, usage-aware switching, and local or remote API proxy workflows.

This repo now contains two desktop tracks:

- Apple app: native SwiftUI for macOS and iOS in `Sources/`, `Tests/`, and `Copool.xcodeproj`
- Windows app: native desktop app in `apps/windows-desktop/` using React + Tauri + Rust

## Platform Matrix

### macOS / iOS

- SwiftUI app with layered architecture
- iCloud and CloudKit sync
- Apple platform launch and menu bar integration

### Windows v1

- Native Tauri desktop app
- Core account management, usage refresh, smart switch, local proxy, cloudflared, and remote Linux proxy control
- Copool-compatible account store fields including `currentSelection`, `teamName`, and `teamAlias`
- No CloudKit or iCloud sync in v1
- Editor auto-restart is intentionally disabled in v1

## Build And Run

### Apple app

```bash
xcodebuild test -project Copool.xcodeproj -scheme Copool -destination "platform=macOS"
xcodebuild -project Copool.xcodeproj -scheme Copool -configuration Debug -destination "platform=macOS" build
xcodebuild -project Copool.xcodeproj -scheme CopooliOS -configuration Debug -destination "platform=iOS Simulator,name=iPhone 17" build
```

Open `Copool.xcodeproj` in Xcode and run `Copool` for macOS or `CopooliOS` for iOS.

### Windows app

```bash
cd apps/windows-desktop
npm install
npm run build
cd src-tauri
cargo test
```

For local desktop development from the Windows app folder:

```bash
npm run tauri dev
```

To build a Windows installer from `apps/windows-desktop/`:

```bash
npm run tauri build
```

The packaged Windows outputs are generated at:

- `apps/windows-desktop/src-tauri/target/release/bundle/nsis/Copool Windows_1.0.5_x64-setup.exe`
- `apps/windows-desktop/src-tauri/target/release/bundle/msi/Copool Windows_1.0.5_x64_en-US.msi`

## Repo Layout

- `Sources/Copool/`: Apple-platform app code
- `Tests/CopoolTests/`: Swift tests
- `apps/windows-desktop/src/`: Windows React frontend
- `apps/windows-desktop/src-tauri/`: Windows Tauri + Rust backend

## Reference

The Windows app is bootstrapped from the ideas and Windows runtime patterns in [170-carry/codex-tools](https://github.com/170-carry/codex-tools), then adapted to Copool data contracts and behavior.
