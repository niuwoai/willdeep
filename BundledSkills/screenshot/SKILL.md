---
name: screenshot
description: Capture a Mac display, Android device, iOS Simulator, Chrome tab, Embedded Browser page, or native app window with WillDeep's screenshot tools. Use for user-requested captures and visual verification after UI changes.
effects: host-control
---

# Screenshots

Choose the narrowest capture surface:

- Whole Mac display, Android device, or iOS Simulator: `capture_screenshot`
- Native macOS app window plus Accessibility state: `computer_use_get_app_state`
- Chrome tab: `chrome_capture_tab`
- Embedded Browser page: `embedded_browser_capture_screenshot`

## Workflow

1. Confirm the intended surface and display or device when ambiguous.
2. Use the appropriate status or discovery tool first.
3. Capture directly as a read-only tool call. On the first Mac capture, macOS may still show its “Screen & System Audio Recording” permission prompt. That system category does not mean WillDeep requested microphone access; microphone permission is separate.
4. Successful platform captures are persisted under `~/.willdeep/captures/<capture-id>/` and surfaced as a clickable image in the final assistant message. Use the full-resolution path from the tool payload when later local analysis needs the original pixels.
5. Use the image attached to the tool result for immediate inspection.
6. Call `visual_qa_screenshot` only when the user asks for UI, color, layout, theme, or accessibility review.
7. Return the saved image with an absolute Markdown image link when the user asks to see or keep it.

Screenshots may contain private information. Capture the smallest useful area and avoid unrelated displays or apps. Pure capture does not need a WillDeep confirmation card; uploading pixels to an external provider remains separately approval-gated.
