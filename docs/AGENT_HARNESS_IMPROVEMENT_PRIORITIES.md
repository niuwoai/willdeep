# Agent Harness Improvement Priorities

> Last updated: 2026-06-17 | Current version: v1.85.0-rc7

这份文档用于回答一个核心问题：一个 harness 级 Agent 要继续变强，哪些问题必须优先解决。

## 结论

代码复杂度上升必须排在 P0。理由很简单：复杂度会放大所有后续改动的成本，尤其是执行权限、工具审批、远端 runtime、自学习、MCP、移动端桥接和测试隔离这些横切链路。复杂度不先控住，后面每加一个能力都会变成“加功能时顺手多挖一个坑”。

## P0：复杂度与边界

当前状态：已经从多个 2000-3000 行热点拆出 AppState companion、Agent composer、Agent composer palette/chips/badges、Agent message support views、Agent learning event views、Agent learning review store/view、Agent runtime accessors、remote runtime models、Agent tool models、panel cards、file tools、self-learning、turn-end learning、streaming buffer、mobile gateway models、mobile desktop peer、AppState mobile gateway controller、chat history chrome renderer、provider library models、Agent dispatch queue、request estimate helper、tool authorization support、MCP models 和 MCP server directory 等文件；截至 rc90，`scripts/complexity_guard.rb` 扫描 193 个源代码/自动化文件，没有文件超过 2000 行软阈值或 3000 行硬阈值，本地 `scripts/run_tests.sh` 与 GitHub Actions `Tests` workflow 都会生成 Markdown/JSON 复杂度报告。

仍然不好：`AgentMobileGatewayBridge.swift` 已从约 1332 行降到约 593 行，`AgentChatHistoryFormatter.swift` 已从约 1330 行降到约 825 行，`AgentModels.swift` 已从约 1307 行降到约 1090 行，`AppStateAgentLoop.swift` 已从约 1251 行降到约 986 行，`AgentToolAuthorization.swift` 已从约 1177 行降到约 869 行，`AgentMCPBridge.swift` 已从约 1130 行降到约 440 行，`AgentModeComposerView.swift` 已从约 1103 行降到约 687 行，`AgentMessageView.swift` 已从约 1080 行降到约 527 行；`AppStateAgentSessions.swift` 和 `AppState.swift` 仍是 Agent harness 的关键路径。它们暂时没超线，但都是 session lifecycle、routine、provider library 和窗口级状态聚合区，继续叠功能会很快反弹。复杂度守门目前只看行数，还不能发现职责耦合、循环依赖或横切状态扩散。

下一步顺序：

1. `AppStateAgentSessions.swift` / `AppState.swift`：继续观察 session lifecycle、routine、provider library 和窗口级状态聚合。
2. 自学习 review 队列后续动作：继续保持独立 store/view 边界，候选编辑和 MCP 安装确认不要回塞消息主文件。
3. `AppStateAgentLoop.swift`：后续如新增 provider round、tool execution、turn finalization 逻辑，优先落入独立执行阶段文件。
4. `AgentModels.swift`：后续如新增模型域，优先落入独立文件，不再回塞主模型文件。

## P0：执行自主性

当前状态：依赖安装、构建、测试、后台任务和远端 runtime 已经能通过工具链执行；TLS/临时网络错误有重试；沙箱和审批链路能区分 read/write/danger。

仍然不好：真实任务里只要遇到工具缺失、依赖安装失败、远端环境不完整、证书/代理波动，就容易退化成“让用户本地执行”。Harness 级 Agent 应该先自查环境、自己重试、自己给出可执行修复路径，只有凭据、危险操作或外部安装才交给用户确认。

下一步顺序：

1. 把“缺少依赖/命令不存在/权限不足/证书问题”的错误分类做成统一恢复策略。
2. 对 artifact 类任务建立生成后验证规范，例如 PPT/PDF/截图必须由 harness 自己渲染或检查。
3. 对远端 runtime 增加一次性环境准备建议和可复制诊断报告。

## P1：自学习

当前状态：rc71 起有 `add_memory`、`create_user_skill`、`suggest_mcp_server`，并在回合结束时尝试自动 memory 捕获和 skill 候选提取；rc75 起新增 `search_mcp_servers`；rc82 起 system prompt 把 meaningful task 的 learning checkpoint 写成必经路径，同一句“自动 memory / skill / MCP 建议”会拆成具体 memory、skill 和 MCP discovery 策略。rc85 起新增 `AgentSelfLearningAudit`，把本轮 memory、skill 候选、MCP 建议和工具证据数量结构化，MCP 缺口记忆会带具体 `Search query`，默认 skill 沉淀门槛降为 3 次工具调用。rc88 起 `AgentLearningEvent` 会把自动 memory、skill 创建/跳过/失败和 MCP discovery 建议持久化到 session，并在 transcript 底部展示最近学习记录。rc89 起新增持久 review 队列，在 Memory 设置页集中处理待审核学习项，支持复制、标记已审核、忽略和清理已审核记录。rc95 起 `AgentLearningAction` 会给每条自动学习事件附上结构化下一步：工具名、目标、搜索词、原因、下一步、是否需要用户确认；transcript、review 队列和 turn report 都能展示“已经自动保存/创建”和“建议用户确认”的差异。rc98 起 turn report 会额外展示 `Recall`：本轮检索命中的 memories 和随消息注入的 attached skills 会持久化成 `latestTurnRecall`，避免“学到了什么”和“用了什么上下文”继续混在一起。rc99 起 review 队列里的 skill / MCP 项已经能直接跳到对应设置标签、打开用户 skills 目录或复制 MCP 搜索词，开始从“可见”走向“可执行”。rc100 起 skill 候选草稿会结构化保留在 learning action 里，review 队列可直接落盘创建用户 skill，开始从“可执行入口”走向“真正闭环执行”。rc101 起 MCP 建议草稿也会结构化保留，并能直接预填 MCP 新建服务器表单，开始补上外部能力建议的半闭环。rc102 起 MCP 建议在创建成功后会自动收口 review 项，并立刻尝试刷新工具列表，开始从“预填配置”迈向“配置后初步验证”。rc103 起 review 队列里的 skill 候选也支持先编辑草稿再保存，补上从“自动提议”到“人工整理后落盘”的最后一截。rc104 起 learning event 会额外展示 `Confidence / Why`，开始从“有结果”走向“解释得清为什么这样学”。rc105 起 skill / MCP 事件 detail 进一步补上 `Source:`，把工具序列、显式用户要求和外部能力缺口直接暴露出来。rc106 起每条 learning 事件会在回合结束时与本轮 turn recall 命中做确定性交叉关联（命中项标题逐字出现，或共享 ≥2 个关键词即关联），`AgentLearningEvent.relatedRecall` 持久化这些回链，transcript 学习卡、复制文本和 turn report 学习行都会显示 `Related recall:`，让系统不只说“建议来自工具序列”，还能说“它和本轮哪些 recall 命中有关”。rc108 起每条回链再带上 0–1 关联评分、strong/related/weak 分档和“为什么关联”的原因（逐字标题命中或共享了哪些关键词），按强度排序，summary 显示分档、复制文本展开每条原因。rc109 起评分把召回检索分数也并进来（match 0.7 + 检索 0.3，原因里注明 `recalled at 0.NN`），turn report 的 recall 区会逐条标注“已关联到学习建议”或“为什么没关联”（近失：只共享 1 个关键词，需 ≥2）。rc110 起 recall 区顶部加一行利用率汇总（`N linked · M near-miss · K unused`），零学习的回合改标注“无学习建议可关联”，一眼看出本轮召回是否真的喂给了学习。

仍然不好：学习结果已经结构化、可见、可审核，能与本轮 recall 命中带评分/原因地互链，turn report 也解释近失并给出利用率汇总；但“为什么没关联”目前只覆盖召回侧的近失，还没扩展到学习侧候选被阈值过滤/去重/置信度过低等跳过类别，也仍缺少自动 skill 发现来源和 MCP 建议命中来源。MCP 建议已经带 action metadata 和用户确认边界，也开始做创建后的工具列表探测，但还没有进入一键确认安装、凭据配置和安装后验证闭环。

下一步顺序：

1. （rc106 关联，rc108 评分/分档/原因，rc109 检索分数 + 近失原因，rc110 利用率汇总）recall↔learning 关联已把检索分数并进评分，turn report 逐条标注命中项是“已关联/近失/未用”，并新增一行利用率汇总（`N linked · M near-miss · K unused`，零学习的回合单独标注“无学习建议可关联”）。下一步可做：把“为什么没命中”从近失扩展到学习侧的跳过类别（候选被阈值过滤、被去重、置信度过低），把跳过理由也带进 recall/learning 视图。
2. 在 transcript 或 debug 面板展示本轮命中的 memory/skill/MCP 建议、跳过原因和召回来源。
3. 对重复、过期、低置信度 skill/memory 做维护任务。

## P1：MCP 与外部能力发现

当前状态：Agent 可以列出 MCP server/tool，也可以在缺少外部能力时先 `search_mcp_servers` 搜索候选、再用 `suggest_mcp_server` 记录 MCP 建议；没有 web search key 时仍会返回具体查询和 fallback 指引。rc82 起“不能访问外部服务”前必须先走 MCP discovery 判断，GitHub、Gmail、数据库、Figma、浏览器、ERP 等常见缺口会自动沉淀为后续可召回策略。rc88 起 MCP discovery 建议会作为 session 学习事件在 transcript 中可见，包含 search query 和用户确认边界。rc89 起这些建议也会进入 review 队列，避免只在当前会话里临时可见。rc95 起 MCP 建议在学习事件里携带 `suggestMCPInstall` action，明确 capability、search query、原因、下一步和 `requiresUserConfirmation`。

仍然不好：还没有形成“建议面板 -> 用户一键确认配置 -> 安装后自动验证 server/tool 可用”的完整 UI 闭环。凭据与安全边界也必须在流程里显式出现。

下一步顺序：

1. 建立 MCP 建议 review UI：能力缺口、候选 server、来源、安装方式、凭据需求、安全风险。
2. 安装前必须给用户确认，安装后自动 `list_mcp_servers` / `list_mcp_tools` 验证。
3. 对常见系统（GitHub、Gmail、数据库、浏览器、ERP）维护推荐 MCP/connector 映射。

## P2：可观测性与测试

当前状态：工具调用、审批、沙箱、后台任务、版本、Mobile Gateway readiness 都已有一定测试或报告。rc90 起基础 GitHub Actions workflow 会跑复杂度守门和 XeditTests，并上传复杂度报告与 Xcode 测试报告。rc91 起同一 workflow 增加版本一致性检查和 `willdeep-agent` 的 `go test ./...`，版本漂移与 Go agent 回归会在 PR 级别暴露。rc93 起 transcript 底部新增最新 turn report，用户能看到模型/provider、工具、审批、sandbox 和自学习动作的一轮摘要。rc95 起 turn report 的学习区会优先显示结构化 action（例如 saved memory、created skill、suggest MCP install），复制报告时也包含这些动作。rc98 起 turn report 新增 `Recall` 区块，显示本轮命中的 memory / attached skill 来源。

仍然不好：CI 覆盖面还不够，跨 runtime、跨移动端、跨 MCP 的端到端验证仍然依赖本机人工触发。turn report 已经补了第一段 memory / attached skill 召回来源，但还没有精确记录网络/TLS retry 次数、自动 skill / MCP 建议的召回来源，以及每个工具的完整 sandbox decision 历史。

下一步顺序：

1. 给 Agent turn report 继续补精确 retry 计数、自动 skill / MCP 建议召回来源和完整 sandbox decision。
2. 对高风险路径补最小 E2E smoke：远端 runtime、Mobile Gateway、MCP 调用、artifact 生成。
3. 给 CI 失败摘要补更明确的“哪个闸门失败、下一步怎么修”提示。

## 执行原则

- 先降复杂度，再叠能力。
- 任何自动化动作都要可审计。
- 能由 harness 执行和验证的，不交给用户执行。
- 安装、凭据、危险写操作必须让用户确认。
- 每次新增能力都要配一个最小验证路径。
