---
name: self-management
description: Inspect or change WillDeep preferences, models, integrations, permissions, updates, and current session settings through supported WillDeep tools and the app's Settings UI. Use when the user asks to configure WillDeep itself.
---

# WillDeep Settings

Prefer dedicated tools over direct file edits.

## Workflow

1. Identify the exact setting and whether the user wants inspection or modification.
2. For Computer Use permissions, call `computer_use_permissions`; request or restart the helper only after user approval.
3. For current-session naming, use `suggest_session_title` and `rename_session`.
4. For MCP integrations, use `list_mcp_servers`, `search_mcp_servers`, `suggest_mcp_server`, or `configure_mcp_server`.
5. For other WillDeep preferences, use Computer Use to open WillDeep Settings, inspect the current value, then change only the requested control.
6. Re-read the UI state to verify the change.

Never edit undocumented preference files, UserDefaults databases, Keychain entries, or app bundle contents. Never type secrets through Computer Use; let the user enter credentials into the dedicated Settings field. Do not change a chat model to an image or video model.
