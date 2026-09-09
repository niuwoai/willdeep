---
name: design-to-code
description: Implement a selected screenshot, mockup, Figma frame, generated design, or other visual reference as a faithful, responsive, interactive web frontend. Use when the user asks to turn a visible design into code, recreate or clone a UI from an image, reproduce a mockup in React/HTML/CSS, or says design to code, screenshot to code, 截图转代码, 照着实现, 还原页面, or 复刻界面. Require an identifiable visual target before editing. Prefer the existing project stack; for a new web frontend prefer React and TypeScript. Route native SwiftUI targets to figma-swiftui instead.
effects: read-only
---

# Design to Code

Recreate the selected visual target as working frontend code, then verify the rendered result against the source.

## Start gate

1. Resolve the exact screenshot, mockup, Figma frame, generated image, or reference file to implement.
2. If no visual target is available, stop before editing and ask for one concise attachment or link.
3. If the destination is native SwiftUI, load `figma-swiftui` instead.
4. Read `references/implementation-workflow.md` with `read_skill` before changing code.
5. Read `references/design-qa.md` before handoff.

## Core rules

- Inspect the existing repository, components, tokens, fonts, assets, routes, and i18n conventions first.
- Preserve the current framework and component system. For a new web frontend, prefer React + TypeScript and keep user-visible copy in i18n resources.
- Treat the source visual as truth. Do not invent a new palette, layout, typography system, icon style, or art direction while claiming faithful reproduction.
- Use real supplied assets. When an asset is missing, use `generate_image` only when appropriate and disclose the substitution; never replace visible artwork or logos with emoji, CSS drawings, placeholder boxes, or improvised inline SVG.
- Implement the core interactions visible in the target, including relevant hover, focus, selected, open, loading, empty, and success states.
- Use configured Figma MCP tools only after discovering them with `list_mcp_servers` and `list_mcp_tools`; never assume a Figma server or write capability exists.
- Run the project's normal build and tests. Render the implementation in the in-app browser when available, capture it, compare it with the source at the same viewport and state, and fix material mismatches.
- Do not claim completion when the source or rendered implementation could not be visually compared. Record the blocker in `design-qa.md`.
