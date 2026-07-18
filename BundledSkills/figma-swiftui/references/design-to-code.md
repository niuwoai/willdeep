# Figma → SwiftUI

## 1. Gather authoritative inputs

1. Inspect the workspace for the Xcode project, deployment targets, existing views, assets, fonts, localization, and theme tokens.
2. When a Figma URL is present, extract its file and node identifiers.
3. Call `list_mcp_servers`, locate the configured Figma server, and inspect it with `list_mcp_tools`.
4. Prefer a design-context tool that returns node structure, text, component metadata, variables, and a screenshot. Request Swift/SwiftUI-oriented output when the tool supports language/framework hints.
5. If a node points to a page rather than a renderable frame, inspect metadata to find the intended child frame and retry.

If no Figma MCP server is available, use an attached or exported screenshot plus any user-provided measurements. State that exact component metadata, variables, and hidden states could not be verified.

## 2. Map design structure to native SwiftUI

- Repeated full-width rows → `List`; input/settings groups → `Form`.
- Large or inline titles with navigation actions → `NavigationStack` and toolbar placements.
- Repeated bottom destinations → `TabView`.
- Modal composition/editing flows → `.sheet` or `.fullScreenCover`.
- System-looking segmented controls, toggles, sliders, pickers, and buttons → their native SwiftUI controls.
- SF Symbols → `Image(systemName:)` using a verified symbol name. Do not guess private glyph code points.
- Semantic label/background/separator colors → project tokens or platform semantic colors, not copied fallback hex values.

Build navigation and shared state before polishing individual screens when multiple frames form one flow.

## 3. Implement in the repository

1. Reuse existing components when they match the design.
2. Keep state and data flow separate from presentation.
3. Add user-visible text through the project's localization mechanism.
4. Support dark mode, Dynamic Type, accessibility labels, reduced motion, and right-to-left layout where the existing app does.
5. Avoid absolute positioning unless the design is genuinely freeform; prefer stacks, grids, alignment guides, safe-area APIs, and native containers.

## 4. Verify

1. Build or run focused tests with the repository's normal Xcode command.
2. Launch the built app or simulator and use Computer Use (or an approved platform screenshot capture) to capture the actual implemented screen at the source state and viewport. Source inspection alone is not verification.
3. Call `design_to_code_acceptance` with the source image path from the run contract, the fresh rendered screenshot path, and `surface: computer_use` (or the actual platform screenshot surface).
4. When acceptance returns `NEEDS_ITERATION`, inspect the diff, correct material hierarchy, spacing, typography, color, content, and state mismatches, then rebuild and repeat capture plus acceptance.
5. Finish only after acceptance returns `PASS`. Report deliberate native-platform substitutions or inaccessible Figma details without using them to excuse unverified material differences.
