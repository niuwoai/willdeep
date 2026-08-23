# Goal Teams 执行期角色与版本锚定里程碑设计（goal-teams.v1）

> Last updated: 2026-08-14 | 状态：§7 已确认；Xedit 侧执行期角色与里程碑账本已落地（见 §6 映射与 docs/AGENT_PROFILE_UNIFICATION_DESIGN.md）
> 适用范围：Xedit（WillDeep macOS App，本仓库）与 willdeep-rs（CLI/Runtime，`~/Sites/willdeep-rs`）
> 本文件是双端共享的 canonical 规范；willdeep-rs 侧的引用与落地映射见其 `docs/GOAL_TEAMS.md`。

## 0. 背景与动机

对标对象是 Codex 目标模式在真实长期项目中表现出的六个构件：

1. 长期 Goal 可恢复，恢复后先输出状态快照（分支、未提交文件、当前版本、上/下次门禁）；
2. 版本驱动的里程碑表：一个 rc 一个里程碑，每行固定「内容（锁定范围）/ 验证 / Git 动作」，每 N 版一次周期大门禁；
3. Teams 表 = 虚拟成员 + 职责分离矩阵：开发 / 测试（QA）/ 评审各绑定一个 subagent，Test Owner 与 Validator 交叉指派，禁止自证；
4. 子代理与主代理的双向交互：独立可视会话、结构化交接物（Doc Capsule）、约束自报告；
5. SPEC 与环境状态盘点：开工前列出「哪些规则/文档已存在并采用、哪些待创建、环境有什么限制」；
6. 开工确认门：表格摆完，等用户确认才启动。

两端现状（2026-08-12 探查结论，代码锚点见 §6）：

| 构件 | Xedit 1.247.0-rc13 | willdeep-rs 0.21.0-rc66 |
|---|---|---|
| 长期 Goal + 恢复 | 有（`AgentGoal` / `AppStateAgentGoalRecovery`） | 仅 `Session.goal` 单字符串 |
| 里程碑 | 半个：`AgentGoalRoadmap` 有 Phase，但不锚定版本号、无周期门禁 | 无 |
| Teams 表 | 半个：规划期三成员辩论 + 固定列头提案表，但执行期角色蒸发 | 无（路线图 §7.8 未勾选） |
| QA/评审执行成员 | 有机制无身份：任务契约只读复核是一次性上下文 | 无（§7.7 未勾选） |
| 结构化交接物 | 有 `structured_output` 机制，`spawn_agent` 默认仍回裸文本 | 裸 final text（64KiB 上限） |
| 主→子运行中指令 | 无（只有失败升档重跑） | 有（`instruct` / stop / retry） |
| SPEC 盘点 | 有目标收敛诊断，无文档/环境盘点表 | 无 |

核心缺口不是「没有 Teams」，而是四件事：**角色只活在规划期**、**里程碑不锚定版本**、**交接物非结构化**、**无跨里程碑记忆**。本设计只补这四件，不重造已有轮子。

## 1. 设计原则

1. **机制而非人设**。「QA 员工」的价值 = 独立上下文 + 权限收窄 + 证据交付 + 交叉验收；人设名字只是进度可读性的 UX 层。禁止「同一上下文起三个名字」的角色扮演式实现。
2. **文件层共享 schema**。两端目前没有共享运行时协议（Xedit 连 daemon 走的是 `/v1/fs/*` 远端工具后端，不是 willdeep-rs 的 `/v1/api` 控制面），短期不追求同一 runtime。角色定义、里程碑、归档一律落成 workspace 内的文件，沿用两端已有的文件层互通模式（会话文件、projects.json、mobile-gateway.v1）。将来 Swift 接入 Runtime 协议时，这些文件 schema 原样升为协议对象。
3. **小刀切香肠**。四步落地（§6），每步独立可验收、可单独提交；涉及大改动（子代理聊天会话、跨端 runtime 合并）明确排除在外（§8）。
4. **复用既有基建**。Xedit 复用 subagent profile 目录、`structured_output`、任务契约复核链、`.codex/goal-teams/` 归档惯例；willdeep-rs 复用 SubagentCatalog、`instruct` 通道、Runtime 事件流。

## 2. 角色注册表（Role Registry）

### 2.1 角色 schema

每个角色（member）是一条声明式定义，双端同构：

| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | string | 稳定标识，如 `developer` / `tester` / `reviewer` |
| `display_name` | i18n key | 展示名（zh-Hans：开发 / 测试 / 评审） |
| `binding` | string | 绑定的 subagent 工种 id（见 §2.3 映射） |
| `tool_policy` | enum | `read_only` / `read_plus_test` / `write_scoped`，只能收窄绑定工种的白名单，不能放宽 |
| `locked_scope` | text | 本里程碑内允许触碰的范围声明；范围外一律拒绝并上报 |
| `deliverable` | template ref | 交付物模板（§5 Doc Capsule 的特化） |
| `done_criteria` | text | 完成判据，必须可被 Validator 独立检验 |
| `validator` | role id | 验收人，**硬规则：`validator != id`** |
| `memory` | file ref | 跨里程碑记忆文件（§4.3），可为空 |

### 2.2 内置三角色

| id | 展示名 | binding | tool_policy | 职责 | validator |
|---|---|---|---|---|---|
| `developer` | 开发 | editor（写口）+ deep（调查） | `write_scoped` | 实现当前里程碑锁定范围内的改动 | `reviewer` |
| `tester` | 测试 | 新工种 `tester` | `read_plus_test` | 跑专项单测/门禁，产出 JSON+Markdown 证据；**不改业务实现** | `reviewer` |
| `reviewer` | 评审 | 新工种 `reviewer` | `read_only` | 只读审查改动边界、版本一致性、Git 完整性，出具独立验收结论 | Goal Lead（宿主/用户） |

硬规则（实现层必须是执行路径拦截，不是 prompt 约定）：

- Validator 交叉指派禁止自证：任何角色的 done 状态只能由其 validator 置位。
- `tester` / `reviewer` 无写权限；`tester` 额外允许执行只读风险级命令（跑测试、读报告），复用现有 run_command 风险分级。
- 每份交付物必须包含**约束自报告**（§5 `constraints_honored`）：声明「未修改文件 / 未越出 locked_scope / 跑了哪些验证」，供 Validator 核对。

### 2.3 与现有工种的关系

现有 4 个工种（scout / reader / deep / editor）语义不变。新增 `tester` 与 `reviewer` 两个工种：

- `tester`：工具白名单 = deep 的只读集 + 只读级 `run_command`（跑测试）；输出强制走结构化 schema。
- `reviewer`：工具白名单 = `read_file` / `list_directory` / `grep_files` / `search_files` / `git_status`（willdeep-rs 侧可加 `git_diff` / `git_log` / `git_blame`，其 `READ_ONLY_TOOLS` 已预留）；禁 shell。

角色（member）与工种（profile）分层：工种回答「能用什么工具、什么预算」，角色回答「在这个 Goal 里负责什么、向谁交付」。规划期三成员（requirements / architecture / testing）继续存在，属规划角色；本设计新增的是**执行期角色**，两者在 Teams 表中同表呈现。

## 3. 版本锚定里程碑（Version-anchored Milestones）

### 3.1 milestone schema

在现有 Roadmap Phase 之下增加版本锚点。一个里程碑 = 一个 rc 版本：

| 字段 | 说明 |
|---|---|
| `version` | 目标版本号（如 `1.248.0-rc3`），一里程碑一版本 |
| `scope` | 锁定范围：本版做什么、**明确不混入什么** |
| `verification` | 验证方式：专项单测 / 回归 / 冒烟，指明 Test Owner |
| `git_contract` | Git 动作契约：独立提交、tag `v{version}`、是否推送 |
| `gate` | `none` / `periodic`；periodic = 周期大门禁 |

### 3.2 周期门禁

每 N 版（默认 N=40，待确认，§7）设一个 `gate: periodic` 里程碑，内容固定：全量编译、完整单测、契约/守卫脚本、冒烟、签名检查（Xedit 侧对应 `scripts/run_tests.sh` + `version_consistency.rb` + 发布前检查；willdeep-rs 侧对应 `cargo test --workspace` + clippy + 发布脚本）。周期门禁版本**不混入功能改动**。

### 3.3 与现有机制的关系

- Xedit：`AgentGoalRoadmap` 的 Phase 增加可选 `version` 锚点与 `git_contract`；Phase 收口条件从「验收标准满足」扩展为「验收标准满足 且 git_contract 履行」。
- 版本号纪律沿用仓库既有规则：bugfix 只递增 rc，功能新增才提升正式版本位；一里程碑一版本天然与「一个 PR 不混 feat+fix」对齐。

## 4. 归档目录规范（goal-teams archive）

### 4.1 目录布局

沿用 `.codex/goal-teams/` 既有惯例（2026-08-14 确认：不另起 `.willdeep/`，历史归档与新归档同一目录，不做双目录兼容），双端读写同一格式：

```
<workspace>/.codex/goal-teams/
  INDEX.md                     # 目录：每个 Goal 一行（版本区间、状态、一句话）
  versions/<version>/
    plan.md                    # 本里程碑计划（含 Teams 表，固定列头见 §4.2）
    tasklist.md                # 任务清单与勾选状态
    progress.md                # 推进记录（谁、何时、结果）
    decisions.md               # 本里程碑内的关键决策
    spec/
      inventory.md             # SPEC 与环境盘点表（§4.4）
      *.md                     # 渐进整理的 PRD / 架构 / 验收标准
    capsules/*.json            # 各成员交付的 Doc Capsule（§5）
    qa-notes.md                # tester 维护的跨里程碑记忆（§4.3）
```

格式约定：归档文档用 Markdown（人可读、可 diff）；机器交换物（capsule）用 JSON。schema 版本标识 `goal-teams.v1` 写入 INDEX.md 头部。

### 4.2 Teams 表固定列头

沿用 Xedit 规划期已强制校验的列头，不新造：

```
| Member | Skill/Subagent | Goal Slice | Claimed Tasks | Locked Scope | Deliverable | Done Criteria | Docs/Tasklist Updates | Test Owner | Validator |
```

执行期角色与规划期角色同表；校验规则复用现有实现（列头不匹配打回，连续 3 次失败暂停）。

### 4.3 跨里程碑记忆

`qa-notes.md` 由 `tester` 在每个里程碑收口时追加：flaky 测试、已知回归点、环境陷阱。下一里程碑的 `tester` 启动时**必须注入**该文件（进 system prompt 或首条消息）。`reviewer` 同理可维护 `review-notes.md`（可选）。这是「QA 员工记得上一版哪个测试 flaky」的落地方式——记忆在文件，不在会话。

### 4.4 SPEC 与环境盘点表

`spec/inventory.md` 固定两列（项目 / 状态），开工时生成、里程碑收口时更新：

- 规则文件（AGENTS.md / CLAUDE.md 等）：已发现并采用 / 缺失；
- 产品概览、CHANGELOG、路线图：已存在 / 待创建；
- 长期 PRD / 架构 / 验收标准：状态与渐进整理计划；
- 环境限制：构建互斥、进程查询限制、CI 可用性等。

Xedit 现有的目标收敛性诊断（1.223.0-rc1）输出并入此表，作为确认门材料的一部分。

## 5. Doc Capsule 报告契约

子代理/角色成员的交接物统一为结构化 capsule，不再默认裸文本：

```json
{
  "schema": "goal-teams.capsule.v1",
  "role": "tester",
  "milestone": "1.248.0-rc3",
  "conclusion": "一段话结论（给主代理/用户读）",
  "evidence": [
    { "kind": "test-report", "path": "…/report.json", "summary": "128 passed, 0 failed" },
    { "kind": "file-ref", "path": "Xedit/Foo.swift:123", "summary": "边界检查缺失点" }
  ],
  "files_touched": [],
  "constraints_honored": {
    "read_only": true,
    "scope": "未越出 locked_scope",
    "commands_run": ["xcodebuild test -only-testing …"]
  },
  "next_suggestion": "建议 rc4 只修 X，不动 Y"
}
```

- Xedit：`spawn_agent` 增加默认 outputSchema = capsule（机制现成：`structured_output` 虚拟工具，校验失败回灌重试）；普通对话型 spawn 可显式关闭。
- willdeep-rs：为 SubagentCatalog 增加 outputSchema 等价物（当前无此机制，报告为 final text）。
- capsule 同时落盘到 §4.1 的 `capsules/` 目录，供 Validator 与下一里程碑召回。

## 6. 两端落地映射与实施里程碑

### 6.1 Xedit（代码锚点为 2026-08-12 现状）

| 步骤 | 内容 | 关键位点 |
|---|---|---|
| X1 | 本设计文档评审定稿；`.willdeep/goal-teams/` 目录规范以 bundled skill 或宿主逻辑落地 | `.codex/goal-teams/`（现有惯例）、`BundledSkills/` |
| X2 | 新增 `tester` / `reviewer` 工种；角色注册表与 Teams 表打通；**新逻辑落独立文件**（复杂度 P0 约束，不回塞 `AppStateAgentGoalPlanning.swift`） | `AgentSubagentProfile.swift:145-247`（catalog）、`AgentSubagentProfileSettingsSection.swift` |
| X3 | 任务契约的只读复核挂到 `reviewer` 名下；`qa-notes.md` 注入链路；Roadmap Phase 增加 `version` / `git_contract` | `AgentPlanGoalModels.swift`（Roadmap）、任务契约链路（1.195.0-rc1 起） |
| X4 | `spawn_agent` 默认 capsule schema；评估从 willdeep-rs 移植 `instruct` 主→子指令 | `AgentSubagents.swift:507,611-623`（structured_output） |

### 6.2 willdeep-rs

| 步骤 | 内容 | 关键位点 |
|---|---|---|
| R1 | `docs/GOAL_TEAMS.md` 引用文档（随本设计同步落地）；归档目录读写 | — |
| R2 | `builtin_profiles` 增加 `tester` / `reviewer`，配置白名单同步（**两处必须一起改**）；对齐路线图 §7.7 | `crates/willdeep-core/src/subagent.rs:622-687`、`crates/willdeep-cli/src/config.rs:249` |
| R3 | goal / roadmap / teams 对象持久化（替代单字符串 `Session.goal`）；修 Web 端 `/goal` 刷新即丢 | `crates/willdeep-core/src/session.rs:50`、`crates/willdeep-cli/src/web.rs:351`、路线图 §7.8 |
| R4 | capsule outputSchema 机制；`<subagent-report>` 升级为 capsule 投递 | `crates/willdeep-core/src/subagent.rs:422-446,610-620` |

### 6.3 步序约束

X1/R1（规范与归档，零业务代码）→ X2/R2（新工种）→ X3/R3（角色存续 + 里程碑锚定）→ X4/R4（capsule 与交互对齐）。每步独立提交、独立验收；两端可错峰（默认 Xedit 先行，§7）。

## 7. 默认假设清单（2026-08-14 已确认：除 #3 改为 `.codex/goal-teams/` 外，其余照默认）

| # | 假设 | 默认值 | 备注 |
|---|---|---|---|
| 1 | 周期门禁间隔 N | 40 版 | 与现有发版节奏一致；可配置 |
| 2 | 执行期角色命名 | `developer` / `tester` / `reviewer`（开发/测试/评审） | 规划期三角色名不变 |
| 3 | 归档目录位置 | ✅ `<workspace>/.codex/goal-teams/`（2026-08-14 确认，改自原默认 `.willdeep/`） | 历史归档与新归档同目录，无需双目录兼容 |
| 4 | 交接物格式 | 文档 Markdown、capsule JSON | Teams 表列头复用现有校验 |
| 5 | 落地顺序 | Xedit 先行，willdeep-rs 随后 | R2 依赖的两处白名单已确认可改 |
| 6 | 子代理独立聊天会话 | 本期不做 | 现有检视器窗口够用，见 §8 |

## 8. Non-goals

- 不合并两端 runtime，不在本设计内引入共享控制协议（那是 `CLI_TUI_RUNTIME_ROADMAP` 的 Swift Harness 替换线，四阶段另行推进）。
- 不改动 scout / reader / deep / editor 四个既有工种的语义与预算。
- 不实现 Codex 式「子代理独立聊天标签页」；主→子交互以 `instruct` 指令通道为上限。
- 不做多数投票式仲裁：Validator 是单一负责人，不是投票器（与 `MULTI_EXPERT_CONSULTATION.md` 的立场一致）。

## 附：相关文档

- `docs/SUBAGENT_PROFILES_DESIGN.md` — 工种设计（已实现，1.230.0-rc1）
- `docs/ORCHESTRATOR_DESIGN.md` — 外部执行器调度
- `docs/AGENT_HARNESS_IMPROVEMENT_PRIORITIES.md` — P0 复杂度约束（新逻辑落独立文件的依据)
- `docs/CROSS_PLATFORM_CLI_STRATEGY.md` — 两端协议协作的长期战略
- willdeep-rs `docs/GOAL_TEAMS.md` — CLI 侧引用与落地映射
- willdeep-rs `docs/CLI_TUI_RUNTIME_ROADMAP.md` §7.7 / §7.8 — tester/reviewer profile 与 Agent Team 的既有路线图位置
