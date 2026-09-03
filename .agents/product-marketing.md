# WillDeep Product Marketing Context

*Last updated: 2026-09-03*

## Product Overview

**One-liner:** 一个借鉴 OS/systemd 机制的开源 macOS Agent Runtime：把会话当进程、把 Worker 与外部变化当信号，让长任务可调度、可中断、可恢复、可验收。

**What it does:** WillDeep 用宿主 Runtime Kernel 接收、校验、去重、持久化并路由 Worker、终端、后台 Job、Webhook、邮件和审批事件；主 Agent 像 `init + systemd + 调度器` 一样响应信号并协调执行资源。用户描述目标后，Agent 可以读取项目、修改文件、运行命令和测试；需要承担风险的决策停下来交给用户，完成后提供可复核结果。

**Product category:** Agent Runtime / Agent OS control plane / coding agent orchestration / native macOS developer tool

**Product type:** Apache 2.0 开源 macOS App + 可选托管服务的 Open Core 产品

**Business model:** Community 版保持可独立使用；官方签名构建、托管模型与 runtime、云同步、团队治理和企业支持可作为商业服务。

## Target Audience

**Primary audience:** 已经在使用 Codex、Claude Code、Cursor 或其他 AI 编程工具，但需要多任务可见性、明确权限边界和可验证交付的 macOS 开发者。

**Secondary audience:** 需要让 Agent 操作本地、SSH 或自建 daemon，同时保留审批、审计和模型选择权的小型技术团队。

**Primary use case:** 把一项真实开发或运维任务交给 Agent，让它执行到可审查、可验证的结果，而不是只返回建议。

**Jobs to be done:**

- 同时推进多个 Agent 任务，又不让会话、终端、分支和产物串台。
- 允许 Agent 动手，但对危险命令、凭据和越界写入保留确定性控制。
- 在本机和远端使用同一套工作流，并自由选择模型、Skill、MCP 和执行器。

## Problems & Pain Points

**Core problem:** 模型能推理、CLI Agent 能干活，但长生命周期 Agent 缺少类似 OS 的宿主能力：任务隔离、事件路由、中断、恢复、资源调度、权限边界和统一可观测性。

**Why alternatives fall short:**

- 纯聊天产品离真实工具链太远，建议与执行脱节。
- 单终端 Agent 缺少多会话总览、可视审批和集中交付界面。
- 云优先平台可能不适合敏感代码、内网环境、BYOK 或自建 runtime。
- AI IDE 仍以文件和光标为中心，长任务、后台任务与多 Agent 协作容易淹没在编辑器界面中。

**Cost:** 用户需要来回搬运上下文、盯住多个终端、猜测 Agent 是否真的验证过，并承担误操作与凭据暴露风险。

**Emotional tension:** 想让 Agent 放手干，又不敢真的放手；任务跑得越久，越难知道它做到哪、动了什么、是否可信。

## Competitive Landscape

**Direct:** 原生或桌面 Agent 工作台；竞争焦点是任务编排、可观测性、权限和本地体验。

**Secondary:** Cursor 等 AI IDE；以编辑体验为中心，覆盖部分 Agent 工作流。

**Indirect:** Codex CLI、Claude Code 等终端 Agent，以及自建脚本和多个终端窗口。

## Differentiation

**Key differentiators:**

- 原生 SwiftUI macOS 体验，不以浏览器壳或聊天网页作为主界面。
- 任务优先而非编辑器优先；文件保留预览和 Diff 审查，避免和用户现有编辑器争夺光标。
- 多会话与最多五路 Worker 并行，运行状态、审批和交付物集中可见。
- 宿主 Runtime Kernel 将 Worker、终端、Job、Webhook、邮件和审批收敛为定向事件；主 Agent 以 `init + systemd + 调度器` 的方式响应信号，而不是持续轮询所有资源。
- 事件具备持久化、去重、lease/ACK、速率限制和三档中断策略；多窗口只允许目标会话 owner 唤醒模型，避免串台和重复费用。
- 四档审批、确定性黑名单、seatbelt 沙箱、Keychain 与审计记录共同约束副作用。
- 本地、SSH、daemon 使用一致的会话与审查流程。
- BYOK、托管模型、Skill、MCP、工作流与外部执行器可以组合，不锁死单一模型或网关。
- Apache 2.0 开源核心让本地数据与执行边界可以被检查，而不只是被承诺。

**Why that is better:** 用户获得的不是更多 AI 文本，而是更放心地把真实任务交出去，同时保留看得见、停得住、验得过的控制权。

## Objections

| Objection | Response |
| --- | --- |
| “这是不是又一个 AI 编辑器？” | 不是。WillDeep 主动退出通用编辑器场景，专注任务、会话、执行与交付审查。 |
| “Agent 会不会乱跑命令或读密钥？” | 高风险操作受确定性规则、审批、沙箱和凭据边界共同约束；破坏性操作始终要求用户确认。 |
| “我已经在用 Codex/Claude Code。” | WillDeep 可以把外部执行器纳入任务契约和证据复核，也可以作为多个 Agent、终端和远端 runtime 的可视控制面。 |

**Anti-persona:** 只需要补全代码、极简聊天或跨平台网页 IDE，且不在意原生 macOS、多任务可见性和执行边界的用户。

## Switching Dynamics

**Push:** 多个终端和聊天会话难以追踪；Agent 结论缺少证据；云端或全权限执行让人不放心。

**Pull:** 原生、开源、本地优先；多任务并行；明确审批；Diff、测试和产物集中交付。

**Habit:** 已熟悉现有 IDE 与 CLI，不愿迁移编辑器、快捷键和项目配置。

**Anxiety:** 新工具是否稳定、是否支持现有模型、是否泄露代码、是否值得把真实项目交给它。

## Customer Language

**Words to use:** Agent Runtime、借鉴 OS/systemd、会话像进程、事件像信号、主 Agent 像调度器、真正动手、看得见、停得住、验得过、本地优先、可审查、可验证。

**Words to avoid:** 真正的操作系统、系统内核替代品、革命性、颠覆、万能、全自动、零风险、Cursor 平替、最强 AI IDE。

## Brand Voice

**Tone:** 直接、克制、有技术判断。

**Style:** 先说用户得到什么，再解释机制；用真实界面和明确边界建立信任，不编造统计数字或客户评价。

**Personality:** 可靠、坦诚、原生、工程化、有一点锋芒。

## Proof Points

| Value theme | Repository evidence |
| --- | --- |
| 开源可信 | Apache 2.0 开源核心、Open Core 边界文档、安全与审批实现可审查 |
| 真正执行 | 文件、终端、浏览器、MCP、工作流、远端 runtime 与测试链路 |
| 多任务可见 | 独立会话运行时、后台任务、最多五路 Worker、Dock/侧栏状态 |
| Agent OS 运行层 | 进程共享 Runtime Kernel、定向事件信封、三档中断、持久化投递、主 Agent 调度与恢复 |
| 可验证交付 | Diff 审查、测试输出、产物面板、工具审计与完成态总结 |
| 模型自由 | some.im 托管模型、BYOK、自定义 provider、外部执行器与本地模型 |

**Unverified proof deliberately omitted:** 用户数量、节省时间比例、客户 Logo、评分和推荐语。

## Goals

**Primary conversion action:** 下载并运行官方签名的 macOS 版本。

**Secondary conversion actions:** Star 仓库以关注进展；Fork 并构建自己的版本；提交 Issue 或 PR。

**README success criteria:** 首屏十秒内说明产品类别、核心结果、差异化和下一步；技术细节保留，但不得先于价值主张和试用入口。
