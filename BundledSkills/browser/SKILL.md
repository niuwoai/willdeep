---
name: browser
description: Automate websites with WillDeep's built-in Chrome Relay or Embedded Browser, and use a configured browser MCP server for structured QA. Use for navigation, page reading, form filling, clicking, screenshots, console or network inspection, and authenticated browser work.
effects: host-control
---

# Browser Automation

Choose the browser surface from the user's actual need:

- Use `chrome_*` tools for the user's existing Chrome tabs, cookies, and signed-in state.
- Use `embedded_browser_*` tools for an isolated in-app browser. If those tools are unavailable, ask the user to activate the Browser Ops expert, then call `activate_expert` after they agree.
- Use `list_mcp_servers`, `list_mcp_tools`, and `call_mcp_tool` when a configured browser MCP server such as Playwright is better for repeatable QA.
- Use `web_search` and `web_fetch` for read-only research that does not need interaction or authentication.

## Workflow

1. Read status or list tabs before changing browser state.
2. Navigate only after the target URL is clear.
3. Take a fresh DOM snapshot before each click, type, select, or key action.
4. Use the fresh element reference returned by that snapshot. Never reuse a reference after navigation or a major DOM update.
5. Read the resulting page or take another snapshot to verify the action.
6. Capture screenshots only when the user requests them or visual verification is necessary. Pure capture tools run as read-only operations without a WillDeep confirmation card.
7. Use `visual_qa_screenshot` only when external visual analysis is appropriate; it remains approval-gated when image bytes may be sent to a configured provider.

## Safety

- Never read, type, or expose passwords, API keys, one-time codes, cookies, or hidden form values.
- Confirm the exact scope immediately before purchases, publishing, sending messages, deleting data, or other consequential actions.
- Do not install a browser CLI or add a project dependency merely to complete ordinary browser automation.
- If no suitable browser surface is configured, report the missing capability and use `search_mcp_servers` or `suggest_mcp_server`; do not invent tool names.
