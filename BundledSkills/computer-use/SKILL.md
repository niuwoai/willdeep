---
name: computer-use
description: Control native macOS applications through WillDeep's separate Computer Use helper. It can inspect Accessibility elements, capture the selected app window, click, right-click, scroll, drag, type, and send keys. Use for native apps, not web pages.
---

# WillDeep Computer Use

WillDeep ships its own independently restartable **WillDeep Computer Use** helper. It does not depend on a third-party CLI or an external MCP server.

The helper has its own macOS privacy entries:

- **Accessibility** permits reading app controls and invoking supported actions.
- **Screen & System Audio Recording** permits capturing only the chosen app's visible window so the Agent can verify every step.

If the user changes either permission, call `computer_use_restart_helper`. Restarting WillDeep itself is unnecessary.

## Permission boundary

1. First call `computer_use_permissions`.
2. If either needed permission is missing, explain why and wait for the user to approve desktop control.
3. Then call `computer_use_request_permissions` and let macOS show its own prompt.
4. Never type passwords, API keys, one-time codes, recovery codes, or any other secret. Ask the user to take over instead.
5. Treat any action that sends, deletes, purchases, changes access, or makes a public/external commitment as an immediate user-confirmation point.

## Required control loop

Every desktop turn follows this loop:

1. `computer_use_list_apps` when the target app is unknown.
2. `computer_use_get_app_state` with `app` or `pid`.
3. Prefer the returned Accessibility `ref` in `computer_use_click` or `computer_use_set_value`.
4. When the app has no useful AX tree, use screenshot-relative pixels with `computer_use_click`, `computer_use_secondary_action`, or `computer_use_drag`.
5. Each action returns a fresh AX tree and an inline screenshot. Re-evaluate it; never reuse an old `ref`.

## Tool map

| Need | Tool |
| --- | --- |
| Permission status / prompt / restart | `computer_use_permissions`, `computer_use_request_permissions`, `computer_use_restart_helper` |
| Discover or background-launch an app | `computer_use_list_apps`, `computer_use_launch_app` |
| AX tree plus selected-window screenshot | `computer_use_get_app_state` |
| Normal click / context menu | `computer_use_click`, `computer_use_secondary_action` |
| Scroll / drag | `computer_use_scroll`, `computer_use_drag` |
| Non-sensitive text / keys / AX field value | `computer_use_type_text`, `computer_use_press_key`, `computer_use_set_value` |

## Coordinates

The screenshot from `computer_use_get_app_state` is cropped to the selected window. Pixel coordinates are relative to that screenshot, including on Retina displays. The helper maps them to native screen points from the same snapshot.

Pass `coordinate_space: "screen"` only when a tool explicitly needs raw macOS screen coordinates. Otherwise use the default screenshot-relative space.

## Limits

- Secure macOS UI such as password prompts, Touch ID, some System Settings panes, and apps that reject synthetic events may not accept automation.
- A window screenshot is a visual verification artifact; it can contain private data. Do not capture other apps or the whole desktop unless the user explicitly requests it.
- Browser work should use the dedicated browser/Chrome tools rather than desktop pixels whenever DOM controls are available.
