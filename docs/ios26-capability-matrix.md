# Copool iOS 26 Capability Matrix

## Deployment Modes

- `localDevice`: iOS app runs only local-safe capabilities.
- `backendService`: iOS app delegates remote deployment and public tunnel operations to backend services.

## Page-Level Behavior

- Accounts
  - Keep account import, usage refresh, and switch workflows.
  - `Add account via login` remains unavailable on iOS (requires Codex CLI login flow).
- Proxy
  - Keep local API proxy controls.
  - Remote server management and public tunnel controls:
    - `localDevice`: shown as unavailable.
    - `backendService`: shown as backend-managed responsibilities.
- Settings
  - Adds deployment mode selector.
  - Adds capability matrix section as source-of-truth status view.

## Source of Truth

- Capability rules are centralized in:
  - `Sources/Copool/Domain/CapabilityMatrix.swift`
- Persisted mode field:
  - `AppSettings.backendServiceMode`

## Test Contracts

- `Tests/CopoolTests/CapabilityMatrixTests.swift`
  - Verifies iOS local vs backend-managed behavior for remote/public capabilities.
  - Verifies macOS capabilities stay available regardless of deployment mode.
