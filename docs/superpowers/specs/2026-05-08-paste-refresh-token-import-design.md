# Paste Refresh Token Import Design

Date: 2026-05-08
Repository: `Copool`
Scope: `Accounts` page import flow on macOS, with repository-consistent model changes that also remain valid for shared account logic.

## Goal

Add a new `Import Account -> 粘贴导入` action that accepts pasted lines such as `邮箱----任意内容----rt_xxx`, extracts only `email` and `refreshToken`, exchanges the refresh token for a full ChatGPT auth payload, imports the account into the existing store, shows the card label as the pasted email, and preserves automatic token refresh after import.

## Problem Summary

The current repository supports two import paths:

- import current local auth
- import an auth JSON file

It does not support the user's real input source: pasted text records where only the email and final refresh token matter.

Today this causes three concrete gaps:

1. No direct paste-based import action exists in the `Import Account` menu.
2. The importer expects auth JSON instead of a lightweight text record.
3. Card naming depends mostly on token-derived email, while the user's source text already provides the desired card label.

## Current Evidence

Relevant current code:

- `Sources/Copool/Features/Accounts/AccountsActionPresentation.swift`
- `Sources/Copool/Features/Accounts/AccountsPageView.swift`
- `Sources/Copool/Features/Accounts/AccountsPageModel.swift`
- `Sources/Copool/Features/Accounts/AccountsPageModel+AccountMutations.swift`
- `Sources/Copool/Behavior/AccountsCoordinator+Maintenance.swift`
- `Sources/Copool/Infrastructure/AuthFileRepository.swift`
- `Sources/Copool/Infrastructure/AuthParsingSupport.swift`

Observed constraints from the current implementation:

- `AccountsActionPresentation` already models `Import Account` as a menu with selectable actions.
- `AccountsPageView` already owns modal state for auth-file import and is the right UI seam for one more import surface.
- `AccountsCoordinator.importAccount(authJSON:)` already handles account insertion, usage fetch, workspace metadata lookup, and persistence once valid auth JSON exists.
- `AuthFileRepository.refreshChatGPTAuth(_:)` already performs access-token refresh using stored refresh-token-backed auth.
- The default card label is `extracted.email`, else `Codex <accountID prefix>`.
- `extractAuth(from:)` currently reads `email` only from JWT claims, not from a top-level auth field supplied by an alternate import path.

## User Input Contract

The new paste importer accepts one or more lines.

Each valid line follows this minimum rule:

- split by literal `----`
- first segment must be an email
- last segment must start with `rt_`
- middle segments are ignored completely

Examples that should parse:

- `a@example.com----password----rt_xxx`
- `a@example.com----foo----bar----rt_xxx`
- `a@example.com----rt_xxx`

Examples that should fail:

- missing email
- invalid email in first segment
- last segment not starting with `rt_`
- blank line with non-whitespace content after normalization

## Non-Goals

- No password-based login flow
- No support for separators other than `----`
- No CSV, Excel, or mixed-format import in this slice
- No dependency on a third-party token-conversion service
- No refactor of the existing account store format beyond fields required for this flow
- No fallback heuristics beyond the explicit parse rules above

## Approaches Considered

### Approach A: Reuse auth-file import and allow text files with the new format

Pros:

- Minimal new UI
- Reuses existing file importer

Cons:

- Does not match the user's required interaction
- Mixes two incompatible import semantics into one file-based path
- Makes future UX and error messages less clear

### Approach B: Add a new paste-import action that parses text and converts each line into auth JSON

Pros:

- Matches the requested workflow directly
- Keeps JSON import logic unchanged
- Lets the new feature stay isolated to a clear input path

Cons:

- Requires one small new modal UI
- Requires one additional import orchestration path

### Approach C: Replace current import account options with a generalized “any source” wizard

Pros:

- Centralized long-term import UX

Cons:

- Overdesigned for the current request
- Forces unrelated workflow changes
- Adds structure without evidence it is needed

Recommendation: Approach B

Reason: it satisfies the exact requested workflow with the smallest clear change set and avoids contaminating the existing auth JSON import path.

## Design Overview

The feature adds a new paste-based import path while reusing the existing post-auth account import path.

High-level flow:

1. User opens `Import Account -> 粘贴导入`
2. User pastes one or more lines
3. A pure parser extracts `email` and `refreshToken` from each valid line
4. A refresh-token exchange service converts each parsed record into a standard auth JSON payload
5. The coordinator imports that auth JSON through the existing account-import flow
6. The imported account label resolves to the pasted email
7. Future token refresh uses the stored refresh token through the existing refresh path

## Component Design

### 1. UI action and paste sheet

Add one new action intent to the `Import Account` menu: `pasteImport`.

The `AccountsPageView` should present a simple text-entry sheet or dialog for paste input. The modal only needs:

- multiline text input
- import button
- cancel button

It does not need preview tables, password columns, format switching, or advanced validation UI.

### 2. Text parser

Add a small parser dedicated to this format.

Responsibility:

- parse pasted multiline text into `[ParsedPastedAccountRecord]`

Fields:

- `email`
- `refreshToken`

Rules:

- trim surrounding whitespace for each line and segment
- skip fully empty lines
- require first segment to be a valid email
- require last segment to start with `rt_`
- ignore all middle segments
- return explicit per-line parse failures instead of guessing

This parser must remain independent of networking and account storage.

### 3. Refresh-token exchange service

Add a dedicated service for:

- input: `email`, `refreshToken`
- output: auth JSON in the repository's existing shape

Target auth shape:

```json
{
  "auth_mode": "chatgpt",
  "email": "user@example.com",
  "tokens": {
    "access_token": "...",
    "id_token": "...",
    "refresh_token": "...",
    "account_id": "..."
  }
}
```

Behavior:

- call the token endpoint using the refresh token
- extract `access_token`, `id_token`, and returned `refresh_token` if rotated
- resolve `account_id` from token claims or token response-backed logic already used in the repository
- stamp the pasted email at top level so card labeling does not depend on `id_token` containing `email`

The service should not store anything directly. It only returns normalized auth JSON.

### 4. Account import orchestration

Add a coordinator path that accepts parsed records and imports them one by one.

Responsibilities:

- parse pasted text
- exchange each record into auth JSON
- call the existing auth JSON import flow
- collect success/failure results
- update the page notice with a concise result summary

The actual account persistence should stay inside the existing account import pipeline.

### 5. Email extraction and card labeling

The current `extractAuth(from:)` behavior is too narrow for this import path because it reads email only from token claims.

Required change:

- when claim email is missing, read top-level auth `email`

This keeps the imported card label stable as the pasted email and avoids inventing fake JWT claims.

## Data Flow

For one pasted line:

`Paste sheet -> text parser -> parsed record(email, refreshToken) -> refresh-token exchange service -> normalized auth JSON -> existing importAccount(authJSON:) -> stored account + card presentation`

For later token expiry:

`stored auth JSON with refresh_token -> existing refreshChatGPTAuth(_:) -> refreshed auth JSON -> existing account refresh flow`

## Error Handling

Errors should stay explicit and local.

Parse-stage errors:

- invalid line format
- invalid email
- missing `rt_` token

Exchange-stage errors:

- refresh token rejected
- token endpoint response missing required fields
- account ID cannot be resolved

Import-stage errors:

- existing current account write failure
- usage fetch failure
- workspace metadata failure

Rules:

- do not guess missing data
- do not silently reinterpret a malformed line
- do not add fallback separators or alternate record grammars

## Testing Strategy

Minimum required tests:

1. Parser accepts valid lines with ignored middle segments.
2. Parser rejects malformed lines without `rt_` as the last segment.
3. Paste import action appears in `Import Account` menu presentation.
4. Pasted import path passes parsed records into import orchestration.
5. Imported auth falls back to top-level `email` for display label when token claims do not contain email.
6. Auth generated from refresh-token exchange includes `refresh_token` and remains refreshable by existing code.

## File Impact

Expected primary files:

- `Sources/Copool/Features/Accounts/AccountsActionPresentation.swift`
- `Sources/Copool/Features/Accounts/AccountsPageView.swift`
- `Sources/Copool/Features/Accounts/AccountsPageModel.swift`
- `Sources/Copool/Features/Accounts/AccountsPageModel+AccountMutations.swift`
- `Sources/Copool/Behavior/AccountsCoordinator+Maintenance.swift`
- `Sources/Copool/Infrastructure/AuthFileRepository.swift`
- `Sources/Copool/Infrastructure/AuthParsingSupport.swift`

Likely new focused files:

- parser for pasted refresh-token rows
- service for refresh-token exchange
- small paste-import sheet view if keeping the view file thin requires a split

## Risks

- The refresh-token exchange endpoint contract must match real token endpoint behavior.
- Some refresh tokens may already be invalid or rotated before import.
- Batch import should remain serial in the first slice to keep error reporting and state transitions clear.
- A dirty worktree exists in `Sources/Copool/Infrastructure/CloudKitCurrentAccountSelectionSyncService.swift`; implementation should not proceed until the user decides how to handle the required pre-change commit point.
