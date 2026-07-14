# Terminal Recording Toolbar Design QA

- selected visual direction: option 2, `/Users/rocky/.codex/generated_images/019f61dd-70dd-7610-a9f0-b0b2f8ebfde4/exec-fcaaab9a-a1ee-4a1f-a990-532a7c2842a0.png`
- implementation screenshot: `build/visual-qa/terminal-recording/implementation-rc7.png`
- viewport: source `2084 x 754`; implementation `1246 x 768`, terminal side panel approximately `480 pt` wide
- state: light app appearance, dark terminal scheme, two persisted recordings, inactive recording and playback
- final result: passed

**Full-View Comparison Evidence**

The selected option and the live Debug build were inspected together in one comparison pass. The implementation preserves the selected two-layer hierarchy: a dark recording-control strip followed by a light, flat recent-recordings list. The terminal tabs and terminal content remain visually separate below it, so the recording area no longer reads as a capsule inside another capsule.

**Focused Region Comparison Evidence**

- The record control uses a red semantic icon while its label uses a high-contrast terminal foreground color; the helper text remains readable but subordinate.
- “最近录制” is a stable section label rather than part of a recording chip.
- Each recording is one flat row with a circular play control, name, localized duration, input count, optional protected-input indicator, and trailing menu.
- Two rows fit without increasing the panel beyond the selected compact direction; additional rows use the bounded vertical scroller.
- The live `480 pt` side panel selects the wide single-line row variant. A narrower width falls back to the two-line metadata variant through `ViewThatFits`.

**Required Fidelity Surfaces**

- Fonts and typography: native macOS system typography is retained; hierarchy comes from weight and semantic foreground colors rather than red/green body text.
- Spacing and layout rhythm: the control row, section header, and two `42 pt` history rows form three distinct bands with single-pixel separators.
- Colors and visual tokens: red is limited to recording affordance; green/orange remain limited to small status icons. Terminal-scheme foreground colors prevent black-on-black labels.
- Image quality and asset fidelity: all controls use native SF Symbols and remain sharp at the captured scale; no bitmap placeholder is used in the implementation.
- Copy and content: start/stop labels, helper copy, section label, duration, input-count metadata, menus, and accessibility descriptions all use localized resources.

**Primary Interactions Checked**

- Open the terminal panel with two persisted recordings: passed in the ad-hoc-signed Debug build.
- Recording rows expose play controls and trailing action menus: passed through the live accessibility tree.
- Protected-input recording exposes its security indicator without turning the entire row into a status pill: passed.
- Narrow-width fallback is present in implementation and compiled; the live screenshot covers the standard side-panel width.

**Findings**

No open P0, P1, or P2 visual findings. The production Swift sources and string catalog compile successfully. The selected terminal tests also compile, but the local XCTest runner cannot launch because two installed Apple Development identities make the repository's signing phase ambiguous; this does not affect the live Debug visual result.

**Comparison History**

- Iteration 1: the previous production UI used dark text on a dark surface, colored whole labels red/green, and nested recording capsules.
- Iteration 2: option 2 established the two-layer structure and flat list-row language.
- Iteration 3: the live Debug build confirmed readable contrast, Chinese duration localization, two visible rows, native menus, and removal of nested cards. Final result passed.

---

# Assistant Status Divider Design QA

- source visual truth: `/var/folders/np/rjc0y5w52x324x21pv6g33440000gp/T/codex-clipboard-ae1c8da7-65a7-484e-b03b-44dc425db09b.png`
- implementation screenshot: `/tmp/willdeep-assistant-divider-rc6.png`
- combined comparison: `/tmp/willdeep-assistant-divider-comparison-rc6.png`
- viewport: source `797 x 102 @1x`; implementation `797 x 106 pt @2x`
- state: light appearance, completed assistant turn, 14 pt base font
- final result: passed

**Full-View Comparison Evidence**

The Codex reference and the actual WillDeep TextKit rendering were normalized to the same 797-point width and stacked in one comparison image. The status, divider, and first body line retain the same hierarchy and low-contrast rhythm. The implementation screenshot comes from `AgentChatHistoryNSTextView`, not a redrawn mock.

**Focused Region Comparison Evidence**

- Reference divider center: source row `43`; sampled center color `RGB(240, 240, 240)` / `#F0F0F0`.
- Implementation divider: physical rows `54-55` at `@2x`; sampled color on both rows `RGB(240, 240, 240)` / `#F0F0F0`.
- Reference status-ink bottom to divider center: `13 px`; implementation: `12.75 pt` after SF-font ink calibration.
- Reference divider center to body-ink top: `21 px`; implementation: `21.25 pt`. The remaining quarter-point is raster antialiasing, not a layout-token mismatch.
- Shared layout tokens are `9 pt` above, `18 pt` below, and `1 pt` line thickness; the same values drive SwiftUI streaming and TextKit history rendering.

**Required Fidelity Surfaces**

- Fonts and typography: existing 14 pt medium-weight SF status and 14 pt body typography are preserved; this change does not alter font, wrapping, or line height.
- Spacing and layout rhythm: measured visible-ink distances match the source within `0.25 pt`; horizontal alignment follows the existing assistant content column.
- Colors and visual tokens: the neutral overlay is calibrated to render exactly `#F0F0F0` on the white reference surface and reverses to a light neutral overlay in dark appearance.
- Image quality and asset fidelity: no image asset is part of this component; the source screenshot and actual native rendering were compared without placeholder reconstruction.
- Copy and content: the localized “处理中 / 已处理 Ns” behavior is unchanged; the QA state uses the same completed-duration meaning as the source.

**Findings**

No open P0, P1, or P2 visual findings. The implementation matches the requested line color exactly and matches the requested vertical distances within native text-rasterization tolerance.

**Comparison History**

- Iteration 1: the shared semantic label overlay rendered as `#F3F3F3`, and the 10 pt top token put the line about `0.75 pt` too far from the visible SF glyph edge.
- Fix: changed the neutral overlay to `7.5%` so AppKit / SwiftUI compositing resolves to `#F0F0F0`, and calibrated the top token to `9 pt`; the bottom token remains `18 pt`.
- Iteration 2: the combined reference/implementation image and direct pixel sampling confirmed exact line color, `12.75 pt` upper visible distance, and `21.25 pt` lower visible distance. Final result passed.

---

# Previous QA Record: Computer Use Preview

- source visual truth: `/Users/rocky/Desktop/截屏2026-07-13 11.38.55.png`
- implementation thumbnail: `build/visual-qa/computer-use/implementation-thumbnail.jpeg`
- implementation overlay: `build/visual-qa/computer-use/implementation-overlay-final.jpeg`
- combined comparison: `build/visual-qa/computer-use/comparison-overlay-final.png`
- viewport: source `2880 x 1800`; implementation `1155 x 768`
- final result: passed

**Full-View Comparison Evidence**

The reference and final implementation overlay were combined into one side-by-side image and inspected together. The compact preview stays at the Agent chat area's upper-right edge, uses the source screenshot rather than a placeholder, and preserves the full image aspect ratio. The expanded state dims the complete Agent window, keeps the screenshot centered with stable margins, and leaves a visible circular close control at the upper-right.

**Focused Region Comparison Evidence**

The upper-right thumbnail was checked in the live Debug app at `176 x 108` points. Its six-point radius, one-point border, restrained shadow, and 18-point outer inset follow the existing WillDeep surface language while retaining the Codex reference's compact placement. The expanded screenshot uses aspect-fit and remains fully visible without stretching or clipping.

**Findings**

No open P0, P1, or P2 visual findings.

**Primary Interactions Tested**

- Latest Computer Use screenshot appears only while the active turn is responding: passed by implementation and focused unit coverage.
- Thumbnail opens the full-window overlay: passed with live Computer Use control.
- Circular X closes and returns to the chat: passed with coordinate click.
- Escape closes and returns to the thumbnail: passed after focus handling was added.
- Clicking the dimmed backdrop closes the overlay: passed with coordinate click.

**Comparison History**

- Iteration 1: the unsigned Debug build could not use the signed app's Keychain session, so the real provider turn could not produce a screenshot.
- Iteration 2: a deterministic Debug-only fixture rendered the thumbnail and overlay; visual inspection found that Escape did not close because focus stayed in the composer.
- Iteration 3: overlay focus and aspect-fit were added; Escape passed, but the side-by-side comparison showed the dimmer covered only the chat column.
- Iteration 4: the presentation layer moved to the complete Agent window while retaining a chat-relative thumbnail inset. Full-window dimming, X, Escape, and backdrop close all passed. The fixture was then removed from production source.
