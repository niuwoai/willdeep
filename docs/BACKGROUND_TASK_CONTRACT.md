# 后台任务合同（Mac / CLI 共用）

> 状态：已确认（2026-09-17，「待确认」四项均按默认值）· 实施中
> 适用：WillDeep macOS（本仓库）与 WillDeep CLI（`willdeep-rs`）。本文件是 canonical，rs 侧 `docs/` 只引用、不另写一份。
> 前置：CLI 0.74.0-rc2 已修掉「无头不等脱离作业 / 空闲不唤醒 / kill_job 杀不掉」三个 bug，本文不再重复。

## 为什么要有这份合同

对标对象是 Claude Code 的后台任务体验：命令丢到后台立刻拿回句柄，输出随时能读尾部，结束后模型在下一个工具边界被告知，读完结论接着干原来的活。两端的**主干机制已经具备**（后台作业、完成回流、空闲唤醒、唤醒额度），差距落在三处合同层面的细节上，而且两端各差各的：

| 维度 | macOS 现状 | CLI 现状 |
|---|---|---|
| 输出保留 | 内存里只留**前** 64KB（`appendBounded`），不落盘 | 落盘但只是**尾部** 128KB，每来一块就整份原子重写一次（`CaptureState`） |
| `get_job_output` | `tail_lines` 省略 = 整个缓冲 | 进程内任务默认 200 行；脱离作业**忽略** `tail_lines`，固定 16KB |
| 提示词 | 标准档有完整说明（`AgentContextBuilder.swift:670-671`），禁忙轮询 | `prompt.rs` 一句都没有，只在工具描述里提了一嘴 |
| 完成通知 | `exit=N`、`duration 1m5s`、仅失败带 40 行尾巴 | `exit=Some(0)`（Debug 格式）、`elapsed=12345ms`、总带 40 行；脱离作业另一套中文标题 + 4KB |

后果是具体的：Mac 上发版、全量测试这种长任务，**结论恰好在被丢掉的末尾**；CLI 上同一个模型换个前端就要重新学一遍通知怎么读。

## 一、输出：完整落盘，内存只留尾部

### 决定

1. 每个 shell 作业一个目录，完整输出**追加写**到文件；内存里只维护尾部环形缓冲给 UI 和通知用。
   - macOS：`~/Library/Application Support/WillDeep/background-jobs/<job_id>/output.log`（`<job_id>` 即 `job_ab12cd` 句柄；stdout/stderr 合并一份）。作业结束时旁边写 `output.log.tail`（内存尾部）与 `output.log.dropped`（仅在有省略字节时）。
   - CLI：沿用 `~/.willdeep/background-jobs/<job_id>/`，`stdout.log` / `stderr.log` 改为追加写。
2. 单个作业日志硬上限 **256MB**。超过后停止追加，记下省略字节数，尾部缓冲照常滚动——保证「末尾永远可读」这一条不被上限破坏。
3. 文件权限 0600、目录 0700。**脱敏在读出时做**（通知、`get_job_output`、UI），落盘是原文：写入路径上脱敏会让模型 grep 日志时对不上行号。
   - macOS 例外：落盘的是 collector 已把**注入的密钥值**（`${secret:...}` 展开后的明文）替换掉的字节，与内存缓冲同一份；通用凭据形态（`KEY=...`、Bearer 等）仍只在读出时脱敏。注入的密钥本来就不该出现在任何宿主产物里，替换只动命中的那段值、不增删换行，行号与原文一致。
4. 保留策略：作业结束 7 天后或每个家目录超过 200 个作业时清理最旧的，**跳过还在跑的**。
5. 尾部环形缓冲 64KB（两端一致），取代 Mac 的「前 64KB」。

### `get_job_output` 统一语义

| 参数 | 语义 |
|---|---|
| `tail_lines` | 默认 **200**，范围 1–2000；两端、进程内与脱离作业一律生效 |
| 返回头部 | 首行 job id，随后 `status`（运行中为 `running`）、`exit_code`、`duration`（运行中算到现在）、`output_path`、`stderr_path`、`omitted_bytes`，与通知同拼写 |
| 正文 | 分流的宿主每条流一段：`--- stdout (last N lines) ---`；合并日志的宿主只有 `--- output (last N lines) ---` |

不再提供「省略即返回全部」：整份日志交给模型等于把上下文预算押在一个参数上。要全量就给路径，让模型自己 `rg` / `sed -n`。

### 要改的地方

- macOS：`AgentBackgroundJobs.swift` 的 collector 增加文件 sink，`appendBounded` 改成尾部环形；`AgentToolsJobs.swift` 默认值；六个消费方（抽屉 200 行、Dev Server 面板 60/120 行、远端运行时与结构化执行器取全量）逐个核对——**取全量的两处改为读文件**。
- CLI：`execution.rs` 的 `CaptureState` 从「每块整份原子重写」改为追加写 + 内存尾部（现在每来一块输出就 O(n) 重写一次文件，长日志下是纯 CPU 浪费）；`tools.rs` 的 `get_job_output` 对脱离作业尊重 `tail_lines`。

## 二、提示词：一段共用的后台说明

两端各自嵌入**同一段英文原文**（逐字一致），canonical 放在本文件附录 A。要点只有五条：

1. 预计 ≥30 秒的构建、测试、发布、dev server 用 `run_in_background`，并给一个面向用户的 `label`。
2. 结束会自动通知，**不要 sleep、不要轮询**；`get_job_output` 只用于看中途进度。
3. 等待期间继续做不冲突的工作；通知到达时先核实结论，再回到原来的任务。
4. 没收到通知之前，不许声称后台任务成功，也不许猜它的结果。
5. 不再需要的后台作业用 `kill_job` 收掉。

### 代价（需要确认）

- macOS 的 `AgentPromptSnapshotGuardTests` 对稳定前缀、紧凑档与能力块都钉了哈希，改这段会**破一次提示词缓存**并需要三档哈希重录。按「能力门控优于重写核心」的既有经验，做法是只替换标准档 :670-671 与紧凑档 :636 两处原文，不动其他段落。
- CLI 的 `prompt.rs` 只有子串测试，没有缓存稳定性约束，直接加在 `STABLE_CONTRACT` 的执行段之后。

## 三、完成通知：v1 格式

### 格式

~~~
<background-task-notification>
id: job_failure01
kind: shell
label: 发布 WillDeep
status: failed
exit_code: 1
duration: 1h2m5s
output_path: /tmp/willdeep-contract/job_failure01/stdout.log
stderr_path: /tmp/willdeep-contract/job_failure01/stderr.log
omitted_bytes: 1024
output_tail (last 40 lines, secrets redacted):
```text
…
```
</background-task-notification>
~~~

字段顺序固定、每行都出现，取不到的值写 `unknown` 或 `none`，不省略行。

| 字段 | 取值 | 备注 |
|---|---|---|
| `kind` | `shell` / `subagent` / `executor` | 子 Agent 用 `<subagent-report>` 包装，字段相同 |
| `label` | 第一行，脱敏，≤200 字符 | 超出以 `…` 结尾 |
| `status` | `completed` / `failed` / `killed` / `timed_out` / `launch_failed` / `vanished`；子 Agent 另有 `partial` / `blocked` | snake_case；`vanished` = 进程没了且没留下退出码，**不是失败** |
| `exit_code` | 整数或 `unknown` | 不再出现 `Some(0)` / `?` |
| `duration` | `0s` / `1m5s` / `1h2m5s`；取不到写 `unknown` | 两端统一，不用毫秒 |
| `output_path` | 完整日志路径（分流的宿主填 stdout）；不落盘写 `none` | |
| `stderr_path` | stderr 单独落盘且非空时的路径，否则 `none` | Mac 合并日志，恒为 `none` |
| `omitted_bytes` | 因 256MB 单日志上限**没能落盘**的字节数 | 通常为 0；不是「尾巴之外的字节数」 |
| `session` | `<executor> <session_id>` | **仅 executor**、且有可复用会话时才出现，紧跟 `omitted_bytes` 之后；shell / 子 Agent 永不输出这一行（Mac 独有，CLI 暂无 executor 作业） |
| 输出尾巴 | 失败类 40 行 / 4000 字符；`completed` 10 行 / 1000 字符；子 Agent 报告一律 40 / 4000 | 超字符上限时保留末尾、以 `…` 开头；无输出写 `output_tail: (empty)` |

脱敏与标签中和在渲染时就地做：尾巴与 `label` 里的 `<字母` / `</` 转成 `&lt;`，凭据按行替换为 `[REDACTED]`（**只改命中的那一行**，其余行保留缩进）。

CLI 仍经事件内核投递，`<runtime-events>` 外壳保留（负责合批与来源标注），内层 body 就是 v1 文本；内核给每条事件正文统一缩进两格，这是外壳的排版，不算偏离。工具输出与 Worker 报告的来源仍记为 `tool` / `model`，事件带 `notice_contract = background-task-notification.v1` 元数据时内核不再整段转义框架；外部入站（`network`）冒充同名元数据照样转义。

### 金样与漂移检查

- 本仓库放 `docs/contracts/background-task-notification.v1.txt`（三份金样：成功、失败、vanished），两端各有一个渲染测试对它逐字比对。金样的**输入**以 rs 侧 `crates/willdeep-core/src/background_notice/tests.rs` 的 `golden_cases()` 为准，Mac 测试照抄同样的输入。以 `#` 开头的注释行不参与比对。
- rs 侧存一份副本；`scripts/check_background_contract.rb`（rs 仓库）在本机找得到 Xedit 时比对金样正文和附录 A 提示词原文，不一致就红，找不到就跳过。`WORKER_ROUTING_CONTRACT.json` 两边已经漂移（第 78 行起不同）而没人发现，这次不能再靠自觉。

## 分期

| 期 | 范围 | 仓库 | 版本位 |
|---|---|---|---|
| B1 ✅ | CLI：追加写日志 + 尾部缓冲、`get_job_output` 统一语义、通知 v1、提示词段落、金样测试、保留策略、漂移脚本 | willdeep-rs | `0.75.0-rc1` |
| B2 ✅ | Mac：文件 sink + 尾部环形、六个消费方核对、通知 v1、提示词两处替换 + 三档哈希重录、金样测试 | Xedit | MINOR |
| B3 ✅ | 漂移检查脚本（rs 仓库）+ Mac 提示词逐字断言 | 两边 | 随 B2（1.379.0-rc1） |
| C1 ✅ | CLI：`monitor` 工具 + `send_agent_message` / `stop_agent`（实现细则已回写「C·一 / C·二」的「实现细则」小节，C2 必须照做） | willdeep-rs | `0.76.0-rc1` |
| C2 ✅ | Mac：`monitor` 工具 + `send_agent_message` / `stop_agent`（实现偏差见下方「C2 落地偏差」） | Xedit | MINOR（未 bump） |
| C3 ✅ | Mac：`lifetime: persistent` 的本地作业退出 App 后保活、下次启动认领（实现偏差：带注入密钥的作业不脱离、仍随退出清理；脱离日志由 shell 直写，不受 256MB 上限；测试宿主用默认目录时不脱离也不认领） | Xedit | MINOR（未 bump） |

第三批设计见文末「第三批」一节。

B1 先做：改动面小、没有提示词缓存代价，做完就能用它验证 v1 格式读起来顺不顺，再动 Mac。

## 验收

1. 起一条输出 >1MB、最后一行是 `RESULT=42` 的后台命令：两端通知尾巴里都有 `RESULT=42`；`output_path` 指向的文件完整、行数对得上。
2. `get_job_output` 不带参数返回 200 行；`tail_lines=5` 在 CLI 脱离作业上返回 5 行。
3. 三份金样两端渲染逐字一致；把任一端金样改一个字符，两端测试和漂移脚本都红。
4. 长任务期间模型继续干别的，不出现 `sleep` 轮询（用 CLI 无头 + mock provider 断言请求序列里没有 `sleep` 命令）。
5. 256MB 上限：写 300MB 的作业，文件停在上限，`omitted_bytes` 正确，尾巴仍是真实末尾。

## 待确认

1. **Mac 提示词缓存破一次**，可以接受吗？（不接受的话，提示词这一条只在 CLI 做，Mac 保持现有说明。）
2. 成功通知带 10 行尾巴——会让每条成功通知多 ~300 token，换少一次工具调用。
3. 保留策略 7 天 / 200 个是否合适。
4. 本文不含 Monitor 工具、Mac 退出保活、子 Agent `instruct_agent`，那是第三批。

## 第三批：Monitor、给子 Agent 发消息、Mac 退出保活

> 状态：设计已按默认值推进（2026-09-17）。以下「默认」均可改，改了要同时改两端与金样。

### 现状（调研结论）

| 能力 | CLI | macOS |
|---|---|---|
| 按行流式读输出 | **无**，`capture()` 按 8KB 块读 | 只有 executor 的 JSON 事件流按行切（`AgentExecutorEventCollector`） |
| 宿主事件唤醒限流 | 宿主事件**不计**入 6 次 / 5 分钟外部额度 | 同上：`trust == .host` 直接唤醒 |
| 模型给运行中子 Agent 发消息 / 停止 | **无工具**；`instruct_agent` 只接到 TUI、daemon CLI、HTTP | **无工具**；只有界面插话（1000 字符，**静默截断**）和界面停止 |
| 后台作业跨进程存活 | 已有：`DetachedJobStore`（supervisor、exit 文件、启动时刻、owner、delivered） | **无**：退出时连 `.persistent` 一起杀；子进程输出走管道，App 一退日志就断 |

### C·一、`monitor` 工具

用途：盯着一条命令的输出，**每行（合批后）是一个事件**推给模型，进程退出或超时即结束。对标 Claude Code 的 Monitor；替代「sleep + get_job_output」式轮询。

**参数**

| 参数 | 默认 | 说明 |
|---|---|---|
| `command` | 必填 | 与 `run_command` **同一条审批路径**（同一命令同一判定，不开新口子） |
| `label` | 必填 | 面向用户，出现在每条事件里 |
| `timeout_seconds` | 300 | 上限 1800；到点杀进程组并发结束事件 |

**行为（默认值）**

1. 只有 **stdout** 是事件源；stderr 只进日志。每行截到 2000 字符。
2. **合批**：200ms 内到达的行合成一个事件，单个事件最多 50 行（多出的并入下一批）。
3. **防刷屏**：任意 60 秒内超过 30 个事件 → 自动停止并发 `reason: flooded` 的结束事件。宿主事件不走外部唤醒额度，所以这道闸只能长在 Monitor 自己身上。
4. **唤醒**：会话空闲时事件会唤醒它，但**每个 Monitor 每 30 秒最多唤醒一次**；其余事件排队，在下一个回合边界一起交给模型（`yieldAtBoundary`，从不抢占正在跑的步骤）。结束事件不受这条限制。
5. **生命周期**：随宿主进程存活（不做脱离）；`list_jobs` 可见、`kill_job` 可停；无头模式把运行中的 Monitor 算作「还在跑」，等它结束。
6. 完整 stdout/stderr 照样按第一节落盘，事件里给 `output_path`。

**事件格式 v1**（金样见 `docs/contracts/monitor-event.v1.txt`，与通知同样的脱敏与标签中和规则）

~~~
<monitor-event>
id: mon_ab12cd
label: 盯发布日志
seq: 3
lines: 2
```text
Uploading dmg… 100%
ERROR: notarization rejected
```
</monitor-event>
~~~

~~~
<monitor-ended>
id: mon_ab12cd
label: 盯发布日志
reason: exited
exit_code: 1
duration: 4m12s
events: 7
output_path: …/output.log
</monitor-ended>
~~~

`reason`：`exited` / `timed_out` / `killed` / `flooded` / `launch_failed`。

**提示词**：不动两端稳定前缀（Mac 刚破过一次缓存）。用法写进 `monitor` 工具描述：「需要对**进行中**的输出作出反应时用 monitor；只关心最终结果用 `run_in_background`；每行都是一次模型注意力，命令里先用 grep --line-buffered 过滤到值得反应的行，并覆盖失败形态（Error / FAILED / Traceback），别只盯成功标记」。

**实现细则（C1 落地时定下，属于合同，两端一致）**

1. 超过 2000 字符的行保留前 1999 个字符再加 `…`（结果恰好 2000 字符）。
2. 只含空白的行不产生事件，但照样写进日志。
3. 合批除 50 行外还有正文上限：累计约 20000 字符即提前收口（内核正文上限 24000，超了会截坏框架）。
4. 唤醒节流的做法：30 秒内的后续事件以「只入队、不唤醒」进内核，下一个回合边界随其他事件交给模型；结束事件不受限。
5. 触发防刷屏的那一批不投递；结束事件的 `events` 记已投递数（即 30）。
6. `output_path` 指向 stdout 日志（CLI 分流为 `stdout.log`；Mac 合并日志为 `output.log`）。CLI 日志目录 `~/.willdeep/monitors/<mon_id>/`。
7. 句柄 `mon_<6 位十六进制>`；运行中 `get_job_output(mon_id)` 返回状态与日志末尾。
8. 只读审批模式下 `monitor` 直接拒绝。

**C2 落地偏差（Mac）**

1. 审批：`monitor` 在主循环唯一入口改写成带宿主私有参数 `_monitor` 的 `run_command`（`run_in_background: true`），风险、自动批准、审批卡、裁判、沙箱与审计都按那条命令走；模型自己塞进 `run_command` 的 `_monitor` 在同一处剥掉。代价：审批卡与沙箱审计里显示为 `run_command`。
2. Mac 没有「只读审批模式」：等价处理为规划只读回合、设计门禁、计划进度核对回合里直接拒绝 `monitor`；远端工作区也拒绝（只支持本机）。
3. 进程复用 `AgentJobRegistry`：句柄 `mon_xxxxxx`，日志 `background-jobs/<mon_id>/output.log`（stdout/stderr 合并，`output_path` 即它），生命周期 `turn`，随 Stop 与退出 App 清理；被 Stop / 退出清理收掉时结束通知照发但只入队、不唤醒。
4. 内核：事件以 `source=background_job, kind=host_notice, trust=host, content_provenance=tool` 发布，元数据 `notice_contract=monitor-event.v1 / monitor-ended.v1`；`modelNotice` 对这类事件不再整段转义框架（非宿主或非 tool 来源照样转义），但仍做注入标记中和（极少数命中时插入零宽字符）。
5. `stop_agent` 的报告照常投递（不同于界面停止会压掉报告），但 Mac 子 Agent 报告不是 v1 格式，状态拼写为 `cancelled` 而不是 `killed`。
6. 审计：不写 sandbox.jsonl（避免把消息正文写进审计）；每次调用记统一日志（subsystem `com.willdeep.agent`，category `subagent-control`，只记工具、目标与结果），投递成功的消息在子 Agent 活动回执里留一条不含正文的记录（显示为「主 Agent 发来一条指令（N 字）」）。消息首尾空白在投递前去掉，长度按原文计。
7. 核心工具面由 24 个放宽到 26 个上限（新增三个工具进核心，`AgentToolPackTests` 同步）；提示词稳定前缀未改，无哈希重录。

### C·二、`send_agent_message` / `stop_agent`

| 工具 | 参数 | 行为 |
|---|---|---|
| `send_agent_message` | `agent_id`, `message` | 投递到运行中后台子 Agent 的指令收件箱，**下一个回合边界**生效（不打断当前步骤）；`message` ≤ 4000 字符，**超出直接报错，不截断** |
| `stop_agent` | `agent_id` | 停止运行中的后台子 Agent；它的报告照常以 `status: killed` 投回 |

- **只能动本会话起的子 Agent**：按父会话归属校验，别的会话的 id 一律报「找不到」。
- **不需要审批**（等同于在自己的子任务里改主意），但每次调用写审计（CLI：approvals.jsonl 同格式；Mac：子 Agent 活动回执）。
- 子 Agent 自己拿不到这两个工具。
- `agent_id` 就是 `spawn_agent` 返回的句柄（CLI 的 agent id / Mac 的 `agent_xxxxxx`）；目标已结束时报「已结束，报告已投递或即将投递」。
- 实现细则（C1）：`agent_id` 同时接受 UUID 与短句柄；审计只记目标与结果，**不记消息正文**；子 Agent 的工具面同时剔除 `spawn_agent` 与恢复类工具。
- 已知缺口（CLI）：daemon 托管会话里 monitor 事件不唤醒空闲会话；TUI 切换会话后旧 monitor 事件仍记在原会话；`~/.willdeep/monitors/` 暂无保留策略。
- Mac 界面插话的 1000 字符静默截断改为：界面仍 1000 字符但**显示剩余字数并拒绝超长提交**；模型通道 4000 字符。

### C·三、Mac：`persistent` 作业退出保活

只针对 `lifetime: persistent` 的**本地** shell 作业（dev server、长时间 watch）；`turn` / `phase` / `goal` 仍随 App 退出清理。

1. **脱离启动**：不再用 `Process` + 管道，改为 `posix_spawn`（`POSIX_SPAWN_SETPGROUP`，自成进程组）起一个极薄的 `/bin/sh` 包装：命令输出直接重定向进 `output.log`（**文件，不是管道**），命令结束后把退出码写 `exit.pending` 再原子改名为 `exit`。沙箱包装照旧套在命令外层。
2. **作业记录**：`meta.json`（句柄、pid、进程启动时刻、owner runtime id、label、命令、超时截止时刻），0600。
3. **运行中**：App 读日志文件的增量更新内存尾部（替代管道回调），UI、`get_job_output`、通知一律不变。
4. **退出 App**：退出清理跳过这类作业；退出确认框把它们单列为「会继续运行」，不再算作阻塞退出的理由。
5. **下次启动认领**：扫描作业记录 → 进程在且启动时刻对得上 = 重新接管为运行中；有 `exit` = 已结束，向 owner 会话投递一次完成通知（`delivered` 标记防重复，与 CLI 同一判据）；进程不在也没 `exit` = `vanished`。owner 会话已删除则只在任务面板里显示、不唤醒。
6. **超时**：截止时刻写在记录里，接管时按剩余时间重新挂计时器；已过期的立即杀进程组并记 `timed_out`。
7. 日志清理（第一节第 4 条）跳过仍在运行的作业目录。

### 分期与验收

- **C1 验收**：CLI 无头 + mock provider：一条每秒打印一行、第 3 行打 `ERROR` 的 monitor → 模型在进程结束前收到含 `ERROR` 的事件；刷屏命令触发 `flooded`；`send_agent_message` 进得了子 Agent 的下一轮；跨会话 id 被拒。
- **C2 验收**：Mac 同样三条，外加金样逐字一致（两份金样都进漂移脚本）。
- **C3 验收**：起一个 persistent `sleep 60; echo done` → 退出 App（测试里模拟 registry 销毁）→ 进程仍在、日志继续增长 → 新 registry 认领为运行中 → 结束后 owner 会话收到**恰好一次**完成通知；另测 exit 已在 / vanished / 超时过期三种认领分支。

## 附录 A：共用提示词原文

```
Background work: run builds, tests, releases and dev servers expected to take 30 seconds or more with `run_in_background: true` and a short user-facing `label`. You are notified automatically when a background task finishes, so never sleep or poll for it; call `get_job_output` only to check progress mid-run. Keep doing independent work while you wait. When a completion notice arrives, verify its result first, then return to what you were doing. Until that notice arrives, do not claim the task succeeded or guess its outcome. Stop background tasks you no longer need with `kill_job`.
```
