# Design QA

- source visual truth path: `/Users/rocky/Sites/Xedit/artifacts/design-qa/agent-attention-1.267.0-rc3/reference.png`
- implementation screenshot path: `/Users/rocky/Sites/Xedit/artifacts/design-qa/agent-attention-1.267.0-rc3/settings-ai-agents.jpeg`
- component implementation capture: Computer Use full-window capture emitted in the 2026-08-17 QA session (confirm and compact authorization states)
- viewport: native macOS window `1256 × 768 px`; source image `1536 × 1024 px`
- density normalization: compared by hierarchy, component proportions, typography weight, action contrast, and neutral-color usage rather than pixel scale
- state: confirm, batch confirm, browser authorization, Computer Use authorization, and AI Agents settings navigation

## Full-view comparison evidence

- The selected monochrome concept was used as the source of truth.
- A freshly built Debug app was launched and the `#1983#` local component fixture rendered the confirmation and authorization states without contacting an AI provider.
- The rendered view preserved the selected direction: black primary actions, white/gray secondary actions, light neutral surfaces, restrained borders, and no system-blue action emphasis.
- The settings capture confirms the new `通知` destination is present inside AI Agents settings.

## Focused comparison evidence

- Primary buttons: black fill, white text, rounded neutral treatment; pass.
- Secondary/destructive buttons: white or translucent neutral surface with gray border/text; pass.
- Confirmation metadata chips and explanatory actions: gray hierarchy; pass.
- Compact browser/Computer Use authorization icon: the first capture exposed a theme-blue icon; changed to secondary gray and rebuilt successfully.
- `ask_user`: shares the same icon tile, eyebrow, option-card, footer, and black-primary-button system; compiled and covered by the local fixture regression test.

## Findings

- No open P0/P1/P2 visual defects after the second pass.
- Existing global settings selection tint remains the app's current navigation convention and is outside the confirm/ask_user/authorization surfaces changed here.

## Required fidelity surfaces

- Fonts and typography: pass; question hierarchy is stronger than supporting copy.
- Spacing and layout rhythm: pass; action groups retain large click targets and consistent gaps.
- Colors and visual tokens: pass after replacing the remaining compact-authorization accent icon with secondary gray.
- Image quality and asset fidelity: pass; the component uses SF Symbols and vector SwiftUI surfaces only.
- Copy and content: pass; all newly exposed component/settings copy is localized.

## Comparison history

- Pass 1: build succeeded and the live component fixture was captured; found one compact authorization icon still using the theme accent.
- Fix: changed the compact authorization icon from `palette.accent` to `palette.secondaryText`.
- Pass 2: Debug build and 12 targeted tests passed; no further blocking visual differences found.

final result: pass
