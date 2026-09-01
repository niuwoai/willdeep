<a id="willdeep-中文版"></a>

<div align="center">

<img src="appicons/icon_256x256.png" width="128" height="128" alt="WillDeep" />

# WillDeep（中文版）

**macOS 上的原生 Agent 工作台。你交代一件事，它读现场、动手、验证，把改动和证据摆回你面前。**

[![macOS](https://img.shields.io/badge/macOS-13.7%2B-black?logo=apple)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-SwiftUI-orange?logo=swift)](https://developer.apple.com/swift/)
[![Version](https://img.shields.io/badge/version-1.316.0--rc2-blue)](CHANGELOG.md)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue)](LICENSE)

[willdeep.com](https://willdeep.com)

[English](#willdeep) · **简体中文** · [日本語](#willdeep-日本語版)

</div>

---

## 先说一件事：这里已经没有编辑器了

从 1.249.0 起，WillDeep 删除了通用编辑器场景——文本/源码文件类型注册、编辑器设置入口、编辑器窗口，全部下线。通用文件编辑交给独立的 **Qeditor**，它有自己的 Bundle ID、沙盒容器、设置和更新通道，不迁移 WillDeep 的数据。

WillDeep 这边留下的是**只读预览**和 **Diff 审阅**：Agent 改完文件，你在 Diff 面板逐段核对，再决定应用还是拒绝；想手改就用你惯用的编辑器打开。

这么切是因为两件事的注意力落点不同。编辑器围着文件和光标转，Agent 工作台围着任务、工作区、会话和交付物转。一个 App 兼顾两头，最后哪头都不透。

---

## 它强在哪

下面每一条都是已经落地的机制，不是路线图。

### 会话各跑各的

每个会话独占一个运行时——消息、请求任务、工具等待、输入草稿、模式状态各自一份。切走不打断，上一个会话继续在后台推进，侧栏的状态点告诉你它是在想、在等你点头，还是停了。

同一个服务商的并发有上限（默认 3，可在设置里调到 1–8），不同服务商互不影响：三个 DashScope 会话堵不住 OpenAI 那条线。

### 派工：三档模型 × 五类职责

模型收敛成基础、进阶、专家三档，职责收敛成调查、实现、验证、审查、运维五类，哪类活用哪档由你配。三档绑定优先读 `~/.willdeep/config.toml`，和命令行版共用同一份 schema——同一个账号不会因为开的是哪个客户端而落到不同模型上。配置点名了本机没有的提供商，那一档直接标为不可用并说明原因，不会静默把请求发去另一个网关。

子代理跑起来之后你还能插话：**下轮生效**把你的原话排进下一轮；**打断并发送**只取消它当前那一个子步骤，不杀掉整个子任务。派工卡上的工具标签带宾语——「运行命令 `ruby sync.rb`」「读取文件 `.env.local`」——你才判断得出要不要打断；宾语先脱敏再截断，`${secret:…}` 在被省略号吃掉之前就已经换成 `[secret]`。

### 审批分四档，判定顺序是死的

四档：严格模式、智能审核、工作区可写、完全访问。判定确定性优先——恶意命令黑名单在任何档位都拦；常见只读命令直接放行；你记过的授权直接生效；都不命中，才轮得到 AI 裁判说话。智能审核档下裁判判不了就回落人工确认；完全访问档根本不过裁判这一关，它的保护全部来自那份确定性黑名单，以及必须由你本人回答的交互边界。

破坏性操作在任何档位都要你亲手键入确认，没有例外。

命令默认套 seatbelt 沙箱执行：没有网络出口，不许越界写，环境里名字像 token / secret / api_key 的变量在传进去之前就被删掉，`HOME` 指向临时目录，`SSH_AUTH_SOCK` 和 `GITHUB_TOKEN` 一并清空。命令因为沙箱被拒时不会当成普通失败丢回给模型反复重试，而是停下来问你要不要无沙箱重跑一次。读凭据这件事就算不带网络出口也照样问——私钥一旦进了回复，它已经离开这台机器去了模型服务商。执行记录写入审计日志，密钥已脱敏。

### 上下文按真实用量算

窗口占用锚定 provider 回的 `prompt_tokens`，不用本地估算凑数（实测本地估算能低到三倍差）。超过阈值自动压缩老对话，请求体里的旧工具结果折叠成占位符，最近几轮保持原样。

快到窗口尽头时走**上下文跑道交接**：模型有序停机，写清停在哪、剩什么没做，末尾挂两个接力图标——一个在当前会话继续，一个开新会话带着交接词继续。交接只在显示层收拢，消息原文一个字节没动。

### 进度上报走工具通道

计划进度由常驻的 `update_plan` 工具上报，不再让模型在回复里写围栏块。落盘复盘的结论是：80% 的围栏块只在回合收尾才出现，长回合里那份清单能一直卡在「第 1 步」直到结束——工具调用是模型在回合中段唯一稳定使用的通道。

普通模式不强制先写计划。宿主自己测量：一个回合真跑满 4 个工具轮，或落地 3 次以上写级调用，才要求补一份只含剩余工作的计划。小任务零开销。

### 工作面板：多标签，能拖成独立窗口

右侧面板承载终端、文件、Diff、网页预览、媒体任务、图片编辑等视图。多个标签并存，终端和后台任务不会因为你切个标签就被顶掉。标签可以拖出来变成原生独立窗口，也能定位、拖回、批量收回；关掉标签不等于终止进程。

终端面板是真实终端——Agent 跑的命令和你手敲的命令，看到的是同一个环境。

### 本地和远端是同一套工作流

在设置 → Runtimes 里加 SSH 主机或 `willdeep-agent` daemon，会话就能绑到远端工作区。文件搜索、Git、shell、构建、测试、派工全在远端执行，界面、审批、结果审查留在本机。SSH 只保存密钥文件路径，不保存私钥内容；daemon token 存在钥匙串里。

```bash
willdeep-agent serve \
  --workspace /path/to/project \
  --token-file ~/.willdeep-agent-token
```

Git 仓库里还可以直接从输入区的工作区菜单创建、切换和清理 worktree；高风险 Git 操作前会重新核对仓库 revision，避免覆盖人或另一个 Agent 刚落地的改动。

### 四种扩展，各管一段

| 扩展 | 管什么 | 说明 |
| --- | --- | --- |
| **技能** | 改变 AI 的做事方法 | 随 App 内置 40+ 个；用户技能放 `~/.willdeep/skills`，兼容旧的 `~/.codex/skills` |
| **MCP 服务** | 给 AI 新的真实能力 | stdio 与 streamable-http 都支持；服务发现合并 App 自有、Cursor `mcp.json` 与 Codex `config.toml`，敏感 header 显示前脱敏 |
| **工作流** | 可重复的多步编排 | `/code-review`、`/pr-review`、`/bug-hunt`、`/release-notes`、`/deep-research`、`/db-explore` 等；fan-out 的维度审查绑小模型工种，可随时停止 |
| **插件** | 在主导航里加一块你直接操作的界面 | 页面跑在隔离环境（无网络、无文件、拿不到密钥），要做真事必须走清单里声明过的命令，安装时一次性授权 |

内置的第一方插件包括经典游戏厅、俄罗斯方块、收藏夹、待办、会话体检中心和项目概览。插件开发文档随 App 发行，在应用包的 `Contents/Resources/BundledSkills/willdeep-plugin-dev/` 下；直接在 WillDeep 里问「怎么开发 WillDeep 插件」，AI 会读这份文档回答你。

### 定时自己干活

左侧栏的「已安排」按周期跑任务：间隔、每天 HH:MM、工作日、指定星期。到点自动开一个新会话执行指定提示词，绑定工作区和模型档位。暂停的任务明确标注「已暂停」，不会假装还有下次运行。近期运行列出结果和失败原因，点一下回到对应会话。

### 其余值得一提的

- **Goal 模式**——长任务先拆成最多 6 个阶段，每阶段只展开当前 6 步计划，做完一段再规划下一段。验收标准由 AI 维护成内部契约，你只负责描述目标。阶段结束时宿主会静默终止该阶段起的进程树，跨阶段常驻必须显式声明。
- **专家圆桌**——十位内置专家。先进准备室精炼决策问题、按理由推荐 2–4 人，讨论真流式呈现，终稿自动规范化并落盘成 Markdown。
- **外部执行器**——Claude Code、Codex CLI、Cursor Agent、Cline 可以接手一轮任务，但要进宿主的任务契约：限定目标、验收标准、允许路径、禁止动作、验证命令、最多三轮。执行器先交证据包，再由只读上下文复核，最后 WillDeep 独立重跑安全检查，不过就拒收。
- **手机端**——Mobile Gateway 配对后可在手机上继续对话、审批工具、发图片；默认走互联网中继，也支持自建 WebSocket 中继。
- **模型来源随你**——登录 some.im 托管服务开箱即用，或在设置里配自己的 provider 与 API Key（key 存钥匙串，托管模型只是推荐值，随时可覆盖）。
- **会话不会越攒越乱**——按项目分组，可搜索、批量归档/恢复/删除；开启自动归档后按项目保留最近 N 个，置顶、正在跑、排队中和有未发草稿的会话受保护。

---

## 开始使用

### 装一个用

到 [willdeep.com](https://willdeep.com) 下载官方签名版，或者从源码编译。需要 macOS 13.7+。

### 从源码编译

```bash
git clone https://github.com/xurenlu/willdeep.git
cd willdeep
open Xedit.xcodeproj
# ⌘R
```

需要 Xcode。产物名为 **WillDeep.app**。

日常命令行编译走共享热缓存入口：

```bash
ruby scripts/build_fast.rb             # Debug 增量编译，默认不生成索引、不签名
ruby scripts/build_fast.rb --release   # Release 编译
ruby scripts/build_fast.rb --sign      # 需要走签名链路时
```

缓存默认在 `~/Library/Caches/WillDeep/Xcode/Xedit`，DerivedData、SwiftPM checkout 与 Xcode compilation cache 跨终端复用；构建报告写到 `build/local/build_report.md`。完整的缓存布局、测试入口与 CI 边界见 [本地构建与测试提速](docs/BUILD_TEST_ACCELERATION.md)。

跑测试优先用快速入口，避免多个 Agent 或 worktree 同时冷构建：

```bash
ruby scripts/run_tests_fast.rb -only-testing:XeditTests/YourTestSuite
scripts/run_tests.sh                   # 完整本地门禁
```

要把当前 worktree 的 Debug 版直接装进 `/Applications`，先在不会提交的 `.env.local` 里配好登录密钥：

```dotenv
WILLDEEP_CLIENT_LOGIN_SECRET=你的本地开发密钥
```

然后：

```bash
ruby dev_install.rb --dry-run
ruby dev_install.rb
```

脚本不打印密钥，会完成干净构建、签名、原子安装，以及版本、签名和密钥注入校验。已经在跑的 WillDeep 不会自动重载，请彻底退出后重开。

### 第一个任务

1. 给它一个模型来源：登录 some.im 托管服务，或在「设置 → AI 服务商」里配自己的 provider 和 key。
2. 在输入区左侧选工作区（一个本地目录，或已配置的远端 runtime）。Agent 的读写和命令都以它为边界。
3. 把想要的结果直接写进输入框发送。需要你点头的地方它会停下来问。
4. 完事后检查 Diff、测试结果和产物。

在「设置 → 工具」里装命令行工具后：

```bash
willdeep-app .
```

命令装在 `~/.local/bin`，必要时把它加进 `PATH`。

---

## 快捷键

App 是 Agent 专用的，快捷键也就这几个：

| 快捷键 | 动作 |
| --- | --- |
| ⌘N | 新建会话 |
| Return | 发送 |
| ⇧/⌥/⌃ + Return | 换行 |
| Esc | 收起搜索 / 关闭当前弹层 |
| ⌘? | 打开内置帮助 |

其余操作（审批档位、工作区、模型、执行器、面板标签）都在输入区和右侧面板上，鼠标可达。

---

## 设计取向

任务优先于文件——用户要的是结果，不是围着 tab 转的仪式。

跑过测试、看过 diff、核对过状态，才叫完成；没验证的事不说成已完成。

会话、终端、分支和产物属于各自的工作区，不互相串台。

Agent 能力越强，审批、机密和副作用的边界越要写死在确定性规则里，而不是交给模型临场判断。

窗口卡成彩虹圈的话，模型再聪明也没用——原生性能是底线，不是加分项。

---

## 项目状态

当前在 `1.315.x` 上活跃迭代。每次发布的具体变化见 [CHANGELOG.md](CHANGELOG.md)，完整能力矩阵与未决问题见 [product-overview.md](product-overview.md)。Release Candidate tag 使用 `vMAJOR.MINOR.PATCH-rcN`。

---

## 参与贡献

欢迎 Issue 和 PR。理解主链路可以从这几个文件开始：

- [AgentModeView.swift](Xedit/AgentModeView.swift)——Agent 主界面
- [AppStateAgentLoop.swift](Xedit/AppStateAgentLoop.swift)——回合循环、工具决策、上下文压缩
- [AgentToolRegistry.swift](Xedit/AgentToolRegistry.swift)——工具目录
- [AgentContextBuilder.swift](Xedit/AgentContextBuilder.swift)——系统提示与上下文组装

提 PR 时请：

1. 按仓库规则更新版本号：bugfix 只递增 `-rcN`，功能新增才提升正式版本位。
2. 同步 CHANGELOG，说明为什么改，而不只是改了什么。
3. 新增界面文案一律走本地化资源。
4. 不要让启动、输入或长会话性能退化；碰热路径先 profile。

---

## 许可与 Open Core

WillDeep 采用 [Apache License 2.0](LICENSE) + [Open Core](OPEN_CORE.md) 模式。

除非具体文件另有说明，本仓库代码按 Apache 2.0 开源。WillDeep 名称、Logo、官方签名构建、托管服务、云同步、受管 runtime、团队功能、marketplace 能力与企业支持可能作为独立商业产品或服务提供；已经按 Apache 2.0 发布的代码会继续保持 Apache 2.0。

---

<a id="willdeep"></a>

<div align="center">

<img src="appicons/icon_256x256.png" width="128" height="128" alt="WillDeep" />

# WillDeep

**A native macOS agent workspace. Describe an outcome; it inspects the work, acts, verifies, and puts the changes and the evidence back in front of you.**

[![macOS](https://img.shields.io/badge/macOS-13.7%2B-black?logo=apple)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-SwiftUI-orange?logo=swift)](https://developer.apple.com/swift/)
[![Version](https://img.shields.io/badge/version-1.316.0--rc2-blue)](CHANGELOG.md)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue)](LICENSE)

[willdeep.com](https://willdeep.com)

**English** · [简体中文](#willdeep-中文版) · [日本語](#willdeep-日本語版)

</div>

---

## First, the editor is gone

As of 1.249.0, WillDeep removed the general-purpose editor entirely — the editor scene, text/source file type registration, and editor settings are all retired. General file editing belongs to the standalone **Qeditor**, which has its own bundle ID, sandbox container, settings, and update feed, and does not migrate WillDeep data.

What remains here is **read-only preview** and **diff review**: the agent edits files, you inspect the diff hunk by hunk, then apply or reject. To hand-edit, open the file in whatever editor you already use.

The split exists because the two jobs put attention in different places. An editor is organized around files and the caret; an agent workspace is organized around tasks, workspaces, sessions, and deliverables. One app doing both does neither well.

---

## What it is good at

Everything below already ships. None of it is roadmap.

### Sessions run independently

Each session owns its runtime — messages, request task, tool waiter, composer draft, mode state. Switching away does not interrupt anything; the previous session keeps working in the background, and the sidebar status dot tells you whether it is thinking, waiting on your approval, or stopped.

Concurrency is capped per provider (default 3, tunable 1–8). Providers are isolated, so three DashScope sessions never block an OpenAI one.

### Delegation: three model tiers × five roles

Models collapse into base, advanced, and expert tiers; roles collapse into investigate, implement, verify, review, and operate. You decide which tier serves which role. Tier bindings are read from `~/.willdeep/config.toml` first, sharing one schema with the CLI — the same account will not land on different models depending on which client you happened to open. If the config names a provider this machine does not have, that tier is marked unavailable with a reason instead of silently sending the request to a different gateway.

You can also correct a running subagent: **next round** queues your words for its next turn; **interrupt and send** cancels only its current substep without killing the subagent. Tool chips on the delegation card carry objects — "run command `ruby sync.rb`", "read file `.env.local`" — because that is what you need in order to decide whether to interrupt. Objects are redacted before truncation, so `${secret:…}` becomes `[secret]` before an ellipsis could ever expose which credential it pointed at.

### Four approval levels, deterministic ordering

The levels are strict mode, smart review, workspace write, and full access. Determinism comes first — a malicious-command blocklist stops the command at every level; common read-only commands run immediately; approvals you already remembered apply directly; only when nothing matches does an AI judge get a say. Under smart review, a judge that cannot decide falls back to asking you. Full access never reaches the judge at all: its protection comes entirely from that deterministic blocklist plus the interactions only you can answer.

Destructive operations require typed confirmation at every level, without exception.

Commands run under a seatbelt sandbox by default: no network egress, no writes outside the workspace, environment variables whose names look like token / secret / api_key stripped before the process starts, `HOME` pointed at a temporary directory, `SSH_AUTH_SOCK` and `GITHUB_TOKEN` cleared. When the sandbox denies a command, that is not handed back to the model as an ordinary failure to retry blindly — it pauses and asks whether to re-run without the sandbox. Reading credentials still prompts even with no network egress: once a private key lands in a reply it has already left this machine for the model provider. Executions are written to an audit log with secrets redacted.

### Context accounting uses real usage

Window utilization is anchored to the provider's reported `prompt_tokens`, not local estimation (measured local estimates ran up to 3× low). Past a threshold, older transcript is compressed automatically and stale tool results collapse to placeholders in the request payload while recent turns stay verbatim.

Near the end of the window it performs a **context runway handoff**: the model stops in an orderly way, records where it stopped and what remains, and the reply gets two relay buttons — continue in this session, or open a new session carrying the handoff prompt. The trimming is display-only; the stored message is unchanged.

### Plan progress goes through a tool

Plan progress is reported by the always-on `update_plan` tool instead of a fenced block in the reply. Post-mortems on persisted sessions showed 80% of fenced progress blocks only appeared at the very end of a turn, leaving the checklist frozen on step 1 for the whole run — tool calls are the one channel a model uses reliably mid-turn.

Normal mode does not force a plan up front. The host measures instead: only after a turn actually spends 4 tool rounds or lands 3+ write-level calls does it ask for a plan covering the remaining work. Small tasks pay nothing.

### The work panel: tabs that detach into windows

The right-hand panel holds terminal, files, diff, web preview, media tasks, and image editing views. Tabs coexist, so a terminal or a background job is not evicted because you switched views. A tab can be dragged out into a native standalone window, then located, dragged back, or recalled in bulk. Closing a tab does not kill the process.

The terminal panel is a real terminal — commands the agent runs and commands you type see the same environment.

### Local and remote are the same workflow

Add an SSH host or a `willdeep-agent` daemon under Settings → Runtimes and bind a session to a remote workspace. File search, Git, shell, builds, tests, and delegation all execute remotely while the UI, approvals, and result review stay local. SSH stores only the key file path, never key material; daemon tokens live in Keychain.

```bash
willdeep-agent serve \
  --workspace /path/to/project \
  --token-file ~/.willdeep-agent-token
```

Inside a Git repository you can create, switch, and clean up worktrees straight from the composer's workspace menu. Before high-risk Git mutations WillDeep re-checks the repository revision so it cannot overwrite what a person — or another agent — just landed.

### Four extension points

| Extension | Scope | Notes |
| --- | --- | --- |
| **Skills** | Change how the AI works | 40+ bundled; user skills in `~/.willdeep/skills`, legacy `~/.codex/skills` still read |
| **MCP servers** | Give the AI new real capabilities | stdio and streamable-http; discovery merges app servers, Cursor `mcp.json`, and Codex `config.toml`, with sensitive headers redacted before display |
| **Workflows** | Repeatable multi-step orchestration | `/code-review`, `/pr-review`, `/bug-hunt`, `/release-notes`, `/deep-research`, `/db-explore`, and more; fan-out review dimensions bind to small-model roles and can be stopped anytime |
| **Plugins** | Add a surface you operate directly in the main navigation | Pages run isolated — no network, no file access, no secrets — and must go through commands declared in the manifest, authorized once at install |

Bundled first-party plugins include the arcade, Tetris, favorites, todos, the session vitality dashboard, and project overview. Plugin development docs ship inside the app bundle at `Contents/Resources/BundledSkills/willdeep-plugin-dev/`; asking WillDeep how to build a plugin makes it read that same document.

### Scheduled work

The Scheduled section runs tasks on an interval, daily at HH:MM, on weekdays, or on a specific weekday. Each run opens a fresh session with the configured prompt, workspace, and model tier. Paused tasks say so instead of pretending a next run exists. Recent runs list outcomes and failure reasons and link back to the session that produced them.

### Also worth knowing

- **Goal mode** — long work is split into up to 6 phases, expanding only the current phase's 6-step plan before planning the next. Acceptance criteria are an AI-maintained internal contract; you describe the goal. When a phase ends the host terminates that phase's process tree, so anything that must outlive it has to say so explicitly.
- **Expert roundtable** — ten built-in experts. A prep room sharpens the decision question and recommends 2–4 of them with reasons; the discussion streams for real, and the final document is normalized and saved as Markdown.
- **External executors** — Claude Code, Codex CLI, Cursor Agent, and Cline can take over a turn, but only inside the host's task contract: bounded goal, acceptance criteria, allowed paths, forbidden actions, verification commands, three attempts max. The executor submits an evidence package, a read-only context reviews it, and WillDeep independently re-runs its own safety checks before accepting.
- **Phone** — pair through Mobile Gateway to continue conversations, approve tools, and send images from a phone. Internet relay by default; self-hosted WebSocket relays are supported.
- **Your choice of models** — sign in to the some.im managed service, or configure your own providers and API keys in Settings (keys in Keychain; managed model picks are recommendations you can override).
- **Sessions stay manageable** — grouped by project, searchable, with batch archive/restore/delete. Auto-archive keeps the most recent N per project and protects pinned, running, queued, and unsent-draft sessions.

---

## Get started

### Install

Download the officially signed build from [willdeep.com](https://willdeep.com), or build from source. Requires macOS 13.7+.

### Build from source

```bash
git clone https://github.com/xurenlu/willdeep.git
cd willdeep
open Xedit.xcodeproj
# ⌘R
```

Requires Xcode. The product builds as **WillDeep.app**.

For day-to-day command-line builds, use the shared warm-cache entry point:

```bash
ruby scripts/build_fast.rb             # incremental debug build; no index, no signing
ruby scripts/build_fast.rb --release
ruby scripts/build_fast.rb --sign
```

Caches default to `~/Library/Caches/WillDeep/Xcode/Xedit`; DerivedData, SwiftPM checkouts, and the Xcode compilation cache are reused across terminals. Build reports land in `build/local/build_report.md`. See [local build and test acceleration](docs/BUILD_TEST_ACCELERATION.md) for the full layout.

Run tests through the fast entry point so parallel agents and worktrees do not each pay for a cold build:

```bash
ruby scripts/run_tests_fast.rb -only-testing:XeditTests/YourTestSuite
scripts/run_tests.sh                   # full local gate
```

To install the current worktree's debug build into `/Applications`, put the development credential in the ignored `.env.local`:

```dotenv
WILLDEEP_CLIENT_LOGIN_SECRET=your-local-development-secret
```

Then:

```bash
ruby dev_install.rb --dry-run
ruby dev_install.rb
```

The script never prints the secret. It performs a clean build, signing, atomic installation, and version/signature/injection verification. Fully quit and relaunch WillDeep after replacing a running build.

### Your first task

1. Give it a model source: sign in to some.im, or configure your own provider and key under Settings → AI Providers.
2. Pick a workspace on the left of the composer — a local directory, or a configured remote runtime. It is the boundary for every read, write, and command.
3. Describe the outcome you want. The agent stops and asks when it needs a decision.
4. When it finishes, review the diff, the test output, and the artifacts.

After installing the command line tool from Settings → Tools:

```bash
willdeep-app .
```

It installs into `~/.local/bin`; add that to `PATH` if needed.

---

## Shortcuts

It is an agent-only app, so the list is short:

| Shortcut | Action |
| --- | --- |
| ⌘N | New session |
| Return | Send |
| ⇧/⌥/⌃ + Return | Newline |
| Esc | Dismiss search or the current overlay |
| ⌘? | Open built-in help |

Everything else — approval level, workspace, model, executor, panel tabs — is reachable from the composer and the side panel.

---

## Design stance

Tasks come before files. People want outcomes, not a ceremony organized around tabs.

Run the tests, read the diff, check the state — then call it done. Unverified work is not reported as finished.

Sessions, terminals, branches, and artifacts belong to their workspace and must not leak into one another.

The more capable the agent, the more its approval, secret, and side-effect boundaries need to live in deterministic rules rather than in a model's judgment of the moment.

A beachballed window makes a brilliant model useless. Native performance is the floor, not a bonus.

---

## Status

Active development on `1.315.x`. See [CHANGELOG.md](CHANGELOG.md) for release details and [product-overview.md](product-overview.md) for the full capability matrix and open questions. Release candidate tags follow `vMAJOR.MINOR.PATCH-rcN`.

---

## Contributing

Issues and PRs are welcome. Start here:

- [AgentModeView.swift](Xedit/AgentModeView.swift) — the agent UI
- [AppStateAgentLoop.swift](Xedit/AppStateAgentLoop.swift) — turn loop, tool decisions, context compression
- [AgentToolRegistry.swift](Xedit/AgentToolRegistry.swift) — the tool catalog
- [AgentContextBuilder.swift](Xedit/AgentContextBuilder.swift) — system prompt and context assembly

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

<a id="willdeep-日本語版"></a>

<div align="center">

<img src="appicons/icon_256x256.png" width="128" height="128" alt="WillDeep" />

# WillDeep（日本語版）

**macOS ネイティブのエージェント・ワークスペース。目的を伝えると、現場を読み、手を動かし、検証し、変更と根拠を目の前に戻します。**

[English](#willdeep) · [简体中文](#willdeep-中文版) · **日本語**

</div>

---

*日本語版の README は準備中です。しばらくお待ちください。*
