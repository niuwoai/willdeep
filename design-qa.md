# Design QA

## 结构化长提问卡片（1.288.0-rc1）

- source visual truth path: `/Users/rocky/Sites/Xedit/artifacts/design-qa/ask-user-1.288.0-rc1/reference-option-2.png`
- implementation screenshot path: `/Users/rocky/Sites/Xedit/artifacts/design-qa/ask-user-1.288.0-rc1/implementation-narrow.png`
- combined full-view comparison: `/Users/rocky/Sites/Xedit/artifacts/design-qa/ask-user-1.288.0-rc1/comparison-full.png`
- combined focused comparison: `/Users/rocky/Sites/Xedit/artifacts/design-qa/ask-user-1.288.0-rc1/comparison-prompt.png`
- viewport: native SwiftUI component at `520 pt` width, rendered at `2×` as `1040 × 784 px`; source normalized to the same `1040 px` width.
- state: pending `ask_user`, structured title/context/requested information/default assumptions, free-form answer field, skip and send actions.

### Full-view comparison evidence

- The production card preserves the selected composition: icon rail on the left; eyebrow, bold action title, regular context, and two labeled information groups on the right.
- The answer field remains directly below the prompt, followed by the existing divider and submit footer; no extra preset-answer row appears in this state.
- Skip and send retain the selected secondary-outline / primary-black hierarchy and remain fully visible at the narrow target width.
- The implementation keeps WillDeep's existing Rice Paper surface instead of replacing the product theme with the concept image's plain white canvas.

### Focused comparison evidence

- Typography hierarchy passes: the action title is the strongest line, context is regular weight, section labels are semibold, and technical values are quieter body text.
- Spacing passes: the two information groups are visibly separate without turning the prompt into stacked cards or adding new borders.
- Wrapping passes: the Secret placeholder wraps within the content column at `520 pt`; no text is clipped or pushed under the icon.
- Legacy compatibility passes: short unstructured questions keep the original compact single-title treatment; long legacy questions receive a localized fallback title and regular body automatically.

### Findings

- Pass 1: the first fixture still included three preset options, which were absent from the selected reference and made the card materially taller.
- Fix: removed preset options from the reference state while retaining the existing `options` schema and interaction behavior for questions that genuinely need choices.
- Pass 2: the combined full and focused comparisons show matching hierarchy, grouping, action contrast, and responsive wrapping; no open P0/P1/P2 visual defects remain.
- Verification: 17 targeted Swift tests passed, including structured/legacy prompt parsing, wide/narrow component rendering, registry coverage, and the local `#1983#` preview path.

final result: passed

---

## 聊天“滚动到最新消息”火箭放大（1.279.0-rc1）

- source visual truth: 用户选定的 1 号概念图，以及“接近填满整个圆形”的本轮反馈。
- implementation screenshot path: `/Users/rocky/Sites/Xedit/artifacts/design-qa/worktree-recovery-1.279.0-rc1/rocket-off-bottom.jpeg`
- viewport: native macOS window `1359 × 768 px`
- state: 长会话已滚离底部，浮动按钮可见；回到底部后按钮仍由既有滚动策略自动隐藏。

### Full-view comparison evidence

- 按钮仍吸附在聊天区右下方、composer 上方，没有遮挡输入区或会话正文。
- 圆形点击热区保持 `44 pt`，只放大内部火箭，不改变布局占位。
- 实机辅助功能树确认 `agent-chat-scroll-to-latest` 节点仅在离底状态出现。

### Focused comparison evidence

- 原始透明图的空白边被裁去，资源画布由大面积留白改为紧贴火箭主体。
- SwiftUI 图像框由 `30 pt` 提升到 `38 pt`，火箭主体现在接近填满圆形，同时保留少量呼吸边距。
- 蓝紫配色、Q 版造型、白色圆面、描边与阴影均沿用选定概念，没有引入新的视觉语言。

### Findings

- Pass 1: 单纯放大 SwiftUI frame 后，透明资源留白导致实机观感仍偏小。
- Fix: 机械裁切透明边并保留原始透明 PNG 质量，再重新构建。
- Pass 2: Computer Use 在新 Debug 构建中确认火箭显著放大、无裁切，位置和交互状态正确。
- Asset Catalog 重新编译无未分配资源警告；相关 51 项测试全部通过。

final result: passed

---

## 聊天“滚动到最新消息”火箭（1.277.0-rc3）

- source visual truth path: `/Users/rocky/Sites/Xedit/artifacts/design-qa/scroll-to-latest-1.277.0-rc3/reference.png`
- implementation screenshot path: `/Users/rocky/Sites/Xedit/artifacts/design-qa/scroll-to-latest-1.277.0-rc3/implementation-off-bottom.jpeg`
- viewport: native macOS window `1359 × 768 px`; source image `1487 × 1058 px`
- density normalization: compared by floating position, button footprint, contrast, icon character, and relationship to the composer rather than full-window pixel scale.
- state: populated long conversation, transcript manually scrolled above the bottom, then returned to the latest message by clicking the rocket.

### Full-view comparison evidence

- The production button floats at the lower-right edge of the transcript, above the composer and clear of message content, matching the selected concept's placement.
- The control is absent while the transcript is already at the bottom and appears only after the operator scrolls upward.
- Clicking the control returns the transcript scroll bar to `1.0`; the accessibility node is removed immediately afterward.

### Focused comparison evidence

- Geometry: pass; the `44 pt` circular target is compact but comfortably clickable.
- Visual treatment: pass; a near-white circular surface, restrained hairline, and soft shadow preserve the concept's lightweight floating treatment.
- Icon character: pass after replacing a visually missing SF Symbol render with a dedicated blue-violet Q-style rocket asset.
- Motion: pass; the control uses a short scale/fade entrance and a subtle hover enlargement without competing with chat content.
- Accessibility and localization: pass; the control exposes `agent-chat-scroll-to-latest` and localized help/label resources for five supported languages.

### Findings

- No open P0/P1/P2 visual defects after the second pass.
- The production button uses a dedicated transparent PNG rocket asset, preserving the concept's blue-violet mascot direction at native scale.

### Comparison history

- Pass 1: interaction and placement were correct, but the SF Symbol rocket was not visibly rendered in the live app capture.
- Fix: generated and integrated a dedicated transparent Q-style rocket asset, then rebuilt.
- Pass 2: Computer Use confirmed the rocket is visible above the composer, activates successfully, scrolls to `1.0`, and disappears at the bottom.
- Verification: `AgentTranscriptScrollPolicyTests` passed all 21 tests; repository version and contract guards also passed.

final result: passed

---

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

## 原生标题栏会话搜索入口（1.274.0-rc3，随当前 1.274.0-rc4 验证）

- source visual truth path: `/Users/rocky/Sites/Xedit/artifacts/design-qa/header-session-search-1.274.0-rc4/reference.png`
- implementation screenshot paths:
  - `/Users/rocky/Sites/Xedit/artifacts/design-qa/header-session-search-1.274.0-rc4/implementation-default.png`
  - `/Users/rocky/Sites/Xedit/artifacts/design-qa/header-session-search-1.274.0-rc4/implementation-search-open.png`
  - `/Users/rocky/Sites/Xedit/artifacts/design-qa/header-session-search-1.274.0-rc4/implementation-sidebar-hidden.png`
- viewport: native macOS window `1359 × 768 px`; search sheet `520 × 440 px`
- source size: Claude Code reference `1748 × 1274 px`
- density normalization: the reference and implementation were inspected together in one comparison input; comparison scope is the macOS window-control cluster and search-entry placement rather than unrelated application content.
- state: populated light-mode session sidebar, native titlebar controls, search sheet open, and sidebar hidden.

### Full-view comparison evidence

- The native titlebar now preserves the reference ordering: macOS traffic lights, sidebar toggle, then search magnifier.
- The former search row below “新聊天” is absent; “已安排” now immediately follows the primary new-chat action.
- The duplicate magnifier in the chat header is also absent, leaving one stable visible search entry for every Agent destination.

### Focused comparison evidence

- Control geometry: pass; the sidebar and search buttons share a `26 pt` footprint with a `3 pt` inter-button gap and align on the same titlebar baseline.
- Sidebar-visible state: pass; the controls remain visually grouped with the traffic lights and do not consume sidebar menu height.
- Sidebar-hidden state: pass; the chat title begins after the complete native control cluster, with no overlap or clipping.
- Search presentation: pass; clicking the magnifier opens the existing localized search sheet with focus in the search field.
- Keyboard behavior: pass; `⌘⇧P` opens the same search sheet from the native titlebar command.
- Assets and localization: pass; the implementation uses the system `magnifyingglass` SF Symbol and the existing localized `header.search-sessions` string.

### Findings

- No open P0/P1/P2 visual defects in the changed titlebar/sidebar surfaces.
- The production search sheet remains intentionally compact and follows WillDeep’s existing visual system; the Claude Code screenshot is used for entry placement and control ordering, not as a request to clone its full search-results layout.

### Comparison history

- Pass 1: combined reference/implementation review confirmed the requested control order and removal of the sidebar row.
- Interaction pass: Computer Use verified click-to-open, `⌘⇧P`, close behavior, and sidebar hide/show behavior in the freshly built Debug app.
- Verification: 22 targeted tests passed across `AgentConfirmationVisualTests`, `AgentHeaderEditorEntryTests`, and `AgentSessionSearchTests`.

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
