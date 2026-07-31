---
name: reactions
description: Add an emoji reaction through a messaging MCP server configured in WillDeep, or through the built-in Lark CLI for Feishu when available. Use only when the target platform, conversation, message, and reaction are known.
---

# Message Reactions

## Workflow

1. Identify the platform, conversation or channel, message identifier, and emoji.
2. For Feishu, use `lark_cli` only after confirming the relevant reaction operation and arguments.
3. For Discord, Telegram, or another platform, call `list_mcp_servers`, then `list_mcp_tools`, and invoke the exact reaction tool through `call_mcp_tool`.
4. Verify the returned message or reaction state.

If the integration is missing, use `search_mcp_servers` or `suggest_mcp_server`. Do not call undocumented localhost endpoints or invent platform commands.

Do not react to every message. Avoid reactions that could be interpreted as approval for legal, financial, security, or other consequential decisions.
