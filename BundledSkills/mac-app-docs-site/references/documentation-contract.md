# Illustrated Markdown contract

## Contents

1. Directory and front matter
2. Overview requirements
3. Chapter requirements
4. Screenshot requirements
5. Links, assets, and privacy
6. Refresh rules

## Directory and front matter

Use one directory as the canonical source. Keep Markdown pages at the root and screenshots below `assets/interface/` unless the target repository already has a stricter convention.

Every page starts with:

```yaml
---
title: Human-readable page title
order: 1
description: One sentence describing the user outcome.
---
```

Use `order: 0` for `README.md`. Chapter filenames use a two-digit prefix and a stable lowercase slug. Keep each `order` unique.

## Overview requirements

The overview must include:

- Product purpose and intended audience.
- Documented app version, capture date, source/build provenance, and minimum supported macOS when known.
- One representative screenshot.
- Ordered chapter links.
- Recommended reading paths for first-time and experienced users.
- A compact goal-to-entry-point index when the tutorial has more than three workflows.
- Notation, security, and environment assumptions.

## Chapter requirements

Each chapter should answer:

1. What outcome will the user achieve?
2. What must already be configured?
3. Where does the workflow start?
4. What exact actions are required?
5. What should the user see after the important actions?
6. How can the user recover from common validation, permission, or loading failures?

Prefer numbered steps for a workflow and short lists for choices. Use real UI labels from the captured version. Put platform shortcuts in both words and symbols when useful, for example `Command+Option+R` (`⌘⌥R`).

## Screenshot requirements

- Use PNG for text-heavy interfaces; use JPEG or WebP only when repository conventions or photo-heavy content justify it.
- Preserve a legible full-resolution source.
- Use meaningful alt text that states the UI and purpose, not merely “screenshot”.
- Place the image immediately after the paragraph or step it verifies.
- Avoid using the same screenshot repeatedly unless it genuinely explains separate details.
- Document dynamic lists, permissions, account roles, and feature flags when they cause visible differences.
- Do not add decorative images that provide no evidence.

## Links, assets, and privacy

- Use relative links such as `[Next](02-workspaces.md)` and `![Model picker](assets/interface/03-model-picker.png)`.
- Never use `file://`, `/Users/...`, temporary screenshot paths, or absolute repository paths inside published Markdown.
- Keep external links authoritative and stable.
- Use fixture names and synthetic content. Blur is a last resort because it can miss data and produces weak evidence.
- Inspect window title bars, sidebars, recent items, terminal output, notifications, and account menus for sensitive information.
- Never publish secrets, API tokens, local usernames, private hostnames, balances, personal conversations, or customer data.

## Refresh rules

When updating existing documentation:

- Preserve stable chapter URLs unless the information architecture is unusable.
- Replace screenshots when labels, layout, workflow, or documented version materially changed.
- Update the capture note when any screenshot changes.
- Check whether a changed page invalidates overview navigation, neighboring chapter links, or website slug tests.
- Remove superseded images only after confirming that no Markdown page references them.
