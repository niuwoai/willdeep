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

---

## Token 单日详情与分享卡（1.272.0-rc7）

- source visual truth paths:
  - `/Users/rocky/Sites/Xedit/artifacts/design-qa/token-daily-1.272.0-rc7/daily-reference.png`
  - `/Users/rocky/Sites/Xedit/artifacts/design-qa/token-daily-1.272.0-rc7/share-reference.png`
- implementation screenshot paths:
  - `/Users/rocky/Sites/Xedit/artifacts/design-qa/token-daily-1.272.0-rc7/daily-implementation.jpeg`
  - `/Users/rocky/Sites/Xedit/artifacts/design-qa/token-daily-1.272.0-rc7/share-implementation.jpeg`
- viewport: native macOS window `1402 × 768 px`; share preview sheet `430 × 562 px`
- source sizes: daily reference `1536 × 1024 px`; share reference `1124 × 1402 px`
- density normalization: the single-day page was compared inside the real chat/composer shell; the share card was compared by its exported 4:5 composition, hierarchy, contrast, grid proportions, and data density.
- state: populated 2026-08-18 calendar day with real local usage snapshots; share preview generated from the same day.

### Full-view comparison evidence

- The selected option-2 daily hierarchy is preserved: date and share action, five-metric strip, model efficiency on the left, achievements and capability usage on the right.
- The selected option-3 share direction is preserved: near-black background, blue activity accents, monospaced developer styling, dominant Token total, bordered metric grid, and compact model/skill/streak footer.
- Initial live navigation exposed inherited transcript scroll position when changing dashboard pages. The implementation now posts a page-change request and scrolls the transcript to its top anchor; the second live capture starts at the daily header as intended.

### Focused comparison evidence

- Typography and hierarchy: pass; the day title, hero Token count, metric values, and supporting labels retain the selected emphasis order.
- Spacing and layout rhythm: pass; the production page is intentionally denser than the concept so it fits the existing 568pt dashboard column without introducing a new window.
- Model bars: pass after separating uncached input, output, and cached input so the rendered segments sum to the model total instead of overflowing 100%.
- Share card: pass; all selected information is visible without clipping, and the preview exposes working Save and Share actions.
- Localization and assets: pass; visible copy comes from the string catalog and icons use native SF Symbols consistent with the existing product.

### Findings

- No open P0/P1/P2 visual defects after the scroll-position and model-segment corrections.
- The app shell and composer remain visible around the daily detail by design; the concept image represented only the content surface.

final result: pass
