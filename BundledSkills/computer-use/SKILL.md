---
name: computer-use
description: Control native macOS applications through WillDeep's separate Computer Use helper. It can inspect Accessibility elements, capture the selected app window, click, right-click, scroll, drag, type, and send keys. Use for native apps, not web pages.
effects: host-control
---

# WillDeep Computer Use

WillDeep ships its own independently restartable **WillDeep Computer Use** helper. It does not depend on a third-party CLI or an external MCP server.

The helper has its own macOS privacy entries:

- **Accessibility** permits reading app controls and invoking supported actions.
- **Screen & System Audio Recording** permits capturing only the chosen app's visible window when the AX tree is insufficient and a pixel fallback is needed.

If the user changes either permission, call `computer_use_restart_helper`. Restarting WillDeep itself is unnecessary.

## Permission boundary

1. First call `computer_use_permissions`.
2. If either needed permission is missing, explain why and wait for the user to approve desktop control.
3. Then call `computer_use_request_permissions` and let macOS show its own prompt.
4. Never type passwords, API keys, one-time codes, recovery codes, or any other secret. Ask the user to take over instead.
5. Truthfully declare any action that sends, deletes, purchases, changes access, or makes a public/external commitment. A click may reuse the current runtime-, turn-, and target-bound control approval; private authentication, payment, credential, or recovery steps still require user takeover, and non-click consequential mutations retain their confirmation boundary.

## Required control loop

Every desktop turn follows this loop:

1. `computer_use_list_apps` when the target app is unknown.
2. Call `computer_use_inspect_app`, or rely on `computer_use_get_app_state` with its default `include_screenshot: false`.
3. Inspect the fresh AX tree and prefer its `ref` in `computer_use_click` or `computer_use_set_value`.
4. Only when the AX tree has no useful target, call `computer_use_get_app_state` with `include_screenshot: true` and use screenshot-relative pixels.
5. Each action returns a fresh AX-only state. Re-evaluate its tree; never reuse an old `ref` or pixel snapshot.
6. Keep the target app in the background for normal AX actions, PID-targeted input, and selected-window capture. Call `computer_use_activate_app` only if that specific app rejects the background operation.

## Tool map

| Need | Tool |
| --- | --- |
| Permission status / prompt / restart | `computer_use_permissions`, `computer_use_request_permissions`, `computer_use_restart_helper` |
| Discover or background-launch an app | `computer_use_list_apps`, `computer_use_launch_app` |
| AX-only semantic inspection | `computer_use_inspect_app`, `computer_use_get_app_state` |
| Explicit selected-window screenshot fallback | `computer_use_get_app_state` with `include_screenshot: true` |
| Foreground compatibility fallback only | `computer_use_activate_app` |
| Normal click / context menu | `computer_use_click`, `computer_use_secondary_action` |
| Scroll / drag | `computer_use_scroll`, `computer_use_drag` |
| Non-sensitive text / keys / AX field value | `computer_use_type_text`, `computer_use_press_key`, `computer_use_set_value` |

## Coordinates

The opt-in screenshot from `computer_use_get_app_state` is cropped to the selected window. Pixel coordinates are relative to that screenshot, including on Retina displays. The helper maps them to native screen points from the same snapshot; arbitrary screen-space coordinates are rejected.

## Limits

- Secure macOS UI such as password prompts, Touch ID, some System Settings panes, and apps that reject synthetic events may not accept automation.
- A window screenshot is a visual verification artifact; it can contain private data. Do not capture other apps or the whole desktop unless the user explicitly requests it.
- Browser work should use the dedicated browser/Chrome tools rather than desktop pixels whenever DOM controls are available.
