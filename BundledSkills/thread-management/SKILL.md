---
name: thread-management
description: Inspect WillDeep sessions in the current workspace and improve the current session title with supported session tools. Use when the user asks which workspace conversations exist or wants the current conversation renamed.
---

# Session Management

Use the tools WillDeep currently exposes:

- `list_workspace_sessions`: list sessions associated with the current workspace.
- `suggest_session_title`: generate a concise title from the current task.
- `rename_session`: rename the current interactive session after the title is known.

Do not claim direct support for creating, switching, reading full transcripts, deleting, pinning, or archiving arbitrary sessions unless matching tools are present in the active runtime. Do not use `change_workspace` as a substitute for switching conversations.

When renaming, preserve the user's language, avoid secrets in titles, and verify the returned session title.
