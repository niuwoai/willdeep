# Design QA

- source visual truth path: `/Users/rocky/.codex/generated_images/019ffef8-814c-7461-b561-242dc359dc39/exec-63b04b3a-0876-4033-a174-edb3e786b3ef.png`
- implementation screenshot path: unavailable
- viewport: intended native macOS window `1120 × 760 pt`; source image `1536 × 1024 px`
- density normalization: not applicable because the implementation editor window could not be captured
- state: existing protected terminal shortcut, JSON editor with secret drawer

**Full-view comparison evidence**

- The source mock was opened and used as the implementation target.
- The freshly built Debug app was launched and its terminal shortcut list was captured successfully.
- macOS accessibility automation could identify the shortcut action menu, but could not activate its menu item to open the new editor window, so a valid implementation screenshot was not available for comparison.

**Focused region comparison evidence**

- Not performed because the required full editor-window capture was unavailable.

**Findings**

- [P1] Missing rendered editor evidence
  - Location: terminal shortcut editor window.
  - Evidence: source mock is available; implementation window could not be opened through the available accessibility automation.
  - Impact: typography, spacing, color-token fidelity, copy fit, icon alignment, pagination layout, and secure-field density cannot be visually certified.
  - Fix: manually open a shortcut's “编辑” action in the Debug build, capture the `1120 × 760` editor window, and compare it with the source mock.

**Required fidelity surfaces**

- Fonts and typography: blocked pending implementation capture.
- Spacing and layout rhythm: blocked pending implementation capture.
- Colors and visual tokens: blocked pending implementation capture.
- Image quality and asset fidelity: no custom imagery is used; SF Symbols are expected, but visual verification is blocked.
- Copy and content: localized strings compile; visible fit is blocked pending implementation capture.

**Comparison history**

- Pass 1: implementation build and targeted functional test passed; visual comparison blocked because the editor window could not be activated by accessibility automation. No visual fixes were made from this pass.

**Implementation checklist**

- Capture the editor window at `1120 × 760`.
- Compare the whole window and the secret-table/search/pagination region against the source.
- Resolve any P0/P1/P2 visual differences and repeat the comparison.

final result: blocked
