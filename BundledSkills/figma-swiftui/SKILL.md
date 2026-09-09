---
name: figma-swiftui
description: Translate between Figma designs and SwiftUI code for iOS, iPadOS, and macOS projects. Use when the user asks to implement, reproduce, convert, or synchronize a Figma design in Swift/SwiftUI, or to push SwiftUI screens, components, or design tokens back into Figma. Trigger when a Figma URL or Figma design is paired with Swift, SwiftUI, iOS, iPhone, iPad, macOS, .swift files, or an Xcode project. Use configured Figma MCP tools when available; otherwise fall back safely to attached screenshots and local code without inventing inaccessible design details.
effects: outbound-query
---

# Figma ↔ SwiftUI

Translate in either direction while preserving native platform behavior.

## Choose the direction

- Figma design to SwiftUI code: call `read_skill` with `name: figma-swiftui` and `resource: references/design-to-code.md`.
- SwiftUI code to a Figma design: call `read_skill` with `name: figma-swiftui` and `resource: references/code-to-design.md`.
- If both directions are plausible and the user did not state an action, ask one concise clarification question.

## Shared rules

1. Inspect the current project before choosing architecture, deployment target, tokens, or component names.
2. Discover configured Figma capabilities with `list_mcp_servers` and `list_mcp_tools`. Call the exact discovered tool through `call_mcp_tool`; never assume a server or tool exists.
3. Treat screenshots as visual evidence and Figma context as structural evidence. Do not translate web-oriented sample code literally into SwiftUI.
4. Prefer native controls and semantic platform colors. Use `NavigationStack`, `List`, `Form`, `TabView`, toolbars, sheets, pickers, toggles, and SF Symbols when the design represents those system patterns.
5. Preserve project conventions and existing design tokens before introducing new abstractions.
6. Do not expose Figma credentials, session data, private file contents, or inaccessible node data.
7. If Figma access is unavailable, say what evidence is missing. Design-to-code may continue from an attached/exported screenshot with explicit limitations; code-to-design must stop before claiming a Figma mutation.
8. Verify code changes with the project's normal Xcode build/tests and visually compare the result when screenshot tooling is available.

Figma API/MCP usage remains subject to Figma's developer terms and the user's configured account permissions.
