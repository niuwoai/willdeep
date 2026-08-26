# WillDeep 混合模型执行设计

> 状态：v2（1.295.0-rc2）
> 日期：2026-08-26
> 目标：让主模型负责规划、取舍与集成，让便宜模型真正承担可界定的执行工作；不是为了“多叫几个 Worker”，而是为了用更低成本得到更可靠、可审计的结果。

## 1. 核心判断

此前派工率低，不是 Worker 数量不够，也不是提示词不够凶，而是执行权仍在主模型手里：

1. 主模型已经拿到仓库工具，直接查、直接改比整理 Task Packet 更顺手。
2. 自动预检和失败自动修复只存在于实时 UI 卡片，没有进入会话账本，统计会漏算。
3. “Worker 调用”把请求、拒绝、失败和真实运行混成一个数，无法判断小模型到底有没有工作。
4. 旧覆盖率用 Worker 运行数除以全部 assistant message；工具循环越长，覆盖率越接近 0，与用户任务是否被分流无关。

所以混合模型不能只靠模型自觉，必须由宿主掌握三个控制点：

- **路由权**：Runtime 先判断任务形状。
- **执行权**：高置信任务在工具边界强制 delegate-first。
- **记账权**：宿主自动运行与模型主动运行进入同一统计口径。

## 2. 四层模型栈

| 层 | 能力与窗口 | 主要职责 | 禁止承担 |
|---|---|---|---|
| D0：确定性 Runtime | 无模型 | 关键词/结构分类、路径归一化、权限、文件锁、命令退出码、统计、预算、Schema 校验 | 语义判断、方案取舍 |
| S：32K–64K Worker | `scout`、`reader`、`editor`、`small_implementer`、`small_reviewer`、`test_fixer`、`build_fixer`、`log_inspector`、`git_detective`、`ops_runner`、`terminal_operator` | 定位、阅读、最多三文件低风险编码、独立验收、有 verifier 的修复、日志/Git/终端/运维预检 | 跨域架构决策、无限扩写、不可逆决策 |
| M：256K 主力 | Root 默认 `glm-5`、`implementer` | 拆任务、编 Task Packet、多文件实现、整合证据、解决冲突、决定下一步 | 重复做 S 已完成且证据充分的扫描 |
| L：1M 稀缺档 | `deep` / `deepseek-v4-flash` | 无法安全切分的跨多文件调查、证据链过长且 M 已尝试的复杂问题 | 默认首选、拼写错误兜底、无票据升级 |

这不是“先小后大”的单线瀑布，而是一个反馈控制系统：D0 决定边界，S 并行收集或执行，M 综合并承担责任，只有证据证明 M/S 不够时才进入 L。

## 3. 标准任务流水线

### 3.1 代码新增或修改

1. D0 从用户原话识别写意图与显式文件范围。
2. S/`scout` 自动预检：只找相关文件、符号、调用点和最窄验证命令。
3. Scout 以结构化输出编成 Task Packet，D0 校验 Schema 并重新判断风险：
   - `goal`：可观察的完成条件；
   - `read_files`：上下文，不授予写权；
   - `write_files`：精确写集；
   - `known_facts` / `constraints`；
   - `verifier.command`。
4. 同时满足“本地工作区、1–3 个明确源码文件、无未决问题、有只读级 verifier、宿主风险 ≤ yellow”时，直接交给基础 `someim-32b` 的 `small_implementer`；其他任务仍走 `editor` / `implementer`。
5. D0 用退出码验收并允许最多两轮 materially different repair；仍失败才用同一写集升级到 `glm-5` 的 `implementer`。
6. 验证通过后，无工具的 `small_reviewer` 只读用户目标、声明范围、实际补丁、当前文件与 verifier 证据，强制输出 accept/reject/uncertain。
7. 只有 verifier 通过且 reviewer 全绿时由宿主直接交付，主模型完全不进入本回合；否则 M/Root 接收当前现场、审查问题和验证命令继续修复。

若 Root 在第 4 步前直接调用 `create_file` / `write_file` / `edit_file` / `apply_patch`，宿主拒绝该工具调用，要求先尝试路由到的写 Worker。用户明确输入 `/no-subagent` 时关闭该闸门。

### 3.2 只读定位、阅读、日志与 Git 追溯

1. D0 高置信分类到 `scout` / `reader` / `log_inspector` / `git_detective`。
2. S 在 Root 首次请求前运行，报告以临时 `<runtime-preflight>` 证据注入。
3. M 不重复扫同一材料，只验证即将依赖的关键引用并回答。
4. 报告上限 6000 字符；截断必须明示，避免把“没传回来”误读成“没有”。

### 3.3 测试与验证

用户说“跑测试/验证一下”时直接由 `tester` 执行，而不是让 Root 先拿到 shell。`tester` 只报告：

- 实际执行的命令；
- 退出码；
- 失败输出；
- 未能执行的原因。

它不能修代码。若失败输出能推导出有界写集，宿主再派 `test_fixer` / `build_fixer`，并用原命令作 verifier。这样“写的人”和“判的人”分离。

### 3.4 生产部署与远程运维

采用两阶段提交，不让 Root 一上来亲自 SSH 写生产：

1. S/`ops_runner` 只读预检：当前版本、服务状态、现有发布脚本、健康检查、回滚入口。
2. M/Root 根据证据选择一条**精确命令**，向用户展示风险和回滚条件。
3. 用户批准后，再次 spawn `ops_runner(target_command=精确命令)`；授权爆炸半径只有这一条命令。
4. S/`ops_runner` 执行并观察；D0/健康检查给出机器判定。
5. M/Root 决定继续、停止或回滚。

非只读 `run_command` 或 `terminal_send_command` 在第 3 步之前都会被宿主拒绝。远程 Runtime 通过原 SSH/daemon 绑定传给 Worker，不再因为“不是本地目录”跳过预检。

### 3.5 可见终端

`terminal_operator` 读取侧栏终端快照、标签和滚动内容，只能发送被静态分类为只读的命令，不能发送控制键打断用户前台任务。若生产写命令必须在已建立的可见 SSH 标签中执行，则由获批的 `ops_runner(target_command=精确命令)` 临时绑定同一终端：先核对标签、主机和 `shell_ready`，只发送与审批文本完全一致的命令，再读取结果；不能静默改走本地 `run_command`。Root 使用其报告判断，不重复操作终端。

## 4. 路由决策表

| 请求特征 | 自动预检 | 执行 Worker | Root 的工作 |
|---|---|---|---|
| “X 在哪/有没有 X” | `scout` | 无 | 根据定位回答 |
| “总结/解释模块或文档” | `reader` | 无 | 综合与取舍 |
| “测试/编译失败，修复” | `log_inspector` | `test_fixer` / `build_fixer` | 编写有界修复包，处理失败兜底 |
| “跑测试/验证” | `tester` | 无 | 解释结果，决定是否进入修复 |
| 1–3 文件低风险、有 verifier 的修改 | `scout` 结构化 Task Packet | `small_implementer` → `small_reviewer` | 全绿时不调用 Root；否则 Root 返工 |
| 单文件但无 verifier / 中高风险修改 | `scout` | `editor` | 给出目标、约束、验收 |
| 普通多文件实现/重构 | `scout` | `implementer` | 拆分、整合、最终负责 |
| 审查改动 | `reviewer` | 无 | 决定接受或返工 |
| 错误日志/崩溃栈 | `log_inspector` | 无 | 选择修复路线 |
| 回归/哪个提交引入 | `git_detective` | 无 | 决定恢复或修复 |
| 部署/生产/重启服务 | `ops_runner` 只读 | `ops_runner` 精确命令 | 风险与回滚决策 |
| “看看终端” | `terminal_operator` | 无 | 根据终端事实继续 |
| 无法分类 | 无 | M/Root 先拆分 | 必要时再选 Worker |

## 5. 升档与失败策略

### S → M

满足任一条件即可回到 M：

- 超出声明文件或工具范围；
- 两次尝试仍无新证据；
- verifier 连续失败且失败形态变化；
- 报告相互矛盾；
- 需要产品/架构取舍；
- 需要用户授权或不可逆决定。

S 的失败不是“再派同一个 S 一次”的理由。同一命令每回合只自动派一次，避免廉价模型低成本空转变成高总成本。

自动编码链只有一个例外：同一个 `small_implementer` 运行内部最多由 verifier 驱动两次修复；失败后不再重复派基础模型，而是新开一个 `glm-5` 运行。独立审查拒绝不会回到原作者自证，直接交给 Root。

### M → L

`deep` 必须携带票据并满足：

1. 说明为什么不能继续拆分；
2. 点名已经尝试的低档 profiles；
3. 与 Runtime 实际观测记录一致；
4. 给出上下文规模证据；
5. 会话预算未耗尽（默认 3 次，可配 0–16）。

目标不是把 Deep Share 做成 0，而是让它保持稀缺且有解释。建议目标 ≤5%。

## 6. 上下文打包原则

- Worker 默认看不到父会话全文，只接收自包含 Task Packet。
- `read_files` 与 `write_files` 分离；上下文不能暗中扩大写权限。
- Root 不向 S 倾倒整个仓库或完整长日志；D0 先截取决定性材料。
- Worker 报告回传“结论 + 证据 + 未确认项”，不要回传完整思考过程。
- Scout Task Packet 可缓存 30 分钟，但键必须包含请求文本、HEAD、分支、暂存区、Git 操作状态和每个工作区文件摘要；任一漂移立即失效。缓存命中不是 Worker 运行，不能混入请求数或实际运行数。
- 本地/企业内网会话优先保持同 Provider；除非用户配置允许，不因为登录了公网 Provider 就把私有代码外送。
- 托管虚拟模型失败只对明确的 `model_not_configured` 做一次可见回落，不能把任意失败悄悄升级。

## 7. 正确的统计口径

Worker 面板必须区分：

- **Worker requests**：模型或宿主提出的 Worker 请求，包括被拒绝或启动失败的请求。
- **Actual runs**：child loop 真正开始的次数。
- **Profiles requested**：请求覆盖的 profile 种类。
- **Chats with workers**：出现过 Worker 请求的会话。

每个 profile 行展示 `requests · runs · chats · share`。

“Worker 承担占比”改为：

```text
实际启动过 Worker 的可路由用户回合 / 全部可路由用户回合
```

不能再除以 assistant message 数；一个用户任务可能产生十几个工具循环消息，那不是十几个新任务。自动宿主 Worker 的请求、开始、状态、模型与用量写入 `AgentSession.hostWorkerRuns`，与模型主动 spawn 的运行共同计算。

建议持续观察：

| 指标 | 用途 | 初期目标 |
|---|---|---|
| Worker Coverage | 可路由任务是否真的分流 | 先达到 30%，再按延迟/质量调高 |
| Request→Run 转化 | 路由是否被权限/配置阻断 | ≥80% |
| Verified Success | 有 verifier 的 Worker 成功率 | ≥70% |
| Escalation Rate | S 是否经常选错档 | 10%–30%，过高说明任务边界太宽 |
| Deep Share | 子运行中使用 1M 的比例 | ≤5% |
| Straight-through Delivery | 自动编码无需 Root 即交付的比例 | 在返工率可控前提下逐步提高 |
| Parent Rework Required | 自动编码最终仍需 Root 修复的比例 | 初期 ≤20%，持续按风险类型收窄 |
| Task-packet Cache Hits | Scout 结构化结果的安全复用次数 | 只观察节省，不设虚荣目标 |
| 重复检查率 | Root 是否重做 Worker 已完成的读取 | 趋近 0 |
| 每任务总成本/时延 | 混合路由是否真的划算 | 相对纯 M/L 下降且 P95 可接受 |

## 8. 发布与调优顺序

1. **先保证真实记账**：请求与运行分开，宿主自动路径持久化。
2. **再强制高置信写路由**：文件编辑与生产命令两个工具边界。
3. **开启自动准备**：scout/log/ops/terminal/tester；允许配置关闭。
4. **观察两周**：按 profile 看 Request→Run、成功率、P95 首字延迟和总成本。
5. **只调窄规则**：优先加确定性触发器，不用一个“大路由模型”替代全部规则。
6. **最后考虑并行 fan-out**：只有彼此独立且结果可合并的读任务并行；写任务继续由文件集锁串行化。

判断标准只有一句：**如果加一个 Worker 没有减少主模型重复劳动、没有产生可验收证据，也没有降低总成本，那它只是把组织架构画得更热闹。**
