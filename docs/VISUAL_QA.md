# Visual QA Screenshot

> Last updated: 2026-06-23 | Current version: v1.103.0-rc11

WillDeep Agent provides an on-demand `visual_qa_screenshot` tool for UI screenshots and design QA. It is intentionally not automatic on every turn: screenshots may contain private data, and visual-model review may send image bytes to the configured Image Understanding provider.

## When The Agent May Call It

- The user explicitly asks for screenshot, color, theme, layout, accessibility, contrast, or visual regression review.
- A browser automation flow captured a screenshot after user approval and the current task needs visual verification before the final answer.
- The user provided a local image path and asked the agent to inspect it.

The agent should not call it on private screenshots unless the user provided the image or approved the screenshot capture.

## Tool Shape

`visual_qa_screenshot` accepts:

- `path` — screenshot/image path. Workspace-relative paths are preferred; absolute paths are allowed for user-provided or approved screenshots.
- `context` — optional page, route, expected state, or recent UI change.
- `focus` — optional focus such as `colors`, `dark-mode`, `layout`, `accessibility`, `regression`, or `general`.
- `allow_vl` — defaults to `true`. When false, the tool only uses local palette, theme estimate, and OCR.

The tool is classified as `write` risk because `allow_vl=true` may call a remote provider with image data. Local-only mode still shares the same approval boundary for a predictable UI and audit trail.

## Output

The tool returns:

- image size and source path
- local theme estimate
- dominant palette with luminance values
- OCR preview from Vision
- visual-model review when Image Understanding is configured and `allow_vl=true`
- a short call-boundary reminder

## Browser Automation Link

For Playwright MCP, PinchTab, or Chrome Relay visual QA:

1. Navigate and interact with the page.
2. Capture a screenshot after user approval.
3. Call `visual_qa_screenshot` with the screenshot path and a focused `context`.
4. Use the report to decide whether more code changes or screenshots are needed.

## Verification

Covered by `XeditTests/AgentToolsCoreTests`:

- descriptor risk and call-boundary wording
- local-only screenshot analysis without a VL provider call
