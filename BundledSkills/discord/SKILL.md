---
name: discord
description: Operate Discord through a Discord MCP server or connector configured in WillDeep. Use for sending messages or files, reading channels, reactions, and server moderation only after discovering the exact available tools and confirming consequential actions.
---

# Discord

Use only capabilities that WillDeep can discover at runtime.

## Workflow

1. Call `list_mcp_servers` and identify a Discord-capable server.
2. Call `list_mcp_tools` for that exact server.
3. Match the user's request to an exposed tool and inspect its required arguments.
4. Call the tool through `call_mcp_tool`.
5. Verify the returned channel, message, or action identifier.

If no Discord integration exists, call `search_mcp_servers` and optionally `suggest_mcp_server`. Do not install software, create a bot, or configure credentials unless the user explicitly asks and provides the required configuration.

## Safety

- Never request that a bot token be pasted into chat or a shell command.
- Confirm the target server and channel before sending.
- Confirm immediately before deletes, bans, kicks, role changes, mass mentions, or broad permission changes.
- Do not claim that Discord is connected until `list_mcp_servers` and `list_mcp_tools` prove it.
