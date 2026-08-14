# Skill Workers 实施任务清单（skill-workers.v1）

> 状态：**规划完毕，等待用户下达「开始」指令后才动工**
> 日期：2026-08-14
> 关联文档：`docs/SMALL_MODEL_SKILL_WORKERS_DESIGN.md`（主设计）、`docs/SOMEIM_WORKER_VIRTUAL_MODELS.md`（服务端虚拟模型与提示词）
> 本文档是唯一的任务台账：每个任务有编号、归属、依赖、验收标准；实施中状态变化回写此处。

---

## 0. 已定决策（2026-08-14 拍板）

1. Worker 基础模型 = some.im 虚拟模型 **`someim-32b`**，背后 glm-5（glm-4.7 已下架）。
2. 七个工种（scout / reader / editor / test_fixer / build_fixer / log_inspector / git_detective）的**职能段 prompt 托管在服务端虚拟模型**（prepend 模式）；`deep` / `reviewer` / 小活 / 不变量段 / Task Packet 留客户端。
3. 客户端把这批 profile 的 `contextWindowTokens` 钉 **32_768**，执行小上下文纪律（服务端不限窗）。
4. 沿主设计默认建议执行（开工前可推翻）：文件集写通道一期就开（否则 test_fixer 闭不了环）；verdict 回执端点后置到 Phase 3；BYOK 遥测 opt-in。

## 1. 任务总览

```text
S 服务端（rocky 后台操作，零代码）──┐
                                    ├─→ C Xedit Phase 1 闭环 ─→ D Phase 2 露脸 ─→ E Phase 3 扩面
O Xedit Phase 0 观测（可与 S 并行）──┘
```

S 与 O 无依赖可并行；C 依赖 S（虚拟模型可用）与 O（有仪表才知道效果）；D 依赖 C；E 依赖 D 攒出的数据。

## 2. S — 服务端配置（muchtoken 后台，rocky 执行）

| # | 任务 | 依赖 | 验收 |
|---|---|---|---|
| S1 | `model_pricing` 建 `someim-32b` 定价行 | — | 行存在，唯一键不冲突 |
| S2 | 后台建 8 个虚拟模型链（`someim-32b` + 7 个工种档），工种档填入 `SOMEIM_WORKER_VIRTUAL_MODELS.md` §3 的 prompt，全部 prepend 模式、`billing_logical_model = someim-32b` | S1 | 8 个模型请求 200，`request_model` 分组正确 |
| S3 | WillDeep 租户打 `extended_billing` 标签 | — | 带 `X-Api-Tag` 的请求落 `usage_record_tags` |
| S4 | 过一遍 `SOMEIM_WORKER_VIRTUAL_MODELS.md` §5 验证清单 | S1–S3 | 清单全勾 |

## 3. O — Xedit Phase 0 观测（可与 S 并行）

| # | 任务 | 依赖 | 验收 |
|---|---|---|---|
| O1 | 子代理 token 计入 usage sidecar：`AgentUsageSessionSnapshot` 增加 per-run 汇总（profileID / model / tokens / verified 占位），面板 model usage 表能看到 Worker 成本 | — | 单测 + 面板可见 |
| O2 | `AgentSubagentTranscript` 补字段：`verifierCommand` / `verifierPassed` / `attemptCount` / `repoCommit`（全部 optional decode，旧 sidecar 兼容） | — | 单测（新旧 sidecar 双向） |
| O3 | 统计面板三 KPI：Skill Coverage / Worker Verified Success / Main Escalation Rate（口径见主设计 §8） | O1 O2 | 面板显示，含数据不足态 |

## 4. C — Xedit Phase 1 闭环（核心）

| # | 任务 | 依赖 | 验收 |
|---|---|---|---|
| C1 | 服务端托管工种的登录态二分（规则见 `SOMEIM_WORKER_VIRTUAL_MODELS.md` §3.8，只作用于那 7 个工种）：**已登录** → 模型锁死 `someim-32b-<skill>`、职能段不发（服务端托管）、设置页该项显示为锁定并说明原因；**未登录** → 用用户为该工种指定的模型，未指定则回退当前会话模型，并拼接 App 内置职能段。两态共用 `contextWindowTokens` 32_768、`toolPayloadCharacterLimit` 4_000 | S2 | 单测：登录态请求 system 不含本地职能段且模型为托管值；未登录态用会话模型 + 内置职能段；登录/登出不迁移用户配置（spawn 时解析） |
| C1b | Swift 侧内置七段职能提示词（`SOMEIM_WORKER_VIRTUAL_MODELS.md` §3 的离线镜像，未登录路径使用）；文档为 canonical 源，两边同步 | — | 单测：内置文案存在且非空；未登录 spawn 命中内置段 |
| C2 | Task Packet：`spawn_agent` 新增可选 `task` 参数（goal / relevant_files / known_facts / constraints / verifier / max_attempts），runner 内联相关文件（32K 档上限 24K chars，超限截断明示）；verifier 命令过 `AgentSafeCommand` 白名单 | — | 单测：无 `task` 行为逐字节不变；内联截断；白名单拒绝危险命令 |
| C3 | Verifier 闭环：runner 判定循环（「没跑过 verifier 的 done 不算 done」）、失败输出确定性消化后回灌、attempt 打满触发升档（升档条件从三条扩到四条）、结果写 transcript（O2 字段） | C2 O2 | 单测：exit 0 才算 done；连败升档且 transcript 可审计 |
| C4 | 文件集写通道：`AgentSubagentWriteAccess` 从单文件泛化为声明式文件集（spawn 即审批列全集合、逐条 diff 路径校验、文件集互斥锁、失败放锁）；editor 成为集合大小 1 的特例 | — | 单测：越界 Denied、交集排队、editor 行为不变 |
| C5 | 新工种 `test_fixer` / `build_fixer` 上线：内置 profile 定义（工具白名单 `read_file`/`apply_patch`/`run_command` 限 verifier 命令、maxRounds 6、32K 档、verifier 必填）、`spawn_agent` schema 与选择指引更新 | C1–C4 | 端到端：一个真实失败测试由 test_fixer 修绿，全程 verifier 判定 |
| C6 | 请求打标：Worker 请求带 `X-Api-Tag: role=worker, skill=<id>, attempt=<n>, parent=<request-id>` 与 session id；BYOK / 非 some.im provider 不带 | S3 | 服务端 `usage_record_tags` 可按 skill 分组 |
| C7 | 全量单测绿 → bump 版本 + CHANGELOG → 合回 develop（既有流程） | C1–C6 | CI 绿 |

## 5. D — Xedit Phase 2 露脸触发点

| # | 任务 | 依赖 | 验收 |
|---|---|---|---|
| D1 | 确定性触发：主循环检测测试/构建失败的 `run_command` 结果，工具结果尾部附「适合派 `test_fixer`/`build_fixer`，相关文件与失败摘要已就绪」结构化提示 | C5 | 单测 + 实测派工率上升（面板 Skill Coverage） |
| D2 | 小活旁路第一批：长工具输出摘要 / 会话标题 / commit message，走裸 `someim-32b` side-call，不进主上下文、独立记账 | S2 | 单测 + 面板 overhead 单列 |
| D3 | workflow / 调度台绑定：内置 workflow 的 `agent()` fan-out 步骤显式指定窄工种；`AgentDispatchExecutorResolver` 规则表加「任务特征 → 建议工种」列 | C5 | BugHunt/CodeReview 跑在窄工种上 |

## 6. E — Phase 3 扩面（数据驱动）

| # | 任务 | 依赖 | 验收 |
|---|---|---|---|
| E1 | `log_inspector` / `git_detective` 客户端工种上线（服务端虚拟模型 S2 已备好）；日志确定性预处理器（失败聚焦段提取，纯 Swift） | D 阶段数据 | 端到端各一例 |
| E2 | `reviewer` 64K 档改造 + findings schema | 同上 | — |
| E3 | Replay 回放工具：transcript（含 repoCommit + verifier）→ 可重放 case，支持换模型对比 | O2 数据积累 | ≥1,000 cases 可回放 |
| E4 | verdict 回执端点（muchtoken 唯一需写代码项，主设计 §13.2）+ 服务端三北极星日报 | C6 数据积累 | 服务端报表按天出 KPI |

## 7. 流程约定

- 每阶段独立 feature 分支，从 `develop` 拉；顺序固定：**跑全量单测 → 提交 → 合回 develop**，失败不合。
- 版本号与 CHANGELOG 随每阶段 bump（功能新增升 MINOR 重置 rc1，修复只递增 rc）；push 前跑 `scripts/version_consistency.rb`。
- 本仓库常有并发会话：提交前查并发、精确 `git add`，不用 `git add -A`。
- 文档回写：实施中与设计不符的决定，回写主设计「实现记录」小节（沿 `SUBAGENT_PROFILES_DESIGN.md` §14 先例）。

## 8. 当前状态

- [x] 规划与三份文档完成（主设计 / 服务端定义 / 本清单）
- [x] **O 阶段（观测）完成并合回 develop**：1.259.0-rc1
- [x] **C 阶段（闭环）完成**：C1 / C1b / C2 / C3 / C4 / C5 / C6 全部落地
- [ ] S 阶段：服务端配置（rocky 执行，见 `SOMEIM_WORKER_VIRTUAL_MODELS.md` §5，现为 **9** 个工种档）
- [ ] D 阶段：露脸触发点
- [ ] E 阶段：扩面与回执端点

### 8.1 实施中新增/修正的决定（2026-08-15）

1. **`extended_billing` 租户标签不再是 Phase 1 必需**。每个工种有独立虚拟模型名，per-skill 维度经 `usage_records.request_model` 已免费获得；`X-Api-Tag` 只补 attempt/parent 这类细分，推迟到确有问题答不上来时再开。
2. **客户端补发 `X-Playground-Session-ID`**（C6 实做内容）。原先只发 `x-willdeep-session-id`，而网关的用量账本只读前者，导致我们全部流量的 `usage_records.session_id` 为空、无法在服务端按会话聚合。
3. **verifier 准入从「必须只读」改为「read 档直放 + 其余走 security_guard 裁判」**。理由见主设计 §4：诚实的 verifier 本来就会写。
4. **新增两个判断型工种 `security_guard` / `judge`**，均为无工具、`maxRounds: 1` 的 32B 档，服务端虚拟模型 `someim-32b-security-guard` / `someim-32b-judge`。注意与既有 `someim-security-guard`（网关 replace 模式、服务于主循环自动审批）并存不合并。
5. **写通道泛化为文件集**：`target_file`（editor，单文件）与 `target_files`（fixer，列表）并存；可写范围**必须显式声明**，绝不从 `task.relevant_files` 推断——「可读」不等于「可写」，审批卡要展示确切的写范围。
