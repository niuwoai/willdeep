# SwiftUI → Figma

## 1. Confirm write capability

1. Inspect the SwiftUI views, shared components, assets, themes, localization, and supported states.
2. Call `list_mcp_servers` and `list_mcp_tools` for the configured Figma server.
3. Continue only if a writable Figma tool is available, such as `use_figma` or an equivalent node-creation/update tool.

If only read tools exist, do not claim the Figma file was changed. Offer a structured design specification instead and explain that a writable Figma integration is required for mutation.

## 2. Inspect before writing

1. Read the target file/page structure, variables, styles, components, naming conventions, and layout modes.
2. Reuse compatible variables and components.
3. Decide whether the request is a screen, a reusable component family, or a token/library update.
4. Preserve native SwiftUI semantics in the design model: navigation, lists, forms, tabs, sheets, controls, accessibility states, and dark mode should remain recognizable.

## 3. Write in bounded batches

1. Create or update variables before nodes that bind to them.
2. Create the page/frame hierarchy and auto-layout structure before decorative detail.
3. Load the required font before writing text when the Figma tool requires it.
4. Use verified SF Symbol names and the Figma tool's symbol-name conversion capability; never hand-code glyph values.
5. Return and retain created or modified node IDs after every tool call so later calls can safely continue.
6. Keep batches small enough to inspect and retry without duplicating the full screen.

## 4. Verify

1. Re-read the changed nodes and capture a screenshot if supported.
2. Compare content, hierarchy, layout, variants, semantic colors, typography, and component reuse against the SwiftUI source.
3. Report the Figma file/page and changed node IDs, plus any source behavior that cannot be represented statically.
