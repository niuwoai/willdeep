# 打包、安装、审批与安全边界

## 包结构

```text
plugin-root/
├── .codex-plugin/plugin.json      # 身份
├── .willdeep-plugin/
│   ├── plugin.json                # 宿主贡献
│   ├── locales/{en,zh-Hans}.json
│   └── schemas/                   # 声明式侧栏/页面
├── skills/                        # 随插件启停生效的技能
├── mcp.json                       # 随插件启停生效的 MCP 服务
├── ui/dist/                       # 网页页面构建产物
└── assets/
```

## 体积与数量上限

| 对象 | 上限 |
| --- | --- |
| 包内文件数 | 20000 |
| 包总大小 | 256 MiB |
| 单个文件 | 32 MiB |
| 清单、声明式 UI 文档 | 1 MiB |
| Web / MCP App 页面资源（单个） | 8 MiB |
| 声明式组件数 / 嵌套深度 | 1000 / 20 层 |
| Bridge 单条消息 | 64 KiB |
| `ai.complete` 请求 | 24 条消息 / 32000 字符 / 4096 输出 token |

## 安装来源

- 本地目录或 ZIP
- Git：HTTPS、SSH 或 `git@host:path`，可指定 branch、tag、commit
- `~/.codex/plugins/cache`（只读发现）
- `~/.willdeep/plugin-drafts`（AI 草案）
- 随 App 内置的第一方包（`bundled`）

安装器**不执行**任何包内脚本：没有 `postinstall`，不跑 npm/yarn install，不跑构建命令。Git 元数据不会复制进安装版本。所以构建产物必须提前打好放进包里。

## 生命周期

```text
发现 → 严格校验 → 权限差异预览 → 用户批准 → 不可变版本安装 → 启用
                                                ↓
                                       停用 / 回滚 / 卸载
```

- 安装版本落在 `~/.willdeep/plugins/<plugin-id>/<version>/`，运行状态落在 `~/Library/Application Support/WillDeep/plugin-registry.json`。
- 更新不覆盖旧版本，失败时旧版本不受影响，用户可以回滚到任何已批准的版本。
- 批准记录同时绑定插件 ID、版本、内容 digest 和来源。来源变化、新增权限、digest 没批准过，都要重新确认。
- 同一版本号但内容 digest 不同会被拒绝。
- 卸载会移除该插件的所有已安装版本以及授权、设置状态。

## 拒载与拒绝启用的常见原因

| 现象 | 原因 |
| --- | --- |
| 整包拒载 | 重复 ID、引用了不存在的 page/sidebar/command、未知 schemaVersion、非法版本号、路径逃逸或符号链接逃逸 |
| 拒绝启用 | `minimumWillDeepVersion` 不满足、资源缺失、digest 变了没重新批准 |
| MCP 服务拒载 | `mcp.json` 里出现明文 token / password / secret |
| 文案显示成 key | 英文 locale 缺该键或值为空 |
| 设置项拒载 | `defaultValue` 与 `type` 不符 |

## 安全不变量

这些是宿主侧的硬约束，插件改不了：

- Secret 只进 macOS Keychain，不进清单、日志、UserDefaults。`mcp.json` 的敏感字段只能用 Keychain 引用或 `${setting:<id>}`。
- 所有资源路径经过规范化、真实符号链接解析和包根前缀校验，逃出包根一律拒绝。
- 每个插件的 WebView 用独立的非持久化数据存储，插件之间不共享 Cookie 和 LocalStorage。
- 每个插件的 MCP 服务在宿主里有命名空间隔离，同名 server 不会串到另一个插件。MCP App 只能调本插件声明过的命令和同服务的 resource。
- Bridge 每次调用都校验插件身份、当前启用版本、命令 ID、参数键值和大小。
- 声明式 UI 不执行脚本，不接受 CSS、Canvas 和任意坐标布局。包内 Schema 和 MCP 动态 Resource 走同一套校验。
- 扫描、哈希和安装 staging 在后台线程做，UI 只收不可变快照。

## AI 生成的插件草案

AI 只能用三个工具在草案根内写文件并验证：`create_plugin_draft`、`write_plugin_draft_file`、`inspect_plugin_draft`。路径穿越、符号链接逃逸、超大文件、草案根外的路径都会被拒绝。

**AI 永远不能安装、批准或启用插件。**必须由用户在插件中心检查权限和目的地之后手动批准。让 AI 写插件时，最后一步一定是把草案路径给用户，而不是宣称"已经装好了"。

## 界面规范

插件界面遵循宿主的灰阶交互规范：导航、开关、菜单、链接式操作和选中态不使用 macOS 系统蓝，也不使用插件品牌色，用不同灰度表达默认、悬停、按下、选中。推动安装流程的主操作用黑底白字，次要和取消操作用灰度文字或描边。

另外，悬停才出现的元素要常驻布局、只切换可见性（`opacity` 而不是条件插入），否则鼠标划过列表时行高会跳。
