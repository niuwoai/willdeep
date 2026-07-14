---
name: some-im-client-services
description: Integrate WillDeep macOS client features with some.im / muchtoken backend, admin console, customer/public APIs, managed web search, update server metadata, client download/update flows, shared some.im login/session, and related i18n/version/changelog work. Use when Codex needs to add or maintain WillDeep features backed by some.im services, especially API-key fallback services, public app update feeds, admin settings pages, or client UI affordances in the some.im account area.
---

# some.im Client Services

## Overview

Coordinate two repositories:

- WillDeep/Xedit: `/Users/rocky/Sites/Xedit`
- some.im backend/admin: `/Users/rocky/Sites/muchtoken`

Use this skill together with `some-im-mac-integration` when the task touches shared login, Keychain credentials, or the some.im settings flow.

## Workflow

1. Identify which service owns the behavior.
   - Use `muchtoken` for server-side provider credentials, admin pages, customer APIs, public APIs, database migrations, and version headers.
   - Use `Xedit` for client fallback logic, account-area UI, polling timers, downloads, Keychain/session reads, and user-facing prompts.
2. Add server support first, then wire the client.
   - Keep customer-specific calls under `/api/v1/customer/...` with customer session/API-key auth.
   - Keep unauthenticated metadata under `/api/v1/public/...` so clients and edge nodes can fetch it.
   - Keep operator controls under `/api/v1/admin/...` and guard secret-bearing pages with ops/admin auth.
3. Keep React admin UI fully localized.
   - Put all labels, button text, hints, toast messages, and empty states in `web/src/locales/admin-*.json`.
   - Do not hardcode visible text in TSX.
   - Prefer `yarn` for frontend scripts.
4. Keep WillDeep UI localized.
   - Add L10n accessors in `Xedit/L10n.swift`.
   - Add matching entries in `Xedit/Localizable.xcstrings`.
   - Do not put new visible strings directly in SwiftUI views or alerts.
5. Update versions and docs after code changes.
   - Bump semantic versions according to the repository rules.
   - Keep frontend/backend versions aligned in `muchtoken`.
   - Update `CHANGELOG.md`; update product overview docs when behavior changes.

## Managed Web Search

Use this pattern when WillDeep should fall back to some.im search:

- Store provider secrets only in some.im server config (`system_configs` or a dedicated secret table), never in public API responses.
- Admin page should support Exa and Brave first, with a provider-shaped config that can accept future providers.
- Customer API should accept WillDeep's some.im login/customer API key and expose a normalized search response:
  - `query`
  - `provider`
  - `result_count`
  - `results[]` with `title`, `url`, `snippet`, and optional metadata.
- WillDeep should try local Exa/Brave keys first.
- If local keys are empty and some.im is signed in, call the some.im customer search API.
- If the some.im call fails, tell the user to fill local Web tool API keys.

## App Update Server

Use this pattern when adding app update metadata:

- Model update records by `app_id`, `platform`, and `channel`; do not hardcode WillDeep-only schemas.
- Include at least `latest_version`, `download_url`, `enabled`, `created_at`, and `updated_at`.
- Include optional `minimum_version`, `minimum_system_version`, `release_notes_url`, `release_notes`, `sha256`, `file_size_bytes`, and `published_at` when useful.
- Expose a public latest endpoint like:
  - `GET /api/v1/public/app-updates/latest?app_id=willdeep&platform=macos&channel=stable&current_version=...`
- Return `update_available` and an `item` object. Keep `version` and `latest_version` compatible for older clients.
- Add an admin page for CRUD over release channels, with localized form labels and table columns.

## WillDeep Update UX

Use this pattern for client updates:

- Poll after a short launch delay, then at a low-frequency interval.
- Store the available update in `AppState`; render it in the lower-left some.im account footer, above the avatar/login row.
- The action button should download the artifact to the user's Downloads folder.
- After download succeeds, ask whether to quit WillDeep and open the installer/package.
- Do not auto-quit or auto-install without user confirmation.

## Validation

Run focused checks before finishing:

- `go test ./internal/authapi -run '<new tests>'` in `muchtoken`.
- A targeted frontend test or `yarn --cwd web test ... --run` if the admin UI changed.
- A targeted Xcode test for changed WillDeep code, or explain if it cannot be run.
- Version consistency scripts if present, such as `ruby scripts/version_consistency.rb`.
