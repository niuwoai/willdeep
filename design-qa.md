# Computer Use Preview Design QA

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
