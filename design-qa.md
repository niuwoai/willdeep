# Video Studio Design QA

- source visual truth: `docs/design/video-studio/current/01-short-drama-library.png` and `docs/design/video-studio/current/02-short-drama-planning.png`
- implementation screenshot path: Codex in-app browser inline capture of `http://127.0.0.1:5173/` (the CUA surface returns image bytes but does not expose a filesystem screenshot path)
- comparison surface: temporary local `qa-compare.html`, removed after QA so it is not shipped
- viewport: source and implementation each rendered at 1536 × 1092 CSS px, device density 1x, then uniformly scaled to 25% in one 778 px comparison canvas
- source pixels: 1536 × 1092 for both selected references
- implementation pixels: 1536 × 1092 CSS capture for library and planning states
- state: realistic three-project library; planning page after one user message and one generated `short_drama_plan` card

**Findings**

- No actionable P0, P1, or P2 differences remain in the compared library and planning states.
- [P3] The implementation intentionally omits the mockup's account/profile footer and decorative icon column because those are host-owned chrome, while the plugin page keeps only its local navigation and language toggle.
- [P3] The planning transcript is less text-dense than the illustrative source because the QA state contains one real interaction round; additional rounds use the same message layout and scroll region.

**Required Fidelity Surfaces**

- Fonts and typography: uses the macOS system stack, compact 10–13 px metadata, 17–31 px titles, source-like dark optical weight, controlled wrapping and row truncation. The 805 px narrow-window capture also retained readable hierarchy without horizontal clipping.
- Spacing and layout rhythm: persistent 224 px desktop sidebar, white/gray surfaces, compact 7–11 px radii, low elevation, list-row density, recent-work region, planning split view, and responsive single-column fallback align with the source structure.
- Colors and visual tokens: final tokens use neutral macOS whites/grays and black primary actions; semantic planning/production/completed pills remain restrained. No gradients or decorative CSS art remain.
- Image quality and asset fidelity: three original, text-free generated covers were resized without stretching from 1086 × 1448 PNG to 600 × 800 WebP (28–71 KiB). Crops stay readable at project-row size; no placeholders, emoji, inline SVG, or text-glyph icons are used as visible artwork.
- Copy and content: all React interface copy is routed through i18n. The library exposes short-drama titles, search, status filters and continuation; planning preserves multi-round AI context and separates generated card confirmation from persistence.

**Interaction Evidence**

- Opened the library in the Codex in-app browser, switched locale, searched/filtered through automated UI tests, and opened planning from the primary CTA.
- Entered a story idea, generated a structured planning card through the development bridge, and verified that the transcript and card update independently.
- Frontend tests pass 8/8; Ruby short-drama flow passes 6/6; Ruby asynchronous video server flow passes 40/40.
- The clean development bridge produced no bridge-unavailable error state. No console-warning surface was exposed by the selected in-app browser; production build and interaction checks reported no runtime error.

**Full-view Comparison Evidence**

- A single browser-rendered QA canvas placed library source/implementation and planning source/implementation together at the same 1536 × 1092 viewport and 25% scale. This exposed and verified the sidebar width, header hierarchy, filters, recent-work block, project-row density, transcript/card split, button hierarchy, and page-level whitespace.

**Focused Region Comparison Evidence**

- Separate full-resolution in-app browser inspections were used for the 805 px narrow library and planning states because the combined canvas already contained all major desktop regions. No additional crop was required: the relevant controls, type hierarchy, cover crops, status pills, transcript bubbles, provider/model selects, and card actions were directly inspected at readable size.

**Comparison History**

- Pass 1 found [P1] dark cinematic theme/top pipeline versus the approved light macOS sidebar and [P2] sparse desktop empty state. Fix: rebuilt the shell with theme tokens and persistent sidebar; added search, status filters, recent continuation and dense project rows. Post-fix evidence: the combined library comparison shows matching macro hierarchy and above-the-fold density.
- Pass 2 found [P1] one-shot planning textarea versus the source's continuing AI conversation. Fix: added a persistent role-based transcript, contextual multi-round request history, bottom composer, revision flow and separately confirmable structure card. Post-fix evidence: the combined planning comparison shows the transcript/card split populated from a real interaction.
- Pass 3 found [P2] purple primary actions and accent states versus the source's neutral black/gray system. Fix: remapped accent and primary-action tokens to black/gray with a dark-theme contrast pair. No actionable P0/P1/P2 finding remained.

**Implementation Checklist**

- [x] Match the approved sidebar, light surfaces, desktop density, typography hierarchy and primary-action treatment.
- [x] Make search, filters, primary CTA, project continuation, provider/model selection, multi-round planning and card generation interactive.
- [x] Replace temporary cover blocks with real optimized raster assets.
- [x] Verify narrow-window responsiveness, build/tests, Ruby workflows and final runtime ZIP.

**Follow-up Polish**

- Capture a second QA set inside the upgraded WillDeep plugin host after the user installs the compatible host build; host-owned window chrome and real persisted project data cannot be evidenced before that upgrade.

final result: passed

---

# Todo Image Thumbnail Final QA Status

- source visual truth: `/var/folders/np/rjc0y5w52x324x21pv6g33440000gp/T/codex-clipboard-ea145551-70ca-41b9-9985-f19bed5bdcef.png` (915 × 339 PNG)
- implementation evidence: `/tmp/todo-thumbnail-implementation.png` and `/tmp/todo-lightbox-implementation.jpg` (805 × 727 CSS viewport, density 1x)
- normalized combined evidence: `/tmp/todo-thumbnail-qa-comparison.png` (915 × 589 PNG)
- state and interactions: pending real-image thumbnail, saved real-image thumbnail, click-to-open complete image, Escape close/focus return; console errors none
- findings: no actionable P0/P1/P2; the complete required-surface review and comparison history are recorded in “Todo Image Thumbnail and Full Preview Design QA” above

final result: passed

---

# Todo Image Thumbnail and Full Preview Design QA

- source visual truth path: `/var/folders/np/rjc0y5w52x324x21pv6g33440000gp/T/codex-clipboard-ea145551-70ca-41b9-9985-f19bed5bdcef.png`
- implementation screenshot paths: `/tmp/todo-thumbnail-implementation.png` and `/tmp/todo-lightbox-implementation.jpg`
- combined comparison path: `/tmp/todo-thumbnail-qa-comparison.png`
- viewport: Codex in-app browser, 805 × 727 CSS px, density 1x
- source pixels: 915 × 339 RGBA PNG
- implementation pixels: 805 × 727 JPEG; focused composer crop 805 × 220, proportionally normalized to 915 × 250 before vertical comparison
- combined comparison pixels: 915 × 589 RGBA PNG
- state: Chinese locale; the supplied PNG path pasted into an empty quick composer, then saved as the attachment of `图片缩略图回归`; pending thumbnail, persisted thumbnail, full viewer and Escape close all exercised

**Findings**

- No actionable P0, P1, or P2 differences remain in the requested thumbnail and full-preview surfaces.
- [P3] The filename is intentionally truncated inside the 270 px attachment card; the full name remains available to accessibility, tooltip and viewer caption. This keeps a long clipboard filename from widening the composer.

**Required Fidelity Surfaces**

- Fonts and typography: the existing macOS system/PingFang stack, weights and composer hierarchy remain unchanged. Thumbnail filenames use the existing secondary text size and a single-line ellipsis; the viewer caption stays readable at the full panel width.
- Spacing and layout rhythm: the thumbnail occupies 72 × 50 px inside a 58 px-high attachment card. It sits below the input with the existing 10 px composer gap and does not alter the 36 px filter-control contract or collide with the “记下” button.
- Colors and visual tokens: card, border, loading state and viewer chrome reuse `--page`, `--fg`, `--muted`, `--surface-strong` and `--border`; the only fixed dark tone is the full-image canvas/backdrop, used to preserve contrast around arbitrary screenshots.
- Image quality and asset fidelity: both thumbnail and full viewer use the exact user-supplied raster image. Thumbnail cropping uses `object-fit: cover`; the viewer uses `object-fit: contain`, so the complete image is visible without stretching. No placeholder image, CSS drawing or invented asset replaces it.
- Copy and content: all new visible labels are paired in Chinese and English dictionaries: view full image, close preview and image preview. The filename is dynamic attachment metadata, not hard-coded UI copy.
- Icons and accessibility: removal and viewer close actions use the existing bundled Heroicons `x-mark`; the preview is a semantic button, the full viewer is an `aria-modal` dialog, focus moves to close and returns to the originating thumbnail, and reduced-motion disables the loading animation.
- Responsiveness: the desktop card caps at 270 px; below 500 px it uses the available width with a 64 px thumbnail. The viewer caps at 94vw/92vh and preserves the entire image aspect ratio.

**Interaction Evidence**

- Pasting the supplied absolute PNG path left the text field empty and rendered a real thumbnail button labeled `查看完整图片: codex-clipboard-ea145551-70ca-41b9-9985-f19bed5bdcef.png`.
- Clicking the pending thumbnail opened a dialog containing the complete screenshot; Escape closed it and restored focus to the thumbnail.
- Saving `图片缩略图回归` increased the isolated list from 12 to 13 items. The persisted 44 KB attachment rendered as a thumbnail and opened the same full-image dialog after lazy loading.
- Browser console warnings/errors: none after the final reload and interactions.

**Full-view Comparison Evidence**

- The implementation screenshot verifies that the thumbnail remains contained within the existing composer and leaves the filter row and list layout untouched. The supplied screenshot and final implementation were both opened during this pass.

**Focused Region Comparison Evidence**

- `/tmp/todo-thumbnail-qa-comparison.png` places the source composer and the implementation composer in one normalized vertical canvas. It makes the requested change explicit: the source filename-only attachment row becomes a compact real-image preview without changing the title/input hierarchy.
- `/tmp/todo-lightbox-implementation.jpg` verifies the separate full-image state: centered panel, filename caption, close affordance, dark backdrop and complete uncropped screenshot.

**Comparison History**

- Pass 1 found [P0] the refreshed preview stuck on its skeleton because the new inline strict-mode script used `arguments` as a function parameter. Fix: renamed the parameter to `options` and added a regression that compiles every inline script block. Post-fix evidence: the page loaded all 12 fixture todos, accepted the supplied image path and completed both pending and persisted preview flows.
- Pass 2 compared the normalized focused source/implementation canvas and the full viewer. No actionable P0/P1/P2 visual or interaction finding remained.

**Implementation Checklist**

- [x] Render a real thumbnail immediately for pasted image files and after secure loading for pasted paths.
- [x] Keep the thumbnail after the attachment is persisted.
- [x] Open the complete image without crop or stretch.
- [x] Close via button, backdrop or Escape and restore focus.
- [x] Preserve non-image attachments as file chips.
- [x] Restrict persisted preview reads to the Todo attachment root and matching ids.

**Follow-up Polish**

- None required for the requested surfaces.

final result: passed

---

# Todo Clipboard Attachment and Filter Row Design QA

- source visual truth path: `/var/folders/np/rjc0y5w52x324x21pv6g33440000gp/T/codex-clipboard-dc1b5286-3dd2-4419-bcf7-cc47ef0d2e70.png`
- implementation screenshot path: Codex in-app browser inline capture of `http://127.0.0.1:38765/` (the CUA surface returns image bytes but does not expose a filesystem screenshot path)
- viewport: implementation checked at 1400 × 700 CSS px and the default 805 px wide viewport; density 1x
- source pixels: 2202 × 571 (display comparison normalized by the client to 2048 × 531)
- implementation pixels: 1400 × 700 browser capture; the focused filter row occupies one line at the wide viewport
- state: Chinese locale, open todos, all projects, five inline labels, closed “更多标签”; a second interaction state pasted the user-provided PNG path and created `最终截图附件验证`

**Findings**

- No actionable P0, P1, or P2 differences remain in the requested surfaces.
- [P3] The isolated preview contains five inline label chips rather than the source screenshot's single `responses 1` chip because it uses deterministic fixture data; this does not change control sizing or alignment.

**Required Fidelity Surfaces**

- Fonts and typography: controls inherit the same 15 px macOS system/PingFang stack; project, status, inline tags and “更多标签” use the same optical size and vertical centering.
- Spacing and layout rhythm: all four filter control groups measured exactly 36 px high with the same `top: 169.7890625` and `bottom: 205.7890625` in the 1400 px viewport. Their 10 px parent gap and 8 px radii remain consistent with the source.
- Colors and visual tokens: existing host foreground, page, border and accent variables remain unchanged; the fix adds no hard-coded theme surface.
- Image quality and asset fidelity: the attachment chip uses the bundled Heroicons outline paper-clip asset at 14 × 14 px. The pasted 2202 × 571 PNG was copied byte-for-byte into the isolated Todo attachment store and remained intact at its source path.
- Copy and content: existing Chinese/English attachment labels are reused; no new user-facing hard-coded copy was introduced. Ordinary text containing `screenshot.png` remained text and produced zero pending attachments.

**Interaction Evidence**

- Pasted the user-provided absolute PNG path into the empty quick input. The input stayed empty and a pending attachment chip named `codex-clipboard-dc1b5286-3dd2-4419-bcf7-cc47ef0d2e70.png` appeared.
- Entered `最终截图附件验证` and activated “记下”. The list count changed from 12 to 13 and the new todo rendered the image as a 163 KB attachment with a remove action.
- Pasted ordinary text `finish screenshot.png tomorrow`; it remained visible in the input and the pending attachment count stayed zero.
- Browser console warnings/errors: none.

**Full-view Comparison Evidence**

- The user source and the wide implementation capture were both opened in this QA pass. The requested main title, quick composer, filter order and count placement retain the same hierarchy; the implementation's fixture list begins below the same filter/count region.

**Focused Region Comparison Evidence**

- Browser geometry was read directly for every child of `#filters`. Both `select` elements, `.tag-inline`, and `.tag-filter` reported identical 36 px heights and identical top/bottom coordinates, resolving the red-box mismatch.
- The pending and persisted attachment states were inspected through both the rendered screen and accessibility tree, including filename and removal affordance.

**Comparison History**

- Pass 1: source showed unequal filter heights and an image path pasted as title text. Fix: enforced a shared 36 px/34 px filter control contract and routed clipboard image files/file URLs/absolute paths into a pending attachment queue. Post-fix evidence: exact shared geometry plus end-to-end creation of a todo carrying the pasted PNG.

**Implementation Checklist**

- [x] Intercept clipboard image files without inserting path text.
- [x] Support macOS clipboard providers that expose only a local image URL/path.
- [x] Show removable pending attachment feedback before creating the todo.
- [x] Persist the pasted image and retain the original source file.
- [x] Keep ordinary text paste behavior unchanged.
- [x] Align all filter controls to one measured height.

**Follow-up Polish**

- None required for the requested surfaces.

final result: passed

---

# Todo Image Thumbnail Latest Verification

- source visual truth: `/var/folders/np/rjc0y5w52x324x21pv6g33440000gp/T/codex-clipboard-ea145551-70ca-41b9-9985-f19bed5bdcef.png` (915 × 339 PNG)
- implementation evidence: `/tmp/todo-thumbnail-implementation.png` and `/tmp/todo-lightbox-implementation.jpg` (805 × 727 CSS viewport, density 1x)
- normalized combined evidence: `/tmp/todo-thumbnail-qa-comparison.png` (915 × 589 PNG)
- state and interactions: pending thumbnail, saved thumbnail, complete-image viewer and Escape focus return all passed; browser console errors none
- findings: no actionable P0/P1/P2; full fidelity-surface review and comparison history are recorded in “Todo Image Thumbnail and Full Preview Design QA” above

final result: passed
