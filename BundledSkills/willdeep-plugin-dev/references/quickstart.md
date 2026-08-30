# 从零做一个 WillDeep 插件

以一个只有本地网页页面的插件为例。仓库里的 `PluginExamples/` 有七个可直接参照的实现：`arcade`、`tetris`、`favorites`、`todo`、`project-overview`（localWeb）、`issue-panel`、`session-vitality`（mcpApp）。

## 1. 目录

```text
my-plugin/
├── .codex-plugin/plugin.json        # 身份：id、version
├── .willdeep-plugin/
│   ├── plugin.json                  # 宿主贡献
│   └── locales/
│       ├── en.json                  # 英文必须齐全，缺键拒载
│       └── zh-Hans.json
└── ui/
    └── index.html                   # 或构建产物 ui/dist/index.html
```

`.codex-plugin/plugin.json` 最少两行：

```json
{ "name": "my-plugin", "version": "1.0.0" }
```

## 2. 清单

```json
{
  "schemaVersion": 1,
  "minimumWillDeepVersion": "1.280.0",
  "contributes": {
    "destinations": [
      { "id": "main", "titleKey": "destination.main", "icon": "sf:square.grid.2x2",
        "mainPage": "main.page", "companionSidebar": "main.sidebar",
        "toolbarCommandIDs": ["main.refresh"] }
    ],
    "pages": [
      { "id": "main.page", "runtime": "localWeb", "entryPath": "ui/index.html" }
    ],
    "sidebars": [
      { "id": "main.sidebar", "mode": "none" }
    ],
    "commands": [
      { "id": "main.refresh", "titleKey": "command.refresh", "icon": "sf:arrow.clockwise",
        "handler": { "type": "host", "action": "plugin.refresh" } }
    ],
    "menus": { "plugin.page.toolbar": ["main.refresh"] },
    "settings": []
  },
  "permissions": [],
  "dependencies": { "mcpServers": [], "skills": [] }
}
```

`locales/en.json`：

```json
{ "destination.main": "My Plugin", "command.refresh": "Refresh" }
```

## 3. 页面

所有 CSS 和 JS 必须内联或打进包里，用相对路径引用。外链会被 CSP 拦掉。

```html
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>My Plugin</title>
<style>
  body { font-family: -apple-system, sans-serif; padding: 16px;
         background: var(--willdeep-bg); color: var(--willdeep-fg); }
  .muted { color: var(--willdeep-secondary); }
</style>
</head>
<body>
  <h1>Hello</h1>
  <p class="muted" id="where"></p>
  <script>
    function render(ctx) {
      document.getElementById('where').textContent =
        ctx.destinationID + ' · ' + ctx.colorScheme;
    }
    render(window.willdeep.getContext());
    window.addEventListener('willdeep:context-changed', e => render(e.detail));
  </script>
</body>
</html>
```

用前端框架也可以，构建产物放 `ui/dist/`，把 `entryPath` 指到 `ui/dist/index.html`。**改了前端源码必须重新构建并把 `dist` 一起提交**——宿主加载的是构建产物，不是源码。

## 4. 安装

插件中心 →「添加插件」→ 选本地目录。安装预览会列出目的地、命令和权限差异，批准后才会写入 `~/.willdeep/plugins/<plugin-id>/<version>/`。

改了包内容就是新的 digest，需要重新批准；版本号不变但内容变了会被直接拒绝，请改版本号。

## 5. 调试顺序

1. 页面不出现 → 看插件中心里插件是不是启用状态，以及 `minimumWillDeepVersion` 是否满足。
2. 白页 → `entryPath` 是不是指到了具体文件；资源是不是超了 8 MiB。
3. 命令没反应 → `host` 的 `action` 只有四个合法值；`mcpTool` 要看依赖的 MCP 服务是否已配置。
4. 文案显示成 key 本身 → 英文 locale 里缺这个键。

## 6. 接下来

- 要用 MCP 工具：在包里放 `mcp.json` 声明服务，命令用 `handler.type: "mcpTool"`。敏感 header/env 只能写 Keychain 引用或 `${setting:<id>}`，写明文 token 会导致该服务拒载。
- 要让页面问模型：清单加 `"permissions": ["ai.chat"]`，页面调 `window.willdeep.ai.complete`，并为模型不可用准备回落。
- 要原生侧栏：`mode: "declarative"` 加一份组件 Schema，不用写前端。
