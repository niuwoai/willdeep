---
name: music-gen
description: Generate music only through a music-generation MCP server explicitly configured in WillDeep. Use for songs, instrumentals, lyrics-to-music, or vocal generation after discovering the exact provider tools; otherwise report the missing capability and suggest an integration.
effects: side-effects
---

# Music Generation

WillDeep does not expose a built-in music-generation tool. Do not pretend that a local command or provider exists.

## Workflow

1. Clarify genre, mood, duration, vocals, language, lyrics, and intended use.
2. Call `list_mcp_servers`.
3. If a music provider is configured, call `list_mcp_tools`, select the exact generation tool, and use it through `call_mcp_tool`.
4. Treat every generation as potentially billable. Submit only after the request and parameters are clear.
5. On timeout or provider failure, report it and ask before retrying.
6. Return completed audio with a local Markdown file link or the provider result supported by WillDeep.

If no provider exists, use `search_mcp_servers` and `suggest_mcp_server`. You may still help draft lyrics, structure, chords, or a production brief without claiming an audio file was generated.
