---
name: telegram
description: Operate Telegram through a Telegram MCP server or connector configured in WillDeep. Use for sending messages or media, reading chats, reactions, and group administration only after discovering the exact available tools and confirming consequential actions.
effects: side-effects
---

# Telegram

## Workflow

1. Call `list_mcp_servers` and identify a Telegram-capable integration.
2. Call `list_mcp_tools` for that exact server.
3. Match the request to an exposed Telegram operation.
4. Confirm the target chat, group, channel, or user before writing.
5. Invoke the exact tool with `call_mcp_tool`.
6. Verify the returned chat and message identifiers.

If no Telegram integration exists, use `search_mcp_servers` and optionally `suggest_mcp_server`. Do not call undocumented localhost endpoints or assemble Bot API requests with a token from chat.

Confirm immediately before deleting messages, banning or restricting members, changing admin rights, sending payments, posting to large audiences, or altering group settings. Never expose bot tokens or download URLs containing credentials.
