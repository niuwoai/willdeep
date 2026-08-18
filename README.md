<a id="willdeep-中文版"></a>

<div align="center">

<img src="appicons/icon_256x256.png" width="128" height="128" alt="WillDeep" />

# WillDeep（中文版）

**一个 macOS 原生 Agent 工作台：理解项目、调用工具、推进任务，并把结果交付到你手上。**

[![macOS](https://img.shields.io/badge/macOS-13.7%2B-black?logo=apple)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-SwiftUI-orange?logo=swift)](https://developer.apple.com/swift/)
[![Version](https://img.shields.io/badge/version-1.272.0--rc3-blue)](CHANGELOG.md)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue)](LICENSE)

*它不只是坐在编辑器旁边回答问题。它会看现场、做事情、留下证据，也知道什么时候该停下来问你。*

[willdeep.com](https://willdeep.com)

[English](#willdeep) · **简体中文** · [日本語](#willdeep-日本語版)

</div>

---

## 这不是另一个“带 AI 的编辑器”

编辑器以文件和 tab 为中心；WillDeep 以**任务、工作区、会话和交付物**为中心。

你告诉它“修掉这个 bug”“把这套设计落成页面”“检查服务器为什么卡住”“把本周工作整理出来”，它会读取项目、搜索代码、操作终端或浏览器、拆解计划、调用技能，必要时创建隔离 worktree，然后持续推进到可以验证的结果。

所以，WillDeep 现在更准确的定义是：

> **一个运行在 macOS 上、能接入本地与远端工作现场的通用 Agent。**

它仍然带着一个很快的原生编辑器，但编辑器已经不是舞台中央的主角，而是 Agent 用来查看、比较和修正现场的工具之一。

---

## 它怎么工作

### 从一句话到可验收结果

- **Normal / Plan / Goal 三种工作方式。** 小事直接做，复杂任务先形成计划，长期目标则带清单持续推进。
- **真正的多轮执行。** Agent 可以连续调用工具、处理结果、修正方案并继续，不会把“给你一段建议”冒充“已经完成”。
- **任务排队与自动化。** 当前回复还在运行时可以继续发送；例行任务可按计划执行，后台任务、媒体任务和构建队列都有可见状态。
- **会话属于工作区。** 对话、文件引用、运行位置、Git 分支、终端和交付物围绕同一个项目组织，不靠你反复解释上下文。
- **隔离工作。** 新任务可以进入独立 worktree；高风险 Git 操作前会重新核对仓库 revision，避免覆盖人类或其他 Agent 刚做的改动。

### 不止会聊天，是真的能动手

WillDeep 的 Agent 可以使用：

- 文件读取、全文搜索、精确编辑、diff 审查与 Git 状态；
- shell 命令、可见终端、构建、测试和长任务；
- 网页搜索、内置浏览器与 macOS Computer Use；
- Codex Skills、MCP servers，以及 Claude Code / Codex CLI / Cursor Agent 等外部执行器；
- 图片理解、图片编辑、媒体任务、网页组件和结构化工作流；
- SSH 或 remote daemon，把同一套 Agent 工作流带到远端 macOS / Linux 工作区。

工具不是烟花。每次调用都应该让任务离完成更近一点——否则只是机器在很努力地表演忙碌。

### 你仍然握着方向盘

- **安全命令可以自动放行。** 明确只读的操作直接执行；边界命令可交给审批模型判断。
- **危险动作必须确认。** 破坏性命令、敏感操作和外部副作用会升级审批，必要时要求手动输入 `confirm`。
- **改动可以审。** 文件变更以 diff 呈现，可逐项 Apply / Reject，也可查看当前 worktree 的完整变化。
- **机密不进对话。** API Key 存在 Keychain；受保护的 secret 以占位符进入上下文，只在本机执行边界解析，并对结果继续脱敏。
- **上下文用量不是玄学。** token 统计按真实请求体计算；长会话可手动或自动压缩，历史仍保留为可读数据。

### 本地、远端，都是同一个工作现场

在 Settings → Runtimes 中配置 SSH 主机或 `willdeep-agent` daemon 后，一个会话可以绑定到远端 workspace。文件搜索、Git、shell、构建、测试和委派任务都在远端执行，本机保留原生界面、审批与结果审查。

```bash
willdeep-agent serve \
  --workspace /path/to/project \
  --token-file ~/.willdeep-agent-token
```

### 内置编辑器还在，而且依然很快

需要直接看文件时，WillDeep 提供原生 AppKit + SwiftUI 编辑体验：

- 文件立即显示，语法高亮在主线程之外增量完成；
- 大文件只优先高亮可见区域，滚动到哪处理到哪；
- 代码折叠、括号配对、Minimap、结构 inspector、跨文件查找替换、Markdown / HTML 预览、分屏和 Focus 模式；
- Swift、Ruby、PHP、Java、JavaScript / TypeScript、Go、Python、Rust、C / C++ / C#、SQL、YAML、TOML、Dockerfile、Makefile、shell 等 25 种以上语言；
- 只有显式打开文件夹时才加载文件树，不会因为双击一个文本文件就擅自扫描整个目录。

换句话说：编辑器从“产品定义”退到了“基础能力”，但没有被扔进地下室吃灰。

---

## 开始使用

### 从源码编译

```bash
git clone https://github.com/xurenlu/willdeep.git
cd willdeep
open Xedit.xcodeproj
# ⌘R
```

需要 Xcode 和 macOS 13.7+。产物名为 **WillDeep.app**。

日常命令行编译优先使用共享热缓存入口：

```bash
ruby scripts/build_fast.rb             # Debug 增量编译，默认不生成索引、不签名
ruby scripts/build_fast.rb --sign      # 需要运行签名链路时
ruby scripts/build_fast.rb --release   # Release 编译
ruby scripts/build_fast.rb --index     # 这次 CLI 编译也生成索引
ruby scripts/build_fast.rb --release --destination 'generic/platform=macOS'
                                      # 为正式 archive 预热全部目标架构
```

默认缓存位于 `~/Library/Caches/WillDeep/Xcode/Xedit`，DerivedData、SwiftPM checkout、package 下载缓存与 Xcode compilation cache 会跨终端和 Codex 任务复用；脚本不会修改 Xcode IDE 的索引设置。构建报告写入 `build/local/build_report.md` 与 `build/local/build_report.json`。

完整的缓存布局、测试入口、CI Runner 与正式发布边界见 [本地构建与测试提速](docs/BUILD_TEST_ACCELERATION.md)。

开发阶段优先通过仓库测试入口执行单测，避免多个 Agent 或 Git worktree 同时冷构建：

```bash
ruby scripts/run_tests_fast.rb -only-testing:XeditTests/YourTestSuite
ruby scripts/run_tests_fast.rb --without-building -only-testing:XeditTests/YourTestSuite
scripts/run_tests.sh
```

快速入口与本地编译共用稳定的 DerivedData、SwiftPM 和 compilation cache，只构建 `XeditTests` Scheme；`--without-building` 会核对源码指纹，源码变化后拒绝运行旧测试二进制。完整本地门禁仍使用 `scripts/run_tests.sh`。

要把当前 worktree 的 Debug 版本直接装进 `/Applications`，先在不会提交的 `.env.local` 中配置登录密钥：

```dotenv
WILLDEEP_CLIENT_LOGIN_SECRET=你的本地开发密钥
```

然后执行：

```bash
ruby dev_install.rb --dry-run
ruby dev_install.rb
```

脚本不会输出密钥；它会完成干净构建、签名、原子安装，以及版本、签名和密钥注入校验。已经运行的 WillDeep 不会自动重载覆盖后的 App，请彻底退出后重新打开。

### 第一个任务

1. 打开 WillDeep，创建一个新对话。
2. 选择本地工作区；如果任务在服务器上，选择已配置的远端 runtime。
3. 登录 some.im 托管服务，或在 Settings → AI Providers 中配置自己的模型与 API Key。
4. 直接描述想要的结果。复杂任务可切到 Plan，长期任务可使用 Goal。
5. Agent 需要授权、选择或补充信息时会明确停下来找你；完成后检查 diff、测试结果和交付物。

Settings → Command Line Tool 可以安装 `willdeep` CLI：

```bash
willdeep .
willdeep path/to/file.go
```

---

## 常用快捷键

| 快捷键 | 动作 |
| --- | --- |
| ⌘⇧A | 打开 Agent 窗口 |
| ⌥⌘A | 显示 / 隐藏项目 Agent 面板 |
| ⌘O / ⇧⌘O | 打开文件 / 打开文件夹 |
| ⌘P | Quick Open |
| ⌘⇧P | 命令面板 |
| ⌘F / ⌘G | 查找 / 查找下一个 |
| ⌘L | 跳到行 |
| ⌘⇧O | 跳到当前文件符号 |
| ⌘⌥R | 切换 Markdown / HTML 预览 |
| ⌘⌥\ | 打开分屏文件 |
| ⌘⌥I | 切换 Inspector |
| ⌘1..9 / ⌘[ ] | 切换编辑器 tab |
| ⌘⇧T | 恢复刚关闭的 tab |

---

## 设计哲学

> 软件不该只告诉你怎么做，它应该在边界清楚的前提下，陪你把事情做完。

- **任务优先于文件。** 用户要的是结果，不是一场围绕 tab 的仪式。
- **证据优先于自信。** 跑过测试、看过 diff、核对过状态，再说完成。
- **上下文属于工作区。** 会话、终端、分支和产物不该互相串台。
- **自动化必须可控。** 越有能力的 Agent，越应该清楚审批、机密和副作用的边界。
- **原生性能仍是底线。** Agent 再聪明，窗口卡成彩虹圈也只能算赛博盆栽。

---

## 项目状态

WillDeep 当前在 `1.165.x` 上活跃迭代。Agent 工作台是主产品界面，原生编辑器作为文件查看、轻量编辑和 Agent 协作能力继续维护。

每次发布的具体变化见 [CHANGELOG.md](CHANGELOG.md)，完整能力矩阵与未决问题见 [product-overview.md](product-overview.md)。Release Candidate tag 使用 `vMAJOR.MINOR.PATCH-rcN` 格式。

---

## 参与贡献

欢迎 Issue 和 PR。理解 Agent 主链路可以从 [AgentModeView.swift](Xedit/AgentModeView.swift)、[AppStateAgentLoop.swift](Xedit/AppStateAgentLoop.swift)、[AgentToolRegistry.swift](Xedit/AgentToolRegistry.swift) 和 [AgentContextBuilder.swift](Xedit/AgentContextBuilder.swift) 开始；编辑器入口仍在 [ContentView.swift](Xedit/ContentView.swift)。

提 PR 时请：

1. 按仓库规则更新版本号：bugfix 只递增 `-rcN`，功能新增才提升正式版本位。
2. 同步 CHANGELOG，并说明为什么改，而不只是改了什么。
3. 新增界面文案必须走本地化资源。
4. 不要让启动、聊天输入或长会话性能退化；触碰热路径时请先 profile。

---

## 许可与 Open Core

WillDeep 采用 [Apache License 2.0](LICENSE) + [Open Core](OPEN_CORE.md) 模式。

除非具体文件另有说明，本仓库代码按 Apache 2.0 开源。WillDeep 名称、Logo、官方签名构建、托管服务、云同步、受管 runtime、团队功能、marketplace 能力与企业支持可能作为独立商业产品或服务提供；已经按 Apache 2.0 发布的代码会继续保持 Apache 2.0。

---

<div align="center">

**不是替你说“应该怎么做”，而是和你一起把它做完。**

⭐ 如果你也觉得 Agent 应该交付结果，而不只是交付一段语气坚定的文字，欢迎点个 Star。

</div>

---

<a id="willdeep"></a>

<div align="center">

<img src="appicons/icon_256x256.png" width="128" height="128" alt="WillDeep" />

# WillDeep

**A native macOS agent workspace that understands projects, uses tools, advances tasks, and delivers verifiable results.**

[![macOS](https://img.shields.io/badge/macOS-13.7%2B-black?logo=apple)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-SwiftUI-orange?logo=swift)](https://developer.apple.com/swift/)
[![Version](https://img.shields.io/badge/version-1.272.0--rc3-blue)](CHANGELOG.md)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue)](LICENSE)

*It does not merely answer questions beside an editor. It inspects the work, takes action, leaves evidence, and knows when to stop and ask.*

[willdeep.com](https://willdeep.com)

**English** · [简体中文](#willdeep-中文版) · [日本語](#willdeep-日本語版)

</div>

---

## This is not another editor with AI attached

Editors are organized around files and tabs. WillDeep is organized around **tasks, workspaces, sessions, and deliverables**.

Ask it to fix a bug, implement a design, diagnose a server, or summarize a week of work. It can inspect the project, search code, operate terminals and browsers, build a plan, load skills, create an isolated worktree when needed, and keep going until the outcome can be verified.

The more accurate definition of WillDeep today is:

> **A general-purpose agent for macOS that can work across local and remote environments.**

It still includes a fast native editor, but the editor is no longer the center of the product. It is one of the tools the agent and its user share to inspect, compare, and correct the work.

---

## How it works

### From one request to a verifiable outcome

- **Normal, Plan, and Goal modes.** Do small jobs directly, plan complex work before execution, or keep a checklist alive for a longer-running goal.
- **Real multi-step execution.** The agent can call tools, inspect results, revise its approach, and continue instead of presenting advice as completed work.
- **Queues and automations.** Send the next request while a turn is running. Scheduled routines, background jobs, media tasks, and build queues expose visible state.
- **Workspace-owned context.** Conversations, referenced files, runtime location, Git branch, terminal, and deliverables stay organized around the same project.
- **Isolated work.** Tasks can run in dedicated worktrees. Before high-risk Git mutations, WillDeep rechecks the repository revision so it does not overwrite changes made by a person or another agent.

### Tools, not just chat

The WillDeep agent can use:

- file reads, full-text search, precise edits, diff review, and Git status;
- shell commands, visible terminals, builds, tests, and long-running jobs;
- web search, an embedded browser, and macOS Computer Use;
- Codex Skills, MCP servers, and external executors such as Claude Code, Codex CLI, and Cursor Agent;
- image understanding, image editing, media tasks, web widgets, and structured workflows;
- SSH or the remote daemon to bring the same workflow to remote macOS and Linux workspaces.

Tools are not decoration. Every call should move the task closer to done.

### You keep control

- **Safe commands can run automatically.** Clearly read-only operations are allowlisted; borderline commands may be evaluated by an approval model.
- **Risky actions require confirmation.** Destructive commands, sensitive operations, and external side effects escalate to approval and may require typed `confirm`.
- **Changes are reviewable.** File edits arrive as diffs that can be applied or rejected individually, with a full worktree review available at any time.
- **Secrets stay out of chat.** API keys live in Keychain. Protected secrets enter context as placeholders, resolve only at the local execution boundary, and remain redacted from results.
- **Context accounting is real.** Token usage is calculated from the actual request payload. Long conversations can be compressed manually or automatically without turning history into an opaque blob.

### Local or remote, one working context

Configure an SSH host or a `willdeep-agent` daemon in Settings → Runtimes and bind a session to a remote workspace. File search, Git, shell commands, builds, tests, and delegated tasks run remotely while the native UI, approvals, and result review remain local.

```bash
willdeep-agent serve \
  --workspace /path/to/project \
  --token-file ~/.willdeep-agent-token
```

### The built-in editor is still fast

When direct file work is useful, WillDeep provides a native AppKit + SwiftUI editor:

- text appears immediately and syntax highlighting is applied incrementally off the main thread;
- large files prioritize the visible range;
- code folding, bracket matching, minimap, structure inspector, project search and replace, Markdown / HTML preview, split view, and focus mode;
- 25+ languages including Swift, Ruby, PHP, Java, JavaScript / TypeScript, Go, Python, Rust, C / C++ / C#, SQL, YAML, TOML, Dockerfile, Makefile, and shell;
- the file tree loads only when you explicitly open a folder.

The editor has moved from the product definition to the capability layer. It has not been abandoned.

---

## Get started

### Build from source

```bash
git clone https://github.com/xurenlu/willdeep.git
cd willdeep
open Xedit.xcodeproj
# ⌘R
```

Requires Xcode and macOS 13.7+. The product builds as **WillDeep.app**.

To install the current worktree's Debug build directly into `/Applications`, put the local development credential in the ignored `.env.local` file:

```dotenv
WILLDEEP_CLIENT_LOGIN_SECRET=your-local-development-secret
```

Then run:

```bash
ruby dev_install.rb --dry-run
ruby dev_install.rb
```

The script never prints the secret. It performs a clean build, signing, atomic installation, and version/signature/injection verification. Fully quit and relaunch WillDeep after replacing a running build.

### Run your first task

1. Open WillDeep and create a new conversation.
2. Choose a local workspace, or a configured remote runtime for server-side work.
3. Sign in to the some.im managed service, or configure your own model and API key in Settings → AI Providers.
4. Describe the outcome you want. Use Plan for complex work and Goal for longer-running objectives.
5. The agent pauses when it needs approval, a decision, or more context. Review its diffs, test results, and deliverables when it finishes.

Install the `willdeep` CLI from Settings → Command Line Tool:

```bash
willdeep .
willdeep path/to/file.go
```

---

## Common shortcuts

| Shortcut | Action |
| --- | --- |
| ⌘⇧A | Open Agent window |
| ⌥⌘A | Show / hide the project Agent panel |
| ⌘O / ⇧⌘O | Open file / open folder |
| ⌘P | Quick Open |
| ⌘⇧P | Command Palette |
| ⌘F / ⌘G | Find / find next |
| ⌘L | Go to line |
| ⌘⇧O | Go to symbol in the active file |
| ⌘⌥R | Toggle Markdown / HTML preview |
| ⌘⌥\ | Open split file |
| ⌘⌥I | Toggle Inspector |
| ⌘1..9 / ⌘[ ] | Switch editor tabs |
| ⌘⇧T | Reopen the last closed tab |

---

## Philosophy

> Software should not only tell you how. Within clear boundaries, it should help you finish the work.

- **Tasks over files.** Users want outcomes, not a ceremony organized around tabs.
- **Evidence over confidence.** Run the tests, inspect the diff, verify the state, then call it done.
- **Context belongs to the workspace.** Sessions, terminals, branches, and deliverables must not leak into one another.
- **Automation must remain controllable.** The more capable an agent becomes, the clearer its approval, secret, and side-effect boundaries must be.
- **Native performance remains the floor.** A brilliant agent inside a beachball is still a houseplant.

---

## Status

WillDeep is in active `1.165.x` development. The agent workspace is the primary product surface; the native editor continues as a maintained capability for file inspection, lightweight editing, and agent collaboration.

See [CHANGELOG.md](CHANGELOG.md) for release details and [product-overview.md](product-overview.md) for the full capability matrix and open questions. Release Candidate tags follow `vMAJOR.MINOR.PATCH-rcN`.

---

## Contributing

Issues and PRs are welcome. Start with [AgentModeView.swift](Xedit/AgentModeView.swift), [AppStateAgentLoop.swift](Xedit/AppStateAgentLoop.swift), [AgentToolRegistry.swift](Xedit/AgentToolRegistry.swift), and [AgentContextBuilder.swift](Xedit/AgentContextBuilder.swift) for the primary agent flow. The editor entry point remains in [ContentView.swift](Xedit/ContentView.swift).

When opening a PR:

1. Follow the repository version rules: bug fixes increment only `-rcN`; new functionality may bump a release component.
2. Update the CHANGELOG and explain why the change exists, not only what changed.
3. Route all new user-facing strings through localization resources.
4. Do not regress startup, composer input, or long-session performance. Profile changes on hot paths.

---

## License and Open Core

WillDeep uses an [Apache License 2.0](LICENSE) + [Open Core](OPEN_CORE.md) model.

Unless a file states otherwise, code in this repository is released under Apache 2.0. The WillDeep name, logo, official signed builds, hosted services, cloud sync, managed runtimes, team features, marketplace offerings, and enterprise support may be provided separately. Code already released under Apache 2.0 remains Apache 2.0.

---

<div align="center">

**Not just telling you what should be done. Working with you until it is done.**

⭐ Star the repo if you believe agents should deliver results, not merely confident prose.

</div>

---

<a id="willdeep-日本語版"></a>

<div align="center">

<img src="appicons/icon_256x256.png" width="128" height="128" alt="WillDeep" />

# WillDeep（日本語版）

**プロジェクトを理解し、ツールを使い、タスクを進め、検証可能な成果を届ける macOS ネイティブのエージェント・ワークスペース。**

[English](#willdeep) · [简体中文](#willdeep-中文版) · **日本語**

</div>

---

*日本語版の README は準備中です。しばらくお待ちください。*
