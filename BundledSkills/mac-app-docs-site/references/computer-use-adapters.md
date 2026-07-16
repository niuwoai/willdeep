# Computer Use adapters

Read this file before capturing UI evidence. Use exactly one adapter for the current host and continue to obey the loaded `computer-use` skill and its confirmation policy.

## WillDeep adapter

Use WillDeep's native Computer Use tools:

1. Call `computer_use_permissions`.
2. If a required permission is missing, explain why it is needed and wait for approval before `computer_use_request_permissions`.
3. Resolve the app with `computer_use_list_apps` or `computer_use_launch_app` when necessary.
4. Call `computer_use_get_app_state` with the app or PID.
5. Prefer fresh Accessibility `ref` values in `computer_use_click` and `computer_use_set_value`.
6. Use screenshot-relative coordinates only when no usable accessibility element exists.
7. Re-fetch state after every action. Each returned screenshot is a verification artifact for that exact state.

Save the selected-window screenshot returned for the verified state to the tutorial's `assets/interface/` directory. Preserve the original resolution for the documentation source; create a temporary thumbnail only for model inspection when necessary.

## Codex Desktop adapter

Use the Computer Use plugin's `node_repl + @oai/sky` workflow. Bootstrap the wrapper exactly as instructed by the installed `computer-use` skill, then operate through `sky`.

```js
var state = await sky.get_app_state({ app: "Target App" });
nodeRepl.write(state.text);
```

Prefer `element_index` actions. Fetch new state after every action because indices may change. If the display name fails, use the bundle identifier discovered through `sky.list_apps()`.

To persist the verified window screenshot:

```js
var fs = await import("node:fs/promises");
var path = await import("node:path");
var { fileURLToPath } = await import("node:url");

var state = await sky.get_app_state({ app: "Target App" });
var output = "/absolute/repo/docs/app-tutorial/assets/interface/01-overview.png";
await fs.mkdir(path.dirname(output), { recursive: true });
await fs.copyFile(fileURLToPath(state.screenshot.url), output);
```

Emit or inspect the screenshot before accepting it:

```js
await nodeRepl.emitImage({
  bytes: await fs.readFile(fileURLToPath(state.screenshot.url)),
  mimeType: "image/png",
});
```

## Capture discipline

- Use one deterministic fixture account/workspace across a chapter.
- Prefer a normal production-sized window; avoid maximized captures when the product is normally used at a smaller width.
- Capture a menu or popover only after verifying that labels are fully visible.
- Keep pointer position away from important labels when possible.
- Name images by documented state, not by timestamps or generic words such as `screen1`.
- Never reconstruct, synthesize, or edit UI content in a way that could imply a state the app did not actually show.
- Cropping may remove unrelated chrome, but must not remove warnings, validation messages, disabled states, or other context needed to interpret the workflow.
