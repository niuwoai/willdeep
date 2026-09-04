<a id="willdeep-中文版"></a>

<div align="center">

<img src="appicons/icon_256x256.png" width="128" height="128" alt="WillDeep" />

# WillDeep（中文版）

**像运行系统服务一样运行 Agent，而不是开一堆聊天框。**

WillDeep 是开源、原生的 macOS Agent Runtime。它把会话当作彼此隔离的任务，把 Worker、终端、后台 Job、Webhook 和审批变成可路由的事件；该唤醒时唤醒，该中断时中断，最后把 Diff、测试和产物交给你验收。

[![macOS](https://img.shields.io/badge/macOS-13.7%2B-black?logo=apple)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-SwiftUI-orange?logo=swift)](https://developer.apple.com/swift/)
[![Version](https://img.shields.io/badge/version-1.323.0--rc1-blue)](CHANGELOG.md)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue)](LICENSE)
[![GitHub Stars](https://img.shields.io/github/stars/niuwoai/willdeep?style=social)](https://github.com/niuwoai/willdeep/stargazers)
[![GitHub Forks](https://img.shields.io/github/forks/niuwoai/willdeep?style=social)](https://github.com/niuwoai/willdeep/forks)

**[下载 macOS 签名版](https://willdeep.com)** · [3 分钟上手](docs/willdeep-tutorial/01-quick-start.md) · [从源码构建](#从源码编译)

[English](#willdeep) · **简体中文** · [日本語](#willdeep-日本語版)

</div>

---

## Agent 不缺模型，缺的是运行它的系统

一次问答很简单。真正的 Agent 任务会持续几分钟甚至更久：它要派 Worker、等命令、接收外部信号、请求审批、从失败中恢复，还不能把两个项目的事件串台。没有生命周期、调度和权限边界，所谓多 Agent 往往只是一排更难盯的聊天窗口。

WillDeep 借鉴 OS 和 systemd 的机制，把模型放在一个真正能长期运行的宿主里：

- **会话像进程一样隔离**——每个任务拥有自己的工作区、终端、Worker、事件和恢复状态；最多五路 Worker 并行，切走不打断，也不会串台。
- **事件像信号一样精确投递**——Worker 完成、终端变化、后台 Job、Webhook、邮件和审批进入统一事件内核，只唤醒目标会话；普通事件排队，紧急宿主事件可以在安全边界抢占。
- **主 Agent 像 `init + systemd + 调度器`**——它不必死盯一个工具调用，而是响应信号、协调 Worker、释放资源、恢复任务，并把需要你的决定送到 Dock 徽标和事件中心。
- **权限和日志属于系统，不靠模型自觉**——审批、确定性拦截、seatbelt 沙箱、Keychain、持久化事件日志和审计记录共同约束副作用；模型不能给自己提权。

你不必迁移编辑器，也不必押注一个模型。WillDeep 支持 some.im 托管模型、BYOK、自定义 Provider、本地模型，以及 Codex CLI、Claude Code 等外部执行器。

### 这套“Agent OS”具体管什么

| OS / systemd 概念 | WillDeep 中的对应机制 | 你得到什么 |
| --- | --- | --- |
| 进程与服务 | 独立会话、最多五路 Worker、后台终端与 Job | 多件事并行推进，互不串台 |
| 信号与中断 | Runtime 事件信封、排队／边界让出／安全抢占 | 不用轮询盯梢，任务在正确时机醒来 |
| `init` 与调度器 | 主 Agent 协调 Worker、工具、外部连接器和恢复流程 | 长任务可以持续运行，不靠人肉接力 |
| 权限边界 | 四档审批、沙箱、凭据隔离与确定性规则 | Agent 能动手，但不能自行扩权 |
| journal 与状态中心 | 持久化事件、审计、Dock 徽标、Diff、测试和产物 | 发生了什么、谁处理的、结果如何，都能追溯 |

它不是一套新的 macOS，也不是给“Agent OS”换个时髦名字。它是一层专门承载长生命周期 Agent 的运行时与控制面。

## 这不是聊天框，是工作现场

| 从一句目标开始 | 在同一个现场看终端 | 自由选择模型来源 |
| --- | --- | --- |
| <img src="docs/willdeep-tutorial/assets/interface/composer-controls.png" alt="WillDeep 任务输入区" /> | <img src="docs/willdeep-tutorial/assets/interface/terminal-panel.png" alt="WillDeep 可见终端" /> | <img src="docs/willdeep-tutorial/assets/interface/model-picker.png" alt="WillDeep 模型选择器" /> |

## 三步开始

1. **安装**：从 [willdeep.com](https://willdeep.com) 下载签名版，或直接 Fork 本仓库从源码构建。
2. **选择现场**：绑定本地目录、SSH 主机或 `willdeep-agent` daemon，再选择你自己的模型来源。
3. **描述结果**：告诉它你最终想得到什么；需要决策时它会停下来，完成后你检查 Diff、测试和产物。

**[下载 WillDeep](https://willdeep.com)** · [查看图文教程](docs/willdeep-tutorial/README.md) · [⭐ 关注项目](https://github.com/niuwoai/willdeep) · [🍴 Fork 并改成你的工作台](https://github.com/niuwoai/willdeep/fork)

## 为什么它值得开源

WillDeep 会接触真实代码、命令和凭据。对这类工具，“请相信我们”不够——执行边界应该能被检查。核心代码按 Apache 2.0 开源；你可以审查、构建、Fork，也可以只用自己的模型和 runtime。

---

## 它强在哪

下面每一条都是已经落地的机制，不是路线图。

### 它为什么不是另一个编辑器

WillDeep 主动退出了通用编辑器场景。你继续用熟悉的编辑器处理光标和文本；WillDeep 围绕任务、工作区、会话和交付物运转。这里保留只读预览与 **Diff 审阅**：Agent 改完文件，你逐段核对，再决定接受还是拒绝。

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
git clone https://github.com/niuwoai/willdeep.git
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

当前在 `1.317.x` 上活跃迭代。每次发布的具体变化见 [CHANGELOG.md](CHANGELOG.md)，完整能力矩阵与未决问题见 [product-overview.md](product-overview.md)。Release Candidate tag 使用 `vMAJOR.MINOR.PATCH-rcN`。

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

**Run agents like services—not a pile of chat tabs.**

WillDeep is an open-source, native Agent Runtime for macOS. It treats sessions as isolated jobs and turns workers, terminals, background jobs, webhooks, and approvals into routed events—waking or interrupting the right task, then returning the diff, tests, and artifacts for review.

[![macOS](https://img.shields.io/badge/macOS-13.7%2B-black?logo=apple)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-SwiftUI-orange?logo=swift)](https://developer.apple.com/swift/)
[![Version](https://img.shields.io/badge/version-1.323.0--rc1-blue)](CHANGELOG.md)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue)](LICENSE)
[![GitHub Stars](https://img.shields.io/github/stars/niuwoai/willdeep?style=social)](https://github.com/niuwoai/willdeep/stargazers)
[![GitHub Forks](https://img.shields.io/github/forks/niuwoai/willdeep?style=social)](https://github.com/niuwoai/willdeep/forks)

**[Download the signed macOS build](https://willdeep.com)** · [3-minute quick start](docs/willdeep-tutorial/01-quick-start.md) · [Build from source](#build-from-source)

**English** · [简体中文](#willdeep-中文版) · [日本語](#willdeep-日本語版)

</div>

---

## Agents have models. They still need a system.

One answer is easy. A real agent task lasts: it delegates work, waits for commands, receives external signals, asks for approval, recovers from failure, and must never deliver one project's events to another. Without lifecycle, scheduling, and permission boundaries, multi-agent work becomes a row of chat windows that is harder to supervise.

WillDeep borrows the mechanics of operating systems and systemd to give models a host built for long-running work:

- **Sessions are isolated like processes** — each task owns its workspace, terminals, workers, events, and recovery state. Up to five workers can run in parallel without crossing session boundaries.
- **Events are delivered like signals** — worker completion, terminal changes, jobs, webhooks, mail, and approvals enter one runtime kernel and wake only the target session. Ordinary events queue; trusted critical events can safely preempt.
- **The main agent acts like `init + systemd + scheduler`** — it responds to signals, coordinates workers, releases resources, resumes work, and surfaces decisions through the Dock badge and Event Center.
- **Permissions and journals belong to the host** — approvals, deterministic blocks, seatbelt sandboxing, Keychain, durable event logs, and audit records constrain side effects. A model cannot promote itself.

You do not have to replace your editor or bet on one model. Use the some.im managed service, BYOK providers, local models, or external executors such as Codex CLI and Claude Code.

### What this “Agent OS” layer manages

| OS / systemd concept | WillDeep mechanism | What you get |
| --- | --- | --- |
| Processes and services | Isolated sessions, up to five workers, background terminals and jobs | Parallel work without crossed wires |
| Signals and interrupts | Runtime event envelopes with queue, yield, and safe preemption | Tasks wake at the right moment—no manual polling |
| `init` and scheduler | Main-agent coordination across workers, tools, connectors, and recovery | Long-running work without human relay duty |
| Permission boundary | Four approval levels, sandboxing, credential isolation, deterministic rules | Agents can act, but cannot grant themselves access |
| Journal and status center | Durable events, audit trail, Dock badge, diffs, tests, and artifacts | A traceable record of what happened and how it ended |

This is not a replacement operating system, and “Agent OS” is not a costume for another chat app. It is the runtime and control plane for long-lived agents.

## A workbench, not a chat tab

| Start with an outcome | Watch the real terminal | Choose your model source |
| --- | --- | --- |
| <img src="docs/willdeep-tutorial/assets/interface/composer-controls.png" alt="WillDeep task composer" /> | <img src="docs/willdeep-tutorial/assets/interface/terminal-panel.png" alt="WillDeep visible terminal" /> | <img src="docs/willdeep-tutorial/assets/interface/model-picker.png" alt="WillDeep model picker" /> |

## Start in three steps

1. **Install** — download the signed build from [willdeep.com](https://willdeep.com), or fork this repository and build it yourself.
2. **Choose the worksite** — bind a local folder, SSH host, or `willdeep-agent` daemon, then choose your own model source.
3. **Describe the result** — WillDeep pauses when it needs your decision and returns the diff, tests, and artifacts when the work is ready to review.

**[Download WillDeep](https://willdeep.com)** · [Read the visual guide](docs/willdeep-tutorial/README.md) · [⭐ Follow the project](https://github.com/niuwoai/willdeep) · [🍴 Fork your own workbench](https://github.com/niuwoai/willdeep/fork)

## Why open source matters here

WillDeep touches real code, commands, and credentials. “Trust us” is not a sufficient security model for that kind of tool. The core is Apache 2.0: inspect it, build it, fork it, and keep using your own models and runtimes.

---

## What it is good at

Everything below already ships. None of it is roadmap.

### Why it is not another editor

WillDeep deliberately stepped away from general-purpose editing. Keep the editor you already know for text and cursor work; use WillDeep for tasks, workspaces, sessions, and deliverables. It retains read-only preview and **diff review**, so every agent change can be inspected hunk by hunk before you accept or reject it.

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
git clone https://github.com/niuwoai/willdeep.git
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

Active development on `1.317.x`. See [CHANGELOG.md](CHANGELOG.md) for release details and [product-overview.md](product-overview.md) for the full capability matrix and open questions. Release candidate tags follow `vMAJOR.MINOR.PATCH-rcN`.

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

**チャットタブを増やすのではなく、システムサービスのようにエージェントを動かす。**

WillDeep は、OS と systemd の仕組みを取り入れたオープンソースの macOS Agent Runtime です。セッションを独立したジョブとして扱い、Worker、ターミナル、Webhook、承認を正しいタスクへ届けます。

[![macOS](https://img.shields.io/badge/macOS-13.7%2B-black?logo=apple)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-SwiftUI-orange?logo=swift)](https://developer.apple.com/swift/)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue)](LICENSE)
[![GitHub Stars](https://img.shields.io/github/stars/niuwoai/willdeep?style=social)](https://github.com/niuwoai/willdeep/stargazers)
[![GitHub Forks](https://img.shields.io/github/forks/niuwoai/willdeep?style=social)](https://github.com/niuwoai/willdeep/forks)

**[署名済み macOS 版をダウンロード](https://willdeep.com)** · [3分で始める](docs/willdeep-tutorial/01-quick-start.md) · [ソースからビルド](#ソースからビルド)

[English](#willdeep) · [简体中文](#willdeep-中文版) · **日本語**

</div>

---

## Agent にはモデルがある。それでも、動かすためのシステムが必要です

一度の回答なら簡単です。しかし実際の Agent タスクは、Worker への委任、コマンドの完了待ち、外部シグナルの受信、承認の要求、失敗からの復帰まで続きます。しかも、別プロジェクトのイベントを誤ったセッションへ届けてはいけません。ライフサイクル、スケジューリング、権限境界がなければ、マルチ Agent は監視しにくいチャット画面が増えるだけです。

WillDeep は OS と systemd の考え方を取り入れ、長時間動く Agent のためのホストを提供します。

- **セッションをプロセスのように分離** — 各タスクがワークスペース、ターミナル、Worker、イベント、復帰状態を所有します。最大5つの Worker を並列実行しても、セッションをまたいで混線しません。
- **イベントをシグナルのように配信** — Worker の完了、ターミナルの変化、バックグラウンド Job、Webhook、メール、承認を一つの Runtime Kernel に集約し、対象セッションだけを起動します。通常イベントは待機し、ホストが署名した緊急イベントだけが安全境界内で割り込みできます。
- **メイン Agent は `init + systemd + scheduler`** — シグナルに応答し、Worker を調整し、リソースを解放し、タスクを再開します。ユーザーの判断が必要なときは Dock バッジとイベントセンターに集約します。
- **権限と記録はホストが管理** — 4段階の承認、決定論的な遮断、seatbelt サンドボックス、Keychain、永続イベントログ、監査記録が副作用を制御します。モデルが自分で権限を昇格することはできません。

エディタを乗り換える必要も、一つのモデルに賭ける必要もありません。some.im のマネージドモデル、BYOK、独自 Provider、ローカルモデルに加え、Codex CLI や Claude Code などの外部実行系も利用できます。

### この「Agent OS」レイヤーが管理するもの

| OS / systemd の概念 | WillDeep の仕組み | 得られるもの |
| --- | --- | --- |
| プロセスとサービス | 分離されたセッション、最大5つの Worker、バックグラウンドのターミナルと Job | 複数タスクを混線させずに並列実行 |
| シグナルと割り込み | queue／yield／安全な preempt を備えたイベントエンベロープ | 人が監視し続けなくても、必要な時点でタスクが再開 |
| `init` と scheduler | メイン Agent が Worker、ツール、コネクタ、復帰処理を調整 | 長時間タスクを人手で中継しなくてよい |
| 権限境界 | 4段階の承認、サンドボックス、資格情報の分離、決定論的ルール | Agent は実行できるが、自分で権限を増やせない |
| journal と状態センター | 永続イベント、監査、Dock バッジ、Diff、テスト、成果物 | 何が起き、誰が処理し、どう終わったかを追跡可能 |

これは macOS を置き換える OS ではなく、単なるチャットアプリを「Agent OS」と呼び替えたものでもありません。長いライフサイクルを持つ Agent のためのランタイム兼コントロールプレーンです。

## チャット欄ではなく、作業現場

| 目標から始める | 同じ現場でターミナルを見る | モデルの接続先を選ぶ |
| --- | --- | --- |
| <img src="docs/willdeep-tutorial/assets/interface/composer-controls.png" alt="WillDeep のタスク入力欄" /> | <img src="docs/willdeep-tutorial/assets/interface/terminal-panel.png" alt="WillDeep の可視ターミナル" /> | <img src="docs/willdeep-tutorial/assets/interface/model-picker.png" alt="WillDeep のモデル選択" /> |

## 3ステップで開始

1. **インストール** — [willdeep.com](https://willdeep.com) から署名済み版をダウンロードするか、このリポジトリを Fork してビルドします。
2. **作業場所を選択** — ローカルフォルダ、SSH ホスト、または `willdeep-agent` daemon を接続し、利用するモデルを選びます。
3. **ほしい結果を伝える** — 判断が必要な場面では WillDeep が停止して確認し、完了時には Diff、テスト、成果物を返します。

**[WillDeep をダウンロード](https://willdeep.com)** · [図解チュートリアル](docs/willdeep-tutorial/README.md) · [⭐ プロジェクトをフォロー](https://github.com/niuwoai/willdeep) · [🍴 自分用に Fork](https://github.com/niuwoai/willdeep/fork)

## なぜオープンソースなのか

WillDeep は実際のコード、コマンド、資格情報を扱います。この種類のツールに「私たちを信じてください」だけでは不十分です。コアは Apache 2.0 で公開されており、コードと実行境界を確認し、自分でビルドし、Fork し、自分のモデルと Runtime だけで使えます。

---

## WillDeep が得意なこと

以下はロードマップではなく、すでに実装されている機能です。

### もう一つのエディタではありません

WillDeep は汎用編集機能を意図的に切り離しました。テキストやカーソル操作には使い慣れたエディタを使い、WillDeep はタスク、ワークスペース、セッション、成果物を管理します。ファイルは読み取り専用でプレビューでき、Agent の変更は **Diff レビュー**で hunk ごとに確認してから採用または拒否できます。

### セッションは独立して動きます

各セッションは、メッセージ、Provider リクエスト、ツール待機、入力中の下書き、モード状態を含む独立 Runtime を持ちます。別のセッションへ移動しても処理は止まらず、サイドバーで実行中、承認待ち、停止を確認できます。

同一 Provider の同時実行数は既定で3、設定では1〜8に変更できます。Provider ごとに枠が分かれているため、DashScope の混雑が OpenAI の処理を止めることはありません。

### 委任：3段階のモデル × 5つの役割

モデルは基本・上位・エキスパートの3段階、役割は調査・実装・検証・レビュー・運用の5種類に整理されています。どの役割にどの段階を使うかはユーザーが設定できます。設定は `~/.willdeep/config.toml` を優先し、CLI と同じ Schema を共有します。存在しない Provider を指定した場合、別 Gateway へ黙ってフォールバックせず、利用不可の理由を表示します。

実行中の子 Agent にも介入できます。「次のラウンドで反映」は指示を次ターンへ追加し、「割り込んで送信」は子 Agent 全体を終了せず現在のサブステップだけをキャンセルします。委任カードには「`ruby sync.rb` を実行」「`.env.local` を読む」のように対象も表示され、機密情報は省略前にマスクされます。

### 4段階の承認と決定論的な判定順序

承認レベルは厳格、スマート審査、ワークスペース書き込み、フルアクセスの4段階です。どの段階でも悪意あるコマンドの遮断が最優先され、一般的な読み取り専用コマンドと記憶済みの承認を先に処理し、それでも決まらない場合だけ AI 判定を使います。破壊的操作はどの段階でもユーザーによる入力確認が必要です。

コマンドは既定で seatbelt サンドボックス内に入り、ネットワーク送信、ワークスペース外への書き込み、Token や Secret に見える環境変数を制限します。サンドボックスで拒否された場合、モデルに盲目的な再試行をさせず、サンドボックスなしで再実行するかをユーザーに確認します。実行履歴は機密情報をマスクして監査ログへ保存します。

### 実際の使用量でコンテキストを管理

コンテキスト使用率はローカル推定ではなく、Provider が返す `prompt_tokens` を基準にします。しきい値を超えると古い会話を圧縮し、古いツール結果をプレースホルダーへ畳みますが、直近のターンはそのまま保持します。

上限に近づくと **context runway handoff** を実行し、現在位置と残作業を記録して、同じセッションまたは新しいセッションへ引き継げます。保存済みメッセージの原文は変更しません。

### 進捗はツール経由で報告

計画の進捗は、回答内のコードブロックではなく常設の `update_plan` ツールで更新します。通常モードでは最初から計画作成を強制せず、実際に長いツール実行や複数の書き込みが発生した場合だけ、残作業の計画を求めます。小さなタスクに儀式を増やしません。

### タブを独立ウインドウにできる作業パネル

右側のパネルにはターミナル、ファイル、Diff、Web プレビュー、メディアタスク、画像編集を並べられます。タブは共存し、ドラッグして macOS の独立ウインドウにしたり、元へ戻したりできます。タブを閉じてもプロセスは終了しません。

ターミナルは実物です。Agent が実行したコマンドとユーザーが入力したコマンドは、同じ環境で動きます。

### ローカルとリモートで同じワークフロー

設定の Runtimes に SSH ホストまたは `willdeep-agent` daemon を追加すると、リモートのワークスペースへセッションを接続できます。ファイル検索、Git、Shell、ビルド、テスト、委任はリモートで実行し、UI、承認、結果レビューは Mac に残ります。SSH は秘密鍵のパスだけを保存し、daemon Token は Keychain に保存します。

```bash
willdeep-agent serve \
  --workspace /path/to/project \
  --token-file ~/.willdeep-agent-token
```

Git リポジトリでは入力欄から worktree の作成、切り替え、整理ができます。危険度の高い Git 操作の前には revision を再確認し、人や別 Agent が直前に行った変更を上書きしないようにします。

### 4つの拡張ポイント

| 拡張 | 役割 | 内容 |
| --- | --- | --- |
| **Skills** | AI の作業方法を変える | 40以上を内蔵。ユーザー Skill は `~/.willdeep/skills` に配置し、従来の `~/.codex/skills` も読み込みます |
| **MCP servers** | AI に実際の機能を追加 | stdio と streamable-http に対応。App、Cursor `mcp.json`、Codex `config.toml` の設定を統合し、機密 Header は表示前にマスクします |
| **Workflows** | 複数ステップを再利用 | `/code-review`、`/pr-review`、`/bug-hunt`、`/release-notes`、`/deep-research`、`/db-explore` など。並列レビューはいつでも停止できます |
| **Plugins** | メインナビゲーションに操作画面を追加 | ページはネットワーク、ファイル、Secret から隔離され、Manifest で宣言してインストール時に許可されたコマンドだけを利用します |

同梱の公式 Plugin にはゲームセンター、テトリス、お気に入り、Todo、セッション診断、プロジェクト概要があります。Plugin 開発資料は App Bundle の `Contents/Resources/BundledSkills/willdeep-plugin-dev/` に含まれています。

### スケジュール実行

「スケジュール済み」では、一定間隔、毎日、平日、指定曜日にタスクを実行できます。実行ごとに設定済みの Prompt、ワークスペース、モデル段階を持つ新しいセッションを作ります。一時停止中のタスクは明示され、最近の実行結果と失敗理由から元セッションへ戻れます。

### そのほかの主な機能

- **Goal モード** — 長い仕事を最大6フェーズに分け、現在のフェーズだけを最大6ステップで展開します。フェーズ完了時には、そのフェーズで開始したプロセスツリーを安全に終了します。
- **専門家ラウンドテーブル** — 10人の組み込み専門家から2〜4人を理由付きで推薦し、議論をストリーミング表示して、最終結果を Markdown に保存します。
- **外部実行系** — Claude Code、Codex CLI、Cursor Agent、Cline を、目標、受入条件、許可パス、禁止操作、検証コマンド、最大3回の試行を持つタスク契約の中で利用できます。
- **スマートフォン連携** — Mobile Gateway とペアリングして、会話の継続、ツール承認、画像送信ができます。公式 Relay とセルフホスト WebSocket Relay に対応します。
- **モデルを自由に選択** — some.im へログインするか、自分の Provider と API Key を設定できます。Key は Keychain に保存されます。
- **セッション管理** — プロジェクト別のグループ、検索、一括アーカイブ／復元／削除、自動アーカイブに対応し、実行中や下書きのあるセッションを保護します。

---

## 使い始める

### インストール

[willdeep.com](https://willdeep.com) から公式署名済み版をダウンロードするか、ソースからビルドします。macOS 13.7 以降が必要です。

### ソースからビルド

```bash
git clone https://github.com/niuwoai/willdeep.git
cd willdeep
open Xedit.xcodeproj
# ⌘R
```

Xcode が必要です。生成される App は **WillDeep.app** です。

日常のコマンドラインビルドには、共有ウォームキャッシュを使う入口を利用します。

```bash
ruby scripts/build_fast.rb             # Debug の増分ビルド。Index と署名は省略
ruby scripts/build_fast.rb --release   # Release ビルド
ruby scripts/build_fast.rb --sign      # 署名が必要な場合
```

キャッシュは既定で `~/Library/Caches/WillDeep/Xcode/Xedit` に保存され、DerivedData、SwiftPM checkout、Xcode compilation cache を再利用します。詳細は[ローカルビルドとテストの高速化](docs/BUILD_TEST_ACCELERATION.md)を参照してください。

テストも高速入口を優先してください。

```bash
ruby scripts/run_tests_fast.rb -only-testing:XeditTests/YourTestSuite
scripts/run_tests.sh                   # ローカルの完全なテストゲート
```

現在の worktree の Debug 版を `/Applications` へインストールする場合は、Git 管理外の `.env.local` に開発用資格情報を設定します。

```dotenv
WILLDEEP_CLIENT_LOGIN_SECRET=your-local-development-secret
```

```bash
ruby dev_install.rb --dry-run
ruby dev_install.rb
```

スクリプトは Secret を表示せず、クリーンビルド、署名、アトミックなインストール、バージョンと署名の検証を行います。実行中の WillDeep を置き換えた場合は、完全に終了してから再起動してください。

### 最初のタスク

1. some.im にログインするか、設定 → AI Provider で自分の Provider と Key を登録します。
2. 入力欄の左側でローカルディレクトリまたは設定済みのリモート Runtime を選びます。ここが読み取り、書き込み、コマンドの境界になります。
3. 欲しい結果をそのまま入力します。判断が必要なときは Agent が停止して確認します。
4. 完了後に Diff、テスト結果、成果物を確認します。

設定 → ツールからコマンドラインツールをインストールすると、次のように起動できます。

```bash
willdeep-app .
```

ツールは `~/.local/bin` にインストールされます。必要に応じて `PATH` に追加してください。

---

## ショートカット

| ショートカット | 操作 |
| --- | --- |
| ⌘N | 新しいセッション |
| Return | 送信 |
| ⇧/⌥/⌃ + Return | 改行 |
| Esc | 検索または現在のポップアップを閉じる |
| ⌘? | 組み込みヘルプを開く |

承認レベル、ワークスペース、モデル、外部実行系、パネルタブは入力欄とサイドパネルから操作できます。

---

## 設計方針

ファイルよりタスクを優先します。ユーザーが欲しいのは、タブを巡回する儀式ではなく結果です。

テストを実行し、Diff を読み、状態を確認してから完了とします。未検証の仕事を完了とは報告しません。

セッション、ターミナル、ブランチ、成果物はそれぞれのワークスペースに属し、別の作業へ漏れてはいけません。

Agent が強力になるほど、承認、Secret、副作用の境界はモデルのその場の判断ではなく、決定論的ルールで管理する必要があります。

優秀なモデルでも、画面が応答しなければ役に立ちません。Native Performance は付加価値ではなく最低条件です。

---

## 開発状況

現在は `1.317.x` 系を開発中です。各リリースの変更は [CHANGELOG.md](CHANGELOG.md)、機能一覧と未解決事項は [product-overview.md](product-overview.md) を参照してください。Release Candidate の Tag は `vMAJOR.MINOR.PATCH-rcN` 形式です。

---

## コントリビューション

Issue と Pull Request を歓迎します。最初に読む場所：

- [AgentModeView.swift](Xedit/AgentModeView.swift) — Agent UI
- [AppStateAgentLoop.swift](Xedit/AppStateAgentLoop.swift) — ターンループ、ツール判定、コンテキスト圧縮
- [AgentToolRegistry.swift](Xedit/AgentToolRegistry.swift) — ツールカタログ
- [AgentContextBuilder.swift](Xedit/AgentContextBuilder.swift) — System Prompt とコンテキスト生成

Pull Request を作成するとき：

1. リポジトリのバージョン規則に従います。Bugfix は `-rcN` だけを増やし、新機能の場合だけ正式バージョン部分を変更します。
2. CHANGELOG を更新し、何を変えたかだけでなく、なぜ必要だったかも説明します。
3. 新しい UI 文言は必ずローカライズリソースを使います。
4. 起動、入力、長いセッションの性能を悪化させないでください。Hot Path を変更する場合は Profile を確認します。

---

## ライセンスと Open Core

WillDeep は [Apache License 2.0](LICENSE) と [Open Core](OPEN_CORE.md) のモデルを採用しています。

個別ファイルに別記がない限り、このリポジトリのコードは Apache 2.0 で公開されます。WillDeep の名称、Logo、公式署名済み Build、ホスティングサービス、Cloud Sync、Managed Runtime、Team 機能、Marketplace、Enterprise Support は別の製品またはサービスとして提供される場合があります。すでに Apache 2.0 で公開されたコードは、今後も Apache 2.0 のままです。
