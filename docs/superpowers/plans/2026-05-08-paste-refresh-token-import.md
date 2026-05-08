# Paste Refresh Token Import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `Import Account -> 粘贴导入` so pasted `邮箱----任意内容----rt_xxx` lines import accounts, display cards by pasted email, and keep automatic token refresh through stored refresh tokens.

**Architecture:** Add one new paste-import UI action, a pure parser for pasted rows, and a refresh-token exchange path that produces the existing auth JSON shape. Reuse the current account import pipeline after auth normalization, and widen email extraction only enough to honor top-level imported email when token claims do not provide one.

**Tech Stack:** Swift 6, SwiftUI, Foundation networking, XCTest, existing `Accounts` feature modules.

---

### Task 1: Add Menu Coverage for the New Paste Import Action

**Files:**
- Modify: `Sources/Copool/Features/Accounts/AccountsActionPresentation.swift`
- Test: `Tests/CopoolTests/AccountsActionPresentationTests.swift`

- [ ] **Step 1: Write the failing test**

Add assertions in `Tests/CopoolTests/AccountsActionPresentationTests.swift` that `Import Account` menu items now include `pasteImport` alongside the existing `importCurrentAuth` and `importAuthFile` actions.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AccountsActionPresentationTests`
Expected: FAIL because `pasteImport` does not exist yet.

- [ ] **Step 3: Write minimal implementation**

Add `pasteImport` to `AccountsPageActionIntent` and insert the new menu item into desktop and toolbar import menus in `Sources/Copool/Features/Accounts/AccountsActionPresentation.swift`.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter AccountsActionPresentationTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/Copool/Features/Accounts/AccountsActionPresentation.swift Tests/CopoolTests/AccountsActionPresentationTests.swift
git commit -m "feat: add paste import account action"
```

### Task 2: Add a Pure Parser for Pasted Refresh Token Rows

**Files:**
- Create: `Sources/Copool/Infrastructure/PastedRefreshTokenAccountParser.swift`
- Test: `Tests/CopoolTests/PastedRefreshTokenAccountParserTests.swift`

- [ ] **Step 1: Write the failing test**

Add parser tests that cover:

- valid `email----password----rt_xxx`
- valid `email----foo----bar----rt_xxx`
- valid `email----rt_xxx`
- invalid first segment email
- invalid last segment without `rt_`
- blank lines are skipped

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PastedRefreshTokenAccountParserTests`
Expected: FAIL because the parser does not exist yet.

- [ ] **Step 3: Write minimal implementation**

Implement a small parser that:

- splits input by lines
- trims whitespace
- skips empty lines
- splits remaining lines by literal `----`
- validates first segment as email
- validates last segment starts with `rt_`
- ignores middle segments
- returns parsed records and explicit failures without guessing

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter PastedRefreshTokenAccountParserTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/Copool/Infrastructure/PastedRefreshTokenAccountParser.swift Tests/CopoolTests/PastedRefreshTokenAccountParserTests.swift
git commit -m "feat: parse pasted refresh token account rows"
```

### Task 3: Add Refresh Token Exchange Coverage Before Networking Implementation

**Files:**
- Modify: `Sources/Copool/Domain/Protocols.swift`
- Test: `Tests/CopoolTests/AuthFileRepositoryTests.swift`
- Test: `Tests/CopoolTests/AccountsCoordinatorTests.swift`

- [ ] **Step 1: Write the failing test**

Add tests that define the intended contract:

- exchange from `(email, refreshToken)` returns auth JSON with top-level `email`
- auth JSON contains `tokens.access_token`, `tokens.id_token`, `tokens.refresh_token`, and `tokens.account_id`
- the resulting auth can be passed through existing account import logic

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AuthFileRepositoryTests --filter AccountsCoordinatorTests`
Expected: FAIL because there is no refresh-token exchange API yet.

- [ ] **Step 3: Write minimal implementation**

Add the smallest repository-facing protocol surface for refresh-token exchange so tests can compile:

- one new `AuthRepository` entry point for creating auth JSON from `email` plus `refreshToken`

Keep implementation placeholder-level until the next task.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter AuthFileRepositoryTests --filter AccountsCoordinatorTests`
Expected: compile succeeds, behavior tests still fail until the real implementation lands.

- [ ] **Step 5: Commit**

```bash
git add Sources/Copool/Domain/Protocols.swift Tests/CopoolTests/AuthFileRepositoryTests.swift Tests/CopoolTests/AccountsCoordinatorTests.swift
git commit -m "test: define refresh token auth exchange contract"
```

### Task 4: Implement Refresh Token Exchange into Standard Auth JSON

**Files:**
- Modify: `Sources/Copool/Infrastructure/AuthFileRepository.swift`
- Test: `Tests/CopoolTests/AuthFileRepositoryTests.swift`

- [ ] **Step 1: Write the failing test**

Add a focused repository test using a mocked `URLSession` response that proves:

- the refresh endpoint is called with the supplied refresh token
- a successful response is normalized into auth JSON
- returned rotated refresh token replaces the original when present
- `account_id` is resolved from the returned `id_token`

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AuthFileRepositoryTests`
Expected: FAIL because the real exchange implementation does not exist.

- [ ] **Step 3: Write minimal implementation**

Implement the refresh-token exchange path in `AuthFileRepository` by:

- posting to the token endpoint
- decoding the token response
- extracting account ID from `id_token`
- writing top-level `email`
- returning normalized auth JSON in the existing repository shape

Do not add alternate endpoint fallbacks or third-party service support.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter AuthFileRepositoryTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/Copool/Infrastructure/AuthFileRepository.swift Tests/CopoolTests/AuthFileRepositoryTests.swift
git commit -m "feat: exchange refresh tokens into auth json"
```

### Task 5: Teach Email Extraction to Honor Imported Top-Level Email

**Files:**
- Modify: `Sources/Copool/Infrastructure/AuthFileRepository.swift`
- Test: `Tests/CopoolTests/AuthFileRepositoryTests.swift`

- [ ] **Step 1: Write the failing test**

Add a test where:

- `id_token` lacks an `email` claim
- auth JSON contains top-level `email`
- `extractAuth(from:)` returns that top-level `email`

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AuthFileRepositoryTests/testExtractAuthFallsBackToTopLevelEmail`
Expected: FAIL because `extractAuth` currently reads email only from token claims.

- [ ] **Step 3: Write minimal implementation**

Update `extractAuth(from:)` to:

- prefer claim email when present
- otherwise fall back to top-level auth `email`

Do not widen fallback beyond this exact field.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter AuthFileRepositoryTests/testExtractAuthFallsBackToTopLevelEmail`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/Copool/Infrastructure/AuthFileRepository.swift Tests/CopoolTests/AuthFileRepositoryTests.swift
git commit -m "feat: preserve imported account email labels"
```

### Task 6: Add Coordinator Support for Pasted Import Records

**Files:**
- Modify: `Sources/Copool/Behavior/AccountsCoordinator+Maintenance.swift`
- Modify: `Sources/Copool/Domain/Protocols.swift`
- Test: `Tests/CopoolTests/AccountsCoordinatorTests.swift`

- [ ] **Step 1: Write the failing test**

Add coordinator tests that prove:

- pasted text is parsed into records
- each valid record is exchanged into auth JSON
- imported account label resolves to the pasted email
- malformed lines fail explicitly instead of being guessed

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AccountsCoordinatorTests`
Expected: FAIL because no pasted import coordinator path exists.

- [ ] **Step 3: Write minimal implementation**

Add a coordinator entry point that:

- accepts pasted text
- uses the parser
- serially exchanges and imports valid lines
- returns or surfaces a concise result summary

Reuse existing auth JSON import logic instead of duplicating account creation.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter AccountsCoordinatorTests`
Expected: PASS for the new pasted import coverage.

- [ ] **Step 5: Commit**

```bash
git add Sources/Copool/Behavior/AccountsCoordinator+Maintenance.swift Sources/Copool/Domain/Protocols.swift Tests/CopoolTests/AccountsCoordinatorTests.swift
git commit -m "feat: import accounts from pasted refresh token rows"
```

### Task 7: Add the Paste Import Sheet to the Accounts Page

**Files:**
- Modify: `Sources/Copool/Features/Accounts/AccountsPageView.swift`
- Modify: `Sources/Copool/Features/Accounts/AccountsPageModel.swift`
- Modify: `Sources/Copool/Features/Accounts/AccountsPageModel+AccountMutations.swift`
- Optionally Create: `Sources/Copool/Features/Accounts/AccountsPasteImportSheet.swift`
- Test: `Tests/CopoolTests/AccountsCoordinatorTests.swift`

- [ ] **Step 1: Write the failing test**

Add page-model coverage that proves:

- triggering `pasteImport` opens the paste-import flow
- submitting pasted text calls the new coordinator path
- success updates notice text
- errors surface as notice text

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AccountsCoordinatorTests/testAccountsPageModel`
Expected: FAIL because the page model and UI do not know about `pasteImport`.

- [ ] **Step 3: Write minimal implementation**

Update the Accounts UI to:

- add the `pasteImport` action
- present a multiline text-entry modal
- submit the pasted text through the page model
- keep the current auth-file and current-auth flows unchanged

If `AccountsPageView.swift` becomes noisy, split the modal into a small dedicated file.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter AccountsCoordinatorTests/testAccountsPageModel`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/Copool/Features/Accounts/AccountsPageView.swift Sources/Copool/Features/Accounts/AccountsPageModel.swift Sources/Copool/Features/Accounts/AccountsPageModel+AccountMutations.swift Sources/Copool/Features/Accounts/AccountsPasteImportSheet.swift Tests/CopoolTests/AccountsCoordinatorTests.swift
git commit -m "feat: add accounts paste import sheet"
```

### Task 8: Run End-to-End Validation for Import and Refresh Behavior

**Files:**
- Modify: `Tests/CopoolTests/AccountsCoordinatorTests.swift`
- Modify: `Tests/CopoolTests/AuthFileRepositoryTests.swift`

- [ ] **Step 1: Write the failing test**

Add end-to-end coverage that proves:

- a pasted line imports into an account labeled by email
- the stored auth contains a refresh token
- the stored auth remains compatible with the existing refresh path

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AccountsCoordinatorTests --filter AuthFileRepositoryTests`
Expected: FAIL until all integration pieces are in place.

- [ ] **Step 3: Write minimal implementation**

Make any final minimal adjustments required to align parsing, exchange, import, and refresh compatibility. Do not broaden feature scope.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter AccountsCoordinatorTests --filter AuthFileRepositoryTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Tests/CopoolTests/AccountsCoordinatorTests.swift Tests/CopoolTests/AuthFileRepositoryTests.swift
git commit -m "test: verify pasted refresh token import flow"
```
