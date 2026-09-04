# Changelog

## [0.2.0] - 2026-09-04

### Fixed

- Storyboard saves no longer crash on the pinned `/usr/bin/ruby` 2.6 interpreter; dialogue normalization dropped the Ruby 2.7 `filter_map` call.
- Partial saves keep untouched fields. Renaming a character no longer wipes its description, identity prompt, and identity version.
- An unreadable archive now refuses the write instead of overwriting it with an empty one, so a truncated file no longer costs the user every drama and job record.
- Generated-image paths are confined to the host's `generated-images` directory and symlinks are rejected.
- Stale `characterID` / `shotID` values are reported instead of silently creating duplicates, and `drama.confirm_plan` accepts a `requestID` for idempotent retries.
- Job and drama archives now share the host's per-plugin directory, with a non-destructive copy of any legacy job store on startup.

### Added

- Added a named short-drama library, AI planning confirmation cards, character identity locking, episode switching, editable scripts/dialogue, and per-shot start/end frame design.
- Added permission-scoped some.im image generation with selectable `gpt-image-2` and `nano_banana_2` models plus configurable candidate counts.
- Added multiple video draws per shot and explicit capability messaging when the default Tsingfly adapter cannot accept an end frame.

### Changed

- Redesigned the React workspace around the full short-drama production pipeline with the approved light macOS sidebar, searchable/status-filtered drama list, recent-work continuation, and responsive narrow-window layout.
- Reworked planning from a one-shot form into contextual AI chat with a persistent transcript and a separately confirmable structured card; all visible copy remains in i18n dictionaries.
- Added three optimized 600×800 WebP cover assets for development previews without increasing the host plugin-size limit.

## [0.1.0] - 2026-09-04

### Added

- Added text-to-video and first-frame image-to-video workflows through a provider-neutral asynchronous video adapter.
- Added Tsingfly Hub `POST /v1/videos` and `GET /v1/videos/{id}` support with multipart uploads, task persistence, polling, explicit retry, and automatic MP4 download.
- Added an AI creative-director workflow that reuses WillDeep's configured chat providers and models without exposing their credentials to the plugin.
- Added bilingual React UI, chat-selection capture, local reference-image picker, output reveal action, and a bundled Agent skill.
- Added manual downloads, in-page paid retry/removal confirmation, non-overlapping polling, Retry-After backoff, interrupted-submission recovery, and runtime-only ZIP packaging.
