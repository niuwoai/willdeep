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

final result: passed

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

final result: passed

---

## Token 活动填宽、分享图加载态与预览焦点（1.272.0-rc11）

- source visual truth paths:
  - `/Users/rocky/Sites/Xedit/artifacts/design-qa/token-heatmap-1.272.0-rc11/reference.png`
  - `/var/folders/np/rjc0y5w52x324x21pv6g33440000gp/T/codex-clipboard-3b67a02d-609e-455e-bb49-f9b59d6afe7d.png`
  - `/var/folders/np/rjc0y5w52x324x21pv6g33440000gp/T/codex-clipboard-3ff6542e-0e93-434b-a691-db203506a31b.png`
- implementation screenshot paths:
  - `/Users/rocky/Sites/Xedit/artifacts/design-qa/token-heatmap-1.272.0-rc11/implementation.png`
  - `/Users/rocky/Sites/Xedit/artifacts/design-qa/token-heatmap-1.272.0-rc11/reference-vs-implementation.png`
  - `/Users/rocky/Sites/Xedit/artifacts/design-qa/token-heatmap-1.272.0-rc11/share-loading.png`
- viewport: production statistics dashboard `608 × 740 pt` at `@2x`; focused heatmap comparison normalized to `700 px` width; loading control captured at `300 × 96 px`.
- source sizes: focused heatmap `700 × 208 px`; implementation heatmap `700 × 298 px`; side-by-side comparison `1400 × 298 px`.
- state: populated light-mode statistics overview, up to 32 visible weeks with 8 month labels, active share-image generation, and share-preview close action.

### Full-view comparison evidence

- The production dashboard render preserves the existing title, range switcher, summary metrics, insight hierarchy, and surrounding content while extending only the activity visualization.
- At the common 568 pt content width, the heatmap fills the available row from its first column to its last column with 32 recent weeks instead of leaving an empty right-hand region.
- Narrow content widths reduce the number of visible weeks before reducing legibility, so the grid remains inside the same content boundaries without horizontal scrolling.

### Focused comparison evidence

- Heatmap geometry: pass; cells resolve within the 12–14 pt target and distribute the remaining width as inter-column spacing, keeping the first and last columns aligned to the content edges.
- Month coverage: pass; the focused implementation shows eight labels covering the recent 32-week window while preserving chronological order.
- Share generation feedback: pass; the initiating button stays visible and changes to a spinner plus localized “生成中…” label until the rendered image payload exists.
- Sheet presentation: pass; the preview sheet is driven by a completed image payload and therefore no longer presents an empty white surface during rendering.
- Keyboard focus: pass; the top-right close button remains clickable but is explicitly excluded from the focus chain, preventing the default blue focus ring seen in the source report.

### Findings

- No open P0/P1/P2 visual defects after the second pass.
- The implementation heatmap capture is taller than the cropped source because it includes the complete section rhythm and eight month labels; width was normalized for the alignment judgment.

### Required fidelity surfaces

- Fonts and typography: pass; existing dashboard text styles and weights are unchanged.
- Spacing and layout rhythm: pass; grid boundaries align with the section header and range controls, and the longer month range does not crowd adjacent sections.
- Colors and visual tokens: pass; activity intensity continues to use the established neutral-to-blue scale and the loading state uses the existing secondary button treatment.
- Image quality and asset fidelity: pass; comparison and loading evidence are captured directly from production SwiftUI components at Retina density.
- Copy and content: pass; the loading label is sourced from all five localization resources and the close-button behavior changes no visible copy.

### Comparison history

- Pass 1: the source crop exposed a fixed 26-week grid anchored to the left with unused space on the right.
- Fix: introduced width-derived cell metrics, expanded the recent window to 32 weeks/eight labels, and reduced visible weeks only when the available width requires it.
- Pass 2: the share flow exposed a blank-sheet interval and a blue focus ring on “关闭”.
- Fix: delayed item-based sheet presentation until rendering completes, added inline generation progress, and marked the close action non-focusable.
- Verification: 27 targeted statistics-dashboard and visual-metrics tests passed, including common-width edge alignment, narrow-width reduction, loading-state rendering, and close-button focus policy.

final result: passed
