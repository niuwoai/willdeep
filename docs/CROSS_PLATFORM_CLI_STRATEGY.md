# WillDeep 跨平台 CLI 与 Agent Core 战略

> 状态：提案（v2 修订版）
> 日期：2026-08-09（v2 同日修订：吸收评审意见与三项创始人决策——融合顺序、开源与商业模式、市场进入策略）
> 目标：确定 WillDeep 跨平台 CLI 的技术选型、开源复用策略、商业模式、产品差异化与落地路线。

## 1. 执行摘要

WillDeep 应推出覆盖 macOS、Linux 与 Windows 的 CLI，但不应把它做成另一个"终端里的模型聊天框"。产品应定位为一个支持长任务、多 Agent、跨设备接管和结果验证的 Coding Agent 控制平面。

核心决策如下：

1. 新的跨平台 Agent Core、CLI 和 TUI 优先采用 Rust；该选型附带前提条件（见 3.2），阶段 0 结束时验收。
2. 现有 Go `willdeep-agent` 暂时保留，继续承担移动网关、协作 Relay、Chrome Native Host 等已稳定能力。
3. SwiftUI macOS App 继续作为体验最完整的桌面控制台。**Rust CLI 先独立发展到成熟，不预设与 Swift App 的融合时间表**；融合风险用"协议先行"对冲（见第 6 节）。
4. 通过 ACP 和 JSON-RPC 接入现有 Agent，先获得成熟执行能力，再逐步建设原生 WillDeep Runtime。阶段 0 必须双轨验证（Codex App Server + 纯 ACP Agent 备胎）。
5. 不完整 Fork Codex、Goose 或 OpenCode；协议和成熟组件可以复用，WillDeep 自己掌握任务编排、会话、权限、验证和跨设备能力。
6. **CLI 与 Core 以 Apache-2.0 开源，"WillDeep"商标单独保护；some.im 服务端闭源**。商业模式是"开源客户端、售卖控制平面"，算力转售只是便利性收入（见第 7 节）。
7. some.im 深度集成但**不是使用 CLI 的必要条件**：BYOK 与本地模型下全功能可用。
8. 市场进入采用双楔子：**国内市场为主攻方向，跨设备体验为全球叙事**；ACP 控制端定位作为零迁移成本的获客钩子（见第 8 节）。
9. 首发差异化收敛为"关闭终端窗口后任务仍继续（本机 daemon）+ 手机审批与接管（现有 Relay）"；"合盖漫游/远程 Runtime"明确属于阶段 3，首发宣传不承诺。
10. 成本策略以**"每个验收通过任务的总成本"为北极星**，构建由托管闭环数据驱动的模型路由飞轮；便宜是结果，不是卖点（见 7.5 与 [COST_ENGINE_DESIGN.md](COST_ENGINE_DESIGN.md)）。

## 2. 背景与目标

当前 WillDeep 的主要产品形态是 macOS 原生应用。项目已经具备较强的 Agent 能力，包括会话、工具调用、审批、Skills、MCP、多 Agent、Goal、worktree、后台任务、移动网关和协作连接器等，但多数核心逻辑与 Swift、SwiftUI 和 macOS 系统能力存在不同程度的耦合（Swift 代码约 23 万行）。

CLI 项目的目标不是复制整个 macOS UI，而是建立一个真正跨平台、可供多个客户端共享的 Agent Runtime：

- macOS、Linux、Windows 单文件或低依赖分发；
- 交互式 TUI 和无交互自动化模式；
- CLI、macOS App、移动端和协作平台共享任务状态；
- 支持接入其他 Agent，也支持运行原生 WillDeep Agent；
- 可持续执行、可恢复、可审批、可审计、可验证；
- 与 some.im 账号体系无缝衔接，同时保持无账号可用。

## 3. 语言选型

### 3.1 Go 与 Rust 对比

| 维度 | Go | Rust |
|---|---|---|
| MVP 开发速度 | 较快 | 前期较慢 |
| 跨平台单文件分发 | 成熟 | 成熟 |
| TUI | Bubble Tea 生态成熟 | Ratatui 生态成熟 |
| 网络服务与网关 | 非常适合 | 适合 |
| PTY、进程和沙箱 | 可以实现 | 更适合精细控制和安全边界 |
| 内存与并发安全 | 工程简单 | 编译期保障更强 |
| Coding Agent 生态 | Crush 等 | Codex、Goose、ACP 等 |
| ACP 官方 SDK | **无** | 有（另有 TS/Python/Kotlin/Java） |
| 长期底层 Core | 合格 | 更优 |
| 团队学习和维护成本 | 较低 | 较高 |

### 3.2 决策与成立前提

战略核心选择 Rust。诚实的理由排序如下：

1. ACP 官方 SDK 覆盖 Rust、TypeScript、Python、Kotlin、Java，**唯独没有 Go**；自行维护 Go 侧协议实现是纯负债。
2. 阶段 2 原生 Core 需要沙箱（seatbelt / Landlock / Windows Job Object）与 PTY 的精细控制，Rust 在该层生态最厚。
3. 周边可复用生态以 Rust 为主：[OpenAI Codex](https://github.com/openai/codex)（Apache-2.0，已拆分 `core`、`exec`、`tui`、`app-server` 模块）、[Goose](https://github.com/aaif-goose/goose)（Apache-2.0，Linux 基金会 AAIF 旗下）、[ACP Rust SDK](https://github.com/agentclientprotocol/agent-client-protocol)（Apache-2.0）。
4. AI 辅助开发已显著降低 Rust 的上手与维护成本。

**成立前提（阶段 0 验收项）**：Rust 相对 Go 的优势必须落在 crate 级复用与底层控制上。若阶段 0 结束时 4.5 节的 crate 级复用清单落空、实际只做协议级复用，则 Rust 选型的核心论据不成立，必须重新评估（届时 Go 的开发速度与团队既有维护经验将占优）。不允许"因为已经写了一些 Rust"而跳过这次重估。

### 3.3 Go 的保留范围

选择 Rust 不意味着立即重写现有 Go 代码。`willdeep-agent` 已有能力应继续工作，通过协议与新 Core 协作：

- 移动端 LAN Gateway；
- 飞书等协作平台 Relay；
- Chrome Native Messaging Host；
- 远程 Runtime 服务和平台探测；
- 已有稳定测试覆盖的服务能力。

只有当迁移能显著减少维护成本或消除协议开销时，才考虑把对应模块迁入 Rust。不得为了语言统一而重写正常工作的服务。

### 3.4 为什么不是 Swift 跨平台（记录在案，防止翻案）

"复用现有 23 万行 Swift 资产"是最直觉的选项，评审后明确否决，理由：

- 现有代码库以 MainActor 全仓默认隔离，且与 AppKit/SwiftUI 深度纠缠，抽取纯核心的成本接近重写；
- Swift on Linux 可用但生态薄，Swift on Windows 工具链不成熟，与"三平台单文件分发"目标冲突;
- 跨平台 Swift 团队/社区可借力的 Coding Agent 生态为零。

**Swift 资产的复用形式是"契约测试与协议规范"，不是代码**（见第 6 节）。

## 4. 开源复用策略

### 4.1 不从头重造基础设施

以下能力已经属于 Coding Agent 的基础设施，不应成为主要研发投入：

- 模型流式传输和 Tool Call 解析；
- Shell、PTY 和进程生命周期；
- 文件读取、搜索、编辑与补丁应用；
- MCP、Skills、上下文压缩；
- 基础审批、Diff、会话恢复和 TUI 渲染；
- 常规 Provider 适配。

WillDeep 应优先复用协议、设计和许可证允许的成熟组件，把研发资源投入任务编排、长任务可靠性、跨设备体验和结果验证。

### 4.2 候选项目

| 项目 | 技术 | 许可证 | 适合复用或借鉴的部分 | 主要风险 |
|---|---|---|---|---|
| OpenAI Codex | Rust | Apache-2.0 | Core、沙箱、审批、执行协议、App Server | 上游迭代快，部分能力偏 OpenAI |
| Goose | Rust | Apache-2.0 | 多 Provider、MCP、ACP、桌面与 CLI 协同 | 产品范围较宽，直接 Fork 容易背负大量代码 |
| OpenCode | TypeScript | MIT | 多客户端架构、Provider 生态、交互设计 | 引入 Bun/TypeScript Runtime，与 Rust Core 方向不一致 |
| Aider | Python | Apache-2.0 | Repo Map、编辑策略、自动测试和提交 | Python 分发与目标架构不一致 |
| Crush | Go | FSL-1.1-MIT | TUI、LSP、多 Provider | FSL 不是即时 MIT，商用复用必须单独审查 |
| ACP | 协议/多语言 SDK | Apache-2.0 | Agent 与客户端的标准连接层 | 能力仍在演进，需保留兼容层 |

### 4.3 复用原则

1. 优先依赖稳定协议，而不是依赖上游内部实现。
2. 优先通过进程边界或适配层连接，不直接绑定快速变化的 Git 主分支。
3. 必须保留第三方代码的许可证、NOTICE 和来源记录。
4. 对许可证、商标、订阅认证和 OAuth 使用范围进行专项审查。
5. 不把第三方项目换名后直接作为 WillDeep 发布。
6. 对关键上游依赖设置版本锁定、兼容测试和退出方案。

### 4.4 推荐实施模式

第一阶段把 WillDeep 建设成 ACP 控制端，同时支持原生 Runtime：

```text
WillDeep CLI / macOS App / Mobile
                 │
        WillDeep Control Plane
                 │ ACP / JSON-RPC
       ┌─────────┼──────────┐
     Codex     Goose    WillDeep Core
```

Codex 已提供面向丰富客户端的 [`app-server`](https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md)，包含 Thread、Turn、事件、审批、Skills 和认证协议。初期应优先采用 stdio JSONL；其 WebSocket 传输当前仍属于实验能力，不应直接作为生产依赖。

**双轨硬要求**：`app-server` 是 OpenAI 的内部快节奏协议，不是稳定公共契约。阶段 0 必须同时打通一个纯 ACP Agent（首选 Goose）作为备胎，任何阶段的退出条件都不得只绑定 Codex。

### 4.5 crate 级复用清单（Rust 选型的验收项）

阶段 0 结束时必须产出一份具体清单，明确以 crate/vendored 形式复用哪些组件（候选：`codex-rs` 的沙箱策略层 seatbelt/Landlock、apply-patch/diff 组件、ACP Rust SDK、ratatui、tree-sitter、Goose 的 Provider 适配层），并对每项记录：版本锁定方式、许可证义务、上游断供时的退出方案。清单落空即触发 3.2 的选型重估。

## 5. 产品差异化

### 5.1 已经商品化的能力

以下能力只能作为入场券，不能作为主要宣传点：

- 多模型与自定义 Provider；
- MCP 和 Agent Skills；
- 漂亮的终端 UI；
- 文件编辑、Shell 和 Git；
- Plan/Build 模式；
- 基础子 Agent；
- LSP 和代码搜索；
- 单机 session resume。

OpenCode、Crush、Codex、Goose 和 Aider 已不同程度覆盖这些能力。WillDeep 如果只做同类功能，很难建立清晰认知。

### 5.2 核心定位与首发承诺的物理边界

> WillDeep 是可以离开终端、跨设备接管、由多个 Agent 持续完成并验证任务的 Coding Agent。

用户交付的不是一次 Prompt，而是一个工程目标：

```bash
willdeep goal "完成支付模块重构，跑完测试并准备 PR"
```

理想执行过程：

1. 自动创建隔离 worktree。
2. Planner 分解目标和验收条件。
3. Implementer、Tester、Reviewer 分工执行。
4. 用户关闭终端后任务继续运行。
5. 高风险操作推送到 macOS、手机或协作平台审批。
6. 用户可以在任意客户端追加要求或接管任务。
7. 任务结束后交付代码、Diff、测试证据、风险和未验证事项。

**首发承诺必须与 runtime 常驻位置对齐**：任务跑在本机 `willdeep serve` daemon 上——关闭终端窗口任务继续、手机可审批（走现有 Relay），这两条 v1 可以兑现；但笔记本合盖即休眠，"人走了任务还在跑"的完整体验依赖远程 Runtime，属于阶段 3。首发文案、demo 脚本一律使用"关闭终端窗口"表述，不使用"合上电脑"表述。

### 5.3 三层护城河

#### 跨界面连续性

- CLI 发起、macOS App 观察；
- 手机审批和接管；
- 飞书等协作平台追加信息；
- 同一任务、会话、工作树和审计记录；
- 本地 Runtime 与远程 Runtime 可以切换（远程为阶段 3）。

#### 多 Agent 工程工作流

- Planner：分解任务与验收标准；
- Implementer：在隔离 worktree 中实现；
- Tester：运行并解释验证结果；
- Reviewer：对 Diff 和风险给出阻断意见；
- Integrator：判断是否满足合并条件；
- Roundtable：对高风险设计进行多角色讨论；
- 失败后可以重试、缩小任务或切换模型。

#### 可验证与可治理

- 每项结论附带测试或检查证据；
- 区分"已验证""合理推断""尚未验证"；
- 命令、文件变更和网络访问可审计；
- 支持工作区、目录、命令和工具级权限；
- 企业可配置禁止自动执行的操作；
- 追踪 Token、费用、耗时、成功率和模型表现；
- 中断后可以恢复，不依赖单次模型上下文。

## 6. Swift 资产与融合顺序

### 6.1 决策：先独立，后融合

Rust CLI 先独立发展到成熟，**不预设与 Swift App 的融合时间表**。理由：Swift App 已经过多个版本的打磨融合，现在强行定融合方案只会同时拖慢两边。融合重估的触发点定在阶段 2 退出条件达成之后（原生 Core 可独立承担常用任务时），届时再评估 macOS App 是否切换到 Rust Core 作为 runtime。

### 6.2 漂移风险与"协议先行"保险

独立发展的真实风险不是融合太晚，而是**两边领域模型漂移**——Swift App 每周迭代，等 CLI 成熟时双方可能已长成两个物种。对冲手段只有一个，且必须从 Rust 侧第一天执行：

- Task / Session / Approval / Event 的 schema 是**有版本号的公开契约**，schema 即事实之源，代码由 schema 生成；
- Swift 侧短期不必接入，但新增领域概念时必须对照该 schema 命名与建模；
- 协议 schema 版本独立于产品版本演进，破坏性变更必须有迁移说明。

### 6.3 领域不变量 → 契约测试

Swift 侧多年踩坑沉淀的不变量，以契约测试形式移交 Rust Core，不移交代码。首批清单：

- **后台任务唤醒链**：恢复路径上每个 guard 提前退出都必须有事后补触发，不允许静默丢失唤醒；
- **辅助请求预算**：压缩/摘要类辅助请求必须走与主请求相同的上下文折叠管线并分块，否则窗口满时必然失败；
- **会话落盘保序**：写盘走串行队列，seq 票据保序，加载时先取快照再叠加增量；
- **消息不丢失**：用户消息的持久化/展示必须先于并发资源（provider 槽位等）的获取，抢不到资源不等于消息消失；
- **审批链路**：每个审批决策必须可审计，裁判失败必须显式降级而不是静默放行。

Rust 实现对照契约测试开发，教训不重复交学费。清单随开发持续扩充。

## 7. 开源与商业模式

### 7.1 开源决策

**CLI 必须开源。** 2026 年一个闭源的、拥有 shell 执行权限的 CLI Agent 无法获得开发者信任——Codex、Goose、OpenCode、Crush、Gemini CLI 全部开源，闭源在此品类不是差异化而是出局条件；对新品牌尤其如此，信任只能靠可审计换取。开源同时是第 8 节市场策略的传播渠道本身。

开源边界：

| 范围 | 内容 | 许可证/策略 |
|---|---|---|
| **开源** | Rust CLI、TUI、Core、工具层、Provider 适配、ACP 接入、协议 schema | Apache-2.0；"WillDeep"商标单独注册保护，防换皮 Fork |
| **闭源** | some.im 服务端：跨设备中继、云端会话同步、远程 Runtime 托管、审批推送、计费、团队与审计 | 专有 |
| **闭源** | macOS SwiftUI App、移动端 | 专有（现状不变） |

许可证选 Apache-2.0 而非 FSL/BUSL 类"延迟开源"：后者损害社区信任与传播（Crush 的 FSL 至今被社区侧目），而我们的护城河本就不在客户端代码里。

### 7.2 some.im 集成原则

- **硬约束：some.im 不是使用 CLI 的必要条件。** BYOK（自带 API Key）与本地模型下 CLI 全功能可用，单机体验不打折。
- `willdeep login` 走 OAuth Device Flow（设备码），凭据进入系统 Keychain / Secret Service / Credential Manager，复用 SomeIMSharedSession 已确立的账号语义；
- 登录后即获得：免配置模型接入、统一计费、模型路由（someim-judge 体系）、跨设备中继与审批推送；
- 日志、会话同步和 Relay 不得包含明文 Token。

### 7.3 分层模型

| 层 | 内容 |
|---|---|
| 免费·无账号 | BYOK / 本地模型，全功能单机使用 |
| 免费·some.im 账号 | 设备码登录、少量赠送算力、基础云同步、手机审批限量 |
| 付费 | 算力包 + 远程 Runtime、无限跨设备接管、团队 / 审计 / 权限策略 |

### 7.4 卖平面，不卖算力

纯算力转售是毛利竞次的生意：用户随时可以 BYOK，转售赚的只是搬运费。some.im 真正的订阅型收入是**控制平面**——跨设备接管必然需要一个会合服务器，那个服务器就是 some.im。算力包定位为便利性收入（"懒得配 key，登录就能用"），平面能力（中继、同步、远程 Runtime、团队治理、成本引擎）才是主菜。定价与包装围绕平面设计，不围绕 token 单价打价格战。

### 7.5 成本引擎与路由飞轮

"成本特别低"可以成为拉开差距的武器，但必须换度量、换打法：

- **裸便宜不是护城河**：deepseek-v4-flash 谁都能调，供给端没有独占；模型价格本身每年下跌一个数量级；而最贵的 token 是失败任务的 token——便宜模型失败三次的总价超过好模型一次成功，还搭上用户信任。
- **北极星指标：每个验收通过任务的总成本**（含失败重试与升档开销），不是每 token 单价。
- **真护城河是路由飞轮**：托管模式 + 可验证交付 = 闭环数据。任务分类 → 模型选择 → 执行 → 测试通过/失败（真实标签）→ 路由器越用越准。纯 API 转售商看不到任务结局，模型厂看不到跨模型对比，只有我们能闭环。**可验证交付由此获得第二个存在理由：它是成本引擎的训练标签。**
- **升降档纪律**：默认便宜、显式升档（触发条件只有三条：Planner 复杂度判定、验证失败 N 次、用户指定），**绝不静默降档**，每任务出账单收据。
- **成本杠杆按收益排序**：prompt caching（命中省约 90%，最大头）> 上下文折叠纪律 > 升降档路由 > 短窗口子 agent > 后台错峰/batch。多 agent 本身不省钱，窄上下文的子任务分工才省钱。
- **定位卖"聪明花钱"，不卖"便宜货"**：账单收据与验收报告是同一张纸；月度省钱报表是国内开发者社区的天然传播物料，同时为楔子二供弹。
- 客户端与服务端的完整协同设计（分工、六大机制、飞轮、隐私红线、分阶段落地）见 [COST_ENGINE_DESIGN.md](COST_ENGINE_DESIGN.md)。其中托管专属能力（实时路由、缓存亲和、错峰调度、飞轮优化）正是 7.4 "卖平面"的实体之一——**托管比 BYOK 更省钱是产品目标**，用调度和飞轮赚出的差价比转售差价体面得多。

## 8. 市场进入策略

### 8.1 现实判断

在全球通用 CLI Agent 市场上正面追赶 Codex / Claude Code / Gemini CLI 不现实——对手背后是模型厂补贴与自带分发。后发者靠楔子取胜，不打全面战争。WillDeep 有两个真实楔子。

### 8.2 楔子一：跨设备平面（全球叙事）

竞品全部是单进程 CLI，没有一家同时拥有已上线的手机端、中继服务和桌面 App——这是 12-18 个月的基建先发优势。核心动作：

- 打磨一个 **5 分钟内可复现的 wow 时刻**：CLI 里扫码 → 手机秒连 → 危险操作推送到手机审批 → 躺在沙发上接管任务；
- 窗口期意识：大厂迟早做手机审批。护城河不是点子而是已经在跑的网关 + Relay + 账号体系，必须趁窗口期把品类认知钉死——"能离开终端的那个 Agent"。

### 8.3 楔子二：国内市场（主攻方向）

美系 CLI 在国内全员水土不服：登录墙、网络墙、付款墙。WillDeep CLI 第一天就能做到：

- 开箱即用，无需翻墙；
- DeepSeek / Qwen / GLM / Kimi 等国产模型一等公民；
- 飞书原生集成（Relay 已存在）；
- 人民币计费，some.im 作为国内友好的算力网关。

Go-to-market 以楔子二为主攻、楔子一为产品叙事：国内市场先站住，跨设备故事做全球传播（GitHub / HN / V2EX 各讲各的版本）。

### 8.4 ACP 柔道：寄生层定位

不喊"换掉你的 Codex"，喊"**你的 Codex / Goose 照用，套上 WillDeep 就多出后台长任务、手机审批和验收报告**"。ACP 控制端架构让迁移成本归零——先做现有 Agent 之上的增值层获客，等原生 Core 成熟后用户自然滑入。这是后发者的经典柔道：做增量层，不做替代品。

## 9. 目标架构

```text
┌───────────────────────────────────────────────┐
│ Clients                                       │
│ Rust CLI/TUI · macOS SwiftUI · Mobile · IM   │
└──────────────────────┬────────────────────────┘
                       │ ACP / WillDeep RPC
┌──────────────────────▼────────────────────────┐
│ WillDeep Control Plane                        │
│ Goal · Session · Approval · Event · Handoff  │
└──────────────┬───────────────────┬─────────────┘
               │                   │
┌──────────────▼────────────┐ ┌────▼─────────────┐
│ WillDeep Rust Core        │ │ External Agents │
│ Loop · Tools · Sandbox    │ │ Codex · Goose   │
│ Provider · MCP · Skills   │ │ ACP adapters    │
└──────────────┬────────────┘ └──────────────────┘
               │
┌──────────────▼────────────────────────────────┐
│ Platform Services                             │
│ Git/worktree · PTY · FS · Go Gateway/Relay   │
│ some.im（账号 · 中继 · 计费 · 远程 Runtime）  │
└───────────────────────────────────────────────┘
```

### 9.1 Rust Workspace 建议

```text
willdeep-rs/
├── crates/
│   ├── core/            # Agent loop 与领域模型
│   ├── protocol/        # WillDeep RPC 与 ACP 适配（schema 即事实之源）
│   ├── tools/           # 文件、Shell、Git、搜索
│   ├── sandbox/         # 平台权限与执行隔离
│   ├── providers/       # 模型 Provider 适配
│   ├── someim/          # some.im 账号、路由与中继客户端（可选依赖）
│   ├── sessions/        # 持久化、恢复、事件日志
│   ├── orchestrator/    # Goal 与多 Agent 调度
│   ├── exec/            # 无交互执行入口
│   └── tui/             # Ratatui 客户端
└── bins/
    └── willdeep/        # CLI 总入口
```

### 9.2 CLI 形态

```bash
willdeep                              # 进入交互式 TUI
willdeep "修复当前项目的测试"          # 单次任务
willdeep run --json "检查安全问题"     # CI/自动化模式
willdeep goal "完成重构并准备 PR"      # 长任务
willdeep resume                       # 恢复最近会话
willdeep sessions                     # 管理会话
willdeep attach <task-id>              # 接管后台任务
willdeep agents                       # 查看 Agent 与 Runtime
willdeep login                        # some.im 设备码登录（可选）
willdeep mcp list
willdeep skills list
willdeep serve                        # 后台 daemon / 远程 Runtime
```

## 10. 分阶段路线

### 阶段 0：技术验证

- 建立 Rust workspace、CI 和 macOS/Linux 构建矩阵（Windows 构建可后置到阶段 1）；
- 验证 ACP Rust SDK；
- **双轨接入**：通过 stdio 接入 Codex App Server，同时打通 Goose（纯 ACP）作为备胎；
- 定义 WillDeep Task、Session、Approval、Event 的最小协议（带版本号，schema 即事实之源）；
- 验证 SwiftUI 客户端与 Rust 进程通信；
- 产出 4.5 节的 crate 级复用清单。

退出条件：CLI 和 macOS App 能观察并操作同一个外部 Agent 会话；crate 复用清单成立。

**止损条件**：若 6 周内双端观察打不通，或 crate 复用清单落空，触发 3.2 选型重估（降级为 Go 方案或推迟项目），不允许沉没成本续命。

### 阶段 1：CLI MVP

- 交互式 TUI；
- `run --json` 无交互模式；
- 文件、搜索、Shell、Git 和基础审批；
- 会话持久化及恢复；
- `AGENTS.md`、Skills、MCP；
- `willdeep login` some.im 设备码登录（可选路径）+ BYOK 路径；
- **平台范围：macOS + Linux 首发；Windows 以 WSL2 兼容交付**，原生 Windows（ConPTY、Job Object/AppContainer 沙箱、Credential Manager、CRLF 处理）单列为独立里程碑；
- 分发渠道：Homebrew、cargo-dist（curl 安装脚本 + GitHub Releases）；scoop/winget 随原生 Windows 里程碑；
- 与现有 Go Gateway/Relay 对接；
- 成本账本（本地 SQLite）+ 遥测埋点 + `willdeep cost` 基础版 + 任务收据 v0（schema 进 protocol crate，**飞轮数据从第一天开始积累**）；
- 静态路由规则表 v0、prompt cache 前缀纪律、任务级预算硬顶（见 [COST_ENGINE_DESIGN.md](COST_ENGINE_DESIGN.md)）；
- **开源仓库随 MVP 发布公开**（Apache-2.0 + NOTICE + 商标声明）。

退出条件：用户能够在真实仓库中完成修改、测试、审查和恢复任务；从安装到完成第一个任务不超过 5 分钟。

### 阶段 2：WillDeep 原生 Core

- 多 Provider；
- 上下文压缩和长期记忆（对照 6.3 契约测试实现）；
- worktree 隔离；
- Goal 编排与后台任务（`willdeep serve` 本机 daemon）；
- 手机审批推送打通（走现有 Relay）；
- 服务端路由器 v1（规则 + 实时价格）：升降档阶梯、缓存亲和调度、后台任务错峰/batch；
- 测试证据和验收报告（与账单收据共用交付结构）；
- CLI 与 macOS App 双向接管。

退出条件：常用任务不再依赖外部 Agent Runtime。**达成后触发 Swift 融合重估**（6.1）。

### 阶段 3：差异化能力

- Goal Teams 和 Roundtable；
- 协作平台审批（飞书等）；
- 本地/远程 Runtime 漫游（"合盖任务不死"从这里才成立）；
- 原生 Windows 里程碑；
- 企业权限策略和审计；
- 数据驱动的路由飞轮闭环、goal 级预算优化与月度省钱报表；
- Skills 市场和团队工作流模板。

退出条件：形成"长任务、多 Agent、跨设备、可验证"的完整产品闭环。

### 版本治理

- `willdeep-rs` 为独立仓库，采用标准 SemVer（对外开源库/CLI，遵循严格语义化版本，不用内部 rc 递增制）；
- 协议 schema 版本独立编号，CLI/App/移动端各自声明兼容的 schema 版本区间；
- 与主仓 `scripts/version_consistency.rb` 体系的衔接：主仓只登记"兼容的协议 schema 版本"，不同步 CLI 产品版本号，避免跨仓库版本锁死。

## 11. 首发演示与衡量指标

### 11.1 首发演示

首发应围绕一个连续故事，而不是罗列功能（注意 5.2 的表述边界——"关闭终端窗口"，不是"合上电脑"）：

```text
CLI 启动目标（willdeep goal）
→ 后台多 Agent 在 worktree 工作（本机 daemon）
→ 关闭终端窗口，任务继续
→ 手机扫码连接，收到危险操作审批
→ 测试失败后自动修复
→ macOS App 查看进度和 Diff
→ CLI 输出验证报告并准备 PR
```

### 11.2 核心指标

- 真实工程任务完成率；
- 首次运行成功率；
- **从安装到完成首个任务的时间（目标 < 5 分钟）**；
- **从安装到手机首次审批成功的时间（目标 < 5 分钟）**；
- 中断后的恢复成功率；
- 需要人工干预的次数与原因；
- 测试通过率及误报率；
- 从任务开始到可审查 Diff 的时间；
- 跨设备审批和接管成功率；
- **每个验收通过任务的总成本（北极星，含失败重试与升档）**；
- Prompt cache 命中率；
- BYOK 用户 → some.im 账号的转化率；
- 上游 Agent/协议升级导致的兼容故障率。

## 12. 主要风险

### Rust 开发效率

通过明确 crate 边界、减少过度抽象、优先集成成熟协议来控制。MVP 不同时重写所有底层能力。阶段 0 设有止损条件，不允许沉没成本续命。

### 双语言维护与双 Runtime 漂移

Rust 与 Go 并存会增加构建复杂度，但短期成本低于重写稳定服务。Rust Core 与 Swift App 在融合前是双 Runtime 并存，漂移风险靠"协议先行 + schema 即事实之源"对冲（第 6 节）。两者必须通过有版本的协议通信，不允许跨语言复制领域状态。

### 上游依赖变化

ACP、Codex App Server 和 Goose 都在快速迭代。必须锁定版本，设置协议契约测试，并保留外部 Agent 适配层；任何阶段不得只绑定单一外部 Agent。

### 差异化窗口关闭

大厂迟早会做手机审批与跨设备。对策是速度与品类认知：趁 12-18 个月基建先发窗口，把"能离开终端的那个 Agent"的认知钉死；护城河是已上线的网关 + Relay + 账号体系，不是功能点子本身。

### 开源伴生风险

- 换皮 Fork：Apache-2.0 + "WillDeep" 商标保护 + NOTICE 要求；
- 社区维护负担：明确 issue/PR 响应 SLA 的边界，核心路线不被社区需求牵着走；
- 开源部分与 some.im 闭源服务的接口必须清晰，避免"开源壳、实际不可用"的口碑反噬——无账号单机路径必须真实好用。

### 差异化范围过大

首发只承诺"关闭终端窗口后台继续 + 手机审批 + 可验证交付"。合盖漫游、企业治理、Skills 市场、复杂路由等能力后置。

### 安全与凭据

凭据必须进入系统 Keychain、Secret Service、Credential Manager 或受保护的配置存储。日志、会话同步和远程 Relay 不得包含明文 Token。

## 13. 最终决策

WillDeep CLI 采用以下总体策略：

- **Rust Core + Rust CLI/TUI**（附阶段 0 验收前提与止损条件）；
- **保留现有 Go 平台服务**；
- **SwiftUI 继续作为高级桌面控制台；Rust CLI 先独立发展，协议先行对冲漂移，阶段 2 后重估融合**；
- **ACP 优先连接外部 Agent，双轨验证不绑单一上游**；
- **逐步建设原生 WillDeep Runtime，Swift 资产以契约测试形式移交**；
- **CLI 以 Apache-2.0 开源 + 商标保护；some.im 服务端闭源，卖控制平面而非算力**；
- **some.im 深度集成但非必要条件，BYOK 单机全功能**；
- **成本引擎以"每验收任务成本"为北极星，托管闭环数据驱动路由飞轮；便宜是结果不是卖点**；
- **主攻国内市场，跨设备体验做全球叙事，ACP 寄生层定位降低获客成本**；
- **首发 macOS + Linux，Windows 先 WSL2 后原生**；
- **不从头重造通用基础设施，不做换皮 Fork**；
- **以长任务、多 Agent、跨设备和可验证交付建立差异化**。

这条路线既能利用现有 Swift 产品积累和 some.im 基础设施，也能避免在已经拥挤的 CLI 市场中重复实现同质功能。
