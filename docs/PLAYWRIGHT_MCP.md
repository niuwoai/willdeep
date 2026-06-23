# Playwright MCP

> Last updated: 2026-06-23 | Current version: v1.104.0-rc1

WillDeep integrates Playwright through MCP, not as a bundled global Node dependency.
The recommended server runs on demand with npm's `npx`:

```json
{
  "command": "/usr/bin/env",
  "args": ["npx", "-y", "@playwright/mcp@latest"]
}
```

## Why npx

- `@playwright/mcp` is published as an npm package and the upstream examples use `npx`.
- `-y` answers npm's first-run install prompt, so the GUI does not hang at `Ok to proceed?`.
- This is a tool runtime, not a project dependency. It must not modify the user's workspace `package.json` or lockfile.
- `pnpm dlx` and `yarn dlx` are valid advanced choices, but they depend on extra user machine setup.

## China Mirror

For users in China, WillDeep offers a second preset with npm registry override:

```json
{
  "command": "/usr/bin/env",
  "args": ["npx", "-y", "@playwright/mcp@latest"],
  "env": {
    "npm_config_registry": "https://registry.npmmirror.com"
  }
}
```

This keeps the package manager as `npx` and only changes npm's registry lookup. Corporate users can still create a custom MCP server and point `npm_config_registry` to an internal registry.

## Safety Notes

- The MCP server is added as a user MCP server and still follows WillDeep's MCP trust policy.
- Read-style Playwright calls may auto-run under the default MCP policy; browser actions with side effects can still require approval.
- The first tool refresh may access the network to download `@playwright/mcp@latest`.
