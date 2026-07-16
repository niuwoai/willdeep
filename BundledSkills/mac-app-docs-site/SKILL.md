---
name: mac-app-docs-site
description: Capture real macOS app interfaces and end-to-end workflows with the available Computer Use skill, turn the evidence into an illustrated Markdown tutorial directory, and integrate that directory into a tested documentation website. Use when documenting or re-documenting a Mac app, creating screenshot-based help/tutorial pages, refreshing docs after UI changes, converting an existing Markdown tutorial directory into web routes, or auditing that screenshots, Markdown, navigation, and website rendering still agree.
---

# Mac App Docs Site

Produce documentation from verified product behavior, not from assumptions. Keep the Markdown directory as the canonical content source and make the website render it instead of duplicating prose in components.

## Choose the mode

- **Full workflow**: capture the app, author or refresh Markdown, then build the website. Use this by default when the request mentions both documentation and a site.
- **Capture and author**: stop after the Markdown directory and its audit pass.
- **Site only**: start from an existing Markdown directory. Do not recapture unless the pages are missing evidence or conflict with the current UI.
- **Refresh**: compare existing pages and screenshots with the current app, replace only stale evidence, then rebuild affected routes.

## Establish the contract

Resolve these values from the request and repository before asking questions:

1. App name, bundle identifier or app path, and the version being documented.
2. Repository root and documentation directory. Default to `docs/<app-slug>-tutorial/`.
3. Website repository, locale, public base path, and the most similar existing documentation route.
4. Required workflows, intended audience, and whether deployment is in scope.

Ask only when multiple plausible choices would materially change the output. Treat local build/install, website deployment, Git commit, and push as separate permissions unless the user already requested them.

Create a small coverage matrix before capture. Each row needs a user goal, start state, actions, expected result, screenshot state, and destination chapter. Include empty, loading, success, validation, and recovery states when users are likely to encounter them.

## Capture the real app

Before operating the UI, load and follow the available `computer-use` skill. Then read [references/computer-use-adapters.md](references/computer-use-adapters.md) and select the adapter exposed by the current host.

1. Check Computer Use permissions before UI actions.
2. Prepare a clean fixture workspace and non-sensitive demo data.
3. Inspect the app state, act through accessibility references when possible, then fetch fresh state after every action. Never reuse stale element references.
4. Capture only a stable, relevant app window. Wait for menus, sheets, loading states, or animations to reach the intended evidence state.
5. Save the full-resolution screenshot directly under `assets/interface/` with a semantic lowercase name such as `03-model-picker.png`.
6. Visually inspect every saved image. Reject captures containing credentials, tokens, email addresses, personal conversations, account balances, server names, unrelated apps, cursor-only artifacts, or clipped controls.
7. Record the app version, capture date, source/build provenance, fixture assumptions, and any permission-dependent differences.

Do not trigger destructive, financial, external-communication, permission-changing, login-secret, or production-data actions merely to obtain a screenshot. Use a safe fixture state or stop at the confirmation boundary required by Computer Use policy.

## Author the Markdown source

Read [references/documentation-contract.md](references/documentation-contract.md). Copy the templates from `assets/` when starting a new tutorial.

Required output shape:

```text
docs/<app-slug>-tutorial/
├── README.md
├── 01-<topic>.md
├── 02-<topic>.md
└── assets/
    └── interface/
        ├── 01-<state>.png
        └── 02-<state>.png
```

Use `README.md` as the overview and ordered navigation source. Give every page `title`, numeric `order`, and `description` front matter. Use only relative links and relative image paths. Put a screenshot next to the step or explanation it proves; do not make an image dump at the end.

For each workflow, explain the goal, prerequisites, exact steps, expected result, and recovery path. Match labels and keyboard shortcuts to the captured build. Describe version-dependent or permission-dependent differences explicitly.

Run the bundled audit after authoring:

```bash
ruby <skill-dir>/scripts/audit_docs.rb <docs-dir> --report-dir <repo>/build/mac-app-docs-site-audit
```

Fix every error. Review warnings rather than suppressing them blindly. Open representative full-resolution images after the audit; file existence alone does not prove a usable screenshot.

## Generate the website

Read [references/site-integration.md](references/site-integration.md). Inspect the nearest existing documentation page and follow its route, layout, styling, metadata, asset loading, SSR/static generation, and testing conventions.

1. Map `README.md` to the docs landing route and chapter filenames to stable slugs.
2. Load Markdown and assets from the canonical directory. Do not paste page content into JSX, TSX, Swift, or route configuration.
3. Derive sidebar/navigation order and page titles from front matter or the README index.
4. Preserve relative Markdown links and images after routing.
5. Route all visible React text through the existing i18n system. When only one content locale exists, implement an explicit documented fallback instead of silently returning an empty page.
6. Add or update valid-slug, route-refresh, navigation, missing-page, image-resolution, and Markdown-rendering tests in proportion to the site architecture.
7. Verify the production build and direct navigation to both the overview and at least one chapter URL.

If no website exists and a framework choice is necessary, prefer React + TypeScript + Vite, strict TypeScript, existing repository package management, and content-driven routes. Do not introduce a new framework into an established site merely for this feature.

## Verify and hand off

Complete all applicable checks:

- Documentation audit exits successfully and produces both Markdown and JSON reports.
- Every planned workflow is represented by prose and at least one meaningful visual state.
- Screenshot dimensions and text are legible; images contain no sensitive or unrelated data.
- Overview, chapter navigation, relative links, deep links, missing routes, and localized fallbacks behave correctly.
- Relevant unit tests, route/SSR tests, lint, and production build pass.
- Deployment, Git commit, push, or publication occurs only when requested.

Report the documentation directory, generated routes, capture coverage, audit report paths, verification commands, and any states that still require manual capture.
