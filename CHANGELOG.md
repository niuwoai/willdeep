# Changelog

> 当前文件保留最新版本（1.247.0-rc16 至 1.109.0-rc340）。
> 更早的 1000 个版本已移至 [CHANGELOG-ARCHIVE.md](CHANGELOG-ARCHIVE.md)。

## 1.247.0-rc16 - 2026-08-12

### Fixed

- 侧边栏会话列表在冷启动加载完成前不再显示"您开始的会话将显示在这里。"的空态文案。会话目录在后台线程从磁盘读取（`AgentSessionStore.loadAllWithMetadata()`），头几百毫秒列表必然为空，旧逻辑只看 `agentSessions.isEmpty` 就渲染空态，用户会误以为会话丢了。现在空态三分：目录未加载完且列表为空 → 显示"正在加载会话…"加载占位（小号 ProgressView + 说明文字，高度钉在正常行高 31pt，首批会话落地时无布局跳动）；目录加载完且确实没有会话 → 维持既有空态文案；列表非空 → 现状不变。分支选择抽成纯函数 `AgentSidebarCatalogPlaceholder.state(hasLoadedCatalog:isSessionListEmpty:)`，由已有的 `@Published hasLoadedAgentSessionCatalog` 驱动视图刷新。
- 中继模式的配对载荷不再复制局域网字段。`MobileGatewayCoordinator.relayPairingPayload` 此前把中继地址和中继 token 各复制一份填进 `base_url` / `pairing_token`，中继模式下压根没有本地网关可连，这两份副本换不来任何能力，却白占约 100 字节二维码容量（重复 token 单独就能把码推高一到两个版本）。现在两字段改为可选、传 `nil`，JSON 编码时直接省略；手机端本就从 `relay_base_url` / `relay_token` 取值（紧凑二维码参数 `r`/`t` 一直如此），紧凑分支不受影响，对 Android ≥ 1.25.0-rc5 线上兼容。
- 设置面板"配对地址"一行改取 `baseURL ?? relayBaseURL`，中继模式显示手机实际加入的中继端点；两者皆空时整行隐藏，不再留一行空白。

### Tests

- `AgentSidebarListVisualMetricsTests` 新增占位三分支用例，覆盖加载中/真空态/列表非空的输入组合。
- `MobileGatewayCoordinatorTests.relayPairingPayloadCarriesRelayCoordinates` 改为断言 `baseURL` / `pairingToken` 为 `nil`，并新增断言配对 JSON 不含 `"base_url"` / `"pairing_token"`。

### Meta

- 侧边栏加载态与中继配对载荷瘦身合入 develop，预发布版本从 **1.247.0-rc15** 提升为 **1.247.0-rc16**，内部构建号 **359 → 360**，Help 与 Computer Use Helper 构建号 **275 → 276**；App、Go agent、Help、Helper、浏览器扩展、响应头契约与产品文档保持一致。
- 两个分支各自携带的版本位点（rc14 / rc12）在合并时统一取 develop 侧，条目文本归位到本条 rc16。

## 1.247.0-rc15 - 2026-08-12

### Fixed

- “已安排”中的只读远程巡检会先验证 SSH 传输参数，再递归检查远端载荷；有时间边界的 `journalctl` 读取、`systemctl show/status/is-active` 查询和 grep/sort/head 等只读分析链可在 Smart 审核下直接执行，不再频繁停在无人值守的人工审批卡。
- 普通 Smart 会话的可见终端与后台周期任务共用 `readOnlyNetwork` 边界；交互式 SSH、隧道或代理、远端重定向写入、服务重启及日志维护仍进入 `someim-security-guard` 或人工复核。
- `someim-security-guard` 请求新增精确工具类型和从当前用户诉求截取、凭据脱敏、限长的任务意图。任务意图只帮助判断动作相关性，不构成授权、不能覆盖命令事实或扩大沙箱权限。
- 智能审核 YES 缓存收紧为“工具 + 精确命令 + 脱敏任务上下文”，避免依赖一次任务意图的结论跨目标复用；明确 NO、无效输出和服务不可用继续失败关闭。

### Tests

- 新增只读 SSH 日志、服务状态、复合过滤链、交互式 SSH、代理参数、远端写入、服务重启及日志维护的分类回归覆盖。
- 新增任务上下文 XML 隔离、凭据脱敏、长度上限、伪造 verdict 防护、上下文缓存键及 some.im 服务端托管请求体测试。

### Meta

- 周期任务、普通会话与 Auto-review 审核边界补齐，预发布版本从 **1.247.0-rc14** 提升为 **1.247.0-rc15**，内部构建号 **358 → 359**，Help 与 Computer Use Helper 构建号 **274 → 275**；App、Go agent、Help、Helper、浏览器扩展、响应头契约与产品文档保持一致。

## 1.247.0-rc14 - 2026-08-12

### Fixed

- 用量统计价格表补齐缺口：some.im 托管系列（`someim-auto-*` / `someim-code-*` / `someim-coding-plan-*`，含经 `custom` 中转的场景）按 `deepseek-v4-flash` 价目（$0.14 / $0.28 每百万 token）估算；`kimi-k3` 按 Moonshot 官方牌价 $3 输入 / $0.30 缓存命中 / $15 输出补入。此前这批模型全部落入"未定价"。
- 修复 `gpt-5.6-sol` / `gpt-5.6-terra` / `gpt-5.6-luna` 被子串匹配误算成 gpt-5 价目（$1.25/$10）的问题：新增 gpt-5.6 三档专属价格行（sol $5/$30、terra $2/$12、luna $0.20/$1.20，缓存输入 10%），并置于 `gpt-5` 家族行之前。
- 用量日历"未定价"不再一票否决：某天存在无法计价的消息（无价格行、外部 CLI 委托等）时按 $0 计入而非把整天金额置为"未定价"，月汇总同步恢复显示真实金额。

### Meta

- 定价与统计修复，预发布版本从 **1.247.0-rc13** 提升为 **1.247.0-rc14**；App、Go agent、Help、Helper、浏览器扩展、响应头契约与产品文档保持一致。

## 1.247.0-rc13 - 2026-08-12

### Fixed

- 其余测试一次性 UserDefaults suite 全部纳入 rc12 引入的卫生机制。开发机上 `~/Library/Preferences` 里仍有约 4800 个未登记前缀的壳在泄漏：`willdeep-runtime-store-*` 数千个、`com.willdeep.tests.learningReview.*` 约 580 个，外加 `willdeep-mobile-gateway-*`、`test.workspace.identity.*`、`CollaborationConnectorSettingsTests.*` 等。8 个测试文件（AgentSelfLearningTests、AgentRemoteRuntimeTests、MobileGatewayCoordinatorTests、SomeIMManagedRoutingTests、CollaborationConnectorSettingsTests、AgentSidebarWorkspaceStateStoreTests、AgentMCPServerDirectoryTests、AgentDispatchCoordinatorTests）的收尾统一改走 `TestDefaultsHygiene.cleanup`，其中 MobileGatewayCoordinatorTests 的 6 处和 AgentWorkspaceIdentityStoreTests 此前完全没有收尾。
- `TestDefaultsHygiene.disposableSuitePrefixes` 登记全部 16 个一次性前缀（含 `willdeep-runtime-store-` 这类 UUID 直接用连字符相接、不带结尾点的前缀，按实际字面量登记，不误伤 `com.willdeep.app` / `WillDeep` 等真实配置域）；`cleanup` 现在兜底触发进程级 sweep，`-only-testing` 只跑单个套件时也能扫掉上一轮残留，存量壳会在登记后的第一轮测试被自动清空。

### Meta

- 测试卫生修复，预发布版本从 **1.247.0-rc12** 提升为 **1.247.0-rc13**；App、Go agent、Help、Helper、浏览器扩展、响应头契约与产品文档保持一致。

## 1.247.0-rc12 - 2026-08-12

### Fixed

- 单元测试不再往 `~/Library/Preferences` 里无限撒一次性 UserDefaults 壳文件（开发机上已累积 2182 个 `com.willdeep.agent.test.defaults.*.plist` 和 202 个 `com.willdeep.mcp.test.*.plist`）。两处根因实测确认：其一，MCP 信任测试的 defer 只调 `removePersistentDomain`，而该调用只清空域内容，磁盘上必留一个 ~42 字节空壳，每跑一次漏一个；其二，`KeychainSandbox` 虽然在 deinit 里删了壳文件（1.228.0-rc8 起），但删除动作与 cfprefsd 的异步落盘存在竞态，每轮全量测试仍漏出个位数的壳。
- 新增 `XeditTests/TestDefaultsHygiene.swift` 双层防御：每个 suite 用完即走完整收尾（`removePersistentDomain` + `removeSuite(named:)` + 删壳文件），并在每个测试进程首次建 suite 时扫掉上一轮被 cfprefsd 复活的壳——磁盘残留从此收敛在一轮的量以内。`KeychainSandbox` 与 MCP 信任测试均改走该工具；一次性 suite 前缀集中登记，避免误伤 `com.willdeep.app` 等真实配置域。

### Meta

- 测试卫生修复，预发布版本从 **1.247.0-rc11** 提升为 **1.247.0-rc12**；App、Go agent、Help、Helper、浏览器扩展、响应头契约与产品文档保持一致。

## 1.247.0-rc11 - 2026-08-12

### Fixed

- 快速测试入口失败时不再把上一次的绿色报告留在原地冒充本次结论。`scripts/run_tests_fast.rb` 此前只在成功路径写 `build/fast-tests/report.{json,md}`，一旦测试失败或构建阶段就挂掉，脚本直接退出，磁盘上仍是上一轮的 `"ok": true`——而 `TESTING.md` 恰恰让调用方以该文件为准，一个陈旧的绿勾足以让跑崩的构建冒充跑通的构建。现在失败路径会先把报告置为红，再交给 `xcresult_report.rb` 补齐真实失败详情（bundle 不可读时回落原始日志），并以运行器自身的退出码为最终裁决，避免"构建未进入测试阶段、xcresult 计数看着干净"被误报为通过。
- 失败报告因此带上了可直接读的失败用例名、断言和行号，不必再去 grep 原始 xcodebuild 日志。

### Tests

- 手工验证三种路径：用例失败（`source=xcresult`，26 passed/1 failed 且 `failures` 含用例名与断言行）、编译失败（`source=xcodebuild-log`，计数归零并注明为近似值）、正常通过（`ok=true`）。

### Meta

- 测试报告可信度修复，预发布版本从 **1.247.0-rc10** 提升为 **1.247.0-rc11**；App、Go agent、Help、Helper、浏览器扩展、响应头契约与产品文档保持一致。

## 1.247.0-rc10 - 2026-08-12

### Fixed

- CI 的 `short-drama` 守卫组恢复通过。`short_drama_media_contract` 用源码字符串比对断言侧边栏组件历史的取数方式，而 2026-08-09 的重构（`420dad70`）已把 `widgetRegistry.widgets(forRuntime: appState.activeRuntime?.id)` 换成等价的局部变量写法 `runtime?.id`，断言文本没有跟着更新，从那天起该守卫一直为红（此前几次发布的 Actions 均被取消，没有暴露）。断言改为匹配现有写法，行为未变。

### Meta

- CI 守卫断言跟上既有重构，预发布版本从 **1.247.0-rc9** 提升为 **1.247.0-rc10**；App、Go agent、Help、Helper、浏览器扩展、响应头契约与产品文档保持一致。

## 1.247.0-rc9 - 2026-08-12

### Fixed

- 审阅卡片渲染用例（`AgentSidePanelDiffPerformanceTests` 的"差异行底色铺到卡片右边缘"）不再随机翻车。旧写法先 `Task.sleep` 硬等 300ms 让 SwiftUI 收敛再抓位图，机器忙时布局尚未完成就采样，采到未着色的画面；现在改为反复 `layoutSubtreeIfNeeded` + 采样，直到画面进入目标状态为止，上限 20 秒，超时才失败并打印诊断（负载高只是变慢，不再假失败）。
- 同一用例的采样坐标修掉一个真实的取样错误：`NSBitmapImageRep.colorAt(x:y:)` 取的是像素坐标，而用例按点坐标取样，在 Retina 位图（1800×520）上实际只扫了卡片左半边的上半截。现在按位图与视图的实际缩放比换算，并改为"卡片中部有底色的行，在右边缘必须同样有底色"的逐行比对——右边缘那颗"+2 −1"统计角标的红色字形不再被误判成删除行。

### Fixed

- Agent 回复末尾的「已处理 · 用时」状态行改为跟随正文字体与字号，此前固定使用 13pt 系统字体，调大正文字号后这一行会明显偏小，与上一版「统计跟随正文排版」的约定不一致。

### Changed

- 桌面宠物动画节拍由 8fps 降为 4fps（前后台一致）。对空闲 App 的采样显示，主线程残余的 CPU 时间几乎全部落在这条时间线驱动的 CA transaction flush 上；宠物姿势以约 3 秒为周期且像素画风，减半节拍不改变动作观感。
- 桌面宠物处于 `idle` 心情时不再挂载时间线，改为停在固定姿势；`walking`／`typing`／`ready`／`attention`／`celebrating` 以及周期性自动跳跃仍照常播放，宠物会自行恢复动作而不是看上去卡住。
- 桌面宠物的消息预览由每 0.4 秒重算改为每 2 秒重算并复用缓存。该计算需要遍历全部运行时与历史会话并切分消息正文，是 0.4 秒定时器上最贵的一步，而它本身并不需要即时刷新；忙碌、输入中等状态仍按原节拍响应。

### Tests

- 覆盖 4fps 节拍上限、`idle` 停表与其余心情继续动画的门禁，以及消息预览的重算节流（含时钟回拨不会让缓存永久失效）。
- 修正消息页脚渲染回归测试中与目标测试互相矛盾的字号断言：一处要求状态行等于正文字号、另一处要求等于系统字号，二者不可能同时成立，前者长期为红。现统一为跟随正文。
- 修复网络桩测试之间的并发互扰：三个 `URLProtocol` 桩此前各用一个全局 `static handler`，同一 Suite 内并发执行的用例会互相顶掉对方的桩（`someIMRouteJudge…` 因此收到安全裁判的响应且录制器为空）。改为按 stub 会话令牌路由处理器，令牌随会话默认请求头下发，用例之间不再可见彼此的桩。

### Meta

- 桌面宠物空转开销优化，预发布版本从 **1.247.0-rc7** 提升为 **1.247.0-rc8**；App、Go agent、Help、Helper、浏览器扩展、响应头契约与产品文档保持一致。

## 1.247.0-rc7 - 2026-08-12

### Fixed

- 审阅文件卡片不再把主线程钉死：卡片宽度改为在卡片本体上测量，不再测量它内部那个由行宽撑开的横向滚动视图。旧写法让"测量 → 行宽 → 内容尺寸 → 再测量"形成闭环，采样显示主线程 100% 卡在 SwiftUI 的 `LazySubviewPlacements.placeSubviews` 里空转、整分钟不回到 runloop。写回宽度另加 0.5pt 量化门禁，亚像素抖动不再重新触发布局。
- 工作区改动签名不再为了两个数字读遍扩展属性：`FileManager.attributesOfItem` 换成 `lstat(2)`。前者会对每个改动文件额外发起 `listxattr` 加逐个 `getxattr`，在改动较多的工作区里这些系统调用是刷新开销的大头。语义保持不跟随符号链接。
- 刷新 Git worktree 列表时仓库根目录只解析一次：`listGitWorktrees` 与仓库身份查询过去各自解析一遍，等于每次刷新对同一目录多 spawn 一个 `git rev-parse --show-toplevel` 子进程。

## 1.247.0-rc6 - 2026-08-12

### Fixed

- 审阅侧边栏的差异行底色不再"画一半"：文件卡片里的新增绿底、删除红底会铺满整行（横向可滚动内容也一样），不再停在文字末尾或固定的 480pt 处。
- 单文件详情差异（TextKit 渲染）改为按整行绘制底色，取代只给字形上色的字符属性，行尾之后不再出现空白断口。

## 1.247.0-rc5 - 2026-08-12

### Fixed

- Agent 右侧“预览”面板的 Markdown 正文、标题、列表、引用、表格与代码块现在跟随主聊天区的字体、字号和行高设置，不再使用系统 `.body`、固定 3 pt 行距及 12 pt 表格字号。
- 编辑器自身的 Markdown 预览继续使用原有排版默认值；Agent 外观设置只影响 Agent 侧边栏，避免跨功能意外改样式。

### Tests

- 新增 Markdown 预览排版回归，覆盖 Agent 字体、字号、行高、设置边界收敛及侧边栏注入关系。

### Meta

- Agent 预览排版同步修复使预发布版本从 **1.247.0-rc4** 递增为 **1.247.0-rc5**，内部构建号 **357 → 358**，Help 与 Computer Use Helper 构建号 **273 → 274**；App、Go agent、Help、Helper、浏览器扩展、响应头契约与产品文档保持一致。

## 1.247.0-rc4 - 2026-08-12

### Fixed

- 编辑器设置移除重复的“背景”标签及其页面；工作区壁纸和 Agent 背景效果现在只在独立“Agent 外观”中配置。
- 编辑器二级导航收敛为编辑、格式、字体和工作区四项，避免同一壁纸设置在两个入口并存。

### Tests

- 更新设置页信息架构回归，锁定编辑器四标签结构，并确认 Agent 外观继续作为背景设置的唯一归属。

### Meta

- 设置页背景入口归属修复使预发布版本从 **1.247.0-rc3** 递增为 **1.247.0-rc4**，内部构建号 **356 → 357**，Help 与 Computer Use Helper 构建号 **272 → 273**；App、Go agent、Help、Helper、浏览器扩展、响应头契约与产品文档保持一致。

## 1.247.0-rc3 - 2026-08-11

### Fixed

- 修复 Composer 内 `Menu` 与无边框 `Button` 仍继承 macOS 系统蓝色强调色的问题；在 Composer 卡片边界统一覆盖控件 tint，使工作区、运行位置、执行器、模式和审核图标按真实渲染结果保持黑白灰。

### Tests

- 扩展 Composer 图标色回归，除单色 SF Symbol 与语义色令牌外，额外锁定 Composer 根层的灰阶 tint，防止源码前景色看似正确但系统控件仍渲染为蓝色。

### Meta

- Composer 控件 tint 修复使预发布版本从 **1.247.0-rc2** 递增为 **1.247.0-rc3**，内部构建号 **355 → 356**，Help 与 Computer Use Helper 构建号 **271 → 272**；App、Go agent、Help、Helper、浏览器扩展、响应头契约与产品文档保持一致。

## 1.247.0-rc2 - 2026-08-11

### Changed

- Composer 顶部运行上下文、底部操作栏、附件与技能标签、任务进度及模型选择面板中的图标统一使用黑、白、灰语义色。
- 选中、警告、完成、失败和录音状态继续通过图标形状、描边与明暗层级表达，图标不再继承蓝色强调色、Provider 品牌色或绿／橙／红／紫／青状态色。

### Tests

- 新增 Composer 图标色源代码回归，阻止 SF Symbol 与带图标 Label 重新使用彩色前景，并锁定单色渲染和黑白灰令牌。

### Meta

- Composer 视觉一致性修正使预发布版本从 **1.247.0-rc1** 递增为 **1.247.0-rc2**，内部构建号 **354 → 355**，Help 与 Computer Use Helper 构建号 **270 → 271**；App、Go agent、Help、Helper、浏览器扩展、响应头契约与产品文档保持一致。

## 1.247.0-rc1 - 2026-08-11

### Added

- 设置侧栏新增独立一级“Agent 外观”，集中管理 Agent 背景、正文字体、字号与行高；Agent 相关选项不再混在编辑器字体和背景页面中。
- Agent 正文字体新增系统、圆体、衬线体、系统等宽与 Menlo 选项，历史消息和正在生成的消息即时同步。
- Agent 行高支持 1.20×–2.00× 调节，新安装默认使用 15 pt、1.50×，改善中英文长回复的阅读密度。

### Changed

- Agent 正文结束后按当前字号与行高留出一整行空白；工具摘要和消息统计保持相邻，并与正文分层展示。
- 工具摘要、Token／托管路由统计统一跟随 Agent 正文的字体、字号和行高；当前工具执行区与历史 TextKit 消息采用同一排版规则。
- 强化 Agent 输出克制规则，禁止用勾、叉、庆祝图案等 emoji 充当完成状态标记，完成情况改用普通句子表达。

### Tests

- 扩展设置导航、聊天排版与系统提示快照回归，覆盖独立“Agent 外观”分组、默认字体、默认行高、元信息排版、正文分隔及工具摘要与统计栏成组关系。

### Meta

- 新增 Agent 外观与消息排版能力，功能预发布版本从 **1.246.0-rc1** 提升为 **1.247.0-rc1**，内部构建号 **353 → 354**，Help 与 Computer Use Helper 构建号 **269 → 270**；App、Go agent、Help、Helper、浏览器扩展、响应头契约与产品文档保持一致。

## 1.246.0-rc1 - 2026-08-11

### Added

- “Token 活动”区新增可点击的月度用量日历，按周日到周六展示每天的 Token、预估费用和会话数。
- 用量日历支持上一个月、下一个月切换，并可通过“概览”返回新聊天统计页。
- 每日数据从真实会话快照聚合；遇到未定价模型时显示未知费用，不输出误导性的部分合计。

### Tests

- 新增每日 Token／费用／去重会话聚合、2026 年 8 月周日起始 6 周网格和生产 SwiftUI 月历渲染回归。

### Meta

- 功能预发布版本从 **1.245.0-rc4** 提升为 **1.246.0-rc1**，内部构建号 **352 → 353**，Help 与 Computer Use Helper 构建号 **268 → 269**；App、Go agent、Help、Helper、浏览器扩展、响应头契约与产品文档保持一致。

## 1.245.0-rc4 - 2026-08-11

### Fixed

- 修复 Goal 尚未完成时，仅因连续缺少机器可读计划状态就停止执行的问题；完成一次状态校准后恢复完整执行，而不是把格式遗漏误判为实际阻塞。
- 未完成 Goal 使用独立的 24 轮有界续跑预算，普通计划仍保留原有 8 轮安全上限。
- 吸附目标条新增播放/暂停按钮：运行中可暂停当前 Goal，空闲时可沿用现有路线图、计划、验收项与证据继续执行。

### Tests

- 新增 Goal 缺失计划状态时继续执行、Goal 独立续跑上限、播放/暂停图标与继续提示词回归。
- 新增真实吸附目标条渲染夹具，用于校验播放按钮、阶段信息和编辑操作的紧凑布局。

### Meta

- Bugfix 预发布版本从 **1.245.0-rc3** 递增为 **1.245.0-rc4**，内部构建号 **351 → 352**，Help 与 Computer Use Helper 构建号 **267 → 268**；App、Go agent、Help、Helper、浏览器扩展、响应头契约与产品文档保持一致。

## 1.245.0-rc3 - 2026-08-11

### Fixed

- 修复对话右下角折叠计划卡同时展示阶段与执行状态时，状态徽标被横向压缩成竖排文字的问题。
- 窄宽度下优先保留单行状态；空间不足时先省略次要阶段标签，展开、菜单及状态语义保持不变。

### Tests

- 新增窄宽度状态徽标渲染回归，验证“执行中”等本地化文案不会被压成多行。

### Meta

- Bugfix 预发布版本从 **1.245.0-rc2** 递增为 **1.245.0-rc3**，内部构建号 **350 → 351**，Help 与 Computer Use Helper 构建号 **266 → 267**；App、Go agent、Help、Helper、浏览器扩展、响应头契约与产品文档保持一致。

## 1.245.0-rc2 - 2026-08-11

### Fixed

- 左侧“置顶”分组中的会话不再于每一行右侧重复显示常驻图钉，多个置顶会话并列时保持简洁；非悬停状态同时释放尾部图标宽度，让较长标题获得更多展示空间。
- 鼠标悬停时的取消置顶与归档操作保持不变，置顶排序、分组和右键菜单行为不受影响。

### Tests

- 更新侧栏视觉尺寸回归，验证非悬停会话不再预留置顶图标宽度，悬停后仍恢复完整操作区。

### Meta

- Bugfix 预发布版本从 **1.245.0-rc1** 递增为 **1.245.0-rc2**，内部构建号 **349 → 350**，Help 与 Computer Use Helper 构建号 **265 → 266**；App、Go agent、Help、Helper、浏览器扩展、响应头契约与产品文档保持一致。

## 1.245.0-rc1 - 2026-08-11

### Added

- Goal 模式的吸附目标编辑器现在只向用户展示目标描述；验收标准改为 AI 管理的内部契约，不再暴露文本编辑或手动勾选入口。
- Goal Teams 规划提案新增机器可读的 `goal-acceptance` 契约。目标变化后，AI 会判断现有验收项是否仍适用，并自行保留、修改、删除或补充；完全相同且仍适用的条目保留既有完成状态。

### Changed

- 保存有实质变化的目标后，会立即废止旧 Plan、规划证据与阶段路线图，并自动启动新一轮 Goal Teams 规划；若当前回合仍在输出，则在安全点排队触发。未修改目标文本时不会重复规划。

### Tests

- 新增目标编辑与 AI 验收契约回归，覆盖保存后自动重规划、内部验收项不被用户编辑、AI 调整验收项以及仍适用完成状态的保留。

### Meta

- 功能预发布版本从 **1.244.0-rc4** 提升为 **1.245.0-rc1**，内部构建号 **348 → 349**，Help 与 Computer Use Helper 构建号 **264 → 265**；App、Go agent、Help、Helper、浏览器扩展、响应头契约与产品文档保持一致。

## 1.244.0-rc4 - 2026-08-11

### Fixed

- 修复 Goal Teams 首轮规划成员因结构化工具调用格式不兼容而整轮停止的问题：Provider 未发出工具调用时，可接纳通过相同 Schema 校验的纯 JSON 或单个 JSON 代码块，并在格式无效时发起纠正重试。
- 首轮只有 0/3 或 1/3 份有效报告时不再直接阻塞，改由只读仲裁器检查仓库并补足证据；仲裁器自身仅发生结构化格式错误时使用保守兜底继续生成提案，真实的网络、权限与外部状态故障仍保持阻塞。

### Tests

- 扩展子 Agent 与 Goal 规划回归，覆盖纯 JSON/JSON 代码块兼容、额外字段和混杂说明拒绝、0/3 与 1/3 报告补偿、仲裁格式兜底，以及网络超时后人工重试仍只重跑仲裁。

### Meta

- Bugfix 预发布版本从 **1.244.0-rc3** 递增为 **1.244.0-rc4**，内部构建号 **347 → 348**，Help 与 Computer Use Helper 构建号 **263 → 264**；App、Go agent、Help、Helper、浏览器扩展、响应头契约与产品文档保持一致。

## 1.244.0-rc3 - 2026-08-11

### Fixed

- 修复拖拽调整右侧文件、终端、预览、计划等面板宽度时，聊天区偶发滚动到顶部的问题。
- 连续宽度变化现在共用拖拽开始前的阅读锚点，并等待 TextKit 的宽度与高度重排稳定后再提交最终锚点；重排过程中的临时顶部偏移不再污染后续恢复。

### Tests

- 扩展聊天滚动策略回归，覆盖连续侧边栏拖拽期间原始阅读锚点不会被瞬时零偏移覆盖。

### Meta

- Bugfix 预发布版本从 **1.244.0-rc2** 递增为 **1.244.0-rc3**，内部构建号 **346 → 347**，Help 与 Computer Use Helper 构建号 **262 → 263**；App、Go agent、Help、Helper、浏览器扩展、响应头契约与产品文档保持一致。

## 1.244.0-rc2 - 2026-08-11

### Fixed

- 修复侧边栏终端只读命令的智能审核误判：管道中仅以 `token`、`secret` 等凭据名词作为 `grep`/`rg` 筛选模式时，不再被当成读取凭据文件，截图中的 Kubernetes 查询现在可由静态安全分类直接放行。
- 文本筛选只在“读取管道输入且只有一个筛选模式”时享受只读判定；一旦附带 `.env`、凭据路径或额外文件参数，仍要求人工确认。

### Tests

- 扩展命令安全与 Smart 审核回归，覆盖完整 Kubernetes 查询链自动放行，以及相似的敏感文件读取继续拦截。

### Meta

- Bugfix 预发布版本从 **1.244.0-rc1** 递增为 **1.244.0-rc2**，内部构建号 **345 → 346**，Help 与 Computer Use Helper 构建号 **261 → 262**；App、Go agent、Help、Helper、浏览器扩展、响应头契约与产品文档保持一致。

## 1.244.0-rc1 - 2026-08-11

### Added

- 自动学习审阅队列新增 15 天待处理保留期：记忆、Skill 候选和 MCP 建议从创建起满 15 天仍未审阅或忽略时自动过期；已处理记录不受影响。
- 学习审阅说明同步展示自动过期规则，避免用户误以为待处理内容会永久保留。

### Tests

- 新增自动学习过期边界回归，覆盖到期前一秒仍保留、满 15 天立即移除、已审阅记录不被误删，以及过期清理持久化。

### Meta

- 自动学习待处理内容生命周期能力使版本从 **1.243.0-rc2** 推进为 **1.244.0-rc1**，内部构建号 **344 → 345**，Help 与 Computer Use Helper 构建号 **260 → 261**；App、Go agent、Help、Helper、浏览器扩展、响应头契约与产品文档保持一致。

## 1.243.0-rc2 - 2026-08-11

### Fixed

- “添加记忆”和编辑记忆的文本输入区补齐 8 pt 内容内边距，文字不再紧贴输入框边缘。
- 记忆时效、范围与来源标签统一走本地化资源；简体中文界面现在显示“临时/长期”“全局/项目”“自动/手动”，不再混入 `Long-term`、`Global` 等英文。

### Tests

- 新增记忆设置展示回归，锁定元数据标签必须由本地化映射提供，并固定文本输入区的内容内边距。

### Meta

- Bugfix 预发布版本从 **1.243.0-rc1** 递增为 **1.243.0-rc2**，内部构建号 **343 → 344**，Help 与 Computer Use Helper 构建号 **259 → 260**；App、Go agent、Help、Helper、浏览器扩展、响应头契约与产品文档保持一致。

## 1.243.0-rc1 - 2026-08-11

### Fixed

- Composer 的 `@` 引用和 `$` 技能触发菜单在方向键切换选项时，会把当前选中项自动滚动到可视区域中间；`/` 命令菜单继续保持同一行为。
- `$` 技能菜单的保底高度由 3 个完整项目提高到 5 个，搜索结果较多时可同时浏览更多候选。
- 用量统计不再只依赖会话当前模型：客户端会为每条助手回复持久化实际请求的 Provider 与模型，同一会话中途切换模型也会分别归因；已有省心托管记录可从逐轮路由决定恢复模型，不再无故汇入 `unknown-model`。

### Tests

- 更新技能菜单布局回归，锁定 0、1、3、5 与 20 个候选时的保底高度和全局最大高度。
- 新增逐轮 Provider／模型归因、轻量历史解码与旧托管路由恢复回归，覆盖同一会话切换模型的统计拆分。

### Meta

- Composer 触发菜单与模型用量归因修复使版本从 **1.243.0** 进入 **1.243.0-rc1**，内部构建号 **342 → 343**，Help 与 Computer Use Helper 构建号 **258 → 259**；App、Go agent、Help、Helper、浏览器扩展、响应头契约与产品文档保持一致。

## 1.243.0 - 2026-08-11

### Added

- “AI Agents”新增独立“子 Agent”子页，Scout、Reader、Deep、Editor 可分别绑定具体 Provider 配置实例和模型。
- 子 Agent 模型既可从所选 Provider 的 `/v1/models` 拉取候选，也可自由输入；默认优先 some.im，不存在 some.im 时回退到默认 Provider。
- 设置侧栏改为“账户与设备 → AI Agents → Agent 工具”优先；“工作区”并入倒数第二的“编辑器”组，“通用”更名为末尾的“更新”。
- 智能审核新增 some.im 专用 `someim-security-guard` 路由：登录 some.im 后固定使用服务端安全策略模型；未登录时复用当前会话 Provider 与模型。

### Changed

- some.im 智能审核请求只发送经过本地危险边界预检、凭据脱敏的单条 user message，不再重复携带客户端 system prompt；固定长策略由网关注入，提升缓存复用率。
- 专用审核模型返回 NO、无效输出、超时或网络失败时仍进入人工复核，任何审核故障都不会默认放行。

### Fixed

- 修复 AI Agents 首次渲染时 Provider Picker 短暂使用空选择的问题，避免 SwiftUI 报告无匹配 tag 的无效配置。

### Tests

- 新增子 Agent Provider 路由与设置信息架构回归，覆盖 some.im 优先、默认 Provider 回退、Provider UUID 精确绑定和设置标签顺序。
- 新增 some.im 登录／退出审核路由与 Responses 请求体回归，锁定专用模型只发送 user message，未登录时沿用当前会话模型。
- 完成真实 SwiftUI 设置窗口视觉验收，并保存参考图与实现图的同画布对照证据。

### Meta

- 子 Agent 独立 Provider/模型路由、设置导航重组与 some.im 服务端智能审核属于新增功能，正式版本从 **1.242.0** 提升为 **1.243.0**，内部构建号 **341 → 342**，Help 与 Computer Use Helper 构建号 **257 → 258**；App、Go agent、Help、Helper、浏览器扩展、响应头契约与产品文档保持一致。

## 1.242.0 - 2026-08-11

### Added

- 新会话活动洞察新增可点击的“最常用 Worker”，并提供 Scout、Reader、Deep、Editor 的调用次数、涉及会话数和调用占比明细。
- Worker 统计复用历史 `spawn_agent` 工具参数；未显式指定 profile 的兼容调用按运行时规则归入 Deep，无需等待新版本重新积累数据。
- “AI Agents”新增独立“子 Agent”子页，Scout、Reader、Deep、Editor 不再混在 AI 服务商配置页中；每个工种均可单独绑定具体 Provider 条目与模型。
- 子 Agent 模型支持从对应 Provider 的 `/v1/models` 拉取候选，也保留自由输入模型 ID；Provider 默认优先 some.im，不存在 some.im 时使用当前默认 Provider。

### Fixed

- 轻量会话索引现在保留省心托管状态，重启或冷加载历史后不再把托管会话占比错误显示为 0%。
- 原“快速模式”更名为“省心托管会话占比”；原“最常用的推理强度”更名为“含推理输出的回复占比”，使标题与真实统计口径一致。

### Tests

- 新增轻量会话快照回归，覆盖省心托管状态及显式、默认 Worker profile 的恢复。
- 新增跨会话 Worker 聚合回归，覆盖大小写规范化、默认 Deep 和未知 profile 的兼容行为。
- 新增子 Agent Provider 路由回归，覆盖 some.im 优先、默认 Provider 回退、重复预设下的 Provider UUID 精确绑定，以及 AI Agents 子页信息架构。

### Meta

- Worker 用量明细与子 Agent 独立 Provider/模型配置属于新增功能，正式版本从 **1.241.0-rc14** 提升为 **1.242.0**，内部构建号 **340 → 341**，Help 与 Computer Use Helper 构建号 **256 → 257**；App、Go agent、Help、Helper、浏览器扩展、响应头契约与产品文档保持一致。

## 1.241.0-rc14 - 2026-08-11

### Fixed

- Agent 模型选择器不再把跨供应商累计的“最近获取模型”合并到当前供应商目录；自定义供应商从 `/models` 获取 10 个模型时，供应商计数和列表现在只包含其配置模型及本次实际获取的模型，不再膨胀成 70 多个。
- 编程推荐模型继续保留在独立推荐区，不再隐式计入供应商模型数量。
- Agent 请求停止或异常结束后，同一轮的工具活动不再回填到各段 AI 进度文字之间；运行态底部活动行会在轮次末尾稳定折叠为一条汇总，失败数量仍保留在汇总结果中。

### Tests

- 新增自定义供应商目录隔离回归，锁定获取 10 个模型时去重后的供应商目录仍为 10 项。
- 新增多段 assistant 进度与多个命令的停止态回归，锁定工具汇总仅出现一次且位于该轮最终正文之后。

### Meta

- Bugfix 预发布版本从 **1.241.0-rc13** 递增为 **1.241.0-rc14**，内部构建号 **339 → 340**，Help 与 Computer Use Helper 构建号 **255 → 256**；App、Go agent、Help、Helper、浏览器扩展、响应头契约与产品文档保持一致。

## 1.241.0-rc13 - 2026-08-11

### Fixed

- curl 的 API Key、Authorization Header、用户凭据和常见令牌值现在先在本地脱敏，再把保留 HTTP 方法、URL、循环边界与请求体结构的命令交给 AI 智能审核；POST、`-d`、`--json`、Header 和 Cookie 不再仅因形态直接转人工。
- curl 文件上传、本地输出、证书/私钥、netrc/config 文件和路由覆盖仍保留输入式人工确认，AI 审核无法绕过本地高风险边界。
- 助手消息渲染会裁掉模型输出首尾的空格与空行；同一轮被工具调用拆开的连续进度消息改用单行分隔，工具摘要前间距由整行压缩为 6pt，避免 provider 的 `\n\n正文\n\n`、消息间隔和工具占位叠加成异常大块留白；正文内部段落保持不变。

### Tests

- 新增认证 curl 循环脱敏回归，锁定真实凭据不会进入 judge payload，且有界 POST 请求可进入智能审核。
- 新增聊天 Markdown 外缘空行与同轮进度消息紧凑分隔回归，并保留正文内部段落分隔。

### Meta

- Bugfix 预发布版本从 **1.241.0-rc12** 递增为 **1.241.0-rc13**，内部构建号 **338 → 339**，Help 与 Computer Use Helper 构建号 **254 → 255**；App、Go agent、Help、Helper、浏览器扩展、响应头契约与产品文档保持一致。

## 1.241.0-rc12 - 2026-08-11

### Fixed

- 聊天进度摘要中的“查看完整计划”现在一步打开右侧“计划”预览面板，不再先展开右上角浮动计划卡、再要求用户二次点击。
- 历史消息与当前流式消息使用同一侧栏跳转行为；浮动计划卡自身的展开、收起和详情入口保持不变。

### Tests

- 新增计划入口回归测试，锁定两条消息渲染链路都直接请求计划侧边栏，并禁止重新接回浮卡展开信号。

### Meta

- Bugfix 预发布版本从 **1.241.0-rc11** 递增为 **1.241.0-rc12**，内部构建号 **337 → 338**，Help 与 Computer Use Helper 构建号 **253 → 254**；App、Go agent、Help、Helper、浏览器扩展、响应头契约与产品文档保持一致。

## 1.241.0-rc11 - 2026-08-11

### Fixed

- 历史聊天中的工具活动摘要不再把读取文件、浏览目录、代码搜索、Git 状态、命令执行及其他工具计数拆成多行；所有类别统一以图标和中点分隔在单行展示，可用宽度不足时使用尾部省略。
- 工具摘要整行保持可点击，展开后仍展示完整工具调用明细，不影响审批、失败详情或原始参数查看。

### Tests

- 更新 TextKit 历史渲染回归，锁定多个操作类别之间只使用行内分隔符、不再出现换行，并验证摘要段落采用尾部省略策略。

### Meta

- Bugfix 预发布版本从 **1.241.0-rc10** 递增为 **1.241.0-rc11**，内部构建号 **336 → 337**，Help 与 Computer Use Helper 构建号 **252 → 253**；App、Go agent、Help、Helper、浏览器扩展、响应头契约与产品文档保持一致。

## 1.241.0-rc10 - 2026-08-11

### Fixed

- Smart 模式不再把所有 `$(...)` 命令替换一刀切为“必须人工审核”：宿主会递归验证替换载荷，确认其本身为确定性只读命令后，将完整原始命令交给 Flash AI 裁判；历史上的死锁诊断命令可由智能审核判定，不再因 `OUT=$(find ... | tail -1)` 直接落到人工审批。
- AI 裁判的 Shell 结构摘要改用经过验证的占位结构生成，内层 `find | tail` 不会再被误算成外层管道；裁判看到的 `<command>` 仍是未经改写的完整原始命令。
- MySQL/MariaDB 带显式单条 `SELECT`、`SHOW`、`DESCRIBE` 或 `EXPLAIN` 的只读查询进入智能审核；写操作、多语句、`INTO OUTFILE`、锁定读、显式密码/配置凭据及交互式连接继续要求输入式人工确认。

### Tests

- 新增历史死锁排查命令的端到端授权回归，锁定“受控只读命令替换 → AI 智能审核”的路径；补充破坏性/未知替换、反引号、写库、多语句、凭据与交互式数据库客户端的人工确认边界。

### Meta

- Bugfix 预发布版本从 **1.241.0-rc9** 递增为 **1.241.0-rc10**，内部构建号 **335 → 336**，Help 与 Computer Use Helper 构建号 **251 → 252**；App、Go agent、Help、Helper、浏览器扩展、响应头契约与产品文档保持一致。

## 1.241.0-rc9 - 2026-08-10

### Fixed

- 聊天记录中的行内代码与关键词灰色底片不再把正文的 5pt 段落行距计入自身高度，`gateway_credit_settlements`、`tenants` 等标记的下沿留白恢复紧凑，不再显得底部 padding 偏厚。
- 最后一行本来没有额外行距时保持原有高度；底片垂直边界不再被整点取整额外向外扩张。

### Tests

- 新增真实 TextKit 几何回归，复现 15pt 正文、14pt 等宽字体与 5pt 行距产生的 23pt 行框，锁定底片仅使用 18pt 自然内容高度；同时覆盖末行不重复裁减。

### Meta

- Bugfix 预发布版本从 **1.241.0-rc8** 递增为 **1.241.0-rc9**，内部构建号 **334 → 335**，Help 与 Computer Use Helper 构建号 **250 → 251**；App、Go agent、Help、Helper、浏览器扩展、响应头契约与产品文档保持一致。

## 1.241.0-rc8 - 2026-08-10

### Fixed

- 聊天记录中的“处理中”状态统一使用与“已读取文件”等活动摘要相同的常规紧凑字号、次要标签颜色与不透明度，不再因字号偏大且颜色过淡而显得发虚。
- AppKit 主聊天记录与 SwiftUI 备用消息视图同步采用同一视觉规格，避免不同渲染路径出现样式差异。

### Tests

- 更新聊天记录渲染测试，锁定处理状态的系统常规字号、非粗体字重与次要标签颜色。

### Meta

- Bugfix 预发布版本从 **1.241.0-rc7** 递增为 **1.241.0-rc8**，内部构建号 **333 → 334**，Help 与 Computer Use Helper 构建号 **249 → 250**；App、Go agent、Help、Helper、浏览器扩展、响应头契约与产品文档保持一致。

## 1.241.0-rc7 - 2026-08-10

### Fixed

- 聊天页右上工具图标会同时响应右侧面板与已分离的独立窗口；文件、终端、预览等工具只要仍有对应界面活跃，就持续使用强调色，不再因分离出窗口而熄灭。
- 关闭最后一个对应窗口后图标立即恢复普通色；点击已点亮的分离工具仍沿用现有归位行为，将独立窗口收回右侧面板。

### Tests

- 扩充 Agent 顶栏入口契约测试，锁定工具栏观察分离窗口注册表并合并侧栏、独立窗口两类活跃状态。

### Meta

- Bugfix 预发布版本从 **1.241.0-rc6** 递增为 **1.241.0-rc7**，内部构建号 **332 → 333**，Help 与 Computer Use Helper 构建号 **248 → 249**；App、Go agent、Help、Helper、浏览器扩展、响应头契约与产品文档保持一致。

## 1.241.0-rc6 - 2026-08-10

### Changed

- Smart 审核模式将直接启动 Vite、常规包管理器/Go 编译流程和精确的 `nginx -s reload` 识别为普通本地开发操作，不再让用户仅凭命令文本承担无意义的例行审核。
- Smart 模式允许清理工作区内 `node_modules`、`.vite`、`dist`、`.build`、`.cache/go-build` 等明确可重建目录；删除工作区根目录、源码目录、通配符目标、敏感路径或工作区外路径仍需人工确认。
- Strict 模式和可指向远端会话的可见终端命令继续保持审核，避免把本地信任规则误套到线上环境。

### Tests

- 新增常规开发命令与可重建目录清理的安全分类、Smart 自动放行及 Strict 拒绝回归测试，并覆盖混合目标与越界路径。

### Meta

- Bugfix 预发布版本从 **1.241.0-rc5** 递增为 **1.241.0-rc6**，内部构建号 **331 → 332**，Help 与 Computer Use Helper 构建号 **247 → 248**；App、Go agent、Help、Helper、浏览器扩展、响应头契约与产品文档保持一致。

## 1.241.0-rc5 - 2026-08-10

### Fixed

- 关于页补回真正的 WillDeep App 图标，并移除企鹅头图，改为复用桌宠时间线展示熊耳妹待机动画。
- “Rocky 的其他 App”卡片不再使用通用 SF Symbol 占位图，改为展示各产品仓库中的真实 App 图标。
- 桌宠外观列表将熊耳妹调整到第一位；已有用户的当前宠物选择与其他外观保持不变。

### Tests

- 扩充桌宠外观顺序测试，锁定熊耳妹为选择列表首项，同时保留 25 个外观及既有资源名契约。

### Meta

- Bugfix 预发布版本从 **1.241.0-rc4** 递增为 **1.241.0-rc5**，内部构建号 **330 → 331**，Help 与 Computer Use Helper 构建号 **246 → 247**；App、Go agent、Help、Helper、浏览器扩展、响应头契约与产品文档保持一致。

## 1.241.0-rc4 - 2026-08-10

### Fixed

- 打开或关闭右侧文件、终端、预览、计划等面板时，聊天滚动观察器不再把布局触发的视口宽度变化误判为用户滚动，已上滚的阅读位置会按重排前的相对锚点恢复，不再跳到聊天顶部。
- 位于聊天底部的用户仍保持贴底跟随；消息追加、流式回复和主动滚动行为不受侧栏修复影响。

### Tests

- 扩充聊天滚动策略测试，覆盖明显的侧栏宽度变化、小于容差的布局抖动以及首次挂载无旧宽度三种情况。

### Meta

- Bugfix 预发布版本从 **1.241.0-rc3** 递增为 **1.241.0-rc4**，内部构建号 **329 → 330**，Help 与 Computer Use Helper 构建号 **245 → 246**；App、Go agent、Help、Helper、浏览器扩展、响应头契约与产品文档保持一致。

## 1.241.0-rc3 - 2026-08-10

### Fixed

- 关闭当前 SSH 终端标签后，未指定 `terminal_tab_id` 的后续命令不再自动投递到剩余本地标签或新建的本地 Shell，而是明确拒绝并要求重新打开或选择目标标签。
- 用户或 Agent 显式选择有效标签后会清除远端关闭阻断；携带有效精确标签 ID 的命令仍可安全继续，首次使用且没有既往远端上下文时仍可自动创建本地 Shell。
- 终端工具说明与系统提示词同步强调关闭 SSH 后禁止隐式本地降级，避免模型把新本地提示符误报为已恢复线上连接。

### Tests

- 新增终端路由回归测试，覆盖关闭活动 SSH 标签、仍有本地标签时命令零执行、标签数量不变，以及显式重新选择后解除阻断。

### Meta

- Bugfix 预发布版本从 **1.241.0-rc2** 递增为 **1.241.0-rc3**，内部构建号 **328 → 329**，Help 与 Computer Use Helper 构建号 **244 → 245**；App、Go agent、Help、Helper、浏览器扩展、响应头契约与产品文档保持一致。

## 1.241.0-rc2 - 2026-08-10

### Fixed

- 命令执行审批中的长命令会在可用宽度内自然换行，不再要求用户横向拖动才能审阅完整内容。
- 命令区最多展示 5 行（112 pt），更多内容改为纵向滚动；等宽字体、文本选择和一键复制能力保持不变，其他审批行为不受影响。

### Tests

- 扩充命令审批视觉测试，覆盖仅纵向滚动、5 行视口，以及宽、中、窄三档窗口下的响应式换行布局。

### Meta

- Bugfix 预发布版本从 **1.241.0-rc1** 递增为 **1.241.0-rc2**，内部构建号 **327 → 328**，Help 与 Computer Use Helper 构建号 **243 → 244**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.241.0-rc1 - 2026-08-10

### Fixed

- `kill_job` 的人工审批不再复用命令执行的大型说明卡，改为贴近 Composer 的紧凑确认卡，仅展示后台任务标识和“拒绝/允许”操作；命令、沙箱升级及危险级操作仍保留完整审批说明。
- 紧凑确认卡会显示具体后台任务句柄，缺少句柄时使用通用提示；展示变化不修改既有 write 风险分类、审批回调或 SIGTERM/SIGKILL 终止逻辑。

### Tests

- 新增后台任务终止审批展示策略测试，覆盖 write 风险使用紧凑卡、danger 风险不降级以及普通命令继续使用大型审批卡。
- 扩充审批视觉测试，真实渲染后台任务终止确认并锁定高度低于 180 pt；两组定向测试共 8 项通过。

### Meta

- Bugfix 预发布版本从 **1.241.0** 进入 **1.241.0-rc1**，内部构建号 **326 → 327**，Help 与 Computer Use Helper 构建号 **242 → 243**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.241.0 - 2026-08-10

### Added

- 展开的浮动计划卡支持点击摘要或任一步骤文字，直接打开右侧“计划”面板；更多菜单同时提供“查看完整计划”入口。
- 右侧计划面板改用现有 Markdown 预览管线展示完整标题、摘要和步骤列表，长步骤可自然换行、选择复制，并随实时步骤状态同步更新，不再重复嵌套会截断文本的紧凑卡片。

### Tests

- 新增完整计划 Markdown 格式测试，覆盖摘要、所有步骤、实时状态符号与长文本不丢失。

### Meta

- 完整计划侧栏预览属于新增功能，正式版本从 **1.240.0-rc2** 提升为 **1.241.0**，内部构建号 **325 → 326**，Help 与 Computer Use Helper 构建号 **241 → 242**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.240.0-rc2 - 2026-08-10

### Fixed

- 聊天历史中的浅灰行内代码胶囊将屏幕下方内边距从 1.5 pt 收紧到 0.5 pt，与上方内边距保持一致，减少 `tokenhub` 这类短代码标记下沿过厚的问题。

### Tests

- 新增行内代码胶囊屏幕下方内边距回归断言，并用视觉方向命名布局参数，避免 TextKit 翻转坐标造成上下语义混淆。

### Meta

- Bugfix 预发布版本从 **1.240.0-rc1** 提升至 **1.240.0-rc2**，内部构建号 **324 → 325**，Help 与 Computer Use Helper 构建号 **240 → 241**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.240.0-rc1 - 2026-08-10

### Fixed

- 工具活动摘要改用紧凑中文计数格式，移除数字两侧多余空格；失败与拒绝状态不再使用容易误读为关闭或错误按钮的叉号，而是直接显示为“已运行1条命令(1条失败)”这类括号补充信息。
- 多行工具摘要缩小图标与文案的水平间隔，并降低行间距和段前后留白，在不牺牲可扫描性的前提下减少聊天历史占用高度。

### Tests

- 更新工具分组、聊天历史与 Goal 历史渲染测试，锁定紧凑计数、括号式失败状态和无叉号输出。

### Meta

- Bugfix 预发布版本从 **1.240.0** 进入 **1.240.0-rc1**，内部构建号 **323 → 324**，Help 与 Computer Use Helper 构建号 **239 → 240**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.240.0 - 2026-08-10

### Added

- Goal 模式新增持久化 Roadmap：一个 Goal 最多拆成 6 个粗粒度 phase，每个 phase 激活时再独立生成最多 6 步的 Plan；完成当前 phase 后自动进入下一阶段规划，允许跨多个模型轮次持续推进，界面显示“阶段 X/Y”。
- 后台命令新增 turn、phase、goal、persistent 生命周期。Goal 内自动识别的 dev server 默认绑定当前 phase，只有用户明确要求跨任务保留时才使用 persistent。

### Changed

- Goal 初始提案与调度图增加硬性规模门禁，拒绝超过 6 步的当前阶段 Plan、超过 6 个 phase 的 Roadmap，以及超过 9 个节点的调度图，避免把长期目标一次展开成难以观察的十几步清单。
- Goal 续跑、恢复与持久化改为理解 phase 边界；长期 phase/persistent 服务不再被误判为当前 Plan 的有效进展信号。

### Fixed

- phase 完成时由宿主静默终止该阶段后台任务及其已跟踪的完整子进程树，避免 E2E/浏览器验收结束后遗留 dev server、watcher 或浏览器子进程长期占用 CPU 与内存。
- 用户在 Goal 空闲时手动完成当前 phase 后，下一 phase 现在会立即启动规划；正在响应时仍使用宿主指令队列串行衔接，避免空闲队列无消费者而卡住。
- 过期 Goal 规划代次在进入新 Roadmap/Plan 验证前直接丢弃，避免旧 synthesis 碰撞新规划代次后触发无意义的修正轮次。

### Tests

- 新增 Roadmap 解析、安全边界、持久化、6 步上限、phase 自动推进与 phase 计划恢复测试。
- 新增后台任务生命周期隔离测试，覆盖只清理完成 phase、保留其他 phase/persistent 任务、静默清理不唤醒 Goal，以及 phase 服务不冒充 Plan 进展。

### Meta

- Goal 分阶段执行属于新增功能，正式版本从 **1.239.0** 提升为 **1.240.0**，内部构建号 **322 → 323**，Help 与 Computer Use Helper 构建号 **238 → 239**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.239.0 - 2026-08-10

### Added

- 项目名称右键菜单新增“置顶项目/取消置顶”。置顶状态持久化到项目数据，项目名称旁显示低干扰图钉；侧栏先展示全部置顶项目，置顶组内部按项目创建时间从新到旧排列，普通项目继续按相同创建时间规则排列，“无工作区”仍固定在底部。

### Tests

- 新增项目置顶排序测试，覆盖置顶项目优先、多个置顶项目仍按创建时间排列，以及普通项目不会仅因创建时间更晚越过置顶项目。
- 新增旧版项目 JSON 兼容测试，确认缺少置顶字段的数据能安全读取为未置顶。

### Meta

- 新增项目置顶功能，正式版本从 **1.238.2-rc2** 提升为 **1.239.0**，内部构建号 **321 → 322**，Help 与 Computer Use Helper 构建号 **237 → 238**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.238.2-rc2 - 2026-08-10

### Fixed

- 计划卡的普通状态和低频操作同时争抢视觉注意力：移除没有额外信息量的“已就绪”状态胶囊，执行中、完成、中断等状态仍保留；常驻底部的橙色“重新规划”入口移入头部系统更多菜单，只有用户主动选择后才展开修订备注输入框。
- 计划卡从橙色图标、橙色描边和强调色按钮混用，收敛为系统中性语义色；“标记计划完成”改为次要文字操作，避免与真正需要关注的异常状态抢层级。

### Tests

- 扩充计划卡展示策略测试，锁定普通已就绪状态隐藏、执行状态显示、被中断的已就绪计划仍显示异常状态。

### Meta

- Bugfix 预发布版本从 **1.238.2-rc1** 递增为 **1.238.2-rc2**，内部构建号 **320 → 321**，Help 与 Computer Use Helper 构建号 **236 → 237**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.238.2-rc1 - 2026-08-10

### Fixed

- AI 流式回复会把 WillDeep CPU 短时推到约 32%–40%：现场 8 秒采样确认没有编译干扰、死锁或同步 IO，主线程忙碌约 43%，热点集中在 SwiftUI / AttributeGraph / AppKit 文本布局。根因是流式层固定 10 Hz 发布，每次都对持续增长的完整正文重做 Markdown `AttributedString` 和高度测量。现在刷新策略改为按累计内容自适应降档：短内容 5 Hz、4,000 字符后约 3 Hz、16,000 字符后 2 Hz；非 delta 事件和结束事件仍立即冲刷，最终内容与事件顺序不变。
- 流式光标原先以完整正文作为 `.task(id:)`，每次刷新都会取消并重建 500ms 计时任务。现在改为单一生命周期任务读取最近输出时间，内容变化只更新时间戳和可见状态，不再制造与 token 批次同频的任务抖动。

### Tests

- 新增流式刷新策略边界测试，锁定 4,000 / 16,000 字符两档退避及对应 200 / 333 / 500ms 刷新间隔；保留既有光标 500ms 活跃/隐藏边界回归。

### Meta

- Bugfix 预发布版本从 **1.238.2** 进入 **1.238.2-rc1**，内部构建号 **319 → 320**，Help 与 Computer Use Helper 构建号 **235 → 236**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.238.2 - 2026-08-09

### Fixed

- 登录成功当下就显示昵称和头像，不再"先秃几秒再慢慢冒出来"。登录响应本身不带 `nickname` / `avatar_url`（线上 some.im 在这条路径只 `SELECT email`），资料要等下一次 `fetchAccountBalance` 顺带打 `/customer/me` 才补上。现在登录保存账号前直接补拉一次资料，并给 **2.5 秒硬预算**——`/customer/me` 自身 12s 超时、失败还会再叠一次 token 续期，不封顶的话「登录慢半秒」会退化成「登录卡二十秒」；超时静默退回旧行为（稍后刷新时补上），登录本身绝不受影响。服务端将来随登录下发资料后，这次补拉会被短路跳过，不会多发一次请求。
- SenseVoice 语音模型迁到自有 CDN：下载源从借用的第三方 endpoint（`cdn.wxside.com`）换成 `https://img.niuwoai.com/models/sensevoice-small/model.onnx`，与 App DMG 同一个发布桶，生命周期自己可控。迁移时校验过完整性（源站 ETag ↔ 本地 MD5 ↔ 上传后回读 SHA256 三方一致，937,615,562 字节）。
- 语音模型下载进度条走不到头：回退分母 `approximateModelBytes` 写成 `937 * 1024 * 1024`（982,614,016），把十进制 937 MB 当 MiB 算，比真实体积大 4.8%；服务端不给 Content-Length 时进度永远差一截。改为实测精确值 937,615,562。

### Tests

- 新增登录资料补拉回归：预算存在且显著小于 `/customer/me` 的 12s 超时、超时按预算返回不阻塞、预算内结果照常拿到、操作失败返回 nil、登录响应已带资料时跳过补拉、会话 token 缺失/空白时安全跳过且不清空已有资料。

### Meta

- Bugfix 正式版从 **1.238.1** 递增为 **1.238.2**，内部构建号 **318 → 319**，Help 与 Computer Use Helper 构建号 **234 → 235**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.238.1 - 2026-08-09

### Fixed

- 学习建议把产品自己的系统提示词当成「用户说的话」：用户只发一句 "hello" 也会弹出 2 条记忆建议，内容是 per-turn 隐藏 host 指令里的原句（"The bounded local rename auto-applies without user approval…"、"Prefer reversible repairs and preserve unrelated changes"——分别命中 candidate marker 词 "never" 和 "prefer"）。根因：1.195.0-rc12 的「只挖用户原话」修复选对了消息（isOperatorInput）但选错了字段——`modelContent` 是喂 provider 的拼接体，末尾携带 `modelContext`（host 注入指令）。新增 `AgentMessage.operatorAuthoredContent`（正文 + 用户粘贴附件，不含 host 注入），memory 候选抽取、auditTurn 全链（framework 规则闸、MCP 缺口、skill 候选、explicit directive）与记忆检索 query 一律改读该字段；检索 query 同时补上 isOperatorInput 过滤（此前连 host carrier 消息都会进 query）。
- 学习建议 chip 计数与 popover 不一致：chip 数「事件数」，popover 逐条展示事件内的 memory drafts，一个事件挂两条记忆就出现「说 1 条点开是 2 条」。新增 `AgentSelfLearning.suggestionItemCount`（memory 事件按待审 drafts 展开、其余各计 1），chip 与任务监控 rail 的「记忆」行统一走该口径。
- chip 文案撒谎：事件状态是 `.suggested`（待用户确认、未落盘），文案却写「Agent 本轮保存了 N 条建议」，与 popover 内「保存记忆 需用户确认」自相矛盾。改为「Agent 本轮提出 N 条建议，待确认」（en: "%@ learning suggestion(s) this turn"），tooltip 同步注明保存需确认。

### Tests

- 新增回归：`operatorAuthoredContent` 排除 modelContext、保留粘贴附件；"hello" + host 注入指令下 memory 候选为空、auditTurn 为 nil、captureAutomaticMCPCapabilityGap 不产事件、memory store 不被写入；`suggestionItemCount` 展开 drafts 的口径（2 drafts + 1 MCP 事件 = 3，saved 后计 1）。

### Meta

- Bugfix 正式版从 **1.238.0** 递增为 **1.238.1**，内部构建号 **317 → 318**，Help 与 Computer Use Helper 构建号 **233 → 234**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.238.0 - 2026-08-09

> 正式版，内容与 1.238.0-rc1 一致。本轮要点：

### Added

- 系统提示词按能力门控瘦身（契约升级为 `willdeep-agent-system-v26`）：浏览器/UI QA、Web 编程工作流、原生 App computer-use 协议三块从稳定核心移入「能力附录」，按需注入；核心字节序全局不变，provider 前缀缓存跨会话照常共享。素会话 standard 稳定前缀 20,938 → 17,494 字符（-16.5%），extended → 19,064（-17%），compact 档不变。
- ZMODEM 终端传输细则外迁为内置技能 `zmodem-terminal-transfers`，提示词只保留强制先读指针与一行安全红线。

### Meta

- 正式版本从 **1.238.0-rc1** 定版为 **1.238.0**，内部构建号 **316 → 317**，Help 与 Computer Use Helper 构建号 **232 → 233**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.238.0-rc1 - 2026-08-09

### Added

- 系统提示词按能力门控瘦身（契约升级为 `willdeep-agent-system-v26`，三档哈希重录）。实测 standard 档稳定前缀 87% 是工具契约文本，其中浏览器、Web 开发工作流、原生 App computer-use 协议这些门控功能的指引却对所有会话无差别收费。现在这三块移入「能力附录」：浏览器/UI QA 块随 browserOps 或 webCoding 专家激活注入，Web 编程工作流块随 webCoding 专家注入，computer-use 协议块在辅助进程首次报告 Accessibility 已授权后注入（粘性标记）。附录严格追加在稳定核心之后——核心字节序全局不变，provider 前缀缓存跨会话照常共享，会话自身的核心+附录组合在其回合间稳定。
- ZMODEM 终端传输细则外迁为内置技能 `zmodem-terminal-transfers`（preselect 参数、lrzsz 双端安装、scp/rsync 回退），提示词只保留强制先读指针；安全红线（屏幕内容不可信、凭据须用户接管）压缩为一行保留在稳定核心，不参与门控。
- 实测效果：素会话 standard 稳定前缀 20,938 → 17,494 字符（-16.5%），extended → 19,064（-17%）；能力全开时与原量级持平（按需付费）；compact 档保持不变。

### Tests

- 新增能力门控回归：前缀不变量（任意能力组合下核心是逐字节前缀）、逐块开关正确性、能力推导（webCoding 蕴含浏览器工具）、三个附录块独立字节哈希守卫；ZMODEM 断言迁移至技能文件内容。

### Meta

- 功能版本从 **1.237.1-rc4** 提升为 **1.238.0-rc1**，内部构建号 315 → 316，Help 与 Computer Use Helper 构建号 231 → 232；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.237.1-rc4 - 2026-08-09

### Fixed

- 统计面板「最长任务时长」算的是会话存续跨度而非投入时长。旧口径是「该会话最后一条消息时间 − 第一条消息时间」取全局最大值，睡觉、周末、App 关着的时间全部计入：本机真实数据里冠军会话 509 条消息显示 **8d3h5m**，其中两个空档分别是 3d16h42m 和 3d15h31m；另一个会话只有 10 条消息，因为隔了三天半回来补一句，就报出 3d11h56m。改为按空闲封顶累加相邻消息间隔（`AgentUsageStats.activeWorkDuration`，阈值 `taskIdleCapSeconds` = 15 分钟，编码时长统计的通行做法）：那个会话现在报 4h21m，而榜首也随之换成真正投入最多的一次对话（1420 条消息、9h50m），不再是躺得最久的那个。指标加了 tooltip 说明口径，免得用户再对着数字犯嘀咕。

### Meta

- Bugfix rc 递增：**1.237.1-rc3 → 1.237.1-rc4**（rc3 被并行会话的 SwiftUI 重建收窄第二批占用）；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档版本保持一致。

## 1.237.1-rc3 - 2026-08-09

### Fixed

- SwiftUI 高频重建热点收窄第二批（性能扫描定位的五处，均为「每次 body 全量重算 / 常驻定时器整块驱动」模式）：
  - Agent 会话 transcript 的 `visibleMessages` 每次 body 都重跑工具回执采集 + 全量 compactMap（左缘 minimap overlay 还会在同一 pass 里再跑一遍）——照 minimapCache 既有指纹缓存范式加 `AgentTranscriptVisibleMessagesCache`，指纹覆盖全部展示相关字段（role、content 长度、tool call id/status、本地事件标记等），输入不变时直接复用；
  - 侧栏 Widget 面板每次 body 对全部运行时消息 `reversed().compactMap(\.widget)`——按运行时 id + 消息数 + 末条 id 指纹缓存消息侧提取，registry 侧保持活读；
  - 底部 Goal 卡整卡包在 1 秒 TimelineView 里，每秒重建图标/状态/摘要/进度/按钮——照 `AgentBackgroundTaskDurationLabel` 范式收窄为仅秒表文本子 view；
  - Dev Server 面板 1.5 秒 `Timer.publish` 无条件驱动整面板重建（空闲侧栏永久空转）——改为仅在存在存活 dev/tail 任务时订阅心跳，任务增删与状态翻转本就由 `@Published jobs` 桥接触发；
  - 会话侧边栏一次 body 跑两遍 `visibleSessions` 全量过滤（分组列表与置顶区各一遍）——收敛为 body 开头算一次、两处共用同一份快照。

### Meta

- Bugfix 预发布版本从 **1.237.1-rc2** 递增为 **1.237.1-rc3**（rc2 被并行会话的委派图/圆桌热点清扫占用），内部构建号 **314 → 315**，Help 与 Computer Use Helper 构建号 **230 → 231**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.237.1-rc2 - 2026-08-09

### Fixed

- 两处每秒/每帧重算热点（性能扫描确认）：
  - 委派图 running 节点的指标条：1 秒 TimelineView 每 tick 调 `AgentDispatchTaskMetrics.make`，遍历该节点全部关联会话的所有 assistant 消息做 token/成本聚合，并对 `appState.agentSessions` 线性查找——多个 running 节点各付一份。现把重聚合拆成 `AgentDispatchTaskMetricsSnapshot`，按（sessionID, messages.count）指纹 memoize，1Hz tick 只对捕获的快照做时长纯算术（sealed 区间和 + 活跃 attempt 起点差）。
  - 圆桌文档页：`persistedDocumentURL` 计算属性每帧 `fileExists`，正文 `ForEach` 里每帧对全文重跑 `MarkdownPreviewParser.blocks`，`normalizedDocument` 一次 body 求值 3+ 次。现照编辑器预览面板既有范式改为 `.task(id: finalDocument)` 异步 normalize + 解析一次落 `@State`，落盘 URL 在写文件成功时直接缓存。

### Meta

- Bugfix rc 递增：**1.237.1-rc1 → 1.237.1-rc2**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档版本保持一致。

## 1.237.1-rc1 - 2026-08-09

### Fixed

- 全仓热路径性能清扫（sample + 静态扫描定位）：
  - 改动文件面板每行最多 4 次同步 `stat`、列表非懒加载，一次渲染数百次系统调用——`agentChangedFileURL` 结果按（仓库根, 相对路径）memoize，worktree 快照刷新时整体失效；
  - 任务监督栏「产物」区每次 body 对全部 artifact 逐个 `fileExists`，流式回复期间约 10Hz 重跑——改 `.task(id: 指纹)` 异步探测 + 缓存；
  - 技能市场每行每渲染 stat+整读已装 SKILL.md 判定安装态——改目录加载/装卸后重建的状态缓存；同一 body 对过滤结果求值三次收敛为一次；技能搜索逐键对约 300 个技能重建多语言检索文本——按 identifier 缓存；
  - 编辑器 Markdown/HTML 预览逐键全文重解析（打字延迟随文档长度线性放大）——照 AgentSidePanel 既有范式改 `.task(id:)` 异步解析，键击风暴合并为一次；
  - 监督栏状态行的 1 秒 TimelineView 从整行收窄到仅秒表文本（等待审批的长挂起期不再每秒重建整行）；最近会话边栏轨一次 body 双份全量过滤收敛为一次；两个设置页 `formatDate` 每行新建 DateFormatter 改 static 缓存。
- ACP 执行器丢尾竞态：进程退出通知可能先于 stdout 排空到达，旧实现在退出回调里抢读一次就强制收流，满载下把已写完的最终响应判成 `processExited`（全量测试中偶现的 symlink 守卫用例假红即此）。改为以 stdout EOF 为唯一正常终局（EOF 分支顺带摘除 handler 防空转），进程退出仅保留 2 秒宽限兜底应对泄漏子进程持有写端的病态场景。压测同用例连续 8 轮全绿（修前满载偶挂）。

### Changed

- 委托外部 CLI 的任务契约补充报告排版约束（无 emoji、无装饰加粗、短报告不加标题），与 1.237.0 的宿主 Markdown 克制契约对齐——外部执行器的可见产出落在同一 transcript。

### Meta

- Bugfix 版本从 **1.237.0** 递增为 **1.237.1-rc1**，内部构建号 **313 → 314**，Help 与 Computer Use Helper 构建号 **229 → 230**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.237.0 - 2026-08-09

### Changed

- Agent 回复的排版收敛为「朴素优先」。此前只有一句「除非用户要求否则不用 emoji」，分量不足，回复里仍充斥装饰性加粗、层层小标题和 emoji 前缀。新增独立的 Markdown 克制契约：全面禁用 emoji（含小节标记、状态勾、条目前缀）；加粗只留给真正的风险提示和密集结果里最关键的那一个值，不得整句加粗、不得加粗条目开头/冒号前的标签/文件名/产品名；短回复不加标题；两三个要点直接用句子而非列表；禁用分隔线、把普通段落塞进引用块以及 ASCII 分隔符。三档 prompt profile（compact / standard / extended）共享这条契约。
- 系统提示词契约升级为 `willdeep-agent-system-v25`，standard / compact / extended 三档字节级哈希同步重录。

### Tests

- 新增守卫：Markdown 克制条款必须出现在全部三档 profile（避免只在 standard 生效）。

### Meta

- 功能版本从 **1.236.2** 提升为 **1.237.0**，内部构建号 **312 → 314**，Help 与 Computer Use Helper 构建号 **228 → 230**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.236.2 - 2026-08-09

### Fixed

- 项目分组重绑终于能落盘。1.236.1 让启动迁移无条件重绑，但内存里那份多半只是目录骨架（无消息），把它整份存盘会被 `wouldTruncateStoredTranscript` 防截断守卫拒绝——于是内存显示归位、磁盘依旧未绑定，下次会话materialize 又跳回路径分组，重复项目组反复复活。新增 `AgentSessionStore.updateStoredSessionMetadata(id:mutate:)`：先materialize完整会话再改元数据落盘，重绑与 `project:<uuid>` 路径修复都改走这条路，正文一字不丢。
- some.im 昵称与头像长时间不显示时不再无从查起。credits 走长期 api_key、profile 走 7 天客户会话，后者失效时前者照常刷新，界面就静默退化成显示邮箱；原先 `try?` 把错误整个吞掉，日志里连一行痕迹都没有。现在 profile 拉取失败会打一条明确日志（保留上次已知昵称/头像不被清空），下次卡住可直接定位。

### Tests

- 新增落盘回归：骨架会话重绑后磁盘上的 `projectID` 必须更新且原有正文完整保留（旧实现此用例失败）。

### Meta

- Bugfix 版本从 **1.236.1** 递增为 **1.236.2**，内部构建号 **311 → 312**，Help 与 Computer Use Helper 构建号 **227 → 228**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.236.1 - 2026-08-09

> 正式版。含 1.236.1-rc1 全部内容：启动重绑游离会话根除重复项目组、项目列表按创建时间倒序并固定、用量热力图 DateFormatter 缓存修复编辑器周期性卡顿。

### Fixed

- 会话行排序补齐最后两处平局裁决：createdAt 相同回退到不可变的会话 id；置顶行平局不再用会变化的 lastActivityAt（改 createdAt → id）。Swift 排序不稳定，比较器只要可能返回「相等」，行就会在每次重排时互换——而侧边栏在共享 AppState 每次发布（包括编辑器打字）时都会重排，这正是「编辑器打字、Agent 窗口列表跳动」的成因；至此排序全链路是不可变量上的全序，任意重排结果恒定。

### Meta

- 正式版本从 **1.236.1-rc1** 定版为 **1.236.1**，内部构建号 **310 → 311**，Help 与 Computer Use Helper 构建号 **226 → 227**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.236.1-rc1 - 2026-08-09

### Changed

- 项目列表顺序改为按创建时间倒序并彻底固定：项目组以项目 createdAt、裸文件夹组以组内最早会话时间为「出生时刻」排序（新的在前），二者均不可变，顺序全生命周期不再变化；「无工作区」仍垫底。此前的名字典序退役。

### Fixed

- 彻底消灭侧边栏重复项目组。1.235.0-rc4 修复了「新会话不绑项目」，但存量旧会话仍是路径分组：启动迁移在所有文件夹都已被项目认领时提前返回，`rebindAgentSessionsToProjects()` 永远轮不到——旧会话的空绑定治不好，同名分组一直挂着。现在迁移无论是否新建项目都执行重绑（幂等），下次启动即把游离会话并回所属项目组。
- 编辑器周期性卡顿（采样定位）：用量热力图每次重渲染为约 371 个格子各新建两次 DateFormatter（每轮 700+ 次毫秒级分配），AppState 一发布就整块重来。改为缓存格子日期与月份两把 formatter（随 locale 失效重建），每格 tooltip 只算一次同时供悬浮提示与无障碍标签使用。
- 同名分组顺序抖动：旧的名字典序比较对相同显示名返回「相等」，而 Swift 排序不稳定，重复组每次重渲染都可能互换位置；新的组排序自带出生时间 → 名字 → key 三级确定性裁决，任何输入下顺序唯一。

### Tests

- 新增回归：项目已存在时启动迁移仍会重绑游离会话（旧代码此用例失败）。

### Meta

- Bugfix 版本从 **1.236.0** 递增为 **1.236.1-rc1**，内部构建号 **309 → 310**，Help 与 Computer Use Helper 构建号 **225 → 226**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.236.0 - 2026-08-09

> 正式版，内容与 1.236.0-rc2 一致。本轮（rc1–rc2）要点：

### Added

- 设置窗口信息架构重组：编辑器相关设置（编辑行为/外观/背景/字体排印）合并为一个「编辑器」标签；所有外部连接器（飞书、钉钉、企业微信、微信 Claw、Replicate）统一进「集成」标签下的连接器中枢，每个集成是一行可点选的子连接器。
- Agent 技能列表分页（每页 20 条，搜索自动回首页，越界页自动收敛）。

### Fixed

- 切到「技能」标签明显变快：进入不再强制重扫技能目录，正文展开时才异步读盘，启用开关就地翻转。
- 「显示行号」「高亮当前行」等编辑器设置重启后不再丢失（双 AppState 通知回声互杀根因修复：采纳广播值不再回存回播，持久化改为同步写盘）。
- Replicate 设置区中文硬编码与「子智能体工种」设置区英文硬编码全部迁入 i18n 字符串目录；工种职责描述拆分为模型语料（英文）与界面展示（本地化）两层。

### Meta

- 正式版本从 **1.236.0-rc2** 定版为 **1.236.0**，内部构建号 **308 → 309**，Help 与 Computer Use Helper 构建号 **224 → 225**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.236.0-rc2 - 2026-08-09

### Fixed

- 「显示行号」「高亮当前行」等编辑器设置重启后不再丢失。根因是双 AppState 实例的通知回声互杀：实例 A 改完设置异步落盘并广播，实例 B 采纳后又把同一份值**再存再播**——若用户紧接着改了第二个开关，B 的回声会把 A 拉回旧值并顺手取消掉第二个开关还没执行的保存，改动就这样静默蒸发。现在采纳广播值不再回存回播（对齐终端设置早已使用的旗标模式），且持久化改为在赋值时同步写盘，退出前的最后一次修改也不会再因异步排队而丢失。
- Replicate 设置区的中文硬编码全部迁入 i18n 字符串目录（清除按钮、配置状态、Token 说明、Workflow Versions 各字段），英文界面下不再夹中文。
- 「子智能体工种」设置区不再显示英文：该区所有键补齐 zh-Hans 翻译（工种名、区标题/脚注、模型/工具标签、「与本会话相同」占位、不可用回退提示）；四个工种的职责描述拆分为「模型语料用英文原文（进 spawn_agent 工具描述）+ 界面展示用本地化文案」两层，互不影响。

### Tests

- 新增编辑器设置持久化回归：单开关同步落盘（无需等待队列）、双实例连续两次开关都保留且两端收敛、采纳广播值不回写存储。

### Meta

- Bugfix 预发布版本从 **1.236.0-rc1** 递增为 **1.236.0-rc2**，内部构建号 **307 → 308**，Help 与 Computer Use Helper 构建号 **223 → 224**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.236.0-rc1 - 2026-08-09

### Added

- 设置窗口信息架构重组其一：编辑器相关设置合并为一个「编辑器」标签，内含编辑行为、外观、背景壁纸、字体排印四个子页；原「编辑」「格式与外观」两个顶层标签退役，侧边栏更短更聚焦。
- 设置窗口信息架构重组其二：所有外部连接器统一进「集成」标签下的连接器中枢——飞书、钉钉、企业微信、微信 Claw 与 Replicate 各自是一行子连接器，点选后在下方展开各自的配置区；Replicate 行直接显示「已配置/未配置」状态。图片编辑面板等处的 Replicate 深链继续可用，落到中枢并预选 Replicate。
- Agent 技能列表分页：每页 20 条，页脚「上一页/下一页 + 第 x / y 页」，搜索时自动回到第一页；过滤收缩时页码自动收敛不会停在空页。

### Fixed

- 切到「技能」标签明显变快：进入不再强制作废缓存重扫全部技能目录（建/删/装技能的路径本就各自作废缓存）；「查看内容」正文改为展开时才异步读盘（此前每次重渲染都对每行同步读 12KB）；启用开关就地翻转不再触发整目录重扫；「刷新」按钮保留完整重扫语义。

### Tests

- 更新设置信息架构测试至新分组；新增 Replicate 深链归组、分页数学（取整、越界收敛、自定义页大小）测试。

### Meta

- 功能版本从 **1.235.0-rc4** 提升为 **1.236.0-rc1**，内部构建号 **306 → 307**，Help 与 Computer Use Helper 构建号 **222 → 223**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.235.0-rc4 - 2026-08-09

### Fixed

- 计划执行中被用户中断后，新指令终于能被执行了。此前旧计划即使被停止仍是「执行合同」：系统提示词命令模型「继续执行、不要重新规划」，模型为新任务产出的计划被宿主拒收，自动续推还会把执行拉回旧计划，委托外部 CLI 时新任务文本甚至被改写成「执行旧计划」。现在点停止会把计划标记为「已中断」（卡片胶囊显示灰色「已中断」）：后续消息另起任务就直接做（新计划可替换旧计划），要求继续就从当前步骤恢复（进度汇报或「从此步重跑」都会解除中断），自动续推对中断计划不再出手。
- 在项目分组上新建聊天不再冒出第二个同名项目。新会话此前不绑定所属项目，按原始路径落进一个新分组，显示名恰与项目同名，要等到下次编辑任意项目才被并回去。现在会话创建时就解析并绑定所属项目（含多目录项目的子目录），直接进项目分组。
- 左侧会话列表组内排序从「最后活动时间」改为「创建时间倒序」。此前任何后台会话（定时任务、调度节点、仍在输出的旧会话）收到一条回复就会蹿到组顶，列表看起来总在变来变去；创建时间与生俱来不再变化，行位置全生命周期稳定，活跃状态改由状态点与最近会话边栏轨提示。置顶（按置顶时间）与归档排序不受影响。

### Tests

- 新增计划中断合同的回归测试：中断后合同失效、委托任务文本不被改写、自动续推停手、系统提示词切换为「用户决定下一步」块、替换计划被捕获、进度汇报解除中断；旧持久化计划无该字段时按未中断解码。
- 新增侧边栏排序与项目绑定测试：组内按创建时间倒序、后台活动不重排、置顶仍居前；项目目录下新建会话落入项目分组、无主目录保持路径分组。

### Meta

- Bugfix 预发布版本从 **1.235.0-rc3** 递增为 **1.235.0-rc4**，内部构建号从 **305** 递增为 **306**，Help 与 Computer Use Helper 构建号从 **221** 递增为 **222**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.235.0-rc3 - 2026-08-07

### Fixed

- Agent 聊天正文改为与 Codex 参考界面一致的阅读密度：默认字号从 14 pt 调整为 15 pt，用户消息、助手完整回复、流式回复与 TextKit 历史记录的额外行距从 3 pt 调整为 5 pt，中文长段落不再挤成一片。
- 已安装用户不会被旧默认值挡住：仍使用历史 14 pt 默认值的安装会一次性迁移到 15 pt；曾主动选择 11–13 pt 或 15–20 pt 的用户继续保留原设置。设置页的中英文说明同步更新。

### Tests

- 新增 Codex 排版基准与字号迁移回归测试，并更新完整历史渲染对正文 15 pt、额外行距 5 pt 的断言。

### Meta

- Bugfix 预发布版本从 **1.235.0-rc2** 递增为 **1.235.0-rc3**，内部构建号从 **304** 递增为 **305**，Help 与 Computer Use Helper 构建号从 **220** 递增为 **221**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.235.0-rc2 - 2026-08-07

### Fixed

- 窄窗口下调度台只剩一个聊天面板。任务图右侧的节点接管抽屉是定宽 420、检查器定宽 315，可用宽度不够时任务图被压到零宽，整块工作区看起来就成了一个孤零零的对话框。现在侧栏宽度跟着可用宽度算：够宽照旧用理想宽度，不够就收窄到给任务图留够保底宽度；窄到两者不可兼得时以面板可读下限为准，任务图挤一点也不整列消失。

### Tests

- 新增侧栏分宽规则的测试：宽窗口保持原宽度、中等宽度收窄后任务图仍拿到保底宽度、约 420pt 的窄窗口下面板落到可读下限且不吃满整宽、首帧尺寸未知时按理想宽度渲染、极端退化宽度不溢出容器。

### Meta

- Bugfix 预发布版本从 **1.235.0-rc1** 递增为 **1.235.0-rc2**，内部构建号从 **303** 递增为 **304**，Help 与 Computer Use Helper 构建号从 **219** 递增为 **220**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.235.0-rc1 - 2026-08-07

### Added

- 调度台可以单独停止一个进行中的节点：节点检查器、图上节点的右键菜单、以及节点接管抽屉里各有一个「停止节点」。此前唯一能叫停的入口是聊天里的通用「停止」，而那一下会顺手把整个项目暂停——想停一个跑偏的节点，就得连带停掉同项目里正常推进的其他节点。现在停止只作用于这一个节点：它落到 `cancelled`，其余节点照常跑，之后还能重新启动它。
- 调度台的两个多行输入框支持回车发送：项目的「运行指令」与节点接管抽屉的「向运行中的任务发送指令」。SwiftUI 的 `TextEditor` 拦不住回车，这两处此前只能用鼠标点发送按钮。Shift/Option/Control + 回车仍是换行；输入法组字期间的回车归候选词上屏，不会误发。

### Fixed

- 在调度台顶部启动整个项目时，界面会跳进一个普通聊天窗口。启动每个节点都要新建一个 agent 会话，而「新建会话」这条路径固定把主界面切到会话视图——这对「新建聊天」是对的，对调度器自己拉起的节点则不是，一次启动多个节点还会连跳多次。现在调度节点的会话创建过程不再改变操作员所在的界面，启动后仍留在任务图上。
- 停止节点后不会被后台监听「复活」。节点的完成监听在停止后半秒会醒来，看到回合已结束就按老逻辑把节点写成 `failed`／`reviewing`，甚至用回退 Profile 自动重试一次；同时已排队的接管指令还会在停止后自动发出去。现在监听以注册表登记为租约，停止即退租，排队消息也不再自动补发。

### Tests

- 新增停止单节点的回归测试：节点落到 `cancelled`、项目不被暂停、监听退租、排队消息不自动消费；并在停止后放行监听等待窗口，确认它不会把状态改回 `merged`、也不会解锁下游节点。
- 新增调度节点会话创建不改变主界面目的地的测试（对照组：普通「新建聊天」照旧切到会话界面），以及回车发送键位判定的测试（裸回车发送、Shift/Option/Control 换行、输入法组字期间不发送）。

### Meta

- 圆桌那份「回车发送」多行输入框实现提取为共用的 `SubmitOnReturnTextView`，调度台的两个输入框复用同一份，圆桌三处调用点改为直接引用新名字。
- 功能新增，版本从 **1.234.0-rc19** 提升为 **1.235.0-rc1**，内部构建号从 **302** 递增为 **303**，Help 与 Computer Use Helper 构建号从 **218** 递增为 **219**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.234.0-rc19 - 2026-08-07

### Fixed

- 修复 1.234.0-rc18 引入的回归：从侧边栏分组「新建聊天」会把会话的工作区锚定到分组 key 本身。侧边栏把 `project:<uuid>` 这个 key 当成路径传了出去——对裸文件夹分组来说 key 恰好就是路径，所以这个缺陷一直看不出来；工作区全面并入项目后，它就变成了字面量 `/project:<uuid>`。表面症状是 Composer 的工作区标签显示成一串 ID 而不是项目名，实际影响更重：该会话的文件读写、终端 cwd 与 git 操作都会以一个不存在的目录为根。现在改为解析出该项目的主文件夹。
- 启动时自愈已被 rc18 写坏的会话：把 `/project:<uuid>` 形式的工作区路径还原为对应项目的主文件夹；项目已被删除时清空工作区，而不是留下一个永远无法解析的路径。rc18 已经发布，因此仅修好产生源头并不足够。

### Tests

- 新增工作区路径修复的回归测试：标准化后的 `/project:<uuid>` 与原始 key 两种形态都能还原为真实目录、真实路径与空工作区不被误判、名字里带 “projects” 的普通目录不受影响、项目缺失时改为清空。

### Meta

- Bugfix 预发布版本从 **1.234.0-rc18** 递增为 **1.234.0-rc19**，内部构建号从 **301** 递增为 **302**，Help 与 Computer Use Helper 构建号从 **217** 递增为 **218**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.234.0-rc18 - 2026-08-07

### Changed

- Composer 上的活动状态条统一走灰色。「验证中」（`run_command`）此前是橙色，一条跑十几分钟的命令就会顶着一张橙卡长期抢注意力；「搜索中」「操作终端」「编辑中」「处理中」同样各自带色。这几个都属于正常推进，现按代码里既有的规则收敛为灰色——彩色只留给唯一卡住进度、必须用户动手的「等待你回答」（橙）。委派给子代理保留 accent 色：那是由另一个 agent 代跑，与本地自己在跑是两回事，属有测试锁定的既有设计决策。

### Performance

- 活动状态条的扫光动画在窗口不活跃时停摆。它按 12fps 驱动且持续整个回合——一条跑十分钟的命令就是十分钟动画——而一次 CA transaction flush 会把所有待布局窗口一起过一遍，因此每一帧都要付一次主窗口整棵视图树的代价。窗口没在前台时这笔开销买不到任何东西。

### Fixed

- 侧边栏预览里的 Markdown 正文无法选中，右键也就没有可复制的内容。标题、段落、引用、列表都渲染成了未启用选择的 `Text`（代码块与表格此前已各自启用），而这几类恰好是一篇文档的主体。
- 窗口过窄导致会话列表自动隐藏时，标题栏那个「收起/展开会话列表」按钮只是变灰，没有任何解释。tooltip 其实早已写好（「加宽窗口以显示侧栏」），但 AppKit 不会为禁用控件跟踪鼠标，于是它永远弹不出来。按钮改为保持启用、由 action 拒绝切换，dim 效果照旧表达不可用。

### Meta

- 拆分 `XeditTests/XeditTests.swift`：终端捷径录制/持久化与终端工具路由的 24 个用例移入新的 `XeditTests+TerminalShortcuts.swift`，原文件从 3066 行降到 2068 行。此前它越过 `scripts/complexity_guard.rb` 的 3000 行硬上限，使 CI 的 `Ruby guards (quality)` 自 1.228.0-rc7 起一直是红的。
- 拆分采用同类型 `extension` 而非新建 `@Suite`：用例的 `XeditTests/WillDeepTests/<name>()` 标识不变，`-only-testing` 过滤与套件的 `.serialized` 特性一并沿用。全量 2157 个用例数量与结果均与拆分前一致，`complexity_guard` 现为 `hard=0`。
- Bugfix 预发布版本从 **1.234.0-rc17** 递增为 **1.234.0-rc18**，内部构建号从 **300** 递增为 **301**，Help 与 Computer Use Helper 构建号从 **216** 递增为 **217**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.234.0-rc17 - 2026-08-07

### Changed

- 工作区全面并入项目。启动时每个仍以裸文件夹分组的工作区会自动升级为同名项目，侧边栏不再并列显示「工作区」和「项目」两类条目——此前把一个工作区升级为项目看起来像是又多出一组，而不是把原来那组转换掉。侧边栏顶部的「+」以及 Composer 的「选择文件夹…」现在添加的直接就是项目，不再产生裸工作区；已被某个项目（或其父目录）认领的文件夹会复用该项目，不会另起一组。远程工作区没有可命名的本地文件夹，不参与升级。
- 聊天记录里只有最新一轮保留「本轮进度」卡片。此前每一轮都留着自己的卡片，长会话会摞出一列内容雷同、计数早已过期的小卡片。更早轮次照旧剥掉 progress 协议块，只是不再渲染卡片。

### Fixed

- 侧边栏「最近会话」轨道把项目分组显示成 `project:6F…262` 这样的原始 key。该处的「分组 key → 显示名」逻辑漏了 `project:` 分支，直接落到 `lastPathComponent` 把 key 原样吐了回来。这套逻辑本有两份副本（会话侧边栏那份有 project 分支、轨道这份没有），现已收敛到 `WorkspacePresentation.groupDisplayName` 一处。
- 语音模型与本地模型下载时进度条在走、字节数却始终显示 `0.0 MB / 0.0 MB`。两处都用 KVO 观察 `progress.fractionCompleted`，却从 `progress.completedUnitCount` / `totalUnitCount` 取字节——下载任务的 fraction 由内部驱动，这两个字段并不保证被填充。改为读取 task 自身的 `countOfBytesReceived` / `countOfBytesExpectedToReceive`，并在服务端未返回 Content-Length 时回退到已知体积。
- 后台任务详情里超长命令的文字溢出、盖住下方的 PID／开始时间／运行时长与日志区。Grid 单元格没有宽度约束，长命令以整行宽度参与列宽计算，把列撑到面板之外，`lineLimit` 也就永远没有换行的理由。
- 「编辑项目」弹窗与项目右键菜单整体显示为英文。这批文案的 19 个 key 从未写进 `Localizable.xcstrings`，`String(localized:)` 找不到条目就回退到英文 defaultValue；i18n 覆盖率检查按 key 是否存在统计，因而一直显示 100%。现已补齐全部条目的中英文案。

### Tests

- 新增工作区升级为项目的选取规则回归测试：裸文件夹被挑出、重复文件夹只升级一次、已被认领（含父目录已认领）的文件夹跳过、无工作区/已属项目/远程会话跳过、升级后沿用文件夹名；以及历史轮次不再各留一张进度卡且不漏出原始 progress 协议块。

### Meta

- Bugfix 预发布版本从 **1.234.0-rc16** 递增为 **1.234.0-rc17**，内部构建号从 **299** 递增为 **300**，Help 与 Computer Use Helper 构建号从 **215** 递增为 **216**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.234.0-rc16 - 2026-08-07

### Changed

- 输入框上方的后台任务状态条只报运行中的数量，不再显示含已结束任务的总数（原为「7 个后台任务 · 1 个运行中」）。该状态条本就只在有任务运行时出现，总数等于在报告用户已经不需要盯的历史；已结束任务仍可在后台任务面板里查看。同时移除了卡片内那套永远走不到的「无运行中任务」灰色样式分支。
- 桌宠后台动画帧率从 12fps 降到 8fps，与前台一致。此前后台反而比前台快，理由是 App 不活跃时桌宠是主要可见界面；但这恰好是代价最高、收益最低的时刻——主窗口那棵庞大的视图树会被一同拖进布局循环。8fps 对约 3 秒的呼吸动画周期依然平滑。

### Fixed

- 后台任务面板的双栏日志不再横向撑破面板。stdout / stderr 两栏各自内部已经支持双向滚动，外面却又套了一层水平 `ScrollView`，等于告诉两栏「宽度无上限」，于是每栏都按最长的一行日志把自己撑开，stderr 被推出可视区、stdout 只剩被裁掉的半截。现在两栏在面板宽度内平分，长行仍可在各自内部横向滚动。

### Performance

- 桌面宠物窗口被完全遮挡、切到别的 Space 或锁屏时，动画时间线整体停摆，不再逐帧驱动渲染。一次 CA transaction flush 会把所有待布局的窗口一起过一遍，所以桌宠时间线实际上决定了整个 App 的 display cycle 节拍——采样证实 `DesktopPetSceneView` 与后台任务面板出现在同一个 `NSHostingView.layout()` 调用栈里。空闲 App 因此长期占用约 20% 单核，其中约 5% 纯粹花在没有任何视觉产出的脏标记传播上。
- 后台任务面板的每秒刷新从整个 body 收窄到耗时标签本身。此前一次 tick 会连带重建作用域选择器、搜索框、全部任务卡和展开的详情面板。已结束的任务耗时恒定，现在直接静态渲染、完全不开时间线——面板里只剩已完成任务时不再每秒空转。
- 任务列表的进程名（`processName`）改为随行模型计算一次。此前它在筛选、每张卡片和详情元数据里各算一遍，每次都要切分命令行并构造 `URL`。同时把区分运行中/已结束的两次 `filter` 合成单次分区。

### Tests

- 新增桌宠动画门禁（不可见或已关闭时停摆）、后台帧率不得超过前台、任务行只派生一次进程名、单次分区保持顺序，以及耗时格式化的回归测试。
- 修正目标模式会话恢复测试里一条与实现相反的断言。它断言「陈述目标后会话离开侧边栏、所有权交给看板」，但 `cc97ab60` 早已把 `belongsInWorkspaceSidebar` 改为 `presentationScope == .workspace`——工作区会话在任何模式下都保留侧边栏位置，看板只是附加投影。该断言使单测门禁在 develop 上持续为红；改为断言两个界面同时可达，这也更贴合该测试套件真正要防的「两边都找不到」。

### Meta

- Bugfix 预发布版本从 **1.234.0-rc15** 递增为 **1.234.0-rc16**，内部构建号从 **298** 递增为 **299**，Help 与 Computer Use Helper 构建号从 **214** 递增为 **215**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。
- 测试用的 `KeychainSandbox` 在销毁时删除 UserDefaults suite 的 plist 文件本身。`removePersistentDomain` 只清空内容、留下约 42 字节的空壳，而每个实例都会新建一个带 UUID 的 suite——开发机上已累积 4712 个残留文件。

## 1.234.0-rc15 - 2026-08-07

### Changed

- 输入框上方「任务运行中」状态条由绿色改为灰色。任务在跑属于正常推进，不需要用户做任何事；彩色 tint 现在只保留给「等待你决定」（橙）——那是唯一卡住进度、必须用户动手的阶段。

### Meta

- Bugfix 预发布版本从 **1.234.0-rc14** 递增为 **1.234.0-rc15**，内部构建号从 **297** 递增为 **298**，Help 与 Computer Use Helper 构建号从 **213** 递增为 **214**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.234.0-rc14 - 2026-08-07

### Fixed

- 计划自动续跑不再把「没输出状态块」一律当成「跑不动了」：本轮之后仍有工具调用成功、或本会话还有后台任务在运行时，改为继续要求模型补一个 `progress` 状态块，而不是直接中止执行。8 轮自动续跑上限保持不变，仍是唯一的硬性兜底。
- 状态校准提示在后台任务仍在运行时会明确告知模型「有后台任务未结束，等它的步骤请保持 `in_progress` 并说明」，避免模型被要求汇报它还无从得知的结果、进而回一段无法解析的散文。

### Changed

- 聊天横幅新增严重级别：计划状态同步暂停、自动续跑达到 8 轮上限这两条属于「交还控制权」而非执行失败，改用蓝色信息样式与 `info.circle` 图标呈现，不再使用红字与警告三角。真正的错误（Provider 失败、some.im 未登录、workflow YAML 解析失败等）仍为红色，且每个清除/设置入口都会把级别复位为红色，避免残留的温和样式淡化真实错误。
- 输入框上方「压缩上下文中」状态条由紫色改为灰色。上下文压缩是例行后台维护，彩色 tint 保留给等待用户决定（橙）与任务运行中（绿）这类真正需要注意的阶段。

### Tests

- 新增自动续跑策略回归测试：有工具成功/后台任务在跑时改为继续校准、无活动证据时仍然暂停、活动证据不得越过 8 轮硬上限，以及后台任务提示语的出现与缺省。

### Meta

- Bugfix 预发布版本从 **1.234.0-rc13** 递增为 **1.234.0-rc14**，内部构建号从 **296** 递增为 **297**，Help 与 Computer Use Helper 构建号从 **212** 递增为 **213**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.234.0-rc13 - 2026-08-07

### Fixed

- 将 macOS 内部构建号从 295 提升至 296，确保新版本可被自动更新服务识别并发布。

### Changed

- 基于 rc12 的完整功能集重新生成、签名、公证并发布正式安装包。

## 1.234.0-rc12 - 2026-08-07

### Changed

- 集成 rc8–rc10 的定时任务卡片、普通/目标模式一致性与 Project 多目录授权改进，以及 rc11 的工具调用参数流性能优化，统一形成可交付版本。

### Tests

- 通过定时任务卡片、会话模式、Project 文件工具、补丁应用、Shell 授权与流式工具调用分层发布相关回归测试。

## 1.234.0-rc11 - 2026-08-07

> 版本号说明：本条目原为 rc8，因并行会话已占用 rc8–rc10（定时任务卡片 / 目标模式修复），改占 rc11；内容即「工具调用参数流并入两档通道」。

### Fixed

- rc7 装机后复采样：主线程 CPU 从 93% 降到 ~40%，但仍偏高——第二个 10Hz 全局发布源是**工具调用参数流**。`toolCallsUpdated` 事件虽有 100ms 发射门（`AgentToolCallStreamEmissionGate`），但每次发射都直写 `runtime.messages[index].toolCalls`，参数越长（edit_file 的 diff 动辄几 KB）整窗失效持续越久。现在并入 rc7 的两档通道：参数片段增长走 overlay/慢档（canonical 1Hz），**新工具调用出现（数量变化）仍立即同步**，live activity timeline 挂载不延迟；`flushPending()` 时序不变，回合收尾/错误路径的 canonical 工具列表完整。

### Tests

- 新增 `testAgentStreamingBufferToolCallTierSplit`：新调用立即发布、同调用参数增长滞后、`flushPending` 落盘最终参数。

## 1.234.0-rc10 - 2026-08-07

### Fixed

- 修复 Project 新增多个目录后工具仍只认会话主目录的问题：Project 文件夹现在会进入会话的授权根目录集合，`read_file`、`grep_files`、`list_directory`、`create_file`、`edit_file` 与 `apply_patch` 均可通过绝对路径访问附加目录，同时继续拒绝未加入 Project 的路径。
- 修复附加目录中的 Shell 命令被误判或被运行期沙箱拦截的问题；命令风险分类、沙箱预检与工作区写入 profile 现在识别全部 Project 根目录，因此 `sed -n` 等只读命令及已授权的工作区写命令不会再因附加目录身份丢失而失败。
- 补丁提案现在持久化实际目标根目录，智能审核、Goal 自动应用、单张应用和批量应用都会写入正确的 Project 文件夹；跨根目录批量补丁按根目录分组，避免回退到主目录或发生同名路径串写。

### Tests

- 新增附加 Project 根目录的绝对路径读取、编辑目标绑定和只读命令授权回归测试，并通过相关 Project、文件工具与补丁批量审批测试。

## 1.234.0-rc9 - 2026-08-07

### Fixed

- 修复 Composer 在普通模式与目标模式之间切换时改变既有会话展示的问题：目标模式不再在回合结束后压缩或改写过程消息，模式切换也不再清空当前计划、目标及目标规划恢复状态，聊天历史在两种模式下保持一致。
- 修复带有效目标的工作区会话从左侧会话列表消失的问题。目标看板现在是会话的附加投影视图，不再取得会话的独占归属；普通会话与目标会话只要属于工作区，都会继续保留在原工作区列表中。

### Tests

- 更新目标模式聊天渲染与侧边栏可见性回归测试，覆盖过程消息和工具元数据不被模式切换改写、目标会话同时出现在工作区列表和目标看板，以及来回切换模式后消息、计划、目标、活动会话 ID 和侧边栏归属保持不变。

## 1.234.0-rc8 - 2026-08-07

### Changed

- 会话内定时任务卡片对齐 Codex 的紧凑展示：使用中性描边卡片、独立时钟图标块、任务标题与频率两行信息，并在右侧提供明确的“打开”按钮；点击后仍进入对应定时任务详情。会话侧边栏继续用时钟标记拥有活跃定时任务的会话，已完成任务则保留为低对比度历史记录。

### Tests

- 新增会话内定时任务卡片的布局指标断言、真实 SwiftUI 渲染入口与导航状态测试，覆盖最大宽度、卡片高度、圆角、图标尺寸、中英文“打开”文案，以及打开对应任务详情的完整状态转换，并用于与 Codex 参考截图进行设计验收。

## 1.234.0-rc7 - 2026-08-06

### Fixed

- 流式输出期间整窗 SwiftUI 全量重布局的风暴（`sample` 实测：主线程 93% CPU 钉死在 `GraphHost.flushTransactions` 的 StackLayout 递归里，连设置页的 `body` 都在陪跑）。根因是发布链路：每 100ms 一次流式 flush 改写 `runtime.messages`（`@Published`）→ 经 `activeRuntimeSubscription` 转发成 `AppState.objectWillChange` → 每个观察 `appState` 的视图重估 + 整窗重测，10Hz 持续整个回合。与 rc482 composer 键击风暴同病，本次给流式内容同款解法：新增 `AgentStreamingContentOverlay` 专用发布通道挂在 `AgentRuntime` 上，只有 transcript 的流式气泡子树（新增 `StreamingBubbleHost`，长消息截断逻辑随之内移）观察它，10Hz 的 token 刷新只失效这一小块；canonical `messages` 数组降为 1Hz 慢档同步（首个正文/reasoning token 仍立即同步，气泡挂载与思考预览无感知延迟），全局失效频率降到原来的 1/10。`flushPending()` 同步排干两档，工具调用/用量/回合结束事件周围的 canonical 时序不变。

### Tests

- 新增流式两档发布测试：`testAgentStreamingBufferTierSplit`（overlay 每 flush 更新、canonical 滞后、`flushPending` 全排干、首 token 立即发布）与 `testAgentStreamingOverlayApplying`（overlay 叠加到 canonical 消息、陈旧快照按单调性丢弃、无关消息 id 直通）。原有原子性测试 `testAgentStreamingBufferPublishesAtomically` 语义不变继续通过。

## 1.234.0-rc6 - 2026-08-06

### Fixed

- 关闭终端标签页时的偶发崩溃（`EXC_BREAKPOINT`，栈为 `AgentTerminalTab.terminate` → `LocalProcess.childStopped` → `childMonitor` getter → `_os_object_retain`）。`LocalProcess.terminate()` 与其退出事件源的回调都会执行 `childStopped()`，二者 cancel 并置空同一个 `DispatchSourceProcess`。上游 SwiftTerm 不受影响是因为它在 `DispatchQueue.main` 上投递；我们为了让 `terminal_snapshot` 不被繁忙主线程饿死，刻意把投递队列换成了快照镜像的后台队列，于是这对操作变成并发——`AgentTerminalTab.terminate()` 又是先杀进程树、退出事件已在镜像队列上在途，主线程随即拆源，造成 dispatch 对象过度释放。现把拆除动作放到投递队列上同步执行，补回上游白拿的那份串行化。**已知局限**：该修复依据是崩溃栈与代码推理，不是实验复现——无同步内存竞争无法靠时序稳定触发，新增的回归测试在退回修复后照样通过（已在测试文件注释中写明）。

### Changed

- 拆分四个触及仓库 3000 行硬上限的文件，`scripts/complexity_guard.rb` 恢复 pass（此前它是 `run_tests.sh` 的第一步，本地整条脚本跑不动）：`L10n.swift`（3089→1759，析出 `L10n+Settings.swift`）、`AppStateAgentLoop.swift`（3058→2378，析出 `AppStateAgentLoopToolBatching.swift` 与 `AppStateAgentBackgroundJobNotices.swift`，媒体任务通知则并入既有的 `AppStateAgentMediaTaskNotices.swift`——那本就是它的家，而 `scripts/short_drama_media_contract_test.rb` 的源码扫描正是按「AppStateAgentLoop + 该文件」拼接取材的）、`AgentChatHistoryRendererTests.swift`（3039→1611，析出 `AgentChatHistoryRendererGoalTests.swift` 与共享探针 `AgentChatHistoryRendererTestSupport.swift`）、`AgentInteractiveTerminal.swift`（3038→2292，析出 `AgentTerminalShortcuts.swift`）。纯搬运，无行为变更；`executeParallelReadBatch` / `patchAutoApplySource` / `activateSerialToolDecision` 因跨文件调用由 `private` 放宽为 internal（调用方仍只有 `runAgentLoop`）。
- 顺带把一段掉队的文档注释送回本主：`appendToolMessage` 的说明早年拆文件时留在了 `AppStateAgentLoop.swift`，贴在不相干的函数头上，而函数本体在 `AppStateAgentToolMessages.swift` 且无文档。

### Tests

- 新增 `AgentTerminalTerminationRaceTests`：覆盖两种拆除次序（杀树后拆、Shell 自然退出后拆），并作为 Thread Sanitizer 的载具。TSan 确实证实 `childStopped()` 被并发进入，但它按栈签名去重，只报出同函数内的 `running` 字段。**注意那条 `running` 竞争是上游的**（镜像队列 vs `LocalProcess` 私有 `readQueue`），本次修复不触及，且不 fork SwiftTerm 就够不着。
- 同族继续加固三处满载下必挂的时间预算，判据一致——**断言的是行为就别让延迟当门槛**：`AgentDispatchTaskTakeoverTests` 等内置浏览器渲染文字的 `timeout_ms` 从 3 秒抬到 20 秒（它断言的是各调度节点浏览器互不抢页）；`AgentExecutorProtocolTests` 五处 `timeoutSeconds: 5` 抽成 `fullSuiteJobTimeoutSeconds = 30`，等待预算 `fullSuiteCompletionAllowanceSeconds` 同步 20→45——此前等待侧已被加固而任务侧没跟上，等 20 秒却让任务 5 秒就被 SIGTERM，加固只做了一半，272 KB 走 stdin 的用例因此报 `.timedOut`。
- `run_tests.sh` 调用的 10 个 Ruby 脚本补上 `Encoding.default_external/internal = UTF-8`（`chrome_extension_contract_test.rb`、`computer_use_helper_contract_test.rb`、`xcodebuild_ci.rb`、`xcresult_report_contract_test.rb` 及 6 个短剧 MVP 脚本），与 `complexity_guard.rb`、`version_consistency.rb` 等既有兄弟脚本一致。未设 `LANG` 的 shell（裸终端、CI 容器）里 Ruby 默认外部编码是 US-ASCII，读到带中文的仓库文件会抛 `Encoding::InvalidByteSequenceError`，于是守门以「编码异常」而非检查结论的形式炸掉。
- `AgentBackgroundJobsTests` 的 `waitUntilFinished` 等待预算从 **15 秒**抬到 60 秒并抽成常量 `finishBudgetMs`。那是「等到终态」的存活预算，不是速度断言——用例跑的是 `true` 和带 trap 的 sleep 循环，空载毫秒级完成；满载全量并行时一次同时挂掉三条（`echoCommandCompletesWithExitZero` / `timeoutSurfacesTimedOutStatus` / `unattendedSandboxDenialAutomaticallyReplaysOnceEscalated`），而同一 suite 单跑 9.8 秒 38 条全过。与 rc4 对 `run_command`、以及更早对 git 类测试的处理同源。

## 1.234.0-rc5 - 2026-08-06

### Fixed

- `edit_file` 精确匹配失败时不再直接报错：新增两级空白容错回退——先忽略行尾空白，再容忍统一的缩进偏移并把 new_string 自动重排到文件真实缩进；仍无法定位时错误里附带针对性诊断（old_string 残留 read_file 行号前缀、首行能对上但后续分叉时报出锚点行号），模型可以据此自我修正而不是盲目重试。歧义（多处匹配）与真实分叉照旧硬报错，不放宽写入边界。
- `read_file` 修复 64KB 字节硬截断切断多字节 UTF-8 → 整段读取回退 Latin-1 解码 → 所有中文变乱码的问题：16MB 以内文件改为整文件解码 + 行边界窗口，超大文件的字节窗口也会先退到 UTF-8 字符边界再解码。
- `read_file` 新增 `offset`（起始行）与 `limit`（行数）参数，截断提示明确给出续读 offset；此前超过 256KB 的文件尾部对模型完全不可达，只能凭记忆构造 old_string。
- `read_file` 改为优先读取打开标签页的编辑缓冲区（与 `edit_file` 匹配的是同一份内容）；此前标签页有未保存修改时，模型读到的磁盘旧内容与编辑目标不一致，后续编辑必然失败。
- `search_files` / `grep_files` 结果行超过 200 字符截断时显式标注 `…[line truncated]`，并在 `edit_file.old_string` 参数说明中禁止用 grep 片段拼 old_string，避免残行被当成精确匹配源。
- 修复 `edit_file` diff 合成器在 CRLF 文件上的存量问题：`\r\n` 在 Swift 中是单个 Character，按字符扫描找不到换行、按字符数偏移会触发 String 索引越界崩溃。行扫描全部改为 `range(of: "\n", options: .literal)` 的索引运算；由于共享 diff 管线按 LF 设计（applier 以 `.newlines` 切分），CRLF 文件的编辑现在返回明确的「先转 LF 再编辑」错误提示，取代此前的内部 roundTrip 报错。

### Tests

- 新增行尾空白/统一缩进偏移回退、歧义与非统一缩进拒绝、行号前缀与首行锚点诊断、CRLF 明确报错，以及 read_file 行窗口、UTF-8 安全截断、越界 offset、标签缓冲一致性的回归测试。

### Meta

- Bugfix 预发布版本从 **1.234.0-rc4** 递增为 **1.234.0-rc5**，内部构建号从 **293** 递增为 **294**，Help 与 Computer Use Helper 构建号从 **210** 递增为 **211**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.234.0-rc4 - 2026-08-06

### Tests

- 加固满载并行下随机红的 `terminal command returns an automatic follow-up snapshot instead of dispatch-only output`。该用例本来就用独立的 `AgentInteractiveTerminalController` 和独立 PTY，`AgentInteractiveTerminalController` 也没有单例或进程级共享状态，不存在跨测试共享的终端占用标记；随机红的真实原因是它自己的登录 Shell 还没启动完——本地 tab 起的是 `zsh -l`，rc 文件里每条外部命令都是这条 PTY 的前台子进程且保持 canonical+echo，`AgentTerminalInputState.classify` 据此正确判为 `foreground_task`，`sendApprovedCommandDispatch` 于是按策略拒发并抛出「A non-interactive foreground task currently owns this terminal」。旧实现靠固定 `Task.sleep(300ms)` 赌启动完成，空载够用、满载（1900+ 用例并行）随机被击穿。
- 新增 `XeditTests/AgentTerminalTestSupport.swift`：`waitForShellReady` 轮询 `refreshInputState()`，要求连续 3 次采样均为 `shell_ready` 才放行（单次采样可能落在两个 rc 子进程之间的空档），30 秒上限，Shell 已退出则立即返回。等不到就绪时断言直接报「login shell never reached its prompt」，不再以「前台任务正占用该终端」的形式误导排查方向。生产代码未改动——前台任务拒发是正确行为，问题只在测试的等待方式。

- 同族加固：`run_command receives the terminal-configured local environment` 与 `testRunCommandUsesHomeDirectoryWithoutWorkspace` 的 `timeout_seconds` 从 **5 秒**放宽到 30 秒（复用 `headlessCommandTimeoutSeconds` 常量）。两条断言的都是环境变量传递与工作目录，不是延迟；`printf`/`pwd` 本身单跑 8ms，但满载 fork 风暴下 `posix_spawn` 加沙箱启动就能吃掉 5 秒预算，实测在全量并行中连挂两轮（12.0s / 12.7s）、单跑必过。与仓库既有做法一致——git 类测试的 5 秒超时此前也是因同样原因放宽的。

### Meta

- Bugfix 预发布版本从 **1.234.0-rc2** 递增为 **1.234.0-rc4**，内部构建号从 **291** 递增为 **293**，Help 与 Computer Use Helper 构建号从 **208** 递增为 **210**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.234.0-rc2 - 2026-08-06

### Fixed

- 多文件夹项目三期：目标看板与侧栏统一项目命名。此前看板自行从路径派生名称，于是同一个项目在侧栏叫「TokenHub」、在看板叫「tokenhub」；重命名项目也只改得动侧栏那一处。现在会话归属托管项目时，看板的名称与主文件夹都取自该项目。
- 「是否同一个项目」的判定改为：两侧都有托管项目 id 时直接比 id。此前只能靠路径与 Git 仓库指纹近似推断，而一个项目横跨两个独立仓库（前后端分离）时指纹本就不同，无法认定为同一项目。
- 未纳入托管项目的会话完全走原有的路径/指纹判定；一侧有托管 id、另一侧没有时也回退到原规则，不会因为无法精确比较就武断判否。

### Tests

- 新增 9 条单测：无托管项目时仍按路径派生、托管项目提供看板名称、未命名项目回退到其主文件夹而非会话所在文件夹、看板锚定项目主文件夹、同项目的两个文件夹判定为同一项目、用户刻意拆分的两个项目不混淆、无托管时沿用旧规则、混合场景不短路、托管 id 编解码往返与旧记录兼容。

## 1.234.0-rc1 - 2026-08-06

### Added

- 多文件夹项目二期（可用了）：侧栏工作区分组右键新增「编辑项目」/「设为项目」。弹窗可改项目名、增删源文件夹，于是前后端两个仓库能归入同一个分组，分组名也不再被目录名锁死。
- 移除项目：**只删除该项目独占的会话**。文件夹同时属于其他项目的会话会被保留并改绑到那个项目——否则移除项目 A 会连带毁掉项目 B 仍在展示的历史，且不可恢复。
- 确认弹窗把两个数字都写清楚：将永久删除多少条、有多少条会保留并移入哪个项目；没有任何会话会被删除时不显示破坏性措辞。

### Changed

- 会话的项目归属在每次创建/编辑/移除项目后重新解析并**持久化**，不在渲染时动态计算；已稳定归属于某项目且该项目仍认领其路径的会话不会被重新洗牌。
- 会话删除复用既有 `deleteAgentSession`，不新写删除路径——那条路径已处理响应中的运行时、异步写队列与 sidecar 清理。移除时先改绑幸存者再删除，中途失败也不会留下指向已删项目的会话。
- 项目引用的文件夹若不存在（移动或外接盘未挂载），弹窗内灰显「文件夹不存在」但不自动清除，避免未挂载时静默改写用户配置。

### Tests

- 新增 10 条单测：独占会话被删、共享会话改绑而非删除、混合场景两个数字都对、其他项目会话不受影响、未纳管会话不受影响、空项目为非破坏性、被移除项目不能继承自己的会话、继承按与新建会话相同的规则裁决、worktree 会话按项目根解析、远程工作区无本地路径可匹配。

## 1.233.0-rc5 - 2026-08-06

### Fixed

- 移动网关的周期快照不再在主线程上打磁盘。`mobileGatewayWorkspaceList` 对每个工作区各做两次文件系统探测——`.git` 的 `fileExists`，以及为找仓库根**逐级向上**遍历目录、每层再 stat 一次——而这个属性每 400ms 就被完整重算一遍，只要手机连着就一直在跑。对 1.228.0-rc10 采样 5 秒，`lstat` 作为主线程叶子帧被抓到 12 次，彼时窗口除了渲染什么也没做。两个探测现在按路径缓存，30s 过期：一个目录是不是 git 仓库属于人类时间尺度的事实，`git init` 之后一两个快照周期内照样能传到手机，稳态则从系统调用降为一次字典查找。
- 三个周期性 envelope（`state.snapshot` / `workspace.list` / `capabilities`）内容没变时不再发送。它们每个 tick 都会被重建，但流式回复期间真正在动的只有 `state.snapshot`——另外两个逐 tick 完全一致，却仍要付一次 JSON 编码、一帧 WebSocket 和手机端的处理，只为了说「什么也没变」。比较的是 payload 而非整个 envelope：后者每次都带新的 `ts`，比出来永远不等，去重会变成死代码。
- 建立新连接时清空这份 payload 记忆。它描述的是「这条连接已经被告知了什么」，重连后的手机需要的是完整画面而不是对着一个已死连接做的 diff。
- `AppState.objectWillChange` 不再对每次字段变化都排一个 `Task` 上主 actor。流式回复期间那是每个 token 一次，而每一次的全部作用只是跑到主线程上撞掉 `snapshotTask == nil` 的判断然后返回；主线程当时正忙于布局，于是这些空转的 hop 排成长队（采样里 `@isolated(any)` 的 async thunk 有 154 个样本，比真正干活的快照闭包还多 33 个）。改为在 hop **之前**用一个线程安全的一位闩锁合并，一个 400ms 窗口只排一个 Task。真正的 400ms 节流仍由 `snapshotTask` 负责，发布频率不变。
- 侧栏会话标题的自然宽度按标题缓存。`sessionRow` 每行调用一次 `sessionTitleNaturalWidth`，而侧栏 body 每帧重跑，于是同一批标题被反复量给同一个字号——采样里这个函数独占主线程 37 个样本，量的全是上一帧刚量过的东西。`sidebarRowFontSize` 是编译期常量，标题本身即完整缓存键；缓存到 1024 条整体清空，不做 LRU。

### Tests

- 新增 13 条单测：payload 去重（首条必发、payload 相同仅 `ts` 变必须压掉、payload 变化必发、A→B→A 必须重发、不同 type 互不遮蔽、`reset` 后即使内容没变也要全量重发——最后一条钉的是重连回归）；一位闩锁（一个 clear→set 周期只放行一个调用者、64 个并发调用者恰好一个胜出）；仓库探测缓存（TTL 内 75 次调用只探测一次、TTL 过期后重探、否定结果同样被缓存、不同路径互不覆盖、仓库根按路径缓存、`reset` 后重新探测）。

### Note

- 「主线程同步读 Keychain」那条不在本轮，已由 **1.233.0-rc3** 单独处理。两轮针对的是同一次采样里的不同热点：rc3 消掉 `SecItemCopyMatching` 的往返，本轮消掉 `lstat` 与空转的快照发布。

### Meta

- Bugfix 预发布版本从 **1.233.0-rc4** 递增为 **1.233.0-rc5**，内部构建号从 **293** 递增为 **294**，Help 与 Computer Use Helper 构建号从 **210** 递增为 **211**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.233.0-rc4 - 2026-08-06

### Fixed

- 聊天正文额外行距由 5pt 收紧为 3pt，对齐 Codex 参考截图的紧凑阅读节奏，中文长段落不再显得行与行之间过松。
- 灰色内联代码 chip 的垂直留白由上下各 1.5pt 改为上 1.5pt、下 0.5pt，修正底部 padding 偏厚的视觉不平衡。

### Tests

- 更新聊天正文行距断言，并补充内联代码 chip 上下留白方向的回归检查。

### Meta

- Bugfix 预发布版本从 **1.233.0-rc3** 递增为 **1.233.0-rc4**，内部构建号从 **292** 递增为 **293**，Help 与 Computer Use Helper 构建号从 **209** 递增为 **210**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.233.0-rc3 - 2026-08-06

### Fixed

- some.im 共享登录态不再每次都同步读钥匙串。读一次是 `SecItemCopyMatching`——到 `securityd` 的同步 XPC 往返——而调用方全在主线程：移动网关每 400ms 在 `publishSnapshot()` 里读一次，模型选择器每次刷新菜单也读。对 1.228.0-rc10 采样 5 秒，89 个主线程样本卡在 `SharedKeychain.read` 上，读回来的还是同一个答案。现在结果记在内存里，只有真正可能变化时才重新读。
- 「没有登录」同样被缓存。否则未登录用户反而每 400ms 都要白跑一趟钥匙串，正好是这个缓存最该覆盖的场景。
- 缓存在每条写路径上失效：本地登录/登出、凭据迁移、账号与设置保存，以及**其它 app** 的登录/登出（走 `SomeIMSharedSessionStore.observe` 的跨进程通知，那是这种变更唯一的信号）。`persistSharedSession` 刻意在写入**之前**失效——它的调用方靠「写完再读回来比对」验证落盘，这个读必须真的到达钥匙串，否则校验会退化成恒真。

### Tests

- 新增 6 条单测：重复读只加载一次、未登录答案同样被缓存、失效后下次读重新加载、重复失效幂等、「先失效再写入」能让读回校验观察到新值（钉死上面那个恒真陷阱），以及 DEBUG 测试替身路径绝不走缓存——否则现有 SomeIM 测试会开始依赖失效顺序。
- 缓存本身拆成独立的 `SomeIMSharedSessionMemo`，因为真实 loader 会读开发者本人的 some.im 登录态，单测绝不能碰；拆开后用计数桩就能验证「到底重读了几次钥匙串」。

## 1.233.0-rc2 - 2026-08-06

### Fixed

- **侧栏终端偶发「一个字符都没有、却还挂着滚动条」**：SwiftTerm 把每一次 frame 变化都翻译成 `terminal.resize`，而它自己的下限是 2 列 × 1 行，且下行途中会整体 reflow。一段有 scrollback 的缓冲区按两列重新折行后行数会暴涨到远超 `rows + scrollback`，缓冲区于是从顶部 trim；等 frame 恢复正常再 reflow 回去也捞不回来——可见区回来时是空的或错位的，滚动条却仍按残留的 scrollback 显示。SwiftUI 递给这个 NSView 的退化 frame 是家常便饭（挂载、卸载、面板切换、分离成独立窗口），所以故障表现为时好时坏。现在低于「20 列 × 3 行」的 frame 一律不落到模拟器上，保留上一次真实几何；侧栏本身最窄 240pt（约 24 列），这条下限只会挡掉任何真实布局都不会提出的尺寸。
- 相应地，`viewDidMoveToWindow` 不再在视图已经脱离窗口时强制 `layoutSubtreeIfNeeded()`——那正是退化 frame 被算出来并推进模拟器的路径之一。1.193.0-rc19 的 resize storm 修复只防住了 SIGWINCH 一侧，模拟器自身的 resize 当时仍是敞开的。

### Tests

- 新增 2 条单测：退化 frame（0×0）往返后可见区文本与 `canScroll` 必须与往返前逐字节一致、且 cols/rows 不被改动；网格下限仍然接受最窄真实侧栏布局（240pt 减去 8pt 左右内缩），并拒绝零宽、零高与全零 frame。

## 1.233.0-rc1 - 2026-08-06

### Added

- 多文件夹项目一期（模型层）：新增 `AgentProject`（名称 + 多个源文件夹 + 仓库指纹）与 `AgentProjectStore`（`projects.json`，与会话目录同级）。会话新增可选 `projectID`，侧栏分组 key 优先级变为 `projectID → sidebarWorkspaceRootPath → workspaceLocation → workspaceRootPath`。前后端分离的两个仓库因此可以归入同一个侧栏分组，分组名也不再被目录名锁死。
- 归属解析 `AgentProjectResolver`：一个文件夹可属于多个项目（已确认的决策 2），并列时**最具体的文件夹胜**，仍并列则取 `updatedAt` 最新者；解析结果需固化到会话，避免新增项目让旧会话悄悄换组。
- `AgentProjectResolver.otherProjectsClaiming` 为二期的「移除项目只删独占会话」提供判定依据。

### Changed

- 项目文件的日期沿用会话既有的数值编码而非 ISO8601：后者丢弃亚秒精度，而 `updatedAt` 正是并列归属的裁决依据，每次读写漂移会让裁决不稳定。
- 侧栏分组名在命中项目时显示项目名；项目已被删除的陈旧 key 回退为「无工作区」而不是裸露 `project:<uuid>`。
- 项目分组 key 带 `project:` 前缀，与绝对路径（恒以 `/` 开头）天然不同命名空间，不会碰撞。

### Compatibility

- 未创建任何项目时 `projects.json` 不存在，全部会话 `projectID == nil`，侧栏行为与此前逐字节一致；旧会话 JSON 直接解码为 nil。worktree 的 `sidebarWorkspaceRootPath` 行为不变，仅在未纳入项目时生效。

### Tests

- 新增 19 条单测：路径包含按边界判定（`/a/b` 不吞 `/a/bc`）、路径规范化（尾斜杠/空白/根目录）、一个项目跨多文件夹、空名回退主文件夹名、最具体项目胜出、并列按时间且与数组顺序无关、未命中返回 nil、共享文件夹的其他claimant可枚举、项目主导分组 key、两个仓库同组、无项目会话分组不变、项目优先于 worktree 根、key 命名空间不碰撞、会话与项目的编解码往返、旧会话 JSON 兼容、store 缺失即空、store 位置在会话目录之外。

## 1.232.0-rc3 - 2026-08-06

### Fixed

- 修掉「上下文压缩必然失败」的死锁。压缩请求此前把待压缩的 head 用 `message.content` **原文**拼成单条 user message 一次性发出，而普通对话请求走的是 `collapseOldToolResults`（长 tool result 截成 head/tail）——也就是说压缩把普通请求已经折叠掉的内容又全量塞了回去，成为全 App 最大的一个请求。现场实测：1M 窗口的会话，压缩请求 1,621,884 tokens，provider 直接 400 `maximum context length`。越需要压缩越压不动，唯一的自救手段恰好在最需要它的时刻卡死。
- 压缩改为 map-reduce 分块：head 先按「每条消息一段」切开（tool result 走 `preferCompactSummary` 压实），再按压缩模型窗口的 15% 打包成块，逐块摘要后把分块摘要再折一轮，直到只剩一份。单条消息本身超预算的（比如一个巨大的 tool result）做头尾截断而不是丢弃，一条超长记录不会再卡死整条流水线。
- 压缩识别 provider 的「超长」类 400（`maximum context length` / `context_length_exceeded` / `prompt is too long` 等），命中时把分块预算减半重折，而不是把一个用户无法处理的 400 直接甩到界面上。
- 修掉上下文占用百分比的严重低估。同一个会话，环形指示器显示 54%，provider 实际已经收到 155% 的窗口用量。根因在本地估算口径 `estimateTextTokens`：**所有空白字符直接跳过不计费**（代码、JSON、终端输出里缩进换行占 20–40%），ASCII 一律按 4 字符/token（而 `call_00_JHrT6ia9tttWsQbHglDu8236`、UUID、路径这类符号密集串真实约 2 字符/token）。现在空白按 1/4 token 计，ASCII 拆成「字母」与「数字/符号」两档分别计价。
- 上下文占用改为优先采信 provider 自己报的 `prompt_tokens`。这个真值一直躺在 `AgentMessage.promptTokens` 上（消息页脚那个 `46.68M/15.1k` 就是它），环形指示器却从来没看过一眼，全程自己按字符猜。现在取「最近一次真实读数 + 其后新增消息的本地估算」与纯本地估算的较大者；自动压缩阈值判定用同一口径，所以 75% 自动压缩不会再因为低估而整场不触发。
- 压缩落地后真实读数会作废（该摘要已经缩小了 provider 看到的请求），此时退回纯本地估算——否则指示器会被旧读数钉在高位，反而盖掉刚刚生效的那次压缩。

### Tests

- 新增 12 条单测：分块后每块都在预算内且首尾段不丢失、超预算单段被截断且带 `elided` 标记、tool result 在压缩段落里被压实到原文一半以下、旧摘要排在段落首位、分块预算对 1M/8k 窗口的取值、真实 400 报文（现场原文）被识别为超长而普通 400 与 500 不被误判、`prompt_tokens` 锚点生效且压缩后作废、空白与符号密集串的新计价口径。
- 工具 schema 估算上限由 38k 调至 48k：同一份注册表在新口径下报 42,951（tool schema 正是符号与空白密集、旧口径低估最多的那类文本），不是注册表变大。

## 1.232.0-rc2 - 2026-08-06

### Fixed

- 修掉左侧「用户输入 minimap」在主线程上的持续空转。对 1.228.0-rc10 采样 5 秒，主线程 3748 个样本里 2699 个（72%）压在 SwiftUI 事务 flush 上，其中 450 个样本单独来自 minimap 这一个 `.overlay`——它挂在会话根视图上，SwiftUI 每次布局都会重跑好几遍，而每一遍都从头重算 `visibleMessages` 并重建全部回合摘要。窗口没人碰也在烧 CPU。
- `AgentTranscriptTurnSummary.build` 由 O(消息数 × 工具调用数) 降为 O(消息数 + 工具调用数)：编辑类工具调用先按所属消息聚合成字典一次，不再为每条 assistant 消息重扫整个 `agentToolCalls` 数组。旧的内层循环每次迭代都要拷贝并 retain/release 一个完整的 `AgentToolCall`（含 arguments 字典），采样显示这是该函数的绝对大头（326 个样本）。长会话里消息数百、调用上千，一次重建就是几十万次迭代。
- minimap 摘要改为按输入指纹缓存，输入没变时直接复用，不再随 `body` 反复重算整条链。指纹沿用 `AgentChatHistoryNSTextView.inputFingerprint` 的既有做法，只取 `content.count` 而不哈希正文，避免流式输出时每来一个 token 就重走多 KB 内容；工具调用只参与数量与末位 id，因为 minimap 读的 `messageID`/`toolName`/`path` 在调用创建后不再变化，状态更新不影响摘要结果。

### Tests

- 新增 8 条单测钉住 minimap 行为，覆盖改算法前后必须一致的语义：回合折叠 assistant 回复与编辑文件、编辑文件不跨回合泄漏、重复路径去重且保持首次出现顺序、非编辑工具与无 path 调用被忽略、只取首条非空 assistant 回复、host instruction 不产生刻度；外加缓存本身的两条——指纹不变只重建一次、指纹变化才重建。

## 1.232.0-rc1 - 2026-08-06

### Added

- 新增 `search_sessions` 工具：检索**历史会话正文**并返回命中片段。此前 Agent 只能用 `list_workspace_sessions` 看到标题等元数据，读不到任何一条消息——「上周我们讨论过 X」只能反问用户，尽管完整记录一直躺在磁盘上。
- 默认只搜当前工作区；`scope: "all"` 跨工作区检索**升为 write-tier 走审批卡**，由用户确认而非模型自行决定。归档会话默认纳入检索（那恰恰是最容易被遗忘的部分）。
- 命中结果带会话标题、工作区、时间、`session_id`、消息序号，以及命中消息 ± 1 轮的上下文；单条截断至 400 字符。

### Changed

- 检索遵循会话存储既有的「元数据先行」纪律：先按轻量目录筛选，再逐个 `load(id:)` 打开候选，凑够结果即停；单次最多打开 40 个会话，每个会话最多返回 3 条命中。故意不提供「读取整个历史会话」的能力——那会撑爆本要节省的上下文。
- 检索匹配为大小写与变音不敏感的**字面子串**，不解析正则：查询由模型书写，一个写坏的正则静默匹配不到东西，比字面搜索更难排查。工具输出（tool 消息）不参与检索。

### Tests

- 新增 11 条单测：匹配规则（含正则不被解析）、工具输出不参与检索、命中带位置与上下文、结果新到旧且按会话封顶、超长消息截断、工作区范围过滤、worktree 会话仍归属原项目、跨工作区检索为 write-tier、工具注册与必填参数、空结果说明搜索范围、结果含 session_id 且如实标注扫描被截断。

## 1.231.0-rc1 - 2026-08-06

### Added

- 每回合上下文新增当前时间与时区块：本机时间（`yyyy-MM-dd HH:mm:ss ±HH:mm`）、IANA 时区标识与 UTC 偏移。此前系统提示里**完全没有时间信息**，模型只能照抄工具输出里的时间戳——而远程主机、容器与 CI 几乎清一色跑 UTC，于是 UTC+8 的用户被告知「08:06:47，还有 ~3 分钟」，而自己表上是 16:06。
- 同时给出使用规则：向用户报时间用其本地时区；引用原始时间戳时保留原值并注明时区，需要用户据此行动时给出本地时间；计算时长前先把两端对齐到同一时区（混用 UTC 日志与本地 now 会整整差一个偏移）；并声明该时间戳取自回合开始时刻，需要精确当前时间时应自行读取时钟而非外推。

### Changed

- 时区块置于动态上下文标记之后，不进入稳定系统提示前缀，因此不影响供应商 prompt 缓存（当前命中率约 99%）。已有回合的时间戳随消息持久化，历史请求字节保持不变。

### Tests

- 新增 8 条单测：本地时区渲染（含与 UTC 的差异对照）、时区标识与偏移文案、整点/半点/UTC/西半球偏移格式、夏令时按具体时刻解析而非假定、转换规则文案完整、格式不随 locale 漂移（不出现 12 小时制或本地化数字），以及「时间块只出现在每回合上下文、绝不进入缓存前缀」的回归护栏。

## 1.230.0-rc6 - 2026-08-06

### Tests

- 为「切到目标模式后点开别的聊天，原会话再也找不回来」补回归测试，钉死完整路径而不只是第一步：切模式后仍在侧栏、失去选中后仍在侧栏、所属工作区分组不消失、已定目标的会话由看板接管且能选回原会话，以及「任一中间态都不会同时从侧栏和看板消失」的可达性断言。另单独钉死「空会话切走后隐藏」属于既有的空会话规则、与目标模式无关，避免日后被误判成此 bug 复发。

### Fixed

- 删除定时任务改为先确认。此前右键菜单里「删除」紧挨着「编辑」，点中即永久删除——任务的排程、提示词与全部设置一并消失且无法恢复。现在弹出与删除会话同款的确认弹窗，写明任务名与后果；未命名任务回退显示默认名称，不会出现「「」将停止运行」这种读不通的句子。

### Tests

- 新增 5 条单测：确认文案带上任务名、未命名任务回退默认名、名称前后空白裁剪、文案明确「无法恢复」与「停止运行」、确认与取消按钮文案不同且非空。

## 1.230.0-rc5 - 2026-08-06

### Fixed

- 头像与昵称现在能在登录态过期后自愈：`/customer/me` 返回 401/403 时，客户端用长期 api_key 静默换取新的会话 token 并重试一次，成功后写回 Keychain。此前客户会话固定 7 天且无续期途径，过期后资料再也刷不回来（余额走 api_key 不受影响），正是「点数在、头像昵称没了」的成因。
- 换取只在**确属登录态失效**时触发：500/429/404、超时、断网等一律不触发，避免把偶发故障放大成无谓的鉴权请求；换取失败时保留本地既有资料，不清空。
- 只重试一次。服务端持续拒绝时不再反复换取。

### Tests

- 新增 3 条单测：401/403/userAuthenticationRequired 判定为可续期；500/429/404/超时/断网/无效响应判定为不可续期；无 api_key 时换取直接失败而不发起请求。

### Note

- 本条依赖服务端 0.207.0-rc1 的 `POST /public/client-login/session/exchange`（仓库 `~/Sites/muchtoken`，分支 `feat/client-session-exchange`，**尚未合并与部署**）。服务端上线前，客户端此路径会走到「换取失败 → 保留既有资料」的兜底分支，行为与 rc4 一致。

## 1.230.0-rc4 - 2026-08-06

### Fixed

- 修复登录后头像与昵称被清空的问题。服务端的登录响应只带 email 与余额，昵称/头像仅由 `/customer/me` 返回，而两条登录路径（邮箱验证码、浏览器登录）都把登录结果**原样覆盖**本地账户，于是已获取到的资料被空值抹掉——表现为「点数还在，头像和昵称没了」。现在登录结果会保留本地已有的昵称、头像、邮箱与租户；服务端确实返回了新值时以新值为准。
- 切换账号（邮箱不同）时不再继承上一位用户的昵称与头像。

### Known issue

- 资料消失后无法自愈的根因仍在服务端：`/customer/me` 只接受 7 天有效期的 session token，且服务端没有任何续期端点，api_key 无法用于该接口。token 过期后昵称/头像将不再刷新（余额走 api_key，不受影响）。修复方案待定，见 `docs/SOMEIM_SESSION_REFRESH.md`。

### Tests

- 新增 8 条单测：登录响应无资料时保留本地资料、浏览器登录空账户块保留资料、换账号不继承、邮箱大小写不敏感、服务端返回新资料时覆盖、空白字符串视为缺失、首次登录无可保留项、displayName 回退链。

## 1.230.0-rc3 - 2026-08-06

### Fixed

- 修复切换到「目标」模式后会话从侧栏消失、所属工作区分组一并不见的问题。此前工作区侧栏按 `interactionMode != .goal` 排除会话，而目标看板只收「已定义实质目标」的会话——于是「已切目标模式但还没定目标」这段中间态两边都不显示，若该会话是这个工作区唯一的一条，整个工作区分组也跟着消失（客户反馈的「选目标模式后工作区不显示」）。现在两侧改用同一条判定（目标非空即归看板），严格互补，不再有真空。

### Tests

- 新增 8 条单测：切目标模式未定目标仍留在侧栏、空目标对象同样保留、工作区分组不因唯一会话切模式而消失、定义目标后移交看板、仅有验收清单也算实质目标、调度子会话与圆桌会话不回流侧栏，以及「任一工作区会话在侧栏与看板中恰好出现一次」的分区不变量。

## 1.230.0-rc2 - 2026-08-06

### Fixed

- 修复思考内容流式输出时 CPU 持续攀升：composer 上方的实时状态行原先每次流刷新（约 10 次/秒）都对**整段** reasoning 做全量 split 取最后一行，而 reasoning 在整个思考阶段单调增长，累计代价是 O(n²)——想得越久越卡。改为只扫末尾 2000 字符窗口。基准（模拟 6KB→240KB 的思考过程按 10Hz 采样）：3.084s → 0.121s，约 25 倍。
- 实时状态行结果按（消息, reasoning 长度）记忆化：同一帧内多个视图（面板活动行、任务监督栏 composer 条）读取时只计算一次，不再各算一遍。
- 修复状态行"闪动"：同一行 reasoning 每增长几个字符就重排文本并重启扫光动画，扫光永远播不完一个周期。现在仅在**换行**（真正的新状态）时立即更新并重启动画；同一行的持续增长按 450ms 节流显示，既保证状态不滞后，也让扫光能完整播放。

### Tests

- 新增 12 条单测：记忆化只算一次、增长触发重算、同一行节流保持稳定、超时后更新、换行与新消息立即生效、reset 清状态、末尾窗口取行正确性、超长行截断、大缓冲区扫描耗时上界（O(n²) 回归护栏）。

## 1.230.0-rc1 - 2026-08-06

### Added

- 子代理引入「工种」（profile）：`spawn_agent` 新增 `profile` 参数，四个内置工种各自绑定模型、工具白名单、职能提示、轮数与截断预算。`scout`（定位，4 个工具）与 `reader`（阅读总结）默认跑 some.im GLM-5；`deep` 保持继承父会话模型与全部只读工具，行为与旧版逐字节一致；`editor` 见下。
- 新增 `editor` 工种：可编辑**单个**已审批文件。spawn 调用本身升为 write-tier 走审批卡（用户批的是「允许子代理编辑该文件」，而非每条补丁）；运行时逐条解析 diff，越界路径、多文件补丁、新建/删除文件一律 Denied；同一会话同一文件同时只允许一个 editor，取消/失败即放锁；补丁走既有 patch 管线，worktree 变更卡与产物账本照常记账。
- 新增升级兜底：便宜工种打满轮数或产出过短时，自动用父会话模型 + `deep` 工具集**整体重跑一次**（不续跑）。升级只升不降、且必须可见——工具卡与检视器都会显示「从 glm-5 升级到 …」。
- 设置 → Agent 新增「子代理工种」区，可为每个工种改模型绑定；工具清单只读展示。
- 子代理检视器新增工种与升级两行信息。

### Changed

- `spawn_agent` 的 `model` 参数废弃：schema 中移除，运行时忽略并在结果里附一句提示（旧提示词平滑过渡，不报错）。成本策略改由用户配置决定，不再依赖模型每次自觉选便宜模型。
- 工种只能**收窄**全局只读白名单（取交集），永远无法放宽；`editor` 的写工具是唯一例外，且仅在持有审批与文件锁时开放。系统提示拆为「不变量段 + 职能段」，只读边界、「最终消息即交付物」、「不能问用户」三条任何工种不可覆盖。
- 子代理工具结果按工种预算截断（窄上下文工种 8K 字符），截断提示对子模型可读，便于其改用更窄的检索方式。
- 未知工种名回退 `deep` 并在结果里提示有效工种；`editor` 不允许后台运行（锁与审批都是回合内语义）。

### Tests

- 新增 35 条单测：工种解析与大小写、`deep` 等价旧行为、工具集交集不可放宽、工具表随工种收缩、editor 写权限门禁与 spawn 风险分级、按工种截断、提示拼装（含 editor 不再声称只读）、设置覆盖只改绑定、diff 路径规范化与越界/多文件/新建拒绝、文件锁互斥与放锁、升级触发条件与重跑参数、transcript 新字段编解码与旧记录兼容。
- 更新 `spawn_agent` schema 注册断言与 Goal Teams 的 `runOperation` 桩签名以匹配新契约。

## 1.229.0-rc1 - 2026-08-06

### Added

- 新增 `/subagent` 与 `/no-subagent` 两条内置斜杠命令，逐回合指定是否委派子代理。正文照常作为普通用户消息发送，用户气泡上方显示「强制子代理 / 禁止子代理」标记，会话重开后仍可审计。
- 新增子代理执行明细检视器：`spawn_agent` 卡片上出现「子代理运行」入口，按轮次展示 prompt、模型、输出、可见 reasoning、每次工具调用的名称/参数/结果/耗时与 token。取消或失败的子代理同样留有记录。
- 子代理逐轮记录以 sidecar 文件（`subagent-transcripts/<runID>.json`）独立落盘，会话 JSON 只保存 `subagentRunID`，避免十几轮的大体积工具输出挤占会话串行写盘管线。

### Changed

- `/no-subagent` 为硬保证：本回合工具表中直接移除 `spawn_agent`，模型无从调用。`/subagent` 为强指令 + 事后审计——供应商不支持跨多轮强制指定某个工具调用，因此该回合若最终未委派，标记会如实显示「强制子代理 · 未派生」，而不是假装指令已生效。
- 上下文压缩与 token 窗口预估改为使用同一份带委派策略的工具表，与真实请求保持一致。

### Tests

- 新增 23 条单测：工具表过滤、honor 判定、提示注入、标记文案、斜杠命令注册与参数解析、队列消息携带策略、`AgentMessage` / `AgentMessageToolCall` 新字段的编解码与旧会话向后兼容、transcript 截断上限与 sidecar 存取往返。

## 1.228.0-rc10 - 2026-08-06

### Fixed

- `willdeep <file>` 改走 macOS 原生文档打开事件，URL-backed Editor Scene 显式声明负责外部事件，并由 AppKit 应用入口提供排队兜底；SwiftUI 不再按默认回退规则把事件交给排在首位的 Agent Scene，可用 Editor 出现后会加载目标文件。既有 `willdeep://open` 继续兼容，但不再是 CLI 文件启动的单点依赖。
- 已安装的用户级 `willdeep` 脚本在 App 升级后自动刷新到当前模板；从未安装过 CLI 的用户仍需主动安装，不会被静默新增命令。
- AppKit 与 SwiftUI 可能重复投递同一 URL 时按短时间窗口去重，避免一次命令打开两个 Editor；已有 Editor 独占事件时也能直接认领队列，不留下稍后误开的陈旧请求。

### Tests

- 新增冷启动 URL 排队、原生文档 URL 解析与 AppKit/SwiftUI 双回调去重测试；完整单元测试共 272 项，仅保留既有工具 Schema Token 上限断言（37106 > 37000）失败，与本次路由变更无关。

### Meta

- Bugfix 预发布版本从 **1.228.0-rc9** 递增为 **1.228.0-rc10**，内部构建号从 **293** 递增为 **294**，Help 与 Computer Use Helper 构建号从 **210** 递增为 **211**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.228.0-rc9 - 2026-08-06

### Fixed

- Editor 输入完成后立即刷新 AppKit 原生插入点，字符与光标竖线在同一轮更新；语法分析、高亮、折叠等高成本工作继续延迟合并，不重新引入整编辑器同步重绘。
- “保存”和“另存为”直接并入 Editor 已拥有的文件命令组，不再依赖普通 `WindowGroup` 中可能不存在的 `.saveItem` 放置锚点，文件菜单与快捷键稳定显示。

### Tests

- 复跑 Editor 输入、IME、异步 gutter、外部文件打开与完整应用构建回归，并通过安装包版本及 Debug 登录配置注入核验。

### Meta

- Bugfix 预发布版本从 **1.228.0-rc8** 递增为 **1.228.0-rc9**，内部构建号从 **292** 递增为 **293**，Help 与 Computer Use Helper 构建号从 **209** 递增为 **210**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.228.0-rc8 - 2026-08-06

### Fixed

- 冷启动时通过 `willdeep somefile.txt` 或 `willdeep://open` 传入的文件 URL 会由默认 Agent 场景转交 Editor 窗口，不再只打开 Agent 首页并丢失文件；普通 Editor 窗口同时挂载完整文件命令，文件菜单恢复“保存”和“另存为”。
- 已结束或历史调度项目恢复时只重新附着观察，不再把排队节点自动启动；用户明确停止调度子任务会同步暂停项目并把节点转入待检查，避免稍后静默续跑。
- 调度节点后台启动不再强制改写当前导航目的地；旧聊天会话首次加载时会保护刚物化的 runtime，避免缓存淘汰造成正文退回调度台或新建页。
- 编辑器输入热路径只同步更新文本和脏状态；折叠缓存、CJK 字体修复、LSP、语法高亮、光标状态及 gutter 刷新按 50ms 合并，整文件变更行比较转到后台，长文件连续输入不再被每个按键后的全量工作拖住。

### Security

- 调度恢复改为观察性重连，不放宽工具授权或沙箱边界；只有用户新建计划、显式恢复或接管时才允许启动节点，停止状态会持久化以阻止隐藏恢复。

### Tests

- 新增冷启动外部 URL 路由、IME 提交后的编辑工作延迟、调度 checkpoint 丢弃、停止后项目暂停、历史会话 runtime 防淘汰与缺失 runtime 自愈回归测试。

### Meta

- Bugfix 预发布版本从 **1.228.0-rc7** 递增为 **1.228.0-rc8**，内部构建号从 **291** 递增为 **292**，Help 与 Computer Use Helper 构建号从 **208** 递增为 **209**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.228.0-rc7 - 2026-08-05

### Fixed

- Composer 发送/停止按钮直接观察当前会话 runtime；聊天仍在流式输出或等待 Provider 槽位时稳定显示停止图标，不再因 AppState 的转发合并而滞留为发送图标。停止等待 Provider 的任务会同步移除其队列项，避免稍后意外启动。
- 同一模型回合中的多个人工审批改为严格串行：后续调用只显示“排队等待确认”，上一条完成后才激活下一张确认卡；界面不再接受没有对应 continuation 的提前决定，也不再出现“已提交决定，等待执行循环接收”的悬空卡死状态。
- 工具活动成功后仅保留“修改了 1 个文件”“已运行 1 条命令”等具体动作摘要，移除依赖 receipt 是否存在而忽隐忽现的“完成”后缀；失败与拒绝提示继续保留。

### Security

- 串行审批只改变人机交互时序，不放宽审核边界；危险操作、提权重试与问答仍逐项门禁。“始终允许同类操作”和会话级授权会把匹配的后续调用转为带来源的真正自动批准，而非伪造提前点击。

### Tests

- 新增 Composer 实时停止状态、Provider 排队取消、审批乱序点击拒绝、逐条推进、Always-Allow 排队重评，以及成功摘要不追加“完成”的回归测试。

### Meta

- Bugfix 预发布版本从 **1.228.0-rc6** 递增为 **1.228.0-rc7**，内部构建号从 **290** 递增为 **291**，Help 与 Computer Use Helper 构建号从 **207** 递增为 **208**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.228.0-rc6 - 2026-08-05

### Fixed

- 本地终端不再把“根 Shell 进程还活着”笼统显示为“运行中”；现按 PTY 前台进程组与 `termios` 模式区分启动中、Shell 就绪、前台任务、交互程序和已退出，长时间静默压测仍占用终端时会明确显示“前台任务运行中”。
- 非交互前台任务占用终端时，方向键导航序列会被窄范围拦截并提示，不再把 `^[[A` / `^[[B` 画到屏幕或排入后续 Shell 输入；SSH、vim、tmux 和 REPL 等 raw/no-echo 交互程序不受影响。
- `terminal_send_command`、终端快捷回放与委托 Shell 复用在 canonical + echo 的前台任务仍拥有 PTY 时拒绝投递新命令，并明确建议等待、Ctrl-C、新开标签页或改用后台命令；终端快照与标签列表同步暴露 `input_state`，避免 Agent 把命令塞进正在运行的负载测试。

### Security

- 前台任务保护采用“Shell 进程组不同 + canonical + echo”联合判据，不根据输出静默时长猜测状态，也不自动改写 PTY 模式；控制键仍走既有白名单和审批链路，避免为修复乱码破坏合法交互会话。

### Tests

- 新增 PTY 输入归属分类、方向键序列窄匹配、命令门禁，以及真实 `/bin/sh` 前台 `sleep` 占用与 Ctrl-C 恢复的回归测试。

### Meta

- Bugfix 预发布版本从 **1.228.0-rc5** 递增为 **1.228.0-rc6**，内部构建号从 **289** 递增为 **290**，Help 与 Computer Use Helper 构建号从 **206** 递增为 **207**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.228.0-rc5 - 2026-08-05

### Fixed

- `rename_session` 更新当前会话标题时不再弹出人工审批卡；普通、Goal 与“每次询问”模式均由宿主的窄范围确定性规则直接放行，避免低风险本地元数据变更打断任务。
- 工具说明、系统上下文与内部命名移除“普通会话需要批准”的旧约定，模型会直接执行有必要的标题更新，不再先向用户口头确认。

### Security

- 会话改名仍保留 write-tier 顺序、工具调用记录和 sandbox 审计；只允许修改发起工具调用的当前会话，继续校验非空单行标题及 120 字符上限。可改变后续工具边界的 `change_workspace` 仍必须人工确认。

### Tests

- 新增普通、Goal、严格审批模式自动改名、sandbox 免审决策、空标题/超长标题拒绝以及 workspace 变更继续闸住的回归覆盖。

### Meta

- Bugfix 预发布版本从 **1.228.0-rc4** 递增为 **1.228.0-rc5**，内部构建号从 **288** 递增为 **289**，Help 与 Computer Use Helper 构建号从 **205** 递增为 **206**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.228.0-rc4 - 2026-08-05

### Fixed

- “智能审核”将 `kubectl get/describe/logs/top`、只读 `config/auth/rollout` 子命令及终端 `clear` 纳入本地确定性白名单，高频集群检查不再依赖联网裁判，也不会因裁判临时不可用退回人工确认；`apply/delete/exec`、上下文切换、凭据参数和 rollout 变更仍继续审核。
- 当前 Provider 的安全裁判不可用时，已登录 some.im 的用户会自动改用托管 Flash 裁判兜底一次；AI 明确拒绝、两路裁判均不可用或命令属于强制确认边界时仍交给用户。
- 人工允许或拒绝命令后立即失效裁判历史缓存，让下一次审核及时读取最新操作偏好，不再最多滞后 30 分钟。
- 普通 `curl`/`wget` 网络读取从终端“静态必问”改为一次性 AI 复核；请求体、上传、凭据、显式落盘、私有协议和传输重定向等高风险形状仍保留人工确认。内部 `run_command` 的网络 GET 也不再假装成纯本地只读，而是统一经过同一复核链路。
- 人工批准的外部/无沙箱命令现在也会作为已批准样本进入裁判历史；审计写入后再次失效缓存，避免并发裁判在点击与落盘之间保留旧快照。
- 终端命令审计记录现在保存经过现有脱敏器处理的命令摘要，不再只写 `terminal_send_command` 工具名，后续可准确定位人工确认来源。

### Security

- 安全裁判的 30 分钟允许缓存改为“工具 + 精确命令”，参数变化会重新机器审核；不再把一次 `git push origin feature` 的隐藏机器许可扩成 `git push origin main`。
- 可见终端命令复用完整路径/凭据预检，`cat ~/.ssh/id_rsa`、Kubernetes Secret 读取和 `kubectl config view --raw` 等敏感读取继续强制人工；只有上下文无关的只读命令静态放行，终端内构建/创建类命令改由机器复核。
- “始终允许 Kubernetes”收窄为仅匹配静态确认过的 `kubectl` 只读命令，旧的宽泛类别不再生效；HTTP GET 的持久规则按公共 Host 限定，并拒绝重定向、认证头、Cookie、代理和路由覆盖参数。

### Tests

- 新增 Kubernetes 只读检查静态放行、写操作/Secret/原始凭据继续审核，网络读取分层、终端敏感路径预检、精确裁判缓存和持久授权边界的回归测试。

### Meta

- Bugfix 预发布版本从 **1.228.0-rc3** 递增为 **1.228.0-rc4**，内部构建号从 **287** 递增为 **288**，Help 与 Computer Use Helper 构建号从 **204** 递增为 **205**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.228.0-rc3 - 2026-08-05

### Fixed

- OpenAI 兼容网关返回“纯空白文本 + 工具调用”时，不再把该中间消息渲染成只有“已处理”和 Token 页脚的空白助手轮次；流结束后会规范化纯空白内容，历史会话也按非空白字符重新识别工具专用轮次。
- 主聊天、紧凑 Agent 面板、流式 SwiftUI 气泡和 TextKit 历史统一使用同一套可渲染文本判定，避免同一消息在不同入口显示不一致。

### Tests

- 新增纯换行 assistant 工具消息回归测试，验证其只显示工具活动摘要，不显示助手状态栏或 Token 页脚空壳。

### Meta

- Bugfix 预发布版本从 **1.228.0-rc2** 递增为 **1.228.0-rc3**，内部构建号从 **286** 递增为 **287**，Help 与 Computer Use Helper 构建号从 **203** 递增为 **204**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.228.0-rc2 - 2026-08-05

### Fixed

- 会话列表不再为普通会话残留的 `currentPlan` 渲染计划模式 `checklist` 图标；目标模式仍保留独立的靶心状态提示。

### Tests

- 新增旧计划进度不占用会话行宽度的 SwiftUI 回归覆盖，并保留 Goal 模式单一徽标验证。

### Meta

- Bugfix 预发布版本从 **1.228.0-rc1** 递增为 **1.228.0-rc2**，内部构建号从 **285** 递增为 **286**，Help 与 Computer Use Helper 构建号从 **202** 递增为 **203**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.228.0-rc1 - 2026-08-05

### Added

- “智能审核”现在是完整、单一的会话授权策略：`run_command`、`terminal_send_command`、终端控制和标准可信 MCP 写操作会自动经过静态分类与一次性 Flash AI 安全裁判，不再要求用户另外开启全局“AI 批准正常命令”开关。

### Changed

- 移除设置页中与会话授权模式重复的 AI 自动批准总开关；需要逐次人工确认时，直接选择“每次询问”，Workspace Access 继续只授权工作区边界内操作。

### Fixed

- Agent 状态栏不再于 SwiftUI 热路径同步重建并扫描完整请求；Token 估算改为尾随防抖、可取消的 utility 后台任务，并降低 Unicode 空白判断分配，减少流式回复期间的 CPU 占用。

### Security

- 破坏性命令、需要输入式确认的操作、ZMODEM 本地路径选择、不受信 MCP、AI 明确拒绝或裁判不可用仍回退人工审批；严格模式不会调用自动批准链路。

### Tests

- 新增智能模式终端检查命令自动批准与严格模式保持人工确认的回归覆盖，并保留 Token Unicode 空白估算测试；完成版本一致性、构建及发布前测试验证。

### Meta

- 功能预发布版本从 **1.227.0-rc5** 提升为 **1.228.0-rc1**，内部构建号从 **284** 递增为 **285**，Help 与 Computer Use Helper 构建号从 **201** 递增为 **202**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.227.0-rc5 - 2026-08-05

### Fixed

- Agent 状态栏不再于每次 SwiftUI `body` 求值时同步重建请求并扫描完整消息与工具 schema；上下文 Token 使用量改为读取稳定快照，相关状态变化后以 750ms 尾随防抖触发可取消的 utility 后台重算，降低流式回复期间的主线程 CPU 占用。
- Token 估算器改用 Unicode scalar 自带的空白属性判断，避免逐字符查询 `CharacterSet` 产生额外分配，同时保持 ASCII、CJK 与其他字符的既有估算口径。

### Tests

- 新增 Unicode 普通空格、换行、制表符与全角空格的 Token 估算回归测试，并完成 WillDeep Debug 全量构建验证。

### Meta

- Bugfix 预发布版本从 **1.227.0-rc4** 递增为 **1.227.0-rc5**，内部构建号从 **283** 递增为 **284**，Help 与 Computer Use Helper 构建号从 **200** 递增为 **201**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.227.0-rc4 - 2026-08-05

### Fixed

- DeepSeek V4 Flash 的 Responses 请求优先把 `web_search` 编码为服务端 hosted tool；网关以 400/422 明确拒绝或不识别该工具时，当前请求自动失效续接游标并回退到原有本地函数工具，其他模型的搜索策略保持不变。
- 解析并持久化服务端流式及完成事件中的 `url_citation`，统一并入现有来源胶囊与回合报告，避免服务端搜索完成后丢失引用。

### Tests

- 新增 DeepSeek V4 Flash hosted `web_search` 编码、服务端拒绝后的本地回退，以及引用保留回归测试；相关 18 个模型适配器测试全部通过。

### Meta

- Bugfix 预发布版本从 **1.227.0-rc3** 递增为 **1.227.0-rc4**，内部构建号从 **282** 递增为 **283**，Help 与 Computer Use Helper 构建号从 **199** 递增为 **200**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.227.0-rc3 - 2026-08-05

### Fixed

- 将所有模型适配器的连续无响应字节等待上限从 120 秒放宽到 180 秒，降低长思考模型在首个 SSE 增量前被 WillDeep 客户端提前取消的概率；请求资源总时限仍保持 600 秒。
- 模型超时提示改为读取统一网络超时常量，避免实际等待时长与用户提示不一致；muchtoken 网关默认 600 秒上游总时限保持不变。
- 终端快捷记录区不再由外层 `TimelineView` 每秒重建整棵列表；只有正在录制或播放的状态文本按秒刷新，快捷项直接使用稳定 ID 集合，避免 `LazyVStack`、`ViewThatFits` 与枚举数组持续触发布局测量。
- Git 变更保护在获取 pre-lease 仓库身份时不再执行完整工作区 revision capture；未跟踪目录优先交给 Git 原生枚举并批量哈希，忽略规则内文件不再进入摘要，异常输出仍回退原遍历实现且正式 CAS 校验保持不变。

### Tests

- 新增统一模型请求与资源超时配置，以及轻量仓库身份、嵌套未跟踪目录内容变化与 ignored 文件隔离回归测试。

### Meta

- Bugfix 预发布版本从 **1.227.0-rc2** 递增为 **1.227.0-rc3**，内部构建号从 **281** 递增为 **282**，Help 与 Computer Use Helper 构建号从 **198** 递增为 **199**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.227.0-rc2 - 2026-08-05

### Fixed

- 重做 WillDeep Agent 的工作区外文件授权：新增面向精确绝对路径的 `write_file` 工具，授权依据改为目标风险、文件状态、内容边界和当前用户消息中的明确写入意图，不再把“位于工作区外”本身当作必须阻断的危险信号。
- Smart 模式可直接批准父目录已存在、目标尚不存在且不敏感的低风险文本文件；覆盖已有文件必须显式传入 `overwrite=true`，并由当前用户消息精确点名路径和覆盖意图，否则仍展示审批。
- 系统目录、凭据目录、Shell 配置、Git hooks 与启动持久化路径保持高风险输入式确认；外部写入采用原子替换、同路径回读校验和符号链接拒绝，避免“工具报告成功、真实文件却不存在”。
- Shell 命令引用工作区外路径时改为启动前直接进入风险审核，不再先用工作区沙箱运行、失败后才补救性提权。

### Tests

- 新增外部路径预检、精确用户意图、已有文件覆盖、敏感路径确认、原子写入与回读校验，以及 Strict/Smart/Workspace Access 模式差异的回归测试。

### Meta

- Bugfix 预发布版本从 **1.227.0-rc1** 递增为 **1.227.0-rc2**，内部构建号从 **280** 递增为 **281**，Help 与 Computer Use Helper 构建号从 **197** 递增为 **198**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.227.0-rc1 - 2026-08-05

### Added

- Composer 上方的后台任务状态卡现在可直接打开右侧“后台任务”管理器；入口只在当前会话存在运行中进程时出现，并同时展示任务总数、运行数与代表性进程名。
- 后台任务管理器默认仅看当前会话，也可切换全部会话；支持按进程名、命令、工作目录或任务句柄搜索，并按运行中/已结束筛选、分组浏览。
- 选中任务后渐进展开进程名、工作目录、完整命令、PID、开始时间和运行时长；日志支持合并流、stdout、stderr 标签页以及宽面板双栏模式，提供自动跟随、复制命令、复制输出和停止任务操作。

### Changed

- 本机后台进程的输出采集从单一混合缓冲扩展为 combined/stdout/stderr 三份有界缓冲；原有 combined 与尾部读取契约保持兼容，结构化托管执行器在没有独立 stderr 时明确返回空流。

### Tests

- 新增 stdout/stderr 隔离采集、进程名提取、会话/状态/关键词筛选与真实 SwiftUI 截图回归测试；后台任务定向 38 项测试全部通过。

### Meta

- 新功能预发布版本从 **1.226.0-rc10** 提升为 **1.227.0-rc1**，内部构建号从 **279** 递增为 **280**，Help 与 Computer Use Helper 构建号从 **196** 递增为 **197**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.226.0-rc10 - 2026-08-05

### Fixed

- 修复从聊天产物卡片打开右侧产物侧栏后，再关闭侧栏会让聊天记录跳到顶部的问题；聊天列因侧栏开合发生横向重排时，现在会按原相对阅读位置恢复视口，停留在底部的会话仍继续稳定跟随最新消息。

### Tests

- 新增聊天记录横向重排位置换算与边界钳制回归测试，覆盖侧栏开合导致文档高度变化时的视口恢复策略。

### Meta

- Bugfix 预发布版本从 **1.226.0-rc9** 递增为 **1.226.0-rc10**，内部构建号从 **278** 递增为 **279**，Help 与 Computer Use Helper 构建号从 **195** 递增为 **196**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.226.0-rc9 - 2026-08-05

### Fixed

- Composer 的 Provider 与模型改为会话级快照：在 A 会话手动切换 Provider/模型只更新 A，切到 B 时恢复 B 自己实际使用的配置，不再被全局活动 Provider 或其他会话的选择覆盖。
- 会话持久化记录精确的 Provider 条目 UUID、Provider 标识、显示名与模型；请求发送、Composer 标签、新会话默认值和 some.im 托管统一从当前会话解析，多个同为 `custom` 的 Provider 也不会串台。
- OpenAI Chat / Responses 获取模型列表遇到 HTTP 404 时按当前地址双向探测 `/v1`：缺少时尝试补上，已有时尝试移除；探测成功后显示对应确认操作，只有用户点击才写回基础地址。

### Tests

- 新增 A/B 会话 Provider 与模型隔离、设置默认值不改写既有会话、some.im 会话级托管及 `/v1` 双向候选回归；Provider 与模型选择相关 61 项定向测试全部通过。

### Meta

- Bugfix 预发布版本从 **1.226.0-rc8** 递增为 **1.226.0-rc9**，内部构建号从 **277** 递增为 **278**，Help 与 Computer Use Helper 构建号从 **194** 递增为 **195**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.226.0-rc8 - 2026-08-05

### Fixed

- 旧会话缺少 Provider 条目 UUID 时，仅在 Provider ID 唯一匹配时回退到该配置，避免依赖不存在的集合扩展并保持多自定义 Provider 的选择确定性。
- OpenAI 兼容地址探测统一返回可直接使用的字符串地址；已有 `/v1` 的地址不再生成反向候选，保持“仅在 404 后追加 `/v1`”的既定行为与设置页提示一致。

### Tests

- Provider 配置、`/v1` 探测与桌面宠物动画共 65 个定向测试通过。

### Meta

- Bugfix 预发布版本从 **1.226.0-rc7** 递增为 **1.226.0-rc8**，内部构建号从 **276** 递增为 **277**，Help 与 Computer Use Helper 构建号从 **193** 递增为 **194**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.226.0-rc7 - 2026-08-05

### Fixed

- 桌面宠物的高频 `TimelineView` 只刷新固定尺寸的宠物动画子树，消息气泡、右键菜单、拖动手势和外层窗口布局不再随每一帧重建。
- 桌面宠物前台与后台动画上限从 15/24 FPS 调整为 8/12 FPS，保留后台稍顺滑的像素动画，同时减少 SwiftUI、AttributeGraph 与 AppKit 布局占用。

### Tests

- 更新桌面宠物动画节奏回归测试，锁定前后台刷新上限及最小帧间隔。

### Meta

- Bugfix 预发布版本从 **1.226.0-rc6** 递增为 **1.226.0-rc7**，内部构建号从 **275** 递增为 **276**，Help 与 Computer Use Helper 构建号从 **192** 递增为 **193**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.226.0-rc6 - 2026-08-05

### Fixed

- OpenAI Chat / Responses 服务商获取模型列表返回 HTTP 404 且基础地址末尾没有 `/v1` 时，会临时追加 `/v1` 再探测一次；其他协议、其他状态码与已有 `/v1` 地址不会产生额外请求。
- `/v1` 探测成功后展示已验证地址和“补全 /v1”操作，只有用户点击确认才更新基础地址；探测过程不会静默修改聊天运行配置。

### Tests

- 新增根地址、带路径地址、已有 `/v1`、非 OpenAI 协议及非 404 错误的探测边界测试。

### Meta

- Bugfix 预发布版本从 **1.226.0-rc5** 递增为 **1.226.0-rc6**，内部构建号从 **274** 递增为 **275**，Help 与 Computer Use Helper 构建号从 **191** 递增为 **192**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.226.0-rc5 - 2026-08-05

### Fixed

- AI Provider 连接表单先显示 Provider 选择，再根据新选择自动生成可继续编辑的显示名称；加载已有配置时保留用户自定义名称。
- 基础地址输入框不再把预设 URL 作为额外标题重复显示，只在输入为空时作为框内提示。
- 模型列表响应解码失败时，错误信息会指出缺失字段或类型不匹配、实际 JSON 顶层结构以及各协议预期格式；诊断仅描述结构，不回显响应正文。

### Tests

- 新增 Provider 显示名称建议、模型列表缺失字段、实际结构识别及非 JSON 响应脱敏回归测试；Debug 构建通过。

### Meta

- Bugfix 预发布版本从 **1.226.0-rc4** 递增为 **1.226.0-rc5**，内部构建号从 **273** 递增为 **274**，Help 与 Computer Use Helper 构建号从 **190** 递增为 **191**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.226.0-rc4 - 2026-08-04

### Fixed

- ZMODEM 上传不再通过 SwiftTerm 的多路异步 `DispatchIO.write` 投递协议块；新增专用有序 PTY 写入器，逐块等待完整写入并正确处理短写、`EINTR`、`EAGAIN` 和写入超时，避免大文件传输中协议字节乱序导致远端 `rz` 中断。
- ZMODEM 本地进程异常退出后，终端会继续隔离协议收尾字节，并在最多 5 秒内等待 0.5 秒静默窗口再恢复文本渲染，避免远端 Shell 把仍在排空的二进制数据回显成满屏 `^@` 乱码。
- 本地 `sz` / `rz` 默认启用控制字符转义，降低 XON/XOFF 和中间 SSH/PTY 驱动转换破坏二进制帧的风险。

### Tests

- 新增 ZMODEM PTY 短写、重试、跨数据块顺序保持、远端写入失败及 2 MB 真实管道背压回归；`AgentGlobalRulesTests` 28 项全部通过。

### Meta

- Bugfix 预发布版本从 **1.226.0-rc3** 递增为 **1.226.0-rc4**，内部构建号从 **272** 递增为 **273**，Help 与 Computer Use Helper 构建号从 **189** 递增为 **190**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.226.0-rc3 - 2026-08-04

### Fixed

- 新会话首页的 Token 活动热力格按本地自然日聚合请求次数与 Token 用量，悬停和辅助功能标签均展示完整的日期、请求数与 Token 数。
- Agent 历史消息中的 Unicode 文件路径会保留完整 basename；`docs/中文文件名.md` 不再因等宽字体缺少 CJK 字形而显示成 `docs/.md`。
- 终端凭据脱敏仅把独立的 snake_case / kebab-case 凭据字段视为敏感键；`tokenhub:0.196.0-rc2` 等镜像仓库与版本号不再被误替换，真实 Token、密码和 Bearer 凭据仍会脱敏。

### Tests

- 新增首页按日 Token 聚合、Unicode 文件路径渲染、镜像标签与语义化版本号脱敏边界回归测试。

### Meta

- Bugfix 预发布版本从 **1.226.0-rc2** 递增为 **1.226.0-rc3**，内部构建号从 **271** 递增为 **272**，Help 与 Computer Use Helper 构建号从 **188** 递增为 **189**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.226.0-rc2 - 2026-08-04

### Changed

- Plan 执行提示明确区分“工作完成证据”与机器可读的 `progress` 状态，普通完成说明、成功工具输出或重复的 `plan` 块不再被误认为已经同步清单。

### Fixed

- 连续回复已报告任务完成却遗漏 `progress` 状态时，宿主会在原本准备显示暂停红字的边界主动追加一次状态核验回合：优先核对既有证据，必要时仅允许只读状态检查，并阻止重新部署、写入或其他副作用操作。
- 状态核验仍失败时，错误提示明确说明“计划状态未同步”不代表任务执行失败；人工标记完成仅保留为最终兜底，不再要求用户先发送“完成”才能推进状态。

### Tests

- 新增 Plan 状态核验决策、只读检查权限边界、禁止重复执行提示与活动计划机器可读状态契约回归测试。

### Meta

- Bugfix 预发布版本从 **1.226.0-rc1** 递增为 **1.226.0-rc2**，内部构建号从 **270** 递增为 **271**，Help 与 Computer Use Helper 构建号从 **187** 递增为 **188**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.226.0-rc1 - 2026-08-04

### Added

- 调度节点默认启用浏览器专家，并在任务工具菜单中开放内置浏览器；普通网页验收优先使用 `embedded_browser_*`，只有明确要求 Playwright/Chromium 引擎或内置浏览器无法表达交互时才回退外部浏览器进程。
- 每个调度 runtime 拥有独立的 WKWebView、页面状态和诊断事件缓存，并行节点不再争抢同一个全局浏览器页面。

### Changed

- 内置浏览器工具可在侧栏未打开时后台懒加载，用户之后打开节点浏览器会接回同一页面现场；Dev Server 预览也跟随当前 runtime。
- runtime 淘汰、侧栏资源回收与会话删除会释放对应浏览器实例，避免后台页面长期占用资源。

### Tests

- 新增调度浏览器专家默认启用、任务提示优先内置浏览器、侧栏入口可见、工具后台懒加载及两个并行 runtime 浏览器隔离回归；相关调度套件 13 项通过。

### Meta

- 新增调度节点内置浏览器能力，功能预发布版本从 **1.225.0-rc5** 提升为 **1.226.0-rc1**，内部构建号从 **269** 递增为 **270**，Help 与 Computer Use Helper 构建号从 **186** 递增为 **187**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.225.0-rc5 - 2026-08-04

### Fixed

- 已完成与已合并的调度节点改用最后一条消息的真实结束时间封口执行耗时，不再把应用重启、会话恢复、重命名或重新持久化造成的后续 `updatedAt` 变化计入执行时间，修复多个节点同时显示五小时以上虚假耗时的问题。
- 失败重试仍按每次运行会话分别累计真实执行区间；只有完全没有消息的旧会话才回退到会话更新时间。

### Tests

- 新增“任务一分钟完成、五小时后会话元数据再次更新”的回归场景，验证节点耗时仍为一分钟；`AgentDispatchTaskTakeoverTests` 共 11 项通过。

### Meta

- Bugfix 预发布版本从 **1.225.0-rc4** 递增为 **1.225.0-rc5**，内部构建号从 **268** 递增为 **269**，Help 与 Computer Use Helper 构建号从 **185** 递增为 **186**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.225.0-rc4 - 2026-08-03

### Fixed

- Mac 移动网关不再把尚未完成 HTTP Upgrade 的 WebSocket 当成已连接；连接先通过 ping 验证，再发布首个状态快照，握手失败或超时会进入受控重连。
- 修改公网中继地址或房间后自动重连桌面 Peer，保证当前二维码与 Mac 实际加入的房间一致，避免 Android 显示“服务器通道已建立”却永远收不到 Mac 响应。

### Meta

- Bugfix 预发布版本从 **1.225.0-rc3** 递增为 **1.225.0-rc4**，内部构建号从 **267** 递增为 **268**，Help 与 Computer Use Helper 构建号从 **184** 递增为 **185**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.225.0-rc3 - 2026-08-03

### Fixed

- 调度图任务卡片不再于 SwiftUI 渲染期间调用会物化会话、启动监听并淘汰空闲 runtime 的生命周期接口，修复任务数超过驻留上限时反复“创建、淘汰、持久化、重渲染”导致主线程占满和应用无响应的问题。
- 已淘汰 runtime 的节点指标改从持久化会话只读计算，避免修复卡死后把历史 Token、执行时长与费用降级为空值。

### Tests

- 新增调度图只读 runtime 查询回归测试，验证命中时返回同一实例，未命中时不会物化 runtime、改写会话或触发淘汰。

### Meta

- Bugfix 预发布版本从 **1.225.0-rc2** 递增为 **1.225.0-rc3**，内部构建号从 **266** 递增为 **267**，Help 与 Computer Use Helper 构建号从 **183** 递增为 **184**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.225.0-rc2 - 2026-08-03

### Fixed

- 调度节点在失败重试或执行器切换后继续累计所有运行尝试的 Token、执行时长与费用，不再因当前运行会话 ID 更新而把历史指标显示为零；执行时长按各次尝试分别累计，不包含尝试之间的空闲间隔。
- 无人值守调度节点统一使用允许网络访问的工作区沙箱，未被命令分类器识别为网络命令的 Playwright、本地测试服务器、端口绑定与依赖测试也不再被 seatbelt 误拦；普通会话仍保留原有最小权限策略。

### Tests

- 新增节点跨两次运行会话累计指标、调度节点只读/写入命令均保留网络能力，以及普通会话仍使用只读沙箱的回归测试；相关 2 个测试套件共 86 项通过。

### Meta

- Bugfix 预发布版本从 **1.225.0-rc1** 递增为 **1.225.0-rc2**，内部构建号从 **265** 递增为 **266**，Help 与 Computer Use Helper 构建号从 **182** 递增为 **183**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.225.0-rc1 - 2026-08-03

### Added

- 调度台任务接管抽屉新增当前执行模型展示，模型名称来自运行中请求的真实配置快照，不再只显示 WillDeep / 外部 CLI 执行器名称。
- WillDeep 节点可在接管抽屉中从项目已选 Worker Profile 切换模型；运行中切换不会打断当前请求，新模型从下一轮安全生效，并明确显示待生效提示。

### Changed

- 外部 CLI 节点继续由原生 Profile 管理模型，调度台不会伪装成可热切换；模型状态展示统一回退运行时覆盖、持久化会话模型，兼容旧任务记录。
- 调度模型展示与切换提示补齐英文和简体中文资源、VoiceOver 标签与当前模型值。

### Tests

- 新增当前轮与下一轮模型分离、空闲节点立即展示新模型、旧任务回退持久化模型的回归测试。

### Meta

- 功能预发布版本从 **1.224.0-rc8** 提升为 **1.225.0-rc1**，内部构建号从 **264** 递增为 **265**，Help 与 Computer Use Helper 构建号从 **181** 递增为 **182**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.224.0-rc8 - 2026-08-03

### Changed

- 调度台“人工干预”收窄为节点目标与验收标准编辑，不再展示或提交前置节点选择，避免人工调整执行中的任务拓扑。
- 人工干预改走不接收依赖 ID 的专用领域接口，从业务层保证原有依赖关系不变；新增节点仍可显式选择前置节点并接入任务图。
- 编辑弹窗标题、说明、字段与保存按钮改为人工干预语义，并缩短无依赖列表时的窗口高度。

### Tests

- 新增人工干预更新目标和验收标准、同时完整保留前置依赖的协调器回归测试。

### Meta

- Bugfix 预发布版本从 **1.224.0-rc7** 递增为 **1.224.0-rc8**，内部构建号从 **263** 递增为 **264**，Help 与 Computer Use Helper 构建号从 **180** 递增为 **181**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.224.0-rc7 - 2026-08-03

### Fixed

- 调度台项目会话、执行节点及仅恢复出任务 ID 的旧会话统一按无人值守运行；写入与高风险工具不再因会话身份差异退回人工审批。
- Agent 正文中的 fenced diff 在调度台内改走与 `create_file` / `edit_file` / `apply_patch` 相同的自动应用链路，不再绕过策略生成 Pending 的 “Agent Patch” 卡片。
- 打开或恢复调度会话时会自动应用历史遗留的待审补丁，避免节点在无人值守阶段永久等待“应用”；无法验证或应用的补丁进入失败状态并回报调度器，不伪装成功。

### Tests

- 新增调度台 fenced diff 静默落盘、历史 Pending 恢复自动应用、项目会话与旧任务身份无人值守判定回归。

### Meta

- Bugfix 预发布版本从 **1.224.0-rc6** 递增为 **1.224.0-rc7**，内部构建号从 **262** 递增为 **263**，Help 与 Computer Use Helper 构建号从 **179** 递增为 **180**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.224.0-rc6 - 2026-08-03

### Fixed

- 文件工具参数解析器会定向修复 Provider 偶发生成的非法 `\${{ ... }}` JSON 转义，并还原为 GitHub Actions 的字面量 `${{ ... }}`；workflow 中的 `secrets.NAME` 引用不再导致整次 `create_file` / `edit_file` / `apply_patch` 调用被判为无效 JSON。
- 文件工具描述与稳定提示契约明确 GitHub Actions 表达式按普通文本写入，Agent 不再把 secret 引用名误当成真实密钥，也不会仅因 `${{ ... }}` 语法降级为需要额外审批的 Python 或 Shell 写文件。

### Tests

- 新增合法与错误转义的 GitHub Actions 工具参数解析回归，以及 workflow 创建、精确编辑、补丁往返测试；覆盖 `${{ secrets.DEPLOY_TOKEN }}` 原样保留且不接触真实密钥值。

### Meta

- Bugfix 预发布版本从 **1.224.0-rc5** 递增为 **1.224.0-rc6**，内部构建号从 **261** 递增为 **262**，Help 与 Computer Use Helper 构建号从 **178** 递增为 **179**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.224.0-rc5 - 2026-08-03

### Fixed

- 沙箱命令统一使用宿主预建、seatbelt 已放行的临时目录，并同步覆盖 `TMPDIR`、`TMP` 与 `TEMP`，避免 Playwright 转换缓存因系统临时目录不可写而报 `EPERM`。
- 无人值守调度节点的后台命令若明确命中沙箱拒绝，会自动在无沙箱模式下重放一次；中间 EPERM 不再先唤醒模型并把节点错误收束为 blocked。
- 调度节点在没有运行时错误但仍有未验收项时最多自动恢复两轮，恢复提示要求针对 Playwright 的临时目录、前台升权与本机端口逐项排障；耗尽预算后才进入人工 review。

### Tests

- 新增后台沙箱拒绝单次自动重放、临时目录环境一致性、无人值守恢复预算与 Playwright 恢复提示回归。

### Meta

- Bugfix 预发布版本从 **1.224.0-rc4** 递增为 **1.224.0-rc5**，内部构建号从 **260** 递增为 **261**，Help 与 Computer Use Helper 构建号从 **177** 递增为 **178**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.224.0-rc4 - 2026-08-03

### Fixed

- “最长任务时长”改用稳定的紧凑 `d`/`h`/`m` 格式；达到一天后自动折算天数，例如原来的“103小时27分钟”现在显示为 `4d7h27m`。

### Tests

- 新增分钟、小时、整天、跨天和 `9d10h3m` 格式回归；`AgentSidebarListVisualMetricsTests` 共 17 项通过。

### Meta

- Bugfix 预发布版本从 **1.224.0-rc3** 递增为 **1.224.0-rc4**，内部构建号从 **259** 递增为 **260**，Help 与 Computer Use Helper 构建号从 **176** 递增为 **177**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.224.0-rc3 - 2026-08-03

### Changed

- Shell 命令审批统一改用保留 `&&`、`||`、`;`、换行、管道、`|&` 与后台执行语义的引号感知解析器，不再由多套字符串切分逻辑各自猜测；工作区内 `cd`、`printf`、`git ls-files | head` 等纯只读组合会按逐段结论直接运行。
- 智能安全裁判提示词新增复合命令规则：条件分支逐段检查、管道逐个检查生产端/转换端/落地端、引号内操作符按数据处理，并随请求附带宿主生成的段数、连接符与后台状态骨架。

### Fixed

- 修复引号中的 `rm`、`>`、`|` 被误当成可执行操作而触发审批，以及管道内 `cd` 错误影响后续兄弟命令工作目录判断的问题。
- 收紧 `command`、`xargs`、`tee`、`sed`、`sort`、`awk`、`yq` 与可写 Git 检查子命令的参数级规则，避免 `command rm`、`xargs sh -c`、原地编辑、文件输出或分支/标签修改伪装成只读命令。

### Tests

- 新增复合连接符、引号与注释、后台执行、管道目录作用域、只读组合免审批及隐藏写操作回归；`WillDeepTests` 共 264 项通过。
### Meta

- Bugfix 预发布版本从 **1.224.0-rc2** 递增为 **1.224.0-rc3**，内部构建号从 **258** 递增为 **259**，Help 与 Computer Use Helper 构建号从 **175** 递增为 **176**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.224.0-rc2 - 2026-08-03

### Changed

- 调度图中仅因等待前置节点而尚未工作的节点改显示“待启动”，不再误写为“被阻塞”。
- 调度任务接管输入框上方新增吸附式活动状态条，实时展示思考、工具执行与 Provider 并发排队状态。

### Fixed

- 人工干预失败节点时会重新把节点置为执行中并挂载完成监听；干预轮成功后节点可正确标记完成、解锁依赖并自动继续启动后续节点。

### Tests

- 新增人工干预恢复节点、重新判定完成并解锁下游的回归测试，以及接管输入框活动/排队状态策略测试。

### Meta

- Bugfix 预发布版本从 **1.224.0-rc1** 递增为 **1.224.0-rc2**，内部构建号从 **257** 递增为 **258**，Help 与 Computer Use Helper 构建号从 **174** 递增为 **175**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.224.0-rc1 - 2026-08-02

### Added

- 调度任务图的每个节点新增 Token 用量、墙钟用时与预估费用；运行节点每秒刷新，用量为估算时明确显示近似标记，Claude Code 等外部 CLI 无可靠定价时显示不可用而不伪造金额。
- 选中已有运行会话的节点后可直接打开调度台内的任务接管抽屉，在不离开任务图的情况下查看完整消息、发送人工指令，并进入计划、文件、终端和 Diff 等干预工具。
- 调度子任务的完整对话标题左侧新增所属调度项目入口，点击即可返回原项目和节点。

### Changed

- 调度任务对话的常驻工具精简为计划、文件、终端和 Diff；预览、开发服务器与网页组件收纳到更多菜单，媒体、浏览器、图片编辑和桌面宠物不再占用任务干预界面。
- 节点 Token 统计按 assistant provider 回合聚合，避免将已包含 prompt 的真实用量与用户文本再次相加；外部执行器费用保持保守不可用状态。

### Fixed

- GPT 全系列模型（含 `gpt-5.5`、`gpt5.5` 与 `gpt-5.6-sol/luna/terra`）统一改走 `/v1/chat/completions`；即使 Provider 被配置为 Responses 也会覆盖为 Chat，避免不支持 Responses `store` 契约的中转服务在 `/v1/responses` 返回请求错误。DeepSeek V4 Flash 的既有 Responses 路由保持不变。

### Tests

- 新增 6 项调度任务接管回归，覆盖真实 Token 口径、外部 CLI 不定价、空节点指标、紧凑格式、工具精简策略和调度台内会话切换不跳页；同步扩展 GPT 传输协议回归，覆盖连字符、无连字符、`chatgpt-*`、命名空间和显式 Responses Provider 等型号写法，并锁定 Chat 请求不携带 `store`。

### Meta

- 功能预发布版本从 **1.223.0-rc2** 提升为 **1.224.0-rc1**，内部构建号从 **256** 递增为 **257**，Help 与 Computer Use Helper 构建号从 **173** 递增为 **174**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.223.0-rc2 - 2026-08-02

### Fixed

- 调度台创建的执行节点现在由宿主明确标记为无人值守任务，WillDeep 的写入及高风险工具不再生成需要人工点击的审批卡；`ask_user` 会收到不可交互结果，让节点自行绕行或向调度器报告具体阻塞原因。
- 调度节点使用 Claude Code 时不再接入宿主交互式 ACP 审批回调，统一改走非交互执行并传入 `--dangerously-skip-permissions`；该权限仅能由宿主的调度子任务归属启用，普通聊天、手动 Goal 和模型发起的 Claude 工具调用无法伪造。
- Claude Code 的内部权限确认被跳过时仍保留 WillDeep 外层 worktree 沙箱，避免无人值守执行扩大到当前调度工作区之外。

### Tests

- 新增调度子任务无人值守审批、普通会话隔离、Claude 非交互参数和 stdin 提示词回归；定向测试 3 个套件共 125 项通过。
- 结构化执行器进程测试增加全量套件高并发下的轮询余量，避免测试主线程繁忙时把已启动进程误报为超时失败；生产执行器超时策略保持不变。

### Meta

- Bugfix 预发布版本从 **1.223.0-rc1** 递增为 **1.223.0-rc2**，内部构建号从 **255** 递增为 **256**，Help 与 Computer Use Helper 构建号从 **172** 递增为 **173**；App、Go agent、Help、Helper、浏览器扩展、响应头契约与产品文档保持一致。

## 1.223.0-rc1 - 2026-08-02

### Added

- 调度项目目标描述下新增 AI 目标体检，可一键诊断目标能否收敛、提示仍需提前决定的边界、提供可编辑目标改写，并生成 3–10 条可观察验收标准自动填入清单。
- 目标体检结果保持建议性质：修改目标后会标记旧诊断过期并支持再次检查；用户也可忽略“需要聚焦”提示，使用当前目标和验收清单继续创建项目。

### Changed

- 普通聊天、Goal 计划和调度节点统一采用“前期集中沟通、后期无人值守”契约：执行前识别范围、凭据、外部副作用和不可逆选择，计划启动后自行诊断并恢复普通 Git/worktree、依赖、构建、测试、路径与瞬态工具问题。
- AI 只有在缺少授权或凭据、需要用户私密交互接管、存在不可逆选择，或必须由用户决定且会实质改变约定目标时才暂停执行。

### Fixed

- 调度任务的确定性分支已被有效隔离 worktree 检出时直接复用该工作区；若仅有陈旧 worktree 元数据则先清理再重查，不再把 `branch is already used by worktree` 作为需要用户处理的启动失败。

### Tests

- 新增目标体检结构化输出、建议式门禁、过期诊断、普通/Goal 无人值守提示词快照及真实 Git worktree 重入回归；核心定向测试 5 个套件共 86 项通过。

### Meta

- 功能预发布版本从 **1.222.0-rc3** 提升为 **1.223.0-rc1**，内部构建号从 **254** 递增为 **255**，Help 与 Computer Use Helper 构建号从 **171** 递增为 **172**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.222.0-rc3 - 2026-08-02

### Fixed

- 调度项目的验收清单不再于 AI 规划完成前投影为一排可执行根节点；它们只保留在虚拟验收关卡，避免“所有任务第一步并行、下一步直接验收”的假 DAG。
- 项目头部、单节点启动与恢复调度路径统一增加正式计划门禁；只有已捕获并校验、带稳定计划节点标识的任务图才能启动 Worker，规划期间按钮显示“规划中”。

### Tests

- 新增规划前验收清单不生成执行任务的回归用例，并同步调整人工追加节点、子会话归属和状态保留测试，使执行计划与项目验收清单保持独立。

### Meta

- Bugfix 预发布版本从 **1.222.0-rc2** 递增为 **1.222.0-rc3**，内部构建号从 **253** 递增为 **254**，Help 与 Computer Use Helper 构建号从 **170** 递增为 **171**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.222.0-rc2 - 2026-08-02

### Changed

- 多节点调度规划明确区分执行节点与虚拟验收关卡，并要求软件项目按“基础契约 → 并行实现 → 独立代码合并/集成 → 独立测试/回归”组织真实依赖。
- 并行写代码节点必须被一个单独的合并/集成节点显式依赖；后置测试节点再直接依赖该合并节点，不能把合并、测试和最终验收揉成一个节点。

### Fixed

- 调度图新增宿主语义门禁，拒绝所有节点都在首轮并行、多个末端节点、层级不足、并行分支未显式汇合、缺少独立合并节点或缺少独立验证节点的 AI 计划，并沿既有纠错链自动要求规划器重排。
- 重复或空任务 ID 在进入语义校验前安全失败，不再因构造依赖字典触发崩溃。
- 规划 Profile 不再被项目 Worker 池错误过滤；选择 `Kimi K3 Planner` 时会固定 `some-im / kimi-k3`，不会因 Worker 池只有 DeepSeek 而静默改用 `deepseek-v4-flash`。
- 调度项目捕获有效 DAG 后立即结束父规划会话，把执行交给协调器创建的隔离子任务运行时；父会话不再自动续跑整份 Plan，绕过节点依赖、Git worktree、Worker 路由与独立合并节点。
- WillDeep 规划模型在最终合成阶段发生网络错误或空响应时，会有界切换到下一个规划 Profile；回退链耗尽则进入可见的 blocked 状态，不再停在“准备提案”。
- 将媒体任务完成提示辅助函数从 3000 行边缘的 Agent 主循环拆到独立文件，复杂度硬门禁恢复为 `hard=0`，对应短剧契约测试同步覆盖拆分后的源码集合。

### Tests

- 调度协调器定向测试 40 项与 Goal Teams 定向测试 30 项通过，新增经典小游戏平台四阶段正例、全首轮并行反例、无汇合分叉反例、“合并并测试”二合一反例、重复任务 ID 安全失败、规划 Profile/Worker 池隔离、父规划会话交接及 WillDeep 规划失败回退用例。

### Meta

- Bugfix 预发布版本从 **1.222.0-rc1** 递增为 **1.222.0-rc2**，内部构建号从 **252** 递增为 **253**，Help 与 Computer Use Helper 构建号从 **169** 递增为 **170**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.222.0-rc1 - 2026-08-01

### Added

- 调度台新增项目级 Worker 池，可同时勾选多个 WillDeep 模型、Codex CLI Profile 与 Claude Code Agent，并按 Worker 数量并行启动就绪节点。
- 内建编程 Worker 覆盖 some.im `deepseek-v4-flash`、`gpt-5.6-sol`、`gpt-5.6-luna` 与 `gpt-5.6-terra`，新调度项目默认选中 DeepSeek V4 Flash。
- Worker 管理统一展示内建、手工配置和自动发现的外部执行器，并标记本机不可用的执行器。

### Changed

- 调度节点同时固定 Provider、模型与执行器；some.im Flash Worker 即使在其他 Provider 为全局当前项时仍使用 `some-im / deepseek-v4-flash / Responses`。
- 每个本机 Git 调度节点自动创建独立 worktree，节点直接执行当前任务，不再递归创建子 Goal 或共享同一 checkout。
- 自动调度优先分配空闲 Worker；执行器失败时沿节点回退链与项目 Worker 池切换到尚未尝试的可用 Worker。

### Fixed

- `goal-check` 全部通过后节点立即进入已合并状态、解锁依赖并补充启动下一批就绪节点，不再停在验证中。
- 调度规划与节点 Profile 选择严格限制在项目勾选的 Worker 池内，避免界面选择与实际执行模型不一致。
- 重启 App 或重新打开调度台后会重新挂接运行中/验收中子会话，自动对账已完成清单并继续解锁后继节点；验收中的节点也可显式重试。
- some.im 登录态刷新不再把已固定 Provider/模型的 Worker 空会话改回省心托管；运行中切换 Worker 会同步更新或清除 Provider 与模型覆盖。

### Tests

- 调度协调器、Provider 与 Responses 编码专项测试共 86 项通过，覆盖 Worker 池顺序、空闲分配、执行器跳过、持久化、调度会话恢复、some.im Provider 固定及 Responses 协议选择。
- 签名 Debug 包实际创建 10 节点经典小游戏平台项目并勾选 3 个 Worker；重启后已完成节点从 0% 自动对账至 10%，重试会话明确显示并实际使用 `some.im · deepseek-v4-flash`。
- 生成站点首页与 5 个游戏页共 6 个 URL 均返回 HTTP 200；独立回归同时抓到俄罗斯方块测试 13 项中 7 项失败，验证最终验收节点不会只凭子节点自报结果放行。

### Meta

- 功能预发布版本从 **1.221.0-rc2** 提升为 **1.222.0-rc1**，内部构建号从 **251** 递增为 **252**，Help 与 Computer Use Helper 构建号从 **168** 递增为 **169**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.221.0-rc2 - 2026-08-01

### Fixed

- 工作区会话侧栏改用有界的 eager `VStack`，避开 macOS 26 上 `LazyVStack` 项目阶段缓存持续失效导致的主线程 AttributeGraph 布局风暴和单核满载。
- 工作区过滤、分组与排序结果在每次视图求值中只生成一份稳定快照，不再把计算属性直接交给 `ForEach` 协调。

### Tests

- 新增侧栏布局回归门禁，确保工作区列表继续使用 eager stack，并保留现有 16 项视觉、渲染和布局测试。

### Meta

- Bugfix 预发布版本从 **1.221.0-rc1** 递增为 **1.221.0-rc2**，内部构建号从 **250** 递增为 **251**，Help 与 Computer Use Helper 构建号从 **167** 递增为 **168**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.221.0-rc1 - 2026-08-01

### Added

- Claude Code 与 Codex 新增结构化执行通道：提示词通过 stdin 传入，流式事件统一为会话、消息、思考、工具、文件变更、用量、警告与完成状态。
- 本机 Codex 可通过 app-server 承接双向审批，本机 Claude Code 可在 ACP adapter 可用时承接审批、文件读写和反向终端；不可用时安全回退到 JSONL 进程通道。
- `claude_code` 与 `codex_cli` 支持 `session_id` 续接；右侧任务面板和 `get_job_output` 展示统一事件、会话与 Token 用量。
- 远端 daemon 支持互斥的结构化 `executable + arguments + stdin_base64` 启动模式，并将 stdout、stderr、退出与结构化事件实时同步回本机任务。

### Changed

- Composer、Goal 与自检委托默认使用结构化执行；显式 Claude Agent、Codex Profile、Cursor、Cline、Hermes 及可见终端继续使用对应兼容路径。
- 前后台任务共享停止、超时、完成通知和密钥脱敏规则；提示词不再出现在 argv、进程列表或审批预览中。

### Security

- ACP 文件访问解析符号链接后校验工作区边界，写入与反向终端继续经过 WillDeep 审批和 sandbox；daemon 结构化 stdin 限制为 1 MiB。

### Tests

- 新增结构化进程工厂、Claude/Codex 事件解码、session resume、脱敏、Codex app-server、Claude ACP、路径守卫与远端 daemon 结构化启动测试。

### Meta

- 功能预发布版本从 **1.220.0-rc17** 提升为 **1.221.0-rc1**，内部构建号从 **249** 递增为 **250**，Help 与 Computer Use Helper 构建号从 **166** 递增为 **167**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.220.0-rc17 - 2026-08-01

### Fixed

- 测试报告无法解析 xcresult 时不再把零计数渲染成“通过”；报告明确区分 `passed`、`failed` 与 `unknown`，无法确认时以非零状态退出。
- xcresult 损坏或收尾不完整时，报告器可从原始 xcodebuild 日志恢复测试结论与计数；看门狗先发送 SIGTERM 并等待收尾，超时后才升级为 SIGKILL。
- 完整测试、快速测试与 CI 都向报告器传入对应日志，并保留报告器的失败或未知退出状态。

### Tests

- 新增 xcresult 报告契约，覆盖半成品 bundle、通过/失败日志回退、缺失 bundle、显式日志路径及零用例门禁。

### Meta

- Bugfix 预发布版本从 **1.220.0-rc16** 递增为 **1.220.0-rc17**，内部构建号从 **248** 递增为 **249**，Help 与 Computer Use Helper 构建号从 **165** 递增为 **166**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.220.0-rc16 - 2026-08-01

### Fixed

- `scripts/run_tests_fast.rb` 现在显式使用 UTF-8 locale，并对 Git 子进程输出执行 UTF-8 转码与非法字节清理；中文未提交改动不再令源码指纹生成在 `JSON.generate` 阶段崩溃。
- Ruby 的默认外部与内部编码统一固定为 UTF-8，避免调用者 locale 缺失时把合法中文输出误标记为 US-ASCII。

### Tests

- 快速测试入口契约共 53 项通过，现有构建缓存、指纹与 CI 分组约束保持不变。

### Meta

- Bugfix 预发布版本从 **1.220.0-rc15** 递增为 **1.220.0-rc16**，内部构建号从 **247** 递增为 **248**，Help 与 Computer Use Helper 构建号从 **164** 递增为 **165**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.220.0-rc15 - 2026-08-01

### 用户可见变化

- 省心托管的路由判断与回答质检现在会正确通过 Responses API 调用 `someim-judge`，避免其切换到 DeepSeek V4 Flash 后仍按旧 Chat 格式发送。

### Fixed

- `routeJudge` 先用目标裁判型号生成独立配置，再按该型号的推理协议分发；不会继续错误继承当前主模型的 Chat 协议。
- 新增无状态 Responses 裁判请求，使用 `instructions`、类型化 `input`、`max_output_tokens` 与 `store=false`，并保留 some.im 会话和工作区诊断头。

### Tests

- 新增请求级回归测试，锁定 `someim-judge` 使用 `/v1/responses`、Responses 请求体字段及严格 JSON 文本解析。

### Meta

- Bugfix 预发布版本从 **1.220.0-rc14** 递增为 **1.220.0-rc15**，内部构建号从 **246** 递增为 **247**，Help 与 Computer Use Helper 构建号从 **163** 递增为 **164**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.220.0-rc14 - 2026-08-01

### 用户可见变化

- “编程推荐”新增 some.im 的 `gpt-5.6-sol`、`gpt-5.6-luna`、`gpt-5.6-terra` 和 `deepseek-v4-flash`；新用户及未明确设置默认模式的用户，新会话默认选中 some.im 的 `deepseek-v4-flash`。

### Added

- 编程推荐列表将四个新推荐型号固定归属到 some.im，并保留原有 DeepSeek V4 Pro 与 GLM 推荐。
- some.im 默认模型模式仍可在设置中显式切换为“省心托管”；已显式选择该模式的用户不受默认值调整影响。

### Tests

- 扩展模型选择器与会话默认值单测，覆盖推荐型号、some.im 归属、默认顺序及省心托管显式选择。

### Meta

- 预发布版本从 **1.220.0-rc13** 递增为 **1.220.0-rc14**，内部构建号从 **245** 递增为 **246**，Help 与 Computer Use Helper 构建号从 **162** 递增为 **163**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.220.0-rc13 - 2026-08-01

### 用户可见变化

- 更新弹窗现在打开 some.im 上的 WillDeep 专属更新日志，只展示这次升级真正影响使用的内容，不再把测试记录、内部版本同步和工程术语一股脑塞给用户。

### Fixed

- 发布脚本优先读取人工撰写的“用户可见变化”，没有专门摘要时才从 Added、Changed、Fixed 等用户相关分段生成发布说明。
- 自动生成发布说明时排除 Tests、Meta 等内部章节，避免 Sparkle 内嵌页面退化为 Git/工程日志陈列柜。

### Tests

- 扩展 macOS 发布契约测试，锁定专属 Changelog URL、用户摘要优先级和内部章节过滤。

### Meta

- Bugfix 预发布版本从 **1.220.0-rc12** 递增为 **1.220.0-rc13**，内部构建号从 **244** 递增为 **245**，Help 与 Computer Use Helper 构建号从 **161** 递增为 **162**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.220.0-rc12 - 2026-08-01

### Fixed

- 将 some.im 托管裁判模型 `someim-judge` 纳入 DeepSeek V4 Flash Responses 路由，复用 `store=false` 与网关状态续接行为。
- 路由覆盖继续受 some.im 提供商约束，自定义提供商的同名模型不会被误切换协议。

### Tests

- 扩充 Flash 别名路由契约，验证 `someim-judge` 使用 Responses、启用网关状态续接，并保持自定义提供商隔离。

### Meta

- Bugfix 预发布版本从 **1.220.0-rc11** 递增为 **1.220.0-rc12**，内部构建号从 **243** 递增为 **244**，Help 与 Computer Use Helper 构建号从 **160** 递增为 **161**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.220.0-rc11 - 2026-08-01

### Fixed

- 将 some.im 下由 DeepSeek V4 Flash 承载的 `someim-auto-flash`、`someim-code-low`、`someim-coding-plan` 与实际托管低档型号 `someim-coding-plan-low` 切换到 Responses 路由，并复用网关状态续接与 `store=false` 行为。
- Responses 协议覆盖同时受提供商与精确型号约束；`someim-coding-plan-high/premium` 和自定义提供商的同名模型继续使用原协议，避免误路由。

### Tests

- 扩充模型路由契约测试，覆盖四个 Flash 别名、some.im 状态续接、自定义提供商隔离，以及 coding-plan 高档型号不受影响。

### Meta

- Bugfix 预发布版本从 **1.220.0-rc10** 递增为 **1.220.0-rc11**，内部构建号从 **242** 递增为 **243**，Help 与 Computer Use Helper 构建号从 **159** 递增为 **160**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.220.0-rc10 - 2026-08-01

### Fixed

- 修复钉钉等动态 Accessibility 树因敏感区域扫描超时或节点瞬时失效而触发 `sensitive_accessibility_scan_incomplete`，继而丢弃整张目标窗口截图并让坐标点击失去截图坐标空间的问题。
- 模型按需截图与聊天区右上角本地控制预览现阶段均直接采集目标窗口，不再执行 Accessibility 敏感区域扫描或像素遮罩；密码、验证码等自动读写限制继续独立生效。

### Tests

- 更新 Computer Use v6 契约测试，确保两条窗口截图路径都传入空遮罩集合、不会调用敏感树扫描，也不会恢复“扫描不完整即返回空截图”的旧逻辑。

### Meta

- Bugfix 预发布版本从 **1.220.0-rc9** 递增为 **1.220.0-rc10**，内部构建号从 **241** 递增为 **242**，Help 与 Computer Use Helper 构建号从 **158** 递增为 **159**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.220.0-rc9 - 2026-08-01

### Fixed

- 将后台 AX 操作、PID 定向输入和目标窗口截图规则对应的稳定提示词契约从 v21 推进至 v22，防止请求继续命中旧提示词缓存而恢复“先激活 App、再截图”的过时行为。

### Tests

- 重新记录 standard、compact、extended 三档提示词的确定性快照哈希，确保 Computer Use 后台控制约束发生意外漂移时测试会直接失败。

### Meta

- Bugfix 预发布版本从 **1.220.0-rc8** 递增为 **1.220.0-rc9**，内部构建号从 **240** 递增为 **241**，Help 与 Computer Use Helper 构建号从 **157** 递增为 **158**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.220.0-rc8 - 2026-08-01

### Fixed

- 修复 DeepSeek V4 Flash Responses 完整历史把 reasoning 的 `content` 编码为字符串，导致上游要求序列并返回 HTTP 400 的问题；reasoning 现按 `reasoning_text` 内容块数组编码。
- 修复 Responses 增量续接未把 reasoning、custom tool call 与 web search call 识别为服务端输出，导致客户端放弃游标并重发超长完整历史的问题；有效游标下只发送新增 user/tool input，由 some.im 服务端从状态存储拼装原始 input/output 历史。

### Tests

- 扩展 Responses 编码与续接测试，覆盖 reasoning 内容块数组、reasoning 加 assistant/function call 输出剥离，以及仅发送新用户或工具增量。

### Meta

- Bugfix 预发布版本从 **1.220.0-rc7** 递增为 **1.220.0-rc8**，内部构建号从 **239** 递增为 **240**，Help 与 Computer Use Helper 构建号从 **156** 递增为 **157**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.220.0-rc7 - 2026-08-01

### Fixed

- 修复模型把 `computer_use_activate_app` 当作键盘操作前置步骤、导致钉钉等目标被反复切到前台并在激活失败时中断的问题；AX 操作、PID 定向输入与目标窗口截图现在明确支持后台运行，激活仅保留为目标应用拒绝后台事件时的兼容兜底。
- 修复 Computer Use 同时显示聊天区右上角控制卡和屏幕底部浮动控制条的重复状态；底部浮条已移除，右上角控制卡成为唯一主状态界面。

### Added

- 右上角控制卡新增 Helper 本地目标窗口预览流；预览不会发送给模型、不会重建 AX 树或使当前 ref/snapshot 失效，暂停和用户接管时会立即停止并清除。
- 菜单栏新增“目标 App 图标 + Computer Use 标识”的组合状态项，并提供暂停、接管、恢复和停止操作。

### Tests

- 新增后台目标窗口预览、快照保持、隐私 epoch、单一控制面板和菜单栏组合状态契约覆盖；同步更新单次授权、AX-first 和提示词快照测试。

### Meta

- Bugfix 预发布版本从 **1.220.0-rc6** 递增为 **1.220.0-rc7**，内部构建号从 **238** 递增为 **239**，Help 与 Computer Use Helper 构建号从 **155** 递增为 **156**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.220.0-rc6 - 2026-08-01

### Changed

- Computer Use 开发期暂时放开终端应用与终端表面：Host 与 Helper 不再按 Terminal、iTerm、Warp 等 Bundle ID/应用名拒绝目标，Accessibility 元数据中的 `terminal`、`终端`、`控制台`等词也不再触发整片子树脱敏或禁止输入。
- 终端规则和已知应用清单继续保留在代码中，由 Host/Helper 各自明确的开发期开关停用，后续可在补齐命中原因、低误报识别与分层策略后逐步恢复。

### Security

- 继续拒绝 Computer Use 控制 WillDeep、Helper 自身及父进程；`AXProtectedContent`、SecureTextField、密码、验证码、密钥、令牌等真实敏感输入仍会脱敏并拒绝自动读写，剪贴板和高影响动作门禁保持不变。

### Tests

- 更新 Host 目标边界单测与 Helper v6 契约：验证开发期开关允许 Terminal/Warp，Helper 运行时可建立并结束 Terminal 控制租约，同时自控边界和敏感输入保护继续存在。

### Meta

- Bugfix 预发布版本从 **1.220.0-rc5** 递增为 **1.220.0-rc6**，内部构建号从 **237** 递增为 **238**，Help 与 Computer Use Helper 构建号从 **154** 递增为 **155**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.220.0-rc5 - 2026-08-01

### Fixed

- 修复同一 Computer Use 控制租约已获批后，截图坐标点击仍被无条件升级为 danger 并反复展示确认卡的问题；同一 runtime、turn 和目标应用内，带新鲜快照及完整动作声明的 AX 点击、坐标点击和右键点击现在都会复用本轮授权，包括已如实声明的有外部影响点击。
- 修复 Computer Use 状态读取和动作后刷新默认附带截图、导致模型跳过 Accessibility 树直接进入视觉方案的问题；`computer_use_get_app_state` 与每次动作后的新状态现在默认 AX-only，只有 AX 树没有可用目标时才显式传入 `include_screenshot=true` 获取窗口截图。
- 保留严格审批模式、控制暂停、用户接管、停止、目标切换、无效或不诚实动作声明、剪贴板操作及认证/验证码/凭据/金融交易私密接管边界，不把跨任务授权持久化。

### Changed

- 系统提示词契约升级为 `willdeep-agent-system-v21`，Computer Use 内置技能、工具描述和结果提示统一为“AX 树优先，截图与像素仅作显式兜底”。

### Tests

- 新增控制租约内 AX/坐标/有外部影响点击复用授权、坐标拖拽继续逐次确认、AX-only 默认状态与 Helper 契约回归覆盖。

### Meta

- Bugfix 预发布版本从 **1.220.0-rc4** 递增为 **1.220.0-rc5**，内部构建号从 **236** 递增为 **237**，Help 与 Computer Use Helper 构建号从 **153** 递增为 **154**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.220.0-rc4 - 2026-07-31

### Fixed

- 修复 Computer Use 将应用激活 API 的一次瞬时失败直接视为致命错误的问题；现在会验证目标是否真正到达前台、短时重试，并在已授予辅助功能权限时通过 AXRaise 兜底。
- 修复钉钉等应用的最上层 CGWindow 与 AXWindow 窗口号缺失或边框几何存在小幅差异时频繁触发 `stale_snapshot` 的问题；窗口绑定会等待界面稳定，并仅在尺寸、重叠率和中心偏差均满足保守阈值时采用几何匹配。
- 同一 runtime、turn 和目标应用的控制租约建立后，重复的普通应用激活自动沿用本轮授权，不再反复展示“允许使用该应用”；严格审批模式仍保持逐次确认。

### Tests

- Computer Use Helper v6 契约 19 项、基础 Helper 契约 7 项通过；Computer Use Coordinator、Policy 与 Tool 三个定向测试套件共 54 项通过。

### Meta

- Bugfix 预发布版本从 **1.220.0-rc3** 递增为 **1.220.0-rc4**，内部构建号从 **235** 递增为 **236**，Help 与 Computer Use Helper 构建号从 **152** 递增为 **153**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.220.0-rc3 - 2026-07-31

### Added

- 设置 → Agent 工具 → 工具新增 WillDeep Computer Use 权限区，分别显示独立 Helper 的“辅助功能”和“屏幕与系统音频录制”授权状态，并为每项提供独立申请与刷新操作。
- 屏幕录制授权后自动重启 Computer Use Helper 并轮询新状态，无需重启 WillDeep；界面说明主程序权限不能替代 Helper 权限，Computer Use 不录制或保存系统音频。

### Tests

- 验证 String Catalog JSON、版本一致性与 Xcode Debug 构建。

### Meta

- Bugfix 预发布版本从 **1.220.0-rc2** 递增为 **1.220.0-rc3**，内部构建号从 **234** 递增为 **235**，Help 与 Computer Use Helper 构建号从 **151** 递增为 **152**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.220.0-rc2 - 2026-07-31

### Fixed

- 修复 Computer Use 授权卡将“允许”放在左侧、“拒绝”放在右侧的问题；现在拒绝固定在左、正向操作固定在右，窄宽布局保持一致。
- Computer Use 授权提问收敛为“允许 WillDeep 操作电脑？”，减少标题与正文重复，更接近 Codex 的简洁确认样式。
- 正向审批按钮改为 Codex 风格的高对比圆角实心按钮：浅色模式黑底白字，深色模式白底黑字；拒绝按钮保留低强调样式。

### Tests

- 版本一致性检查通过；定向 XeditTests 因共享 Xcode 构建锁长时间被其他任务占用而未启动。

### Meta

- Bugfix 预发布版本从 **1.220.0-rc1** 递增为 **1.220.0-rc2**，内部构建号从 **233** 递增为 **234**，Help 与 Computer Use Helper 构建号从 **150** 递增为 **151**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.220.0-rc1 - 2026-07-31

### Added

- `deepseek-v4-flash` 在 DeepSeek 直连与 some.im 中转配置下自动使用官方 `/responses`；`deepseek-v4-pro` 在官方支持前继续使用 Chat Completions。
- some.im 为 WillDeep 增加显式 `X-WillDeep-Responses-State: v1` 协议：客户端在 23 小时安全窗内使用增量续接，超过窗口改发完整历史；服务端游标、路由亲和过期或状态后端不可用时自动安全回退，并兼容旧网关的 `422 response_affinity_not_found`。若流式回答已开始后状态持久化失败，当前回答正常结束但不保存游标，下一轮改发完整历史，避免重放造成重复文本。

### Changed

- DeepSeek Responses 请求固定使用 `store: false`；完整历史会回传已捕获的明文 reasoning item，流式事件新增 `response.reasoning_text.delta` 与 `response.incomplete` 支持。

### Tests

- 新增 DeepSeek Flash/Pro 路由、直连无状态编码、reasoning 历史、23 小时游标边界以及状态后端降级测试；Responses 编码定向测试共 15 项通过。

### Meta

- 功能预发布版本从 **1.219.0-rc9** 提升为 **1.220.0-rc1**，内部构建号从 **232** 递增为 **233**，Help 与 Computer Use Helper 构建号从 **149** 递增为 **150**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.219.0-rc9 - 2026-07-31

### Fixed

- 修复 `run_command` 中 `~/...`、`$HOME/...` 和 `${HOME}/...` 被隔离 `HOME` 静默映射到临时沙箱目录的问题；这些路径现在会在执行前直接请求升级访问，并在获批后保持用户真实 Home 语义。
- 更新命令工具契约：用户明确要求操作 workspace 外路径时保留原路径并走升级审批，不再误称“路径映射有问题”或无故改发可见终端命令。
- 系统提示词契约升级为 `willdeep-agent-system-v20`，同步重录 standard、compact、extended 三档字节级哈希。

### Tests

- 新增真实 Home 路径授权回归测试，覆盖 `~/bin`、无空格重定向、`$HOME` 与 `${HOME}` 环境变量形式；Agent 工具核心测试与三档提示词快照测试通过。

### Meta

- Bugfix 预发布版本从 **1.219.0-rc8** 递增为 **1.219.0-rc9**，内部构建号从 **231** 递增为 **232**，Help 与 Computer Use Helper 构建号从 **148** 递增为 **149**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.219.0-rc8 - 2026-07-31

### Fixed

- 多技能批量创建工具与对应稳定工具规则加入系统提示词后，将契约版本从 `willdeep-agent-system-v18` 升级为 `willdeep-agent-system-v19`，避免发布测试把预期契约更新判定为未审阅漂移。
- 同步重录 standard、compact、extended 三档提示词字节级哈希，恢复完整测试与发布门禁。

### Meta

- Bugfix 预发布版本从 **1.219.0-rc7** 递增为 **1.219.0-rc8**，内部构建号从 **230** 递增为 **231**，Help 与 Computer Use Helper 构建号从 **147** 递增为 **148**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.219.0-rc7 - 2026-07-31

### Fixed

- 修复长对话处于“处理中/思考中”状态时 CPU 异常升高：活动文字扫光刷新率从 30 FPS 限制为最多 12 FPS。
- 聊天搜索状态没有变化时不再重写整段 TextKit 存储，切断活动状态刷新引发全文属性修复、排版和固有高度重算的放大链路。

### Tests

- 扩展活动状态视觉回归测试，锁定扫光动画的最高刷新率与帧间隔，防止恢复为显示器刷新级别的高频更新。

### Meta

- Bugfix 预发布版本从 **1.219.0-rc6** 递增为 **1.219.0-rc7**，内部构建号从 **229** 递增为 **230**，Help 与 Computer Use Helper 构建号从 **146** 递增为 **147**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.219.0-rc6 - 2026-07-31

### Fixed

- 修复聊天记录选中文本后“添加到任务”浮层偶发立即消失：搜索状态没有变化时不再重复重写富文本。
- hover 与搜索高亮等纯样式刷新会在正文未变化时保留有效选区，并恢复对应操作浮层，不再把样式重绘误判成取消选择。

### Tests

- 新增聊天记录样式刷新选区保持测试，覆盖搜索高亮开启与清除后仍可把原选中文本添加到任务。

### Meta

- Bugfix 预发布版本从 **1.219.0-rc5** 递增为 **1.219.0-rc6**，内部构建号从 **228** 递增为 **229**，Help 与 Computer Use Helper 构建号从 **145** 递增为 **146**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.219.0-rc5 - 2026-07-31

### Fixed

- 自动技能提取的默认工具证据门槛从 3 次提高到 6 次，并将旧默认值 3/5 自动迁移到新门槛；仅成功完成的工具调用计入证据。
- 明确创建 Skill 的意图只认用户原话，不再把 Assistant 自己提到的“自动创建 Skill”等表述当成写入授权。
- 未明确要求创建 Skill 的可复用流程即使达到门槛，也只生成待审阅草稿，不再直接写入用户 Skill 目录；用户明确要求创建时至少需要 4 次成功工具调用。

### Tests

- 更新自动技能门槛测试，并新增隐式流程只进审阅、Assistant 自述不得授权创建的回归用例。

### Meta

- Bugfix 预发布版本从 **1.219.0-rc4** 递增为 **1.219.0-rc5**，内部构建号从 **227** 递增为 **228**，Help 与 Computer Use Helper 构建号从 **144** 递增为 **145**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.219.0-rc4 - 2026-07-31

### Fixed

- 收紧后台任务的系统通知策略：仅当应用不在前台且任务失败、超时或启动失败时发送通知。
- 成功完成、用户主动停止以及应用前台可见的失败不再弹出系统横幅，结果仍保留在任务抽屉与会话记录中。

### Tests

- 新增后台任务通知策略测试，覆盖成功、主动停止、异常状态及应用前后台组合。

### Meta

- Bugfix 预发布版本从 **1.219.0-rc3** 递增为 **1.219.0-rc4**，内部构建号从 **226** 递增为 **227**，Help 与 Computer Use Helper 构建号从 **143** 递增为 **144**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.219.0-rc3 - 2026-07-31

### Fixed

- 视觉模型上游返回临时 `422 no route can preserve ... input_modality:image` 时，不再只等待 800ms 重试一次后要求用户手动点击“重试”。
- 针对这一种可恢复路由错误执行最多 3 次指数退避重试（0.8s、1.6s、3.2s）；其他 422 仍立即失败，避免掩盖真实参数或配置问题。

### Tests

- 扩展视觉路由重试策略测试，覆盖三次预算、指数退避时间及非目标 422 不重试；Provider Library 相关 36 项测试通过。

### Meta

- Bugfix 预发布版本从 **1.219.0-rc2** 递增为 **1.219.0-rc3**，内部构建号从 **225** 递增为 **226**，Help 与 Computer Use Helper 构建号从 **142** 递增为 **143**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.219.0-rc2 - 2026-07-31

### Fixed

- 放大浏览器与 Computer Use 紧凑授权卡的全部操作按钮：高度从 22pt 提升到 36pt，普通操作最小宽度 76pt，主操作最小宽度 112pt，并增加字号和水平点击热区。
- 宽聊天栏继续使用单行操作布局，窄栏通过现有自适应布局换行，避免按钮放大后挤压或截断。

### Tests

- 更新紧凑授权卡布局契约，并通过 4 项多皮肤、宽窄尺寸渲染测试。

### Meta

- Bugfix 预发布版本从 **1.219.0-rc1** 递增为 **1.219.0-rc2**，内部构建号从 **224** 递增为 **225**，Help 与 Computer Use Helper 构建号从 **141** 递增为 **142**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.219.0-rc1 - 2026-07-31

### Added

- 新增 `create_user_skills` 批量技能创建工具：一次请求可携带 1–10 个完整技能草稿，模型在用户要求多个技能时必须合并为一次调用，不再逐个调用 `create_user_skill` 触发连续审批。
- 批量创建确认卡集中展示技能数量、名称与用途说明，并明确“一次确认、失败整批回滚”；用户确认一次即可授权整批创建。
- 批量执行会在写入前统一校验数量、字段长度、规范化名称冲突和现有目录冲突；写入过程中任一项失败时撤销本批已创建目录，成功结果逐项返回技能路径。

### Changed

- Skill Hub、Skill Search、Agent 系统提示、语言提示与工具可观测名称同步加入批量技能入口；单技能创建工具继续保留兼容，并明确禁止用它拆分多技能请求。

### Tests

- 新增批量技能成功创建、重复规范化名称整批拒绝、专用审批文案、内置技能工具契约与本地确认预览测试；相关 4 个套件共 58 项测试通过。

### Meta

- 功能版本从 **1.218.0-rc3** 提升为 **1.219.0-rc1**，内部构建号从 **223** 递增为 **224**，Help 与 Computer Use Helper 构建号从 **140** 递增为 **141**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.218.0-rc3 - 2026-07-31

### Fixed

- `$` 技能与 `@` 文件/工作区选择器的列表可视高度上限从 340pt 提升到 440pt，一次可浏览更多候选项，超出区域继续保持纵向滚动。
- `/` 命令选择器新增有界纵向滚动，并在键盘上下选择时自动将当前命令滚入视野；菜单高度与另外两类 Composer 选择器统一为 440pt 上限。

### Tests

- 扩展 Composer 选择器布局回归断言，锁定统一的 440pt 列表高度上限。

### Meta

- Bugfix 预发布版本从 **1.218.0-rc2** 递增为 **1.218.0-rc3**，内部构建号从 **222** 递增为 **223**，Help 与 Computer Use Helper 构建号从 **139** 递增为 **140**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.218.0-rc2 - 2026-07-31

### Fixed

- 手动补丁应用与跨提案重复目标的回归用例显式切换到“每次请求审批”，确保测试真正覆盖待审批、整批预检和原子拒绝路径。
- Goal 模式审批测试按现行 Smart 策略断言受控委托式编码 Agent 使用静态白名单，避免把预期的自动授权误报为失败。
- 修复上述旧断言导致的 4 项发布门禁失败，同时保持 Smart 模式自动应用工作区内安全变更的生产行为不变。

### Tests

- 重新执行 4 项审批/补丁定向回归，全部通过；完整 `XeditTests` 共 1786 项、153 个套件全部通过。

### Meta

- Bugfix 预发布版本从 **1.218.0-rc1** 递增为 **1.218.0-rc2**，内部构建号从 **221** 递增为 **222**，Help 与 Computer Use Helper 构建号从 **138** 递增为 **139**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.218.0-rc1 - 2026-07-31

### Added

- **GPT-5 自动 Responses 路由**：OpenAI-compatible Provider 的最终推理模型 ID 只要包含 `gpt-5`（大小写不敏感，例如 `gpt-5.4`、`gpt-5.5`、`gpt-5.6-sol`），主回复与安全判定就自动使用 `/responses`；显式 Responses Provider 继续生效，Anthropic/Gemini 原生协议保持原路由。
- **Responses 游标跨重启续接**：最近一次成功 Response 的游标与稳定请求签名随 `AgentSession` JSON 持久化，重新打开应用和会话后仍能只发送新增用户输入或工具结果。

### Changed

- 续接前缀校验从包含临时消息 UUID/时间戳的消息编码，改为真实 Responses wire input 的 SHA-256 签名；系统消息在重建或应用重启后不会因本地身份变化误触发完整历史回退。
- 持久化快照只保存不透明 `response_id`、上下文哈希、逐 input-item 哈希和更新时间，不重复保存提示词、工具 schema、凭据或消息正文；Provider、Base URL 或 API Key 变化会改变仅存哈希的连接身份并强制发送完整历史。
- 自动切换 Responses 后继续携带 some.im 会话/工作区上下文头、额度响应观察以及 OpenRouter branding；游标失效仍会清除快照并以完整历史自动重试一次。

### Tests

- 新增 `gpt-5`/非 GPT-5/原生 Anthropic 路由边界，以及会话序列化、模拟应用重启、恢复游标后仅发送新增用户输入的回归；Responses/工具图像编码定向测试套件 11 项全部通过。

### Meta

- 功能版本从 **1.217.0-rc1** 提升为 **1.218.0-rc1**，内部构建号从 **220** 递增为 **221**，Help 与 Computer Use Helper 构建号从 **137** 递增为 **138**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.217.0-rc1 - 2026-07-30

### Added

- **Responses 有状态增量续接**：OpenAI Responses 会话会记录最近一次成功 Response 的游标；当模型、instructions、工具 schema、图像能力与既有消息保持一致且历史严格追加时，后续请求只上传 `previous_response_id` 与增量 `input`，覆盖同一回合的工具循环及打开期间的后续用户回合。

### Changed

- Responses 主请求显式设置 `store: true`，独立安全判定显式设置 `store: false`；模型、工具、上下文或旧消息发生变化时仍发送完整历史。
- 上游返回 `previous_response_id` 不存在、过期或不支持时，客户端会清除会话游标并自动用完整历史重试一次，兼容仅提供无状态 Responses 外壳的网关。

### Tests

- 新增严格追加时仅发送工具结果增量、早期 instructions 变化时回退完整历史的回归；定向执行 Responses/工具图像编码测试套件 9 项，全部通过。

### Meta

- 功能版本从 **1.216.0-rc1** 提升为 **1.217.0-rc1**，内部构建号从 **219** 递增为 **220**，Help 与 Computer Use Helper 构建号从 **136** 递增为 **137**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.216.0-rc1 - 2026-07-30

### Added

- **工作区 Goal 感知**：普通会话现在能从宿主获知同一工作区其他未完成 Goal 的目标陈述、清单进度、运行状态与调度归属；这些信息同时进入 Agent 动态上下文、`list_workspace_sessions` 工具结果和会话早期 Composer 提示，并可一键打开对应 Goal 或调度项目，避免重复建立目标和争抢同一工作现场。
- **调度项目单运行实例**：同一逻辑项目只允许一个未暂停且未完成的调度项目运行；本机不同 worktree 通过 Git common directory 归并，远端工作区按精确位置识别。

### Changed

- 重复创建调度项目时直接复用并打开现有项目；显式暂停或所有任务合并后释放名额。恢复旧项目、把结构化草稿提交为 Goal、启动子任务时都会重新校验冲突，历史数据中已有的重复运行项目在同步时自动暂停多余实例。

### Tests

- 新增工作区 Goal 上下文、会话工具快照，以及调度项目复用、暂停释放、恢复冲突、草稿提交冲突、历史重复收敛、完成状态和 Git common directory 归并回归；定向执行 3 个 Swift 测试套件共 50 项，全部通过。

### Meta

- 功能版本从 **1.215.0-rc6** 提升为 **1.216.0-rc1**，内部构建号从 **218** 递增为 **219**，Help 与 Computer Use Helper 构建号从 **135** 递增为 **136**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.215.0-rc6 - 2026-07-30

### Fixed

- **调度台同步触发主线程永久卡死**：Git 子进程的标准输出与错误输出改为每次调用独占的临时普通文件，父进程启动后立即关闭写句柄，并在子进程退出后限量读取和清理；彻底移除对共享并发队列、管道 EOF 与 `DispatchGroup.wait()` 的依赖，避免高并发 Git 查询留下僵尸进程和大量悬空管道。
- **调度台投影阻塞界面线程**：会话到项目图的仓库探测与任务投影改在 utility 后台任务执行，快速连续更新只允许最新修订写回主线程，旧结果不会覆盖新状态。

### Tests

- 新增 24 路并发 Git 仓库探测回归，验证所有命令均能结束并返回非空输出；定向调度协调器测试与并发 Git 回归均通过。

### Meta

- 版本号从 **1.215.0-rc5** 递增为 bugfix 版本 **1.215.0-rc6**，内部构建号从 **217** 递增为 **218**，Help 与 Computer Use Helper 构建号从 **134** 递增为 **135**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.215.0-rc5 - 2026-07-30

### Fixed

- **独立视觉模型临时路由失败直接中断**：图像理解阶段遇到 some.im 明确返回的 HTTP 422 `input_modality:image` 暂无可用路由时，短暂等待后自动重试一次；整个解析操作共享唯一重试预算，候选模型切换不会各自追加重试，更不会形成循环。
- **视觉错误误报成主模型错误**：独立视觉模型失败时，错误卡明确展示“视觉模型、模型名与图像解析阶段”，并说明图片尚未交给纯文本主模型；解析失败后继续保持硬停止，不会把原图透传给文本模型。

### Tests

- 新增视觉路由 422 精确匹配、单次重试上限、无关 422 不重试，以及视觉阶段错误展示的定向回归。

### Meta

- 版本号从 **1.215.0-rc4** 递增为 bugfix 版本 **1.215.0-rc5**，内部构建号从 **216** 递增为 **217**，Help 与 Computer Use Helper 构建号从 **133** 递增为 **134**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.215.0-rc4 - 2026-07-30

### Fixed

- **编辑器开关重开设置后复位**：编辑设置保存任务在排队时立即捕获规范化快照，并在检查弱引用 `AppState` 之前写入偏好；设置窗口切换当前编辑器、替换临时状态或关闭时，“显示行号”“高亮当前行”等开关不再因旧 `AppState` 提前释放而丢失。

### Tests

- 新增设置持久化不依赖 `AppState` 生命周期的回归检查，并执行版本一致性、定向 Swift 测试与 Debug 编译。

### Meta

- 版本号从 **1.215.0-rc3** 递增为 bugfix 版本 **1.215.0-rc4**，内部构建号从 **215** 递增为 **216**，Help 与 Computer Use Helper 构建号从 **132** 递增为 **133**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.215.0-rc3 - 2026-07-30

### Fixed

- **账号弹窗头像始终显示昵称首字母**：侧栏底部账号条与弹出菜单顶部改为复用同一个远程头像组件和进程级缓存；已有头像正常显示，加载中或请求失败时才回退到昵称首字母。

### Tests

- 新增账号条与弹出菜单共用缓存头像渲染器的回归检查，并执行版本一致性、定向 Swift 测试与 Debug 编译。

### Meta

- 版本号从 **1.215.0-rc2** 递增为 bugfix 版本 **1.215.0-rc3**，内部构建号从 **214** 递增为 **215**，Help 与 Computer Use Helper 构建号从 **131** 递增为 **132**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.215.0-rc2 - 2026-07-30

### Fixed

- **悬停长标题后 WillDeep 主线程卡死**：会话标题和计划步骤恢复为单行尾部省略号，通过系统 tooltip 展示完整内容；移除 `GeometryReader`、`PreferenceKey`、hover 状态回写和 `repeatForever` 跑马灯动画，阻断 hover 命中测试与 `LazyVStack` 重布局之间的反馈环。

### Tests

- 执行静态回归检查、版本一致性、Swift 定向测试与完整 Debug 构建，确认截断组件不再包含布局测量、悬停状态或无限动画。

### Meta

- 版本号从 **1.215.0-rc1** 递增为 bugfix 版本 **1.215.0-rc2**，内部构建号从 **213** 递增为 **214**，Help 与 Computer Use Helper 构建号从 **130** 递增为 **131**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.215.0-rc1 - 2026-07-30

### Added

- **AI 原生 DAG 规划**：调度规划输出独立的 `dispatch-graph` 合同，由 AI 按任务需要决定节点、真实依赖和显式汇聚节点；同一节点可以等待两个或更多上游，不再把验收清单硬编码成单线任务链。
- **节点级执行 Profile 与回退链**：规划阶段和每个执行节点都可绑定不同 Profile，Profile 统一描述执行器、模型、Provider 与原生 CLI 配置；主 Profile 失败后按持久化的有序回退链自动切换，已尝试记录可防止无限重试。
- **Codex、Claude Code 与 Hermes Profile 管理**：调度台新增应用内 Profile 管理器，合并内置、用户管理和本机自动发现的 Profile；Hermes 作为正式外部执行器接入可见终端、工具审核、运行进度与本地/远端执行链。

### Changed

- **编辑节点降级为人工干预入口**：任务节点、依赖与 Profile 默认由 AI 规划；结构化节点编辑继续保留，但在 Inspector 和控制栏明确标为“人工干预”，不再暗示用户必须手工搭图。
- **规划默认采用成本分层**：内置规划 Profile 默认使用 `kimi-k3`，常规执行节点默认使用 `deepseek-v4-pro`；规划 Profile 本身也可以改用 Codex、Claude Code 或 Hermes，并配置独立回退链。

### Fixed

- **调度通知误入聊天**：桌面宠物与系统通知会依据会话的产品归属跳转；顶层调度项目和任务子会话统一打开所属项目的调度台，普通会话仍进入聊天。
- **重试后节点运行历史丢失**：AI 图节点 key 在项目命名空间内映射为稳定 UUID，修订或重试同一规划时继续保留已完成状态、Profile 尝试记录和运行会话历史。
- **远端 Hermes 误用本机主目录**：远端命令在目标主机解析其账户 Home，不再把本机路径写入 `HERMES_HOME`。

### Tests

- 新增真实分叉/双上游汇聚 DAG、稳定节点 ID、Profile 回退顺序、Hermes Profile 发现与命令安全、调度通知归属回跳等定向回归。

### Meta

- 版本号从 **1.214.0-rc1** 提升为功能版本 **1.215.0-rc1**，内部构建号从 **212** 递增为 **213**，Help 与 Computer Use Helper 构建号从 **129** 递增为 **130**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.214.0-rc1 - 2026-07-30

### Added

- **分角色模型路由**：每个调度项目可以独立选择规划模型与执行模型，默认以 `kimi-k3` 负责整体规划、`deepseek-v4-pro` 负责常规执行；路由随项目持久化，并在当前 Provider 支持对应模型时自动应用。
- **本地执行器多 Profile**：调度台自动发现 `$CODEX_HOME/*.config.toml`、`~/.codex/*.config.toml` 与本机/工作区 `.claude/agents/*.md`，允许项目分别选择 Codex Profile 和 Claude Code Agent，并通过 CLI 官方参数安全传入。

### Changed

- **Goal 顶层概念改为项目**：侧栏、创建页、空状态、命令控制台和删除确认统一使用“项目 / Project”；项目内仍保留 Goal 验收语义与任务 DAG，不把项目误解成一段聊天。
- **项目主操作改为启动执行**：原“启动计划”更名为“启动执行”；执行已经活跃时项目级按钮显示运行状态且不可重复创建任务会话，暂停后可恢复，有待执行节点时可继续。具体任务节点仍允许用户显式启动并行执行。

### Fixed

- **发指令或点击启动后侧栏增加重复项目**：任务运行时会话新增项目/任务归属标记，调度同步只投影顶层项目会话，并通过已持久化任务运行时 ID 清理旧版本遗留的重复侧栏记录。

### Tests

- 新增任务会话不提升为项目、旧重复项收敛、模型/Profile 持久化、CLI Profile 发现与参数安全、会话归属字段 JSON 往返回归；调度、执行器与会话持久化 3 个定向套件共 35 项通过。

### Meta

- 版本号从 **1.213.0-rc2** 提升为功能版本 **1.214.0-rc1**，内部构建号从 **211** 递增为 **212**，Help 与 Computer Use Helper 构建号从 **128** 递增为 **129**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.213.0-rc2 - 2026-07-30

### Fixed

- **智能审核仍要求逐个确认工作区文件**：智能审核现在对已验证位于当前工作区内的创建、编辑和补丁直接落盘，不再依赖 Git 基线、文件跟踪或干净状态；外部与网络操作仍进入智能安全审核，危险操作仍要求明确确认。
- **严格模式菜单位置与语义不一致**：审批菜单调整为“智能审核 → 工作区可写 → 严格模式”，严格模式排在最后，并继续作为唯一对每个工作区文件变更逐次询问的模式。
- **历史待审补丁在智能审核下被丢弃**：智能审核会在下一条消息前应用仍可安全落盘的工作区补丁，不再将其标记为“已被新消息取代”。

### Tests

- 更新智能审核无 Git、脏文件、委托执行器与待审补丁回归用例，并新增严格模式菜单顺序断言。

### Meta

- 版本号从 **1.213.0-rc1** 递增为 bugfix 版本 **1.213.0-rc2**，内部构建号从 **210** 递增为 **211**，Help 与 Computer Use Helper 构建号从 **127** 递增为 **128**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.213.0-rc1 - 2026-07-30

### Added

- **Graph Engineer 图工程调度台**：Goal 任务改为由真实依赖驱动的二维 DAG 画布，提供节点端口、依赖连线、分层布局、缩放、状态图例、任务/验收选择和末端任务汇入验收关卡。
- **结构化节点编辑器**：可新增或修改任务标题、多个前置节点和逐条验收标准；保存前验证依赖合法性并拒绝形成环的计划。
- **验收关卡 Inspector**：单独汇总完成进度、待处理任务、验收标准数量和按任务验收清单，可从关卡详情直接切回对应任务。

### Changed

- **运行时指令退出主画布**：底部聊天式 Composer 改为默认折叠的运行时指令控制台；添加节点、编辑节点、暂停/恢复和缩放成为图工程工具栏的一等操作。
- **选择状态统一**：任务节点、验收关卡与右侧 Inspector 使用同一选择模型，修复点击验收关卡后仍显示旧任务详情的问题。

### Tests

- 新增 DAG 依赖分层、末端关卡连线、多前置节点追加和循环依赖拦截测试；调度专项套件 19 项通过，Debug App 在 macOS 13.7 目标完整编译。

### Meta

- 版本号从 **1.212.0-rc9** 提升为功能版本 **1.213.0-rc1**，内部构建号从 **209** 递增为 **210**，Help 与 Computer Use Helper 构建号从 **126** 递增为 **127**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.212.0-rc9 - 2026-07-30

### Fixed

- **外部执行器只能在终端查看实时进度**：Claude Code、Codex CLI、Cursor Agent 与 Cline CLI 的可见终端 runner 现在每秒读取一次有限日志尾部，先移除终端控制序列并按当前会话密钥脱敏，再把当前动作与最近输出回传到对应工具调用；不会把完整日志或实时尾部写入会话持久化。
- **委托状态长期停留在执行器名称和转圈**：Composer 底部活动行、实时工具时间线、工具详情卡与任务监督栏现在展示执行阶段、当前尝试次数和最近动作；执行器独立验收、WillDeep 二次验收、定点返工与最终交付继续使用宿主已有的真实状态机，不伪造百分比。

### Tests

- 新增外部执行器日志尾部读取、ANSI 控制序列清理、行数/字符边界与实时阶段展示回归测试。

### Meta

- 版本号从 **1.212.0-rc8** 递增为 **1.212.0-rc9**（外部执行器进度反馈 bugfix 仅递增 rc），内部构建号从 **208** 递增为 **209**，Help 与 Computer Use Helper 构建号从 **125** 递增为 **126**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.212.0-rc8 - 2026-07-29

### Fixed

- **调度台 Goal 创建仍然像聊天**：移除创建阶段对 `AgentChatTranscript`、`AgentChatComposer` 和聊天状态栏的复用，改为目标陈述、验收清单、工作区与调度策略摘要组成的结构化工作台；提交后原位切换为任务图。
- **错误产品契约被测试固化**：将“内嵌 Goal 会话”回归测试改为“结构化 Goal 草稿不创建聊天消息”，并同步修正文档中把聊天式创建描述为设计目标的内容。

### Meta

- 版本号从 **1.212.0-rc7** 递增为 **1.212.0-rc8**（调度台体验 bugfix 仅递增 rc），内部构建号从 **207** 递增为 **208**，Help 与 Computer Use Helper 构建号从 **124** 递增为 **125**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.212.0-rc7 - 2026-07-29

### Changed

- **快速构建支持发布架构预热**：`build_fast.rb` 新增 `--destination` 与 `WILLDEEP_XCODE_DESTINATION`，本地仍默认使用 `platform=macOS`；new83d 发布器可显式使用 `generic/platform=macOS` 和相同 Swift 编译模式，为正式多架构 archive 预热 compilation cache。
- **构建提速方案形成正式文档**：新增本地编译、定向/完整单测、CI Runner、缓存布局、实测数据与发布边界说明；README 补充常用命令和完整文档入口。

### Tests

- 扩展快速构建入口契约，覆盖 destination 环境变量及显式命令行覆盖。

### Meta

- 版本号从 **1.212.0-rc6** 递增为 **1.212.0-rc7**（构建/发布集成优化仅递增 rc），内部构建号从 **206** 递增为 **207**，Help 与 Computer Use Helper 构建号从 **123** 递增为 **124**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.212.0-rc6 - 2026-07-29

### Changed

- **本地编译与测试共用热缓存**：新增 `ruby scripts/build_fast.rb`，默认把 Debug 增量编译的 DerivedData、SwiftPM checkout、独立 package cache 与 Xcode compilation cache 放在 `~/Library/Caches/WillDeep/Xcode/Xedit`；本地快速单测和完整单测同步改用同一路径，一次构建可以直接预热后续测试，测试构建也能反向预热本地编译。
- **CLI 编译减负且不影响 IDE 索引**：快速编译默认关闭 index store、跳过依赖更新并锁定 `Package.resolved`，但不修改 Xcode 工程的索引设置；`--index`、`--sign`、`--release` 及现有 `WILLDEEP_XCODE_*` 环境变量可按场景覆盖。
- **本地编译结果可观测**：快速编译接入项目级构建队列，避免多个任务同时争抢 Xcode；每次生成 Markdown、JSON、原始日志与构建守卫报告，记录耗时、缓存目录、签名/索引配置及最终 App 路径。

### Tests

- 扩展快速测试入口契约，覆盖本地编译 action、共享缓存、SwiftPM checkout/package cache 隔离、compilation cache、CLI 索引策略、构建协调器与双格式报告。
- 当前工作区实测 Debug 冷构建 **683.9 秒**，无变更热构建 **24.8 秒**（约快 **27.5 倍**）；模拟单 Swift 文件变更为 **124.7 秒**，恢复已有源码内容时 compilation cache 命中 **2/3** 个任务，`SwiftEmitModule` 从 **59.2 秒**降至 **0.12 秒**，整轮 **24.6 秒**。

### Meta

- 版本号从 **1.212.0-rc5** 递增为 **1.212.0-rc6**（本地构建性能优化仅递增 rc），内部构建号从 **205** 递增为 **206**，Help 与 Computer Use Helper 构建号从 **122** 递增为 **123**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.212.0-rc5 - 2026-07-29

### Changed

- **CI 重型任务拆分并行**：原先全部占用同一台 Mac 的 Ruby 契约守门、Go agent 测试和 Xcode 单测拆为独立 Job；三组 Ruby 守门在 Linux Runner 上并行执行并输出各自的 Markdown/JSON 耗时报告，Go agent 使用独立 Linux Job，Mac Runner 只负责构建测试产物和执行原生单测。
- **Xcode 构建与测试解耦**：Mac CI 统一改用 `XeditUnitTests` scheme，先执行 `build-for-testing`，再执行 `test-without-building`；失败重跑和后续测试分片可以直接复用已构建产物，不再把一次测试执行与一次完整编译绑死。
- **仓库外持久编译缓存**：本地完整/快速测试入口新增 `WILLDEEP_XCODE_DERIVED_DATA_PATH`，CI 将 DerivedData 与 SwiftPM 缓存固定在 Runner 用户缓存目录，避免 `actions/checkout` 清理仓库时一并删除。测试构建默认启用 Xcode compilation cache、关闭 index store，仍可通过环境变量显式覆盖。
- **本地快速测试指纹收敛**：`run_tests_fast.rb --without-building` 只根据 App、单测、Xcode 工程、内嵌 Go agent、Computer Use Helper、Vendor 与构建凭据等真实输入判断产物是否过期；README、CHANGELOG 和测试报告变化不再误伤可复用测试二进制，持久化 stamp 只保存 diff 摘要而不保存整份补丁。
- **超长 Swift 文件按职责拆分**：图像理解回退从 Agent 主循环独立出来，Transcript 搜索/历史文案移入专属扩展，Workflow Report 渲染回归测试也单独成组；原 3071、3034、3001 行文件分别降至 2960、2977、2946 行，重新满足仓库单文件 3000 行硬限制。

### Tests

- 新增 CI 守门分组执行器，为 quality、interaction、short-drama 三组记录逐步状态与耗时；扩展快速测试入口契约，覆盖仓库外 DerivedData、编译缓存和 CI 索引配置。
- quality、interaction、short-drama 守门与 Go agent 全量测试通过；新拆出的 Workflow Report 测试套件 2 项通过，同一构建产物的 `test-without-building` 热路径实测约 13 秒。

### Meta

- 版本号从 **1.212.0-rc4** 递增为 **1.212.0-rc5**（构建与测试流水线性能优化仅递增 rc），内部构建号从 **204** 递增为 **205**，Help 与 Computer Use Helper 构建号从 **121** 递增为 **122**；App、Go agent、Help、Helper、浏览器扩展、响应头契约与产品文档保持一致。

## 1.212.0-rc4 - 2026-07-29

### Fixed

- **Skills 目录被高频重复扫描**：技能发现结果改为进程级线程安全缓存；并发读取共享同一轮加载，只有创建、更新、删除、安装、卸载或显式刷新后才会失效。启用/停用技能只重新应用设置，不再遍历磁盘。
- **Skills 扫描阻塞主线程**：应用启动在 utility 后台任务预热技能目录；Composer 的 `$` 补全、插件选择器和技能设置页均改为异步刷新，避免 `FileManager` 目录遍历与 `SKILL.md` 读取进入 SwiftUI 主线程更新链路。
- **调度台选择工作区后跳到新聊天**：新建 Goal 仍复用独立会话运行时，但工作区选择完成后会恢复调度台目的地，并在调度台内嵌 Goal 创建对话；Goal 定义完成后原位切换为任务图，不再把用户带到普通聊天页。

### Tests

- 新增技能目录缓存复用与显式失效回归测试，以及调度台 Goal 会话目的地、展示域和创建完成选中状态测试；两组定向测试共 30 项通过。

### Meta

- 版本号从 **1.212.0-rc3** 递增为 **1.212.0-rc4**（bugfix 仅递增 rc），内部构建号从 **203** 递增为 **204**，Help 与 Computer Use Helper 构建号从 **120** 递增为 **121**；App、Go agent、Help、Helper、浏览器扩展、响应头契约与产品文档保持一致。

## 1.212.0-rc3 - 2026-07-29

### Fixed

- **Editor 选区文字与底色对比不足**：代码编辑器现在成对使用 macOS 系统语义选区前景色与背景色，不再只叠加浅色底而保留主题中的浅色代码文字；深浅外观均由系统提供匹配的高对比组合。
- **Editor 粘贴小段文本仍有迟滞**：编辑器切换为纯文本编辑模式，同时保留语法高亮所需的程序化富文本属性；关闭拼写、语法和自动补全等与代码编辑无关的 TextKit 检查链路，减少粘贴与输入时不必要的同步处理。未命名 `.txt` 标签页仍直接跳过语法高亮。

### Tests

- 新增编辑器纯文本配置、程序化高亮属性保留和系统语义选区配色回归测试，并覆盖相关 CJK 输入与局部字体修复路径。

### Meta

- 版本号从 **1.212.0-rc2** 递增为 **1.212.0-rc3**（bugfix 仅递增 rc），内部构建号从 **202** 递增为 **203**，Help 与 Computer Use Helper 构建号从 **119** 递增为 **120**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.212.0-rc2 - 2026-07-29

### Fixed

- **侧栏会话标题被硬切、悬停跑马灯停不下来**：放不下的标题静止时恢复为常规的尾部省略号截断，不再把尾部文字直接裁掉；只有指针悬停在确实溢出的标题上时才整段左滚，指针离开立即停止并复位，不再残留无限循环动画。计划卡步骤行共用同一组件，一并修正。

### Meta

- 版本号从 **1.212.0-rc1** 递增为 **1.212.0-rc2**（bugfix 仅递增 rc），内部构建号从 **201** 递增为 **202**，Help 与 Computer Use Helper 构建号从 **118** 递增为 **119**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.212.0-rc1 - 2026-07-29

### Added

- **长测试与构建自动后台执行**：`run_command` 在未显式指定执行方式时，会保守识别 `xcodebuild`、Swift/Go/Cargo、常见前端包脚本、pytest/RSpec、Gradle/Maven、Docker Compose 等测试、构建与开发服务入口，并自动交给后台 Job；显式 `run_in_background: false` 始终强制前台，发布、上传、公证与部署脚本不会仅凭名称被自动后台化。
- **命令活动自然标题**：`run_command` 新增可选 `label`，模型可提供“运行前端测试”“编译 macOS Release”等简短用户可见动作；未提供时，聊天活动行会从受支持的安全命令类型推断“运行测试”“编译项目”或“启动开发服务”，不暴露完整命令及其中的敏感参数。

### Changed

- **后台期间继续无冲突工作**：standard、compact 与 extended 提示词统一要求：启动超过约 30 秒的测试、构建或服务后，简短说明当前进度并继续更新 CHANGELOG、发布说明、API 文档等独立工作；不得修改活动验证正在消费的源码、构建配置、依赖锁、生成输入或版本文件。若这些输入发生变化，旧结果必须标记为过期并重新验证。
- **后台完成自动回到验收**：继续沿用 Job 完成通知与 runtime 自动恢复机制；模型收到完成通知后必须检查结果、诊断失败，并在修复或输入已变化时重跑，不能在通知前宣称任务完成。

### Tests

- 新增长命令自动后台分类、显式前后台覆盖、发布/上传等保守排除、聊天自然标题与敏感命令隐藏、工具 schema 的 `label` 参数，以及三档稳定提示词后台并行与结果失效合同回归。

### Meta

- 版本号从 **1.211.0-rc6** 提升为 **1.212.0-rc1**（后台执行编排与聊天展示属于功能增强），内部构建号从 **200** 递增为 **201**，Help 与 Computer Use Helper 构建号从 **117** 递增为 **118**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.211.0-rc6 - 2026-07-28

### Changed

- **顶层交互收敛为普通 / Goal 两种模式**：移除独立 Plan 模式、复杂任务切换建议、倒计时横幅及计划批准/拒绝门禁。普通模式会按需生成一份可见 Plan 并立即执行；用户在聊天中明确要求“只规划、不要执行”时才停在规划结果，工具安全仍由独立审核模式负责。
- **Goal Plan 验证后自动执行**：Goal Teams 完成证据收集与仲裁后，合法 Plan 直接进入执行阶段，不再等待额外批准。Plan 已完成但 Goal 验收未闭合时继续检查同一目标，不清空步骤、不重新启动 Goal Teams；连续两轮 checklist 无变化则暂停，避免无限循环。
- **计划进度成为跨模式任务状态**：普通与 Goal 对话均可显示同一套 Plan 卡和进度；活动计划拒绝被后续新 `plan` 块静默覆盖，只有用户明确选择修订才替换。

### Fixed

- **宽窗口下 Composer 与聊天内容左右错位**：聊天记录、排队卡、进度卡与 Composer 现在共用同一条居中的可读宽度列，并显式允许在右侧面板挤压时收缩；宽窗口、窄窗口及面板开合时不再出现 Composer 单独向右漂移。
- **“只规划”可能仍从工具侧产生写入**：原生工具循环会拒绝本轮 write/danger 调用，委托给外部执行器时同步使用只规划权限并附加只读合同，不再只依赖模型遵守文字指令。
- **Goal 回复漏掉验收块时可能停在已完成 Plan**：Plan 步骤全部完成但 Goal checklist 仍未闭合时，即使模型本轮没有返回 `goal-check`，宿主也会继续同一验收循环并保留原计划。

### Compatibility

- 旧会话持久化的 `interactionMode: "plan"` 自动迁移为普通模式，旧 `awaitingApproval` Goal Plan 自动升级为执行态；历史提案状态会恢复为可执行 Plan，保留原步骤、对话和进度。

### Tests

- 新增普通模式一次规划后执行、明确只规划意图与工具强制只读、活动 Plan 防覆盖、旧模式解码迁移、Goal 自动执行、同 Plan 继续验收与连续无进展暂停回归；新增 Composer 与聊天记录共用居中可读列的结构回归，并同步更新工具门禁、Computer Use、Design to Code、持久化及提示词测试。

### Meta

- 版本号从 **1.211.0-rc5** 递增为 **1.211.0-rc6**（交互模式状态机 bugfix，仅递增 rc 位），内部构建号从 **199** 递增为 **200**，Help 与 Computer Use Helper 构建号从 **116** 递增为 **117**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.211.0-rc5 - 2026-07-28

### Fixed

- **Release 全量测试误判活动 Plan 合同**：`rc4` 已把误留在 Plan 模式的批准计划锁定为活动执行合同，旧断言却仍要求回退到纯规划提示，导致正确行为在发布门禁中失败。测试现与防止“继续”时重复规划的既定语义一致，并验证原批准步骤不可被静默替换。
- **工具注册表合理增长触发过期预算线**：完整内置工具 schema 的估算已随已发布工具扩展至 35,867 tokens，旧 35,000 上限错误阻断 Release。预算线调整为 37,000，仍保留紧凑余量以捕获非预期 schema 膨胀。

### Tests

- 修正发布全量测试发现的两处过期门禁，并先对 Plan 提示词与工具 token 预算执行定向回归，再重新运行完整 Release 测试套件。

### Meta

- 版本号从 **1.211.0-rc4** 递增为 **1.211.0-rc5**（发布测试门禁 bugfix，仅递增 rc 位），内部构建号从 **198** 递增为 **199**，Help 与 Computer Use Helper 构建号从 **115** 递增为 **116**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.211.0-rc4 - 2026-07-28

### Fixed

- **额度中断或切换模型后重复制定整份计划**：Goal 执行轮此前会在统一清理阶段无条件推进规划周期；当 Plan 已完成、最终 `goal-check` 尚未来得及返回就遇到额度、超时、取消或空响应时，旧 Plan 会被清空，下一模型因而重新启动 Goal Teams。现在失败收尾只保留原 Plan 与进度；切换模型后继续会复用原步骤，只补尚未完成的 Goal 验收，不重复已完成实现。
- **再次“继续”可能覆盖正在执行的 Plan**：复杂追问的自动 Plan 建议此前没有排除已批准或执行中的计划，模型切入 Plan 模式后还可能输出一份替代计划并覆盖原执行契约。现在活动 Plan 会抑制自动重规划；即使会话误处于 Plan 模式，提示词与捕获层也会锁定原步骤。用户只有从 Plan 卡明确选择“修订”时，才会安全退出旧执行合同并重新规划。
- **截断或失败回复仍可能误改 Goal 验收**：旧逻辑虽阻止 `finishReason=length` 的回复推进规划周期，却仍会应用其中已闭合的 `goal-check`；取消和网络错误的清理路径也会无条件采纳已流出的验收块。现在只有当前成功、未截断、闭合且语义有效的回复能改写 checklist；Plan 已完成但仍有未完成验收项时才临时开放剩余验证工具，验收全部完成或 checklist 为空都会重新锁门。
- **无法启动的“重试”提前结算待审补丁**：登录门禁未通过或 provider 并发槽已满时，点击重试此前仍会拒绝或自动应用上轮遗留补丁，即使请求根本没有启动。现在只有全部派发门禁通过、重试确定开始后才结算旧提案。

### Tests

- Goal、Plan、补丁与移动端相关的 6 个定向测试套件共 99 项通过；新增闭合 `goal-check` 配合 `finishReason=length` 时 checklist 保持不变、完整 Goal 不再保留中断验收写权限的组合回归，提示词快照继续维持 v15。

### Meta

- 版本号从 **1.211.0-rc3** 递增为 **1.211.0-rc4**（中断续跑与 Goal 验收状态机 bugfix，仅递增 rc 位），内部构建号从 **197** 递增为 **198**，Help 与 Computer Use Helper 构建号从 **114** 递增为 **115**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.211.0-rc3 - 2026-07-28

### Fixed

- **文件修改看似支持批量、实际仍逐文件审批**：`create_file`、`edit_file`、`apply_patch` 此前在生成第一份内联补丁后立即等待用户决定，严格串行的工具循环因此无法继续生成同轮其余文件的补丁；虽然界面早已有“全部应用/全部拒绝”，真实编辑流程通常永远凑不出第二项。现在同一模型回复中连续、目标路径互不重叠的本地文件修改会先全部进入审核组，再统一暂停一次；后续命令和测试仍会等这批补丁结算后执行，不会读取未批准的文件状态。
- **批量应用可能产生部分写入**：同组补丁现在先合并并校验全部目标与 hunk，再开始写盘；写入阶段若后一个文件失败，会回滚本批此前写入的文件，避免磁盘半提交但界面显示整批失败。同一路径会在工具循环中拆开结算；符号链接/硬链接别名若直到真实路径校验阶段才被识别，会令整组失败且保持文件不变。
- **批次尚未收集完就能提前点击**：第一张补丁卡出现时，同轮后续文件可能仍在生成。审核按钮现在会在批次“收集中”保持禁用，待依赖边界封口、所有相邻独立补丁均可见后一次性开放，消除手快时仍被拆成两轮确认的竞态。
- **停止审批后补丁状态分裂**：取消等待此前只把局部返回值标成“已拒绝”，卡片仍可能显示待审批，模型历史却记录已拒绝，抢先点击还可能令二者再次相反。现在停止会在主线程一次性拒绝整批，同步补丁卡、持久化工具消息、活动工具结果与全部 waiter；终态后迟到的桌面或移动端决定不会再复活补丁。
- **移动端绕过批量原子应用**：手机此前仍逐张批准同批补丁，第二张失效时第一张可能已经写盘，而且服务仍回“批准成功”。现在快照公开稳定 `batch_id`、批次数量及收集状态；任一成员的批准/拒绝都按整批执行，批准失败返回真实 `command.error`，与桌面 Apply All 共用预检、回滚和终态。

### Changed

- Agent 工具提示明确要求把多个独立文件的 `create_file` / `edit_file` 调用放在同一回复中，WillDeep 会将其展示为一张可展开的审核组，并提供一次性的“全部应用/全部拒绝”；危险操作、外部命令、沙箱升权、终端、MCP 与 Computer Use 不进入该文件批次。

### Tests

- 新增并扩展补丁批量审批回归，覆盖两文件同时可见后的全部应用/拒绝、收集期门禁、取消整批后的三份状态一致性、后一个补丁失效或写入失败时文件零部分提交、回滚期外部修改保护、重复真实目标拒绝、批量编辑提示词及允许进入批次的工具集合；移动端覆盖批次元数据、收集期拒绝决策、整批批准与失败真实回传。

### Meta

- 版本号从 **1.211.0-rc2** 递增为 **1.211.0-rc3**（批量文件审核执行时序 bugfix，仅递增 rc 位），内部构建号从 **196** 递增为 **197**，Help 与 Computer Use Helper 构建号从 **113** 递增为 **114**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.211.0-rc2 - 2026-07-28

### Fixed

- **同轮多命令确认卡点击后看似无效**：整轮工具调用会先预亮、再按顺序执行；用户提前批准第二或后续命令时，决定虽然已进入执行队列，但此前暂存字典不会发布界面变更，卡片仍停留在可点击状态。暂存决定现在属于可观察运行时状态，点击后会立即切换为“已提交决定”，并继续按原顺序消费，不会重复执行或唤醒错误的等待项。
- **`tokenhub` 业务标识误判为敏感 Token**：命令敏感参数检测从无边界子串匹配改为凭据词边界匹配，`tokenhub`、`tokenhub-redis` 等普通名称不再被错误升级为 danger 确认；`--token`、secret/credential 文件、`.env`、SSH 私钥与密钥目录仍保持原有强制确认。

### Tests

- 新增审批决定暂存的 `objectWillChange` 回归，覆盖第一条命令正在等待时提前批准后续卡片；使用现场三条 `kubectl -n tokenhub ...` 查询锁定敏感词误判，并反向验证真实凭据参数仍需 typed confirmation。终端 Ruby 烟测同步兼容 `terminal_send_command` 独立策略分支，继续校验命令与控制键均要求审批。

### Meta

- 版本号从 **1.211.0-rc1** 递增为 **1.211.0-rc2**（多命令审批反馈与敏感词误判 bugfix，仅递增 rc 位），内部构建号从 **195** 递增为 **196**，Help 与 Computer Use Helper 构建号从 **112** 递增为 **113**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.211.0-rc1 - 2026-07-28

### Added

- **Computer Use 全局控制会话**：原生 macOS Computer Use 现在以 runtime、turn、目标进程和窗口绑定一份全局独占 lease；主窗口状态卡与跨 App 悬浮控制条同步展示当前任务、目标应用及最新截图，并提供暂停、接管、恢复和停止。不同任务不能同时控制桌面，停止后的同一轮也不能静默重新取得控制权。
- **截图与 Accessibility 双通道闭环**：每次观察和动作都会返回绑定 snapshot 的窗口截图与 Accessibility 元素引用；像素坐标统一相对当前截图映射，窗口移动、尺寸变化、过期 snapshot、跨窗口 ref 均拒绝执行。OpenAI Chat Completions、OpenAI Responses 与 Gemini 的工具结果图片会按各自合法的多模态历史格式回送模型，使模型能基于动作后的真实画面继续判断；发送给 provider 的上下文仅保留最近 4 组工具结果中的截图，完整聊天附件仍按原会话持久化。
- **真实用户输入自动让权**：Helper 会区分自身合成事件和真实键鼠输入；用户在目标应用中操作时，在途动作与截图代次立即失效，控制会话切换为用户接管，模型必须等待恢复并重新获取 fresh state，不能重放被打断的动作。
- **ChatGPT 式短期控制租约**：用户批准当前任务对目标应用的首个普通写动作后，lease 才从只读观察升级为控制；此后同一 runtime、turn、目标应用和 fresh snapshot 下，普通非敏感输入、导航键、滚动、聚焦、悬停以及带 fresh Accessibility ref 的 `none/navigation` 点击可连续执行，不再每个原子动作都要求用户点一次。坐标点击、坐标右键和当前仅支持坐标的拖拽无法证明语义目标，始终逐动作确认。严格模式仍逐次询问，lease 不写入会话授权或持久规则，暂停、接管、任务结束及目标变化都会立即失效。

### Security

- **接管期隐私屏障**：暂停或用户接管期间停止 Computer Use 截图和本机屏幕观察；登录、验证码、凭据、支付等步骤必须由用户私下完成，恢复后只允许从新的已脱敏状态继续。密码、OTP、PIN、CVV、恢复码、助记词、私钥等敏感 Accessibility 值不会进入模型。截图遮罩使用独立于模型 AX 树裁剪的完整子树扫描；读取异常、结构畸形、敏感节点无有效位置、超时或超预算时直接返回空截图并禁用像素坐标，不捕获或保存不确定的画面。
- **目标与动作双重门禁**：Host 与 Helper 均拒绝控制 WillDeep 自身和终端应用，避免 Agent 点击自己的审批卡或借 GUI 绕过命令沙箱；普通动作的免确认只认当前内存 lease、owner runtime、目标进程或应用以及完整 fresh snapshot，点击和右键还必须携带与 snapshot 匹配的语义 ref，不能使用 `computer_use:*`、Goal 模式或持久规则旁路。Return/Enter、删除键、修饰键组合、未知按键、坐标点击/右键及拖拽仍逐动作确认，剪贴板 Copy/Cut/Paste 永久拒绝；发送、删除、购买、授权等高影响操作继续确认，登录、验证码、凭据与金融步骤继续转交用户。

### Tests

- 新增 Computer Use 全局 lease、控制状态机、浮层布局、Helper v6 生命周期、目标/窗口/snapshot 绑定、短期租约自动执行、导航键白名单、严格模式隔离、完整敏感子树扫描与失败关闭、接管竞态、安全策略和三类模型多模态工具结果编码回归测试；Helper 契约脚本同时生成 JSON 与 Markdown 报告。

### Meta

- 版本号从 **1.210.0-rc19** 提升为 **1.211.0-rc1**（新增完整 Computer Use 控制会话与安全接管能力），内部构建号从 **194** 递增为 **195**，Help 与 Computer Use Helper 构建号从 **111** 递增为 **112**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。
## 1.210.0-rc19 - 2026-07-28

### Fixed

- **截图成功后聊天记录没有显示图片**：工具结果通过统一敏感信息脱敏层时，现在会保留原有图片附件。此前脱敏逻辑重建 `AgentToolResult` 时仅复制文字与引用，遗漏 `images`，导致 `capture_screenshot` 已保存原图且回报“图片已附上”，但持久化的工具消息与最终助手消息图片数组均为空；同一问题也可能影响其他截图和产图工具。

### Tests

- `AgentToolsCoreTests` 新增工具结果脱敏回归用例，同时断言敏感文字继续被替换、图片附件保持原样。

### Meta

- 版本号从 **1.210.0-rc18** 递增为 **1.210.0-rc19**（截图附件丢失 bugfix，仅递增 rc 位），内部构建号从 **193** 递增为 **194**，Help 与 Computer Use Helper 构建号从 **110** 递增为 **111**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.210.0-rc18 - 2026-07-28

### Fixed

- **委托外部 CLI 的任务因命令被 pty 截断而永久空等**：分派给 Claude Code / Codex 等外部 CLI 的任务重新通过私有 runner 脚本（0600 权限）执行，可见终端只接收一行 `/bin/sh <runner 路径>` 调用。此前完整的 wrapper 脚本连同提示词被当作键盘输入一次性灌入交互式 shell 的 pty：交互式 shell 会回显每个输入字节、并对超宽 CJK 长行整行重绘，回显量超出可见终端的消费能力后 tty 输出队列积压，进而导致 tty 输入队列溢出、内核静默丢弃剩余字节。shell 因此读到被截断的命令——UTF-8 乱码、临时文件路径断成碎片、单引号未闭合——停在 PS2 续行提示符下永久等待，wrapper 的 status 文件永远不会写出；而 `started` 文件在丢字节发生前已写入，15 秒启动看门狗被骗过，任务只能空等到超时（前台默认 6 小时）。中文提示词每字 3 字节，长任务必然触发，短命令则侥幸无恙，因此故障表现为时好时坏。
- **真实命令的可见性改由输出通道承担**：runner 在执行前把真实命令与 runner 路径回显到终端，供用户审阅。回显走输出方向，不受输入队列溢出影响，且位于 `tee` 捕获的子 shell 之外，因此不会污染 Agent 读取的命令输出。超长命令的回显会按 4000 字符截断（仅影响屏幕显示，执行的始终是完整命令，完整内容可通过回显的 runner 路径查看）。

### Changed

- Agent 终端 tab 的自动化命令通道新增 512 字节硬上限（`AgentTerminalTab.maximumAutomationCommandBytes`），超限时明确报错并提示改用 runner 文件。该修复曾在 1.161.0-rc5 落地、又在 1.166.0-rc2 的合并中被改回内联而复发，护栏用于阻止再次回归。

### Tests

- `AgentDelegatedTerminalRunnerTests` 新增 6 个用例：调用行不超过 pty 输入队列上限且不含换行、真实命令回显到屏幕但不进入捕获日志、runner 文件为 0600 私有权限、屏幕回显截断但执行内容完整、artifacts 清理覆盖 runner 文件；原有长提示词与跨 shell 用例改为断言 runner 文件存在且调用行不内联命令。

### Meta

- 版本号从 **1.210.0-rc17** 递增为 **1.210.0-rc18**（委托终端命令截断 bugfix，仅递增 rc 位），内部构建号从 **192** 递增为 **193**，Help 与 Computer Use Helper 构建号从 **109** 递增为 **110**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.210.0-rc17 - 2026-07-27

### Fixed

- **无 Git 工作区探测导致主线程卡死与 29G 内存占用**：仓库根目录上溯现在会在每次删除路径组件后标准化文件 URL；即使 Foundation 把 `/` 的父路径表示为 `/..`，也会归一化回根目录并立即终止，不再生成无限增长的 `/../../..` 路径与海量小对象。

### Tests

- Git 基线检测回归新增文件系统根目录用例，确保无仓库路径能够稳定返回且不会进入无限上溯循环。

### Meta

- 版本号从 **1.210.0-rc16** 递增为 **1.210.0-rc17**（Git 根目录检测内存失控 bugfix，仅递增 rc 位），内部构建号从 **191** 递增为 **192**，Help 与 Computer Use Helper 构建号从 **108** 递增为 **109**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.210.0-rc16 - 2026-07-27

### Fixed

- **智能审核在无 Git 工作区仍自动写入**：默认智能审核现在要求工作区存在可恢复的已提交 Git `HEAD`，才会自动执行构建、文件生成、委托编码 Agent 及干净已跟踪文件修改；无 Git 或仅执行过 `git init` 但尚未提交时，所有工作区写入均要求确认。
- **审批模式语义含混**：“每次询问”更名为“严格模式”，明确每次写入或外部操作都需要确认；智能审核继续自动执行只读操作，并对 `curl` 等联网或外部操作使用静态规则与 AI 安全判断。用户主动选择“工作区访问”时，不要求 Git 基线，但外部和联网操作仍需确认。
- **新文件绕过严格模式**：新建文件、`apply_immediately` 和干净已跟踪文件统一经过当前审批模式；严格模式及无 Git 的智能审核会保留内联补丁卡，不再直接落盘。

### Tests

- 新增 Git 基线检测、无 Git 智能审核写入门禁、严格模式补丁门禁回归；覆盖只读命令仍自动、Git 工作区构建自动、无 Git 构建询问，以及仅初始化仓库不视为可恢复基线。
- 同步 Computer Use Helper 契约检查到当前 `v5` 协议，恢复发布前自动化守门。

### Meta

- 版本号从 **1.210.0-rc15** 递增为 **1.210.0-rc16**（审批模式与无 Git 写入门禁 bugfix，仅递增 rc 位），内部构建号从 **190** 递增为 **191**，Help 与 Computer Use Helper 构建号从 **107** 递增为 **108**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.210.0-rc15 - 2026-07-27

### Fixed

- **Plan 模式输入“继续”后重新规划**：当已有 `proposed` 计划时，宿主会在消息真实派发边界识别“继续”“执行”“按这个计划执行”及对应英文短指令，原子地批准原计划、切回 Normal 模式并按既有步骤执行；消息即使在计划生成前进入队列，也会在实际派发时依据最新状态正确处理。
- **既有计划未进入后续模型上下文**：Plan 模式会显式固定当前提案并禁止无修改意图的静默覆盖；切换到 Codex CLI、Claude Code、Cursor Agent 或 Cline CLI 等委托执行器时，也会把已批准步骤作为权威执行契约打包，不再只转发一个脱离上下文的“继续”。
- **模糊消息误触发执行**：带附件、来自宿主内部、包含否定或计划修改要求的消息不会自动批准，仍保留在 Plan 模式等待明确决策。

### Tests

- 新增 `AgentPlanContinuationTests`，覆盖中英文批准短语、否定与修改语句、附件和宿主消息保护、既有计划提示词固定，以及委托执行器计划透传。

### Meta

- 版本号从 **1.210.0-rc14** 递增为 **1.210.0-rc15**（Plan 继续执行状态机 bugfix，仅递增 rc 位），内部构建号从 **189** 递增为 **190**，Help 与 Computer Use Helper 构建号从 **106** 递增为 **107**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.210.0-rc14 - 2026-07-27

### Fixed

- **仅打开 Agent 窗口时模型无法激活技能包**：`activate_expert` 的 runtime 查找不再只扫描已注册的编辑器窗口，同时覆盖默认冷启动创建的 headless AppState、当前保留的 orphan AppState 与后台活跃编辑器；Web Programming、Browser Ops 和短剧技能包不再要求用户先打开编辑器或工作区。
- **关闭最后一个编辑器后工具失去会话归属**：runtime 定位统一复用 registry 已有的完整保留状态集合，避免会话仍在运行但工具返回 `No active app session found`。

### Tests

- 新增 `EditorAppStateRegistryTests`，覆盖 Agent-only headless、关闭最后一个编辑器后保留 orphan，以及未知 runtime 拒绝三条路径。

### Meta

- 版本号从 **1.210.0-rc13** 递增为 **1.210.0-rc14**（Agent-only 技能包激活 bugfix，仅递增 rc 位），内部构建号从 **188** 递增为 **189**，Help 与 Computer Use Helper 构建号从 **105** 递增为 **106**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.210.0-rc13 - 2026-07-27

### Fixed

- **桌面宠物常驻动画刷新率高于使用场景所需**：WillDeep 主窗口位于前台时，宠物作为余光元素以 15 FPS 刷新；App 退到后台、宠物成为主要可见界面时切换为 24 FPS。激活与失活通知会即时更新动画调度和消息卡状态，避免依赖轮询延迟，也降低前台常驻 CPU 开销。

### Meta

- 版本号从 **1.210.0-rc12** 递增为 **1.210.0-rc13**（桌面宠物动画功耗 bugfix，仅递增 rc 位），内部构建号从 **187** 递增为 **188**，Help 与 Computer Use Helper 构建号从 **104** 递增为 **105**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.210.0-rc12 - 2026-07-27

### Fixed

- **提示词契约更新后发布测试仍引用旧快照**：终端发送回执与自动回读说明属于有意的稳定提示词变更；现已将提示词契约从 v12 升级为 v13，并按固定 locale 重新记录 standard、compact、extended 三档字节级哈希，恢复发布前全量测试的有效护栏。

### Meta

- 版本号从 **1.210.0-rc11** 递增为 **1.210.0-rc12**（提示词快照同步 bugfix，仅递增 rc 位），内部构建号从 **186** 递增为 **187**，Help 与 Computer Use Helper 构建号从 **103** 递增为 **104**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.210.0-rc11 - 2026-07-27

### Fixed

- **Agent 把终端发送回执误判为输出读取失败**：`terminal_send_command` 明确区分“命令已发送”和“命令输出”；普通命令发送后会自动等待一个短窗口并回读同一终端标签页的最新快照。若首轮快照尚未出现预期输出，工具契约要求稍候再次调用 `terminal_snapshot`，不得据此声称终端不稳定。
- **自动回读失败可能诱发重复执行**：命令已经发送后，即使自动快照超时或标签页状态变化，工具仍返回“已发送且需重新读取”，不会把整个调用标成失败，避免模型重发非幂等命令。

### Meta

- 版本号从 **1.210.0-rc10** 递增为 **1.210.0-rc11**（终端工具回读契约 bugfix，仅递增 rc 位），内部构建号从 **185** 递增为 **186**，Help 与 Computer Use Helper 构建号从 **102** 递增为 **103**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.210.0-rc10 - 2026-07-27

### Fixed

- **本轮报告的工具明细与总数不一致**：报告模型不再永久截断第 9 条之后的工具调用；卡片默认显示前 8 条，调用更多时提供“展开其余 N 条”和“收起”，复制报告也会包含完整工具明细。
- **审批统计容易被误认为工具数量**：“7 自动 / 0 用户”等模糊文案改为“7 自动批准 / 0 用户批准”，明确该指标只统计批准来源，不代表本轮工具调用总数。

### Meta

- 版本号从 **1.210.0-rc9** 递增为 **1.210.0-rc10**（本轮报告展示 bugfix，仅递增 rc 位），内部构建号从 **184** 递增为 **185**，Help 与 Computer Use Helper 构建号从 **101** 递增为 **102**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.210.0-rc9 - 2026-07-27

### Fixed

- **终端环境配置未传给 Agent 命令**：设置 → 终端中的环境变量现在由可见编辑器终端、本地前台 `run_command` 与后台任务共用；配置按行依次合并，重复的 `PATH=` 会基于上一行继续累加，`$VAR` 与 `${VAR}` 会按当时已解析的环境展开。SSH、远程 daemon 等远程运行环境仍独立处理，不会收到本机终端配置。

### Changed

- **终端环境说明补全**：设置页明确提示这些变量同时作用于编辑器终端和本地 Agent 命令，并说明变量按行展开，避免把多段 `PATH` 配置误认为只有最后一行有效。

### Meta

- 版本号从 **1.210.0-rc8** 递增为 **1.210.0-rc9**（终端环境注入 bugfix，仅递增 rc 位），内部构建号从 **183** 递增为 **184**，Help 与 Computer Use Helper 构建号从 **100** 递增为 **101**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.210.0-rc8 - 2026-07-27

### Fixed

- **聊天划词浮层缺少层次感**：选中文本后的「添加到任务」浮层不再依赖嵌入 TextKit 时表现不稳定的系统 popover 材质与 `NSShadow`；改用可控的浅色实底、8pt 圆角、0.5pt 发丝描边和柔和投影，并补齐悬停反馈及深色模式，视觉与 Codex 的轻量胶囊操作条保持一致。

### Meta

- 版本号从 **1.210.0-rc7** 递增为 **1.210.0-rc8**（聊天划词浮层视觉 bugfix，仅递增 rc 位），内部构建号从 **182** 递增为 **183**，Help 与 Computer Use Helper 构建号从 **99** 递增为 **100**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.210.0-rc7 - 2026-07-27

### Fixed

- **正式发布被旧测试契约拦截**：Chrome 标签页截图已归为只读操作，但旧测试仍要求写风险；同步更新风险断言，确保截图不再弹出 WillDeep 确认卡。
- **系统提示词快照未随 WillDeep 技能契约更新**：稳定提示词版本升级为 `willdeep-agent-system-v12`，重新记录 standard 与 extended 配置的确定性哈希，恢复完整发布测试闸门。

### Meta

- 版本号从 **1.210.0-rc6** 递增为 **1.210.0-rc7**（发布回归基线 bugfix，仅递增 rc 位），内部构建号从 **181** 递增为 **182**，Help 与 Computer Use Helper 构建号从 **98** 递增为 **99**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.210.0-rc6 - 2026-07-27

### Fixed

- **截图完成后聊天里看不到图片**：截图工具过去只把图片挂在隐藏的 `role=tool` 消息上，模型能读取像素，但聊天记录只显示助手文字。现在截图附件标记为持久化 capture 产物，并在本轮结束时自动挂到最终助手消息，TextKit 历史与实时聊天都会显示可点击缩略图，重开会话后仍可查看。
- **截图文件仍散落在临时目录或 Application Support**：Mac Helper 临时截图迁移到 `~/.willdeep/tmp/computer-use-captures`，主进程随后把所有平台截图归档到 `~/.willdeep/captures/<截图ID>/original.*`，并保存适合模型与聊天缩略图读取的 `preview.jpg`；删除会话时安全清理对应 capture 目录，不触碰用户上传或工作区生成图片。

### Meta

- 版本号从 **1.210.0-rc5** 递增为 **1.210.0-rc6**（截图持久化与聊天展示 bugfix，仅递增 rc 位），内部构建号从 **180** 递增为 **181**，Help 与 Computer Use Helper 构建号从 **97** 递增为 **98**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.210.0-rc5 - 2026-07-27

### Fixed

- **首次截屏授权前的会话保险不完整**：`capture_screenshot(mac_screen)` 与显式 Computer Use 屏幕权限请求会先读取 Helper 权限状态；尚未授权时，主进程先立即持久化当前运行时并同步排空会话写队列，确认快照已经落盘后才允许 Helper 调用系统授权 API。无会话落盘能力的旁路调用不会触发新的屏幕录制授权。
- **Helper 重启协议与签名身份缺少硬约束**：Helper 协议升级为 `willdeep-computer-use.v5`，统一返回 `needs_helper_restart`；主进程收到后只重启 Helper 并重试一次显示器截图。运行时固定校验 `com.willdeep.computer-use-helper`，正式发布同时校验 Helper Bundle ID 与签名 TeamIdentifier，避免临时签名或身份漂移导致 macOS 反复丢失屏幕录制授权。

### Meta

- 版本号从 **1.210.0-rc4** 递增为 **1.210.0-rc5**（Helper 截屏授权时序与签名身份 bugfix，仅递增 rc 位），内部构建号从 **179** 递增为 **180**，Help 与 Computer Use Helper 构建号从 **96** 递增为 **97**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.210.0-rc4 - 2026-07-27

### Fixed

- **纯截屏错误弹出 WillDeep 逐次确认卡**：`capture_screenshot`、Chrome 标签页截图、Embedded Browser 截图及 Computer Use 只读界面快照统一归为只读工具，已获得系统权限后直接执行，不再因“截图可能包含隐私”错误进入写操作审批；向外部视觉模型发送图片的 `visual_qa_screenshot` 仍保持独立审批。
- **首次 Mac 截屏授权要求重启主 App、打断当前对话**：Mac 显示器截图迁移到独立签名的 Computer Use Helper，主 App 移除屏幕录制用途声明；首次授予 macOS“屏幕与系统音频录制”权限后仅自动重启 Helper 并重试，WillDeep 主进程与当前对话继续保留。Android 与 iOS Simulator 截图链路保持不变。

### Meta

- 版本号从 **1.210.0-rc3** 递增为 **1.210.0-rc4**（截屏授权与审批 bugfix，仅递增 rc 位），内部构建号从 **178** 递增为 **179**，Help 与 Computer Use Helper 构建号从 **95** 递增为 **96**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.210.0-rc3 - 2026-07-27

### Fixed

- **内置技能仍残留外部产品语义与失效命令**：全面审校 39 个 `BundledSkills`，移除旧产品名称、旧配置目录、旧 localhost API 与不存在的 CLI，改用 WillDeep 实际提供的图片、截图、定时任务、记忆、浏览器、Computer Use、会话、MCP 与文件工具；当前无原生能力的音乐、Discord、Telegram 等技能改为先发现已配置 MCP，缺失时明确报告能力边界。
- **技能列表描述与正文能力不一致**：英文/简体中文技能展示文案同步到新的 WillDeep 原生契约，`list_skills` 工具描述改为准确说明内置、用户与插件来源；新增 Ruby 审计器和 Swift 回归测试，检查 frontmatter、禁用品牌词、旧工具名、关键运行时工具存在性与技能发现结果。

### Meta

- 版本号从 **1.210.0-rc2** 递增为 **1.210.0-rc3**（内置技能兼容性 bugfix，仅递增 rc 位），内部构建号从 **177** 递增为 **178**，Help 与 Computer Use Helper 构建号从 **94** 递增为 **95**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.210.0-rc2 - 2026-07-27

### Fixed

- **智能审批仍重复询问无沙箱重跑**：同一条 `run_command` 已通过智能审批、随后被 macOS seatbelt 拒绝时，现在直接自动进行一次无沙箱重跑，不再生成第二张人工审批卡；工具记录与审计日志保留原审批来源，并明确记录自动授权。“每次询问”和会越出授权边界的“工作区访问”仍保持人工确认。

### Meta

- 版本号从 **1.210.0-rc1** 递增为 **1.210.0-rc2**（智能审批无沙箱重跑 bugfix，仅递增 rc 位），内部构建号从 **176** 递增为 **177**，Help 与 Computer Use Helper 构建号从 **93** 递增为 **94**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.210.0-rc1 - 2026-07-27

### Added

- **调度台 Goal 支持右键删除**：从未收到 Goal 指令的空 Goal 可直接删除；已经收到指令的 Goal 会先要求用户确认，确认后停止来源会话及所有已启动 Task，再删除 Goal 和其专属会话，取消确认则任务保持运行。
- **专属会话展示域**：普通工作区会话、调度台会话与专家圆桌会话具备明确且可持久化的展示归属；工作区侧栏不再重复展示调度台 Goal/Task 或专家圆桌生成的会话，旧数据会根据 Goal 模式与圆桌报告自动推断归属。

### Meta

- 版本号从 **1.209.0-rc8** 提升为 **1.210.0-rc1**（新增 Goal 删除与专属会话分区能力），内部构建号从 **175** 递增为 **176**，Help 与 Computer Use Helper 构建号从 **92** 递增为 **93**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.209.0-rc8 - 2026-07-27

### Fixed

- **显式模型胶囊误显示为“省心托管”**：模型胶囊改为直接读取当前会话运行时的托管状态与模型，不再依赖可能滞后的菜单快照；新增回归测试，确认从托管切到 `glm-5.2` 后，当前请求、会话持久化及运行时重载均继续使用 `glm-5.2`。
- **多套 WillDeep 凭据反复弹旧式钥匙串密码框**：Provider/API Key、远程 Runtime token、Composer Secret、MCP/Skill 凭据与 Mobile Gateway token 全部统一到绑定 WillDeep 签名访问组的 macOS Data Protection Keychain，覆盖 `com.willdeep.agent(.debug)`、`com.willdeep.credentials(.debug)` 与 `com.willdeep.mobile-gateway`；旧版 Keychain 凭据首次成功读取后自动迁移，清理旧记录时禁止再次弹框，并增加共享进程缓存，避免一次使用期间重复授权。原有 some.im 共享登录本来已使用独立的 Data Protection Keychain 访问组，保持不变。
- **全并发测试下 Git 命令偶发成功却丢失输出**：stdout/stderr 改为两路独立持续排空，并在子进程退出后等待两路读取完成，消除 `readabilityHandler` 与末尾读取争抢最后一批字节造成的空状态快照；高噪声双管道仍保持无死锁。

### Meta

- 版本号从 **1.209.0-rc7** 递增为 **1.209.0-rc8**（模型状态与钥匙串授权 bugfix，仅递增 rc 位），内部构建号从 **174** 递增为 **175**，Help 与 Computer Use Helper 构建号从 **91** 递增为 **92**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.209.0-rc7 - 2026-07-27

### Changed

- **拆分超长 Agent 主循环文件**：将子 Agent 工具执行、工具消息写入、生成图片附件回挂、工作区失败诊断与终端密码卡判断，从 `AppStateAgentLoop.swift` 提取到独立的 `AppStateAgentToolMessages.swift`；主循环文件从 3092 行降至 2839 行，职责文件为 268 行，行为与调用入口保持不变。
- 退出策略的空闲测试不再实例化会读取持久化媒体任务的 `AppState`，避免测试环境残留的远端任务造成并行用例误判。

### Meta

- 版本号从 **1.209.0-rc6** 递增为 **1.209.0-rc7**（代码健康与测试稳定性 bugfix，仅递增 rc 位），内部构建号从 **173** 递增为 **174**，Help 与 Computer Use Helper 构建号从 **90** 递增为 **91**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.209.0-rc6 - 2026-07-27

### Fixed

- **任务运行中误退出会直接中断工作**：正常退出入口现在会汇总所有活跃/保留 AppState 与后台会话中的模型回复、执行槽等待、上下文压缩、工作流、专家咨询/圆桌、Goal 调度、后台命令、子 Agent 和媒体任务；只要仍有工作进行，就先显示确认框，默认“继续任务”，只有用户明确选择“仍要退出”才继续现有的异步会话落盘与终止流程。空闲退出不增加额外步骤。
- 退出确认文案接入英文与简体中文 String Catalog；新增退出策略回归测试，覆盖空闲不询问、非当前后台会话仍会拦截、取消退出与确认退出。

### Meta

- 版本号从 **1.209.0-rc5** 递增为 **1.209.0-rc6**（活跃任务误退出 bugfix，仅递增 rc 位），内部构建号从 **172** 递增为 **173**，Help 与 Computer Use Helper 构建号从 **89** 递增为 **90**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.209.0-rc5 - 2026-07-26

### Fixed

- **Goal 数据模型只绑定路径、没有固定逻辑项目**：新增持久化的逻辑项目身份，Goal 创建时从会话继承或先选择工作区，顶部固定显示“项目名 · 主项目路径”；执行环境只引用该项目的 checkout 映射，不能替换 Goal 所属项目。
- **跨项目 checkout 可被误绑**：本机映射通过 Git common directory 验证同仓库，另一个仓库会被 AppState 启动前校验拒绝；Task 可独立选择同项目的本机 worktree 或 SSH checkout，失效/越界引用不再回落到主目录。
- **SSH 映射静默采用 Runtime 默认目录**：选择 SSH 环境时必须明确确认该项目在远端的对应目录，空路径不可绑定；任务启动严格使用这条显式映射。
- **旧 Goal 可能被静默补绑**：旧的无工作区 Goal 保持“未绑定工作区”，即使来源会话后来出现工作区也不会自动继承，必须由用户绑定一次后才可发指令或启动计划；旧版未经项目身份确认的 SSH 默认目录映射不会被信任，需重新明确映射。

### Changed

- 未绑定 Goal 的顶部启动按钮改为“请先选择工作区”并保持禁用；绑定后顶部明确展示固定逻辑项目和主路径，工作区菜单只负责添加同项目 checkout。
- 新增逻辑项目持久化、旧数据保守迁移、跨仓库拒绝、SSH 空路径拒绝及 Task 多 checkout 选择回归测试，针对性套件 13 项通过。

### Meta

- 版本号从 **1.209.0-rc4** 递增为 **1.209.0-rc5**（Goal 项目边界 bugfix，仅递增 rc 位），内部构建号从 **171** 递增为 **172**，Help 与 Computer Use Helper 构建号从 **88** 递增为 **89**；App、Go agent、Help、Helper、浏览器扩展、响应头契约与产品文档保持一致。

## 1.209.0-rc4 - 2026-07-26

### Fixed

- **点「新聊天」空态显示迟滞**：空态统计仪表盘（token 用量、工具调用、活跃热力图等）此前每次 SwiftUI body 求值都在主线程全量遍历所有会话的所有消息重算聚合，历史越多切换越慢。现在整套聚合收敛为 `AgentUsageStats.dashboardModel` 一次构建，并由 AppState 按「快照修订号 + 本地日历日」记忆化，快照未变化时渲染直接命中缓存；用量快照维护同步从每次全量排序改为单点有序插入。新增聚合等价性、空输入、缓存失效与新建会话排序回归测试。

### Meta

- 版本号从 **1.209.0-rc3** 递增为 **1.209.0-rc4**（新聊天空态性能 bugfix，仅递增 rc 位），内部构建号从 **170** 递增为 **171**，Help 与 Computer Use Helper 构建号从 **87** 递增为 **88**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.209.0-rc3 - 2026-07-26

### Fixed

- **Goal 与工作区关系缺失**：Goal 必须先绑定本机或 SSH 工作区，才能进入 Goal 模式、发送 Goal 指令或启动任务；新建 Goal 会先选择工作区，旧记录以“未绑定工作区”迁移并提供补绑入口，不再把“这台 Mac”错误显示为工作区。
- **跨环境任务可能落到默认目录**：Goal 可为同一项目显式添加本机或 SSH checkout 映射，环境选择只展示已映射目标；任务运行时使用映射中的精确路径，缺少映射时明确阻塞，不再静默使用 Runtime 默认工作目录。

### Changed

- 调度台顶部、侧栏、任务图、检查器和 Goal 指令区统一展示工作区绑定状态；未绑定状态下禁用启动与指令控件，并提供中英双语说明。
- 新增调度工作区持久化、旧数据兼容、环境映射约束和 Goal 模式门禁测试。

### Meta

- 版本号从 **1.209.0-rc2** 提升为 **1.209.0-rc3**（Goal 工作区绑定 bugfix，仅递增 rc 位），内部构建号从 **169** 递增为 **170**，Help 与 Computer Use Helper 构建号从 **86** 递增为 **87**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.209.0-rc2 - 2026-07-26

### Fixed

- **WillDeep 本地 Shell 的重型 prompt 初始化**：编辑器终端与 Agent Terminal 的本地交互 Shell 现在注入 `CLAUDECODE=1`，可直接命中用户 `.zshrc` 中为 Claude Code 配置的轻量 prompt 分支，避免 powerlevel10k/gitstatus 初始化拖慢首屏；Claude/Codex 委派 Shell、SSH 与无 TTY 后台命令保持原环境，避免执行器误判嵌套会话。终端高级环境设置可显式覆盖或清空该变量。
- 新增终端启动环境回归测试，覆盖本地 Shell 注入、委派 Shell 隔离以及用户覆盖优先级。

### Meta

- 版本号从 **1.209.0-rc1** 提升为 **1.209.0-rc2**（终端启动兼容性与性能 bugfix，仅递增 rc 位），内部构建号从 **168** 递增为 **169**，Help 与 Computer Use Helper 构建号从 **85** 递增为 **86**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.209.0-rc1 - 2026-07-26

### Added

- **Goal-first 调度台**：新增与「已安排」「专家圆桌」同级的调度台入口，把真实 Goal 清单投影为可持久化任务依赖图，并提供 Goal、任务、验收关卡与执行环境的一体化工作台。
- **Goal 运行中交互**：普通指令默认排队到当前步骤结束后的安全点；追加任务、暂停与恢复即时生效；需要立即改变正在执行任务时提供明确的中断确认，并先保存新指令再停止目标执行会话。
- **自动与强制执行器路由**：WillDeep 会按测试、搜索、调试、重构和架构任务自动选择已安装执行器；用户可在 Goal 或单任务层强制指定 WillDeep、Claude Code、Codex、Cursor Agent 或 Cline，指定执行器不可用时明确阻塞，不静默回退。
- **本机与 SSH 执行环境**：复用现有远程 Runtime，调度台可选择本机或 SSH 工作区；SSH 探测新增 Claude Code、Codex、Cursor Agent 与 Cline CLI 能力，并支持通过 daemon 返回同等能力信息。

### Changed

- 调度状态、人工追加任务、执行器与环境覆盖、Goal 指令队列均持久化保存；新增调度核心与远程能力兼容测试，并为全部新增界面文案提供英文和简体中文 String Catalog 资源。

### Meta

- 版本号从 **1.208.0-rc5** 提升为 **1.209.0-rc1**（新增 Goal-first 调度能力，递增次版本），内部构建号从 **167** 递增为 **168**，Help 与 Computer Use Helper 构建号从 **84** 递增为 **85**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.208.0-rc5 - 2026-07-26

### Fixed

- **左侧栏会话标题过早截断**：普通未悬停会话行不再为不可见的固定与归档操作长期预留 40pt，标题可直接使用这段空闲空间；已固定会话仅保留紧凑的固定标记宽度，悬停时仍恢复完整操作区。新增布局回归测试，覆盖普通、固定和悬停三种宽度策略。

### Meta

- 版本号从 **1.208.0-rc4** 提升为 **1.208.0-rc5**（侧栏空间利用 bugfix，仅递增 rc 位），内部构建号从 **166** 递增为 **167**，Help 与 Computer Use Helper 构建号从 **83** 递增为 **84**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.208.0-rc4 - 2026-07-26

### Fixed

- **ZMODEM 下载尚未结束却提前报告完成**：带 `zmodem_upload_paths` 或 `zmodem_download_directory` 的 `terminal_send_command` 不再于命令写入 PTY 后立即返回，而是持有一次性传输票据，等待匹配方向的远端握手、本地 lrzsz 进程终止并排空最终协议输出后才确认成功。下载过程中提前生成、仍在增长的本地文件不再构成完成依据；方向不匹配、握手超时、用户取消、空闲超时、本地进程停滞或非零退出均以工具失败返回。
- **终端快照缺少 ZMODEM 活跃状态**：`terminal_snapshot` 现在返回结构化传输状态；传输中明确标注本地文件可能仍不完整，禁止 Agent 将其作为最终文件读取或向用户报告完成。新增协议完成门禁与握手超时回归测试。

### Meta

- 版本号从 **1.208.0-rc2** 提升为 **1.208.0-rc4**（ZMODEM 完成态 bugfix；`rc3` 已由并行的终端会话停止修复占用，因此继续递增 rc），内部构建号从 **165** 递增为 **166**，Help 与 Computer Use Helper 构建号从 **82** 递增为 **83**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.208.0-rc3 - 2026-07-26

### Fixed

- **活跃终端会话可可靠停止**：运行状态胶囊新增会话控制菜单，可直接发送 `Ctrl-C`、telnet 转义键 `Ctrl-]`、`Ctrl-D`，或明确停止整个会话；终端工具审批签名同步支持新增控制键，自动化占用期间会禁用人工控制并解释原因。
- **终端子进程树不再残留**：关闭标签页或停止本地 PTY 会话时先快照整棵子进程树，依次发送 `SIGTERM` 并关闭 PTY，宽限期后对仍存活且 PID 身份未变化的进程升级 `SIGKILL`，避免 `telnet`、`ssh` 或忽略 TERM 的命令卡住标签页，同时防止 PID 复用误杀。
- 新增控制字符精确字节映射测试，以及真实进程忽略 `SIGTERM` 时的升级清理测试。

### Meta

- 版本号从 **1.208.0-rc1** 提升为 **1.208.0-rc3**（终端会话停止 bugfix；`rc2` 已由并行修复分支占用，因此继续递增 rc）；内部构建号保持 **164**，Help 与 Computer Use Helper 构建号保持 **81**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.208.0-rc2 - 2026-07-26

### Fixed

- **插入密码后高亮误盖整段提示词**：Agent 输入框把 `${secret:...}` 画成受保护胶囊时，若占位符恰好在行尾换行，TextKit 的 `boundingRect` 会返回覆盖首尾行的外接大矩形，视觉上像从整段提示词开头一直选中到密码占位符。现按占位符在每个视觉行中的实际 glyph 片段分别绘制背景与边框，普通文本不再被误高亮；新增单行和换行两类 TextKit 回归测试。

### Meta

- 版本号从 **1.208.0-rc1** 提升为 **1.208.0-rc2**（输入框高亮 bugfix，仅递增 rc 位），内部构建号从 **164** 递增为 **165**，Help 与 Computer Use Helper 构建号从 **81** 递增为 **82**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.208.0-rc1 - 2026-07-26

### Added

- **Agent 本地文件搜索接入 ripgrep 快路径**：`search_files` 与 `grep_files` 优先发现 PATH、Homebrew 和常见安装位置中的 `rg`，通过 `--json` 流式读取匹配并在达到结果上限时及时终止进程；大小写、固定字符串/正则、include glob、512KB 文件上限、工作区相对路径和生成目录排除与原工具语义保持一致。`rg` 不存在、启动失败或正则不兼容时无感回退 Swift 扫描器，远端 workspace 路径不变；新增独立 `AgentFileSearchTests` 覆盖大小写、结果上限、生成目录过滤、子目录相对路径和可执行文件发现。

### Changed

- **冷启动测试构建减负**：
  - 项目构建守卫的排队与互斥锁从 worktree 本地 `.codex-build` 拆到按 Git common dir 派生的仓库级共享目录；主工作树与 Claude/Codex linked worktree 现在共用一个重型构建槽，缓存 manifest、报告和实际产物仍留在各自工作树，避免并发重复冷编译而不冒险共享完整 DerivedData。
  - 新增 `XeditUnitTests` Scheme，只构建 App 测试宿主与 `XeditTests`，常规单测不再把 `XeditUITests` 带入构建图；本地 TestAction明确关闭 coverage。
  - 新增 `scripts/run_tests_fast.rb` 开发入口，复用稳定 DerivedData 与共享 SwiftPM checkout/package cache，锁定 `Package.resolved`、跳过更新检查并输出 build timing；`--without-building` 会核对 tracked diff、未跟踪文件内容、工程、依赖锁、Scheme 与 Xcode 版本指纹，发现任何变化即拒绝旧二进制。
  - `scripts/run_tests.sh` 同步切到 Unit Test Scheme 和稳定包缓存参数；新增 Ruby 合约测试覆盖跨工作树共享协调目录、Scheme 边界、缓存参数和 stale-build 拒绝契约。

### Meta

- 版本号从 **1.207.0-rc2** 提升为 **1.208.0-rc1**（新增 Agent ripgrep 搜索快路径，MINOR +1、rc 归位 rc1），内部构建号从 **163** 递增为 **164**，Help 与 Computer Use Helper 构建号从 **80** 递增为 **81**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.207.0-rc2 - 2026-07-26

### Changed

- **Agent 同回合连续只读工具调用改为并发执行**：系统提示词早已引导模型把独立调用 batch 进一次回复，但工具执行循环仍逐个串行付延迟。现在 Stage 2 执行阶段把同一回合内连续的纯只读工具（`read_file` / `search_files` / `grep_files` / `list_directory` / `glob` / `git_status`）收集成批，用 `TaskGroup` 并发执行（实际 IO 在 `AgentFileTools` 的 detached 任务上真并行），结果按模型原始调用顺序回填 `runtime.toolCalls` 与消息历史（记录本身已在 Stage 1 按序建卡），N 次 grep/read 的串行往返合并为一批。安全边界不变：
  - 只有 `.read` 级、免审批、无副作用、且不可能进入沙箱升权流程的白名单工具参与并发；`run_command` 即便被归类为只读也保持串行（升权提示挂在 runtime 单一 decision waiter 上，并发调用不能共享），`spawn_agent` 走独立派发路径不受影响。
  - write / danger / userInput 级与审批、plan 门禁、workspace 变更等流程全部保持严格串行；遇到第一个非只读调用先把已收集的 read 批次收齐再继续，远程 workspace（SSH/daemon）一律不并发。
  - 中途 Stop 与串行路径同语义：批内每个调用以「Response stopped」落卡收尾，其后未执行的 staged 记录走 `settleUnexecutedStagedCalls` 统一清理，不留悬空 running/审批卡。

## 1.207.0-rc1 - 2026-07-26

### Added

- **Agent 工具审批：整轮预亮卡 + 一键「全部允许」**：
  - **预亮卡**：回合开始时把本轮所有工具调用一次性解析、风控分级并落卡——需要人工审批的 write 级调用同时全部置为待批准，不再是批完第一个才看到第二个。执行仍严格按原顺序、逐个消费各自决策；提前点掉的卡显示「已提交决定，等待执行循环接收」，由执行循环快路径按序接收。
  - **全部允许**：审批卡区域新增批量放行条（同轮 ≥2 张普通 write 审批卡时出现，聊天时间线与侧栏工具组两处入口一致）。danger 级打字确认卡（`awaitingConfirm`）、沙箱升权重试卡（`_sandbox_escalation_request` 标记）、`ask_user` 问答卡、`#1983#` 本地预览卡一律不进入批量放行，保持单卡确认。
  - **同族跟批**：点一张卡的「总是允许 / 本对话允许」后，同族已亮出的其余待批卡自动跟批；候选先按新规则预过滤，只走白名单 / 会话授权等廉价确定性判定，不会为此追加 LLM 裁判往返（避免二次裁判把首判留人工的命令放行）。
  - **门禁语义不变**：plan 门禁 / goal 模式拦截在预亮阶段同步落卡为拒绝，不会闪出可批卡（`ask_user` 保持原有豁免）；工作区切换后的「跳过剩余调用」逻辑移至执行阶段就地结算已亮卡，并丢弃用户提前停在卡上的决策。

### Meta

- 版本号从 **1.206.0-rc9** 提升为 **1.207.0-rc1**（功能新增，MINOR +1、rc 归位 rc1）；App、Go agent、Help、Computer Use Helper、浏览器扩展、README、响应头契约与产品文档同步。

## 1.206.0-rc9 - 2026-07-26

### Fixed

- **Agent 编码回合提速一轮（对标 Codex/Claude Code 的"每步交税"清理）**：
  - **裁判 verdict 缓存**：智能审批的 LLM 裁判对同一「工具 + 命令族」的 YES 结论缓存 30 分钟（上限 256 条、只缓存 allow、按 `AgentCommandAuthorization.signature` 族粒度），同族命令不再每次都付一趟 flash 模型网络往返；danger 级打字确认门在裁判之前，不受缓存影响。缓存命中同样落 `judge.jsonl`（model=`verdict-cache`）保持审计完整。
  - **git 状态刷新按轮合并**：此前每个写类工具（含只读 run_command）执行后都 inline `await` 一次 `git status` 子进程，一轮 6 个编辑付 6 次；现改为非产物工具只置标记、整轮结束统一刷一次（产物工具仍即时刷新以保留其专属基线），变更归因基线不变。
  - **run_command 超时放宽**：前台默认 20s→60s、上限 120s→600s（SSH/daemon 远程后端同步，内部探测保持 20s 快失败）；构建/测试类命令不再必然超时后靠模型重试兜底。超时错误文案改为带指引（转 `run_in_background` 或加大 `timeout_seconds`），阻止模型原样重试。
  - **沙箱失败结构化回传**：真实在 seatbelt 下运行且失败的 `run_command`，工具结果追加 `[sandbox]` 说明（当前模式与读写/网络限制 + "不要原样重试，改用文件工具或说明理由请求升权"），终结模型对 `operation not permitted` 的盲目重试；升权后重跑的失败不会误标（以工具卡 `_sandbox` 实际模式判定）。

### Fixed

- **骨架会话被跨实例误判为已加载，持久化时覆盖真实记录（根因清理）**：`metadataOnlySessions` 是进程级 static，而 `AppState` 有多个实例（主窗口、编辑器注册表、设置窗口、桌宠各一个）。实例 A 的 `loadAll` 把会话标记为仅元数据后，实例 B 的 `load(id:)` 会把该 id 从全局标记中摘除；A 手里仍是 messages 为空的骨架，`materializeAgentSessionIfNeeded` 却因标记已消失而判定"无需补全"，直接返回骨架并在下次持久化时写空。现改为 `loadAllWithMetadata()` 随加载结果一并返回分类，`AppState` 各自持有 `metadataOnlySessionIDs` / `metadataOnlyUserMessageIDs`，补全或持久化后就地清除；会话侧栏与最近会话边栏改为从所属 `AppState` 取判定。1.206.0-rc7 的写入护栏是兜底，此项消除根因。

## 1.206.0-rc7 - 2026-07-26

### Fixed

- **跑一次单元测试就清空用户全部会话历史与用量统计**：`AppState` 把 `agentSessions` 初始化为空数组、磁盘加载走 detached async Task，而 7 个测试文件里共 16 处清理代码在 `AppState` 构造后立刻捕获 `existingIDs`（此刻恒为空集），`defer` 执行时异步加载已把用户全部真实会话填入内存，于是逐个 `AgentSessionStore.delete(id:)` 连同 `catalog-v1` 侧车一起删除。`AgentSessionStore` 又没有测试目录接缝（`AgentAttachmentContentStore` 有），测试直接操作 `~/Library/Application Support/WillDeep/agent-sessions`。用量统计没有独立存储、由会话 JSON 现算，故 token 数、streak、热力图随之归零，表现为"装完新版/过一阵历史就没了"。现为测试进程整体重定向到临时目录（`directoryOverride` + 自动沙盒），并把 16 处清理改为只删本用例创建的会话。
- **空事务覆盖真实记录**：`save` / `saveAsync` 增加护栏——待写会话 `messages` 为空、而磁盘上现有文件仍有消息时拒绝写入并告警。此前多个 `AppState` 实例共用进程级 `metadataOnlySessions` 标记，一旦标记被其他实例摘除，`materializeAgentSessionIfNeeded` 会误判骨架为已加载，直接把空 messages 持久化覆盖整段历史。

## 1.206.0-rc6 - 2026-07-26

### Fixed

- **专家圆桌消息气泡偶发"一字一列"竖排（宽度坍缩）**：`RoundtableSelectableMessageText.sizeThatFits` 此前遇到 nil/无界宽度的理想尺寸探测直接返回 `nil`，回退到 frame 为 `.zero` 的裸 `NSTextView`——SwiftUI 把文本视图当成零宽，HStack 将整列宽度分给相邻的贪婪 `Spacer`，CJK 文本（任意两字间可断行）塌成逐字竖排；流式发言每 80ms 重排一次，反复命中。1.206.0-rc2 的修复（971fba3e，流式气泡复用 TextKit 视图）只覆盖了有限宽度回显路径，未给视图"横向身份"，故仍偶发。现探测提议一律应答文本自然尺寸（按 634pt 上限排版一次，短文本贴合、长文本封顶，带缓存随文本变更失效），气泡在任何布局阶段都占住应有宽度。

### Meta

- 版本号从 **1.206.0-rc5** 提升为 **1.206.0-rc6**（UI 排版 bugfix，按只递增 rc 位处理），内部构建号从 **161** 递增为 **162**，Help 与 Computer Use Helper 构建号从 **78** 递增为 **79**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.206.0-rc5 - 2026-07-25

### Fixed

- **终端 rz/sz（ZMODEM）传输经常卡壳，成套修复**：
  - **握手跨 chunk 漏检**：`**`+CAN+`B` 触发序列此前只在单个 PTY 读块内匹配，SSH 分包把它拆开就整帧漏检——协议帧被当普通输出渲染（屏幕留下 `**B00000000000000`），要等远端 lrzsz 约 10 秒重发才有机会接上。检测器改为流式匹配，保留已渲染尾字节拼接跨界匹配。
  - **传输方向不再靠英文文案猜**：改为解析触发序列后的 ZMODEM 帧类型（hex `00`=ZRQINIT→下载、`01`=ZRINIT→上传，ZBIN32 同理），`rz -q`、非英文 locale、滚动缓冲残留 "ready to receive" 等场景不会再判反方向造成两端同为收/发端的死锁。非握手帧类型（如 ZFIN）与二进制误触发一律放行渲染，不再劫持终端。
  - **传输中有进度、结束有交代**：会话期间每秒向可见终端与 snapshot mirror 输出一行传输进度（字节数），完成时打印「complete: N MB in X s」（此前成功静默、屏幕冻结在握手帧上，看起来像卡死；agent 也只能去文件系统查文件落没落盘）。
  - **空闲看门狗 + Ctrl+C 可打断**：会话 30 秒无双向数据自动中止（向远端发 ZMODEM cancel 连发、终止本地 lrzsz、恢复终端）；传输期间用户键盘输入不再直通远端污染协议流，Ctrl+C 现在同时中止本地与远端。
  - **文件选择面板期间的重入**：`NSOpenPanel` 模态泵 run loop 时远端重发的握手帧此前会再次触发检测、再弹面板/再起一个本地进程写同一 PTY；现在 starting 态统一缓冲，进程起来后一次性回放。
  - **主线程不再同步写管道**：远端字节改经串行队列异步写入本地 lrzsz stdin（带 8MB 背压上限，超限判定本地进程停摆并中止），大文件下载不再有 64KB 管道写满阻塞主线程的 beachball 风险。
  - **`rz -E -y` 矛盾参数改为显式 `-y`**：lrzsz 本就按后出现的 `-y`（覆盖）生效，语义不变，去掉误导。

### Meta

- 版本号从 **1.206.0-rc4** 提升为 **1.206.0-rc5**（ZMODEM 可靠性 bugfix，按只递增 rc 位处理；rc4 已被同日的 Mobile Gateway 死循环修复占用），内部构建号从 **160** 递增为 **161**，Help 与 Computer Use Helper 构建号从 **77** 递增为 **78**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.206.0-rc4 - 2026-07-25

### Fixed

- **Mobile Gateway 发布快照在 macOS 13 上主线程死循环（CPU 100%、内存暴涨）**：`AppState.mobileGatewayRepositoryRoot(for:)` 向上回溯找 `.git` 时，macOS 13 老版 Foundation 的 `deletingLastPathComponent()` 在根目录返回 `/..` 而非 `/`，终止条件 `parent.path == current.path` 永不成立，URL 变成 `/../../..` 无限增长——线上 1.206.0-rc1 (157) 实测卡死：主线程被 `appendingPathComponent` / `URL.path` / `deletingLastPathComponent` 打满，5 分钟内存涨到 18.9GB（sample 采样定位，报告见事故记录）。现对 parent 做 `standardizedFileURL` 归一，并加"路径必须严格变短"兜底守卫。
- **终端候选根目录回溯同款死循环隐患**：`EditorTerminalModels.candidateRoots` 的向上回溯循环终止条件同样未对 parent 做标准化，打开的文件不在工作区内时在 macOS 13 上会无限循环且 `roots` 数组无限膨胀。同步修复。全仓其余回溯循环已排查：`EditorLanguageService.nearestWorkspaceRoot`（已有 standardize）与 `AgentContextBuilder`（有 rootPath 前缀兜底）无此问题。

### Meta

- 版本号从 **1.206.0-rc3** 提升为 **1.206.0-rc4**（主线程死循环 bugfix，按只递增 rc 位处理），内部构建号从 **159** 递增为 **160**，Help 与 Computer Use Helper 构建号从 **76** 递增为 **77**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.206.0-rc3 - 2026-07-25

### Changed

- **CI Xcode 不再锁 26.4.1，对齐 macOS 13.7 self-hosted**：项目本身 `MACOSX_DEPLOYMENT_TARGET = 13.7`，self-hosted runner 可跑在 macOS 13.7 + 本机默认 `Xcode.app`。去掉对 `/Applications/Xcode_26.4.1.app` 的硬选；`Select Xcode` 改为优先 `Xcode.app`，并打印 `sw_vers` 方便核对宿主机系统。

### Meta

- 版本号从 **1.206.0-rc2** 提升为 **1.206.0-rc3**（CI 适配为 bugfix/基础设施修正，按只递增 rc 位处理），内部构建号从 **158** 递增为 **159**，Help 与 Computer Use Helper 构建号从 **75** 递增为 **76**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.206.0-rc2 - 2026-07-25

### Changed

- **GitHub Actions Tests 改回默认 self-hosted runner**：`.github/workflows/test.yml` 的 `runs-on` 从 GitHub-hosted `macos-26` 改为 `self-hosted`（仅默认标签）。Xcode / Metal / setup-go / SPM deploy key 步骤保留；部署目标以仓库 `MACOSX_DEPLOYMENT_TARGET = 13.7` 为准。

### Fixed

- **产物清单在 `/var` 临时目录下变空**：`FileManager.enumerator` 常返回 `/private/var/...`，而 `temporaryDirectory` / 部分工作区 URL 仍是 `/var/...`；`standardizedFileURL` 解不开这对前缀，相对路径全部被跳过、会话产物轨漏检。现对两侧做 `/private` 归一化后再算相对路径。

### Meta

- 版本号从 **1.206.0-rc1** 提升为 **1.206.0-rc2**（CI runner 切换与产物清单路径 bugfix，按只递增 rc 位处理），内部构建号从 **157** 递增为 **158**，Help 与 Computer Use Helper 构建号从 **74** 递增为 **75**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.206.0-rc1 - 2026-07-25

### Changed

- **计划模式改为「只规划、不执行」，执行统一回到普通模式**：以前计划被批准后，会话**留在计划模式**里直接开跑（`plan.status == .approved` 时提示词解锁 write 工具、`isPlanGateActive` 放行），语义上「计划模式」既规划又执行，容易让人以为规划态也会动手。现在计划模式是**纯规划态**——`isPlanGateActive` 在计划模式下**恒为真**，无论计划是 proposed 还是 approved，写/命令类工具一律被闸门拦下（只读调查工具与「已校验公网 GET」照旧放行）。批准计划（计划卡片「批准」或就绪横幅「批准并执行」）会把会话**自动切回普通模式**，被批准的计划随切换保留下来（`setAgentInteractionMode` 对 approved/executing 计划豁免清空），执行合同、步骤进度（```progress``` 解析与自动续跑）全部在普通模式里进行。提示词相应拆分：计划模式注入 `=== PLAN MODE — PLANNING ONLY ===`（明确「计划模式永不执行」），普通模式携带 approved 计划时注入 `=== APPROVED PLAN — EXECUTE ===`（步骤清单 + 进度合同）。就绪横幅去掉「倒计时自动执行」——计划绝不自动开跑，执行必须由用户显式确认（勾选「本工作区不再询问」的除外，那是用户自己的常设选择）；破坏性关键词扫描保留，仅作醒目警示。
- **进入计划模式的建议门槛调高**：本地复杂度打分的直接建议阈值 `minimumScore` 从 **3 提到 4**、flash 二次判定窗口从 `1...2` 收紧到 `2...3`——单个强复杂度词（如「重构」，2 分）加一个弱信号不再自动弹「进入计划模式」，需要多个独立复杂度信号叠加才直接建议；仅 1 分的弱任务现在直接放行普通发送，不再消耗 flash 裁判往返。规范的多范围工程任务（重构 + 迁移 + 测试）仍会建议。

### Meta

- 版本号从 **1.205.0-rc2** 提升为 **1.206.0-rc1**（计划模式语义调整属行为变更、提升 MINOR 位并把 rc 重置为 rc1），内部构建号从 **156** 递增为 **157**，Help 与 Computer Use Helper 构建号从 **73** 递增为 **74**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.205.0-rc2 - 2026-07-25

### Fixed

- **打开大项目时主线程假死（老 iMac / Intel）**：Quick Open 的 `refreshProjectFileList` 虽把扫盘放进了 `Task.detached`，但缓存命中后重建上千个 `URL`、以及扫完后的 `save`/`fileURLs` 仍落在默认 MainActor 的 `Task` 里；再叠加 `URL.appendingPathComponent` 在旧 Foundation 上会逐条 `getResourceValue` 探盘，主线程会被路径拼接占满（spindump 热点即 `appendingPathComponent` / `deletingLastPathComponent` / `path.getter`，进程 RSS 可在十余秒内暴涨数百 MB）。现将 load→重建 URL→scan→save 全部留在 detached 任务，URL 改为纯路径字符串拼接，扫盘阶段只保留 path 字符串以降低常驻内存，并对缓存回填加硬顶。

### Meta

- 版本号从 **1.205.0-rc1** 提升为 **1.205.0-rc2**（主线程假死为 bugfix，按只递增 rc 位处理），内部构建号从 **155** 递增为 **156**，Help 与 Computer Use Helper 构建号从 **72** 递增为 **73**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.205.0-rc1 - 2026-07-25

### Changed

- **扩大本地只读 alwaysSafe 白名单**：补上 `diff`/`realpath`/`jq`/`xxd`/`mdfind`/`lsof` 等无写本地工具，以及 `defaults read`、`unzip -l`、更多 git 只读子命令（`grep`/`merge-base`/`version`…）。它们会自动享受 `readOnly` 下跳过 seatbelt；`curl`/`ssh`/`defaults write`/`unzip` 解压仍保持闸门。

### Meta

- 版本号从 **1.204.0-rc1** 提升为 **1.205.0-rc1**（白名单扩面为行为变更，提升 MINOR、rc 重置），内部构建号从 **154** 递增为 **155**，Help 与 Computer Use Helper 构建号从 **71** 递增为 **72**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.204.0-rc1 - 2026-07-25

### Changed

- **只读白名单命令不再套 seatbelt**：`readOnly` 模式下 `SafeCommand` 判定为 `.alwaysSafe` 的命令（如 `git log` / `shortlog` / `status`、`rg`、`pwd`）直接走 `/bin/sh -c`，仍保留 scrubbed 环境；seatbelt 对只读本就无额外收益，却会误伤 `/dev/null`、xcrun 缓存等。`curl`/`ssh` 等网络或凭据类命令即使读形态也仍套 profile；`workspaceWrite*` 模式行为不变。

### Fixed

- **全量并行下 Git 提交单测偶发读到空 log**：`commitsUnstagedChanges` 对 `git log -1` 增加短重试，避免 fork 压力下 `runGit` 吞 spawn 失败成空串。

### Meta

- 版本号从 **1.203.0-rc1** 提升为 **1.204.0-rc1**（只读命令跳过 seatbelt 为行为变更，提升 MINOR、rc 重置），内部构建号从 **153** 递增为 **154**，Help 与 Computer Use Helper 构建号从 **70** 递增为 **71**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.203.0-rc1 - 2026-07-25

### Added

- **沙箱拒绝后可授权无沙箱重跑**：本地前台 `run_command` 被 seatbelt 拦住（如 `Operation not permitted` / `sandbox-exec:`）时，不再只把失败丢回模型瞎重试，而是弹出审批卡询问「允许无沙箱重跑？」；同意后以 `.escalated` 再跑同一条命令，拒绝则记为 denied。Always Allow 签名命中时跳过二次询问。远端 SSH workspace 不走此路径。

### Fixed

- **全量并行下 Git 审阅范围快照偶发空结果**：`loadsScopedSnapshots` 在 fork 压力下可能读到空的 `git status`；加载侧增加短重试，避免与 `runGitCommand` 的 spawn 退避各说各话。

### Meta

- 版本号从 **1.202.0-rc4** 提升为 **1.203.0-rc1**（沙箱事后提权为新能力，提升 MINOR、rc 重置），内部构建号从 **152** 递增为 **153**，Help 与 Computer Use Helper 构建号从 **69** 递增为 **70**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.202.0-rc4 - 2026-07-25

### Fixed

- **工具活动「✗ N 失败」不再用报警红**：对话历史里已结束命令组的结果徽章（如「已运行 1 条命令 · ✗ 1 失败」）改与活动行同色的 secondary 文案，不再刷 `systemRed`。回合内命令失败很常见、Agent 也会重试，红色会把常态噪声抬成事故感。
- **思考预览单测对齐 reasoning 兜底 headline**：`testAgentLiveThinkingPreview` 仍按旧约定断言「仅有 reasoning 时无当前动作标题」，与现有 Codex 式兜底行为冲突；现改为期望 thinking 标题与 reasoning 最新一行 liveTitle。

### Meta

- 版本号从 **1.202.0-rc3** 提升为 **1.202.0-rc4**（失败徽章告警色降噪，按 bugfix 只递增 rc 位），内部构建号从 **151** 递增为 **152**，Help 与 Computer Use Helper 构建号从 **68** 递增为 **69**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.202.0-rc3 - 2026-07-25

### Fixed

- **沙箱模式下 git 恒失败（EPERM）**：Agent 命令沙箱的 seatbelt profile 是 `(deny default)`，`file-write*` 只放行了临时目录和 workspace 根目录，没放行 `/dev/null`。而 git 几乎所有子命令都会以写模式打开 `/dev/null`（重定向 hook/pager/gpg 探测输出），导致沙箱下 git 一律被权限拒绝。现已在所有沙箱模式下放行 `/dev/null` 与 `/dev/tty` 的写入，并补了 profile 纯函数输出的单测。

## 1.202.0-rc2 - 2026-07-25

### Added

- **会话侧栏标题悬停跑马灯**：会话列表里被截断的长标题，鼠标悬停在该行时向左滚动整段可读（参照 Claude 客户端侧栏的体验），指针移开后回位；放得下的标题静止不动、不抖动。实现上复用计划卡既有的 `MarqueeOnHoverText` 组件，为它新增 `hugWidth` 参数支持「短标题紧贴内容、徽章跟在标题后」的 hug 布局——自然宽度用 NSFont 同步测出，首帧即有正确上限，避免靠 PreferenceKey 回填造成的徽章闪动。双击重命名、tooltip 与原行为保持不变。

### Meta

- 版本号从 **1.202.0-rc1** 提升为 **1.202.0-rc2**（侧栏交互打磨，同属本轮 UI 迭代，按只递增 rc 位处理），内部构建号从 **150** 递增为 **151**，Help 与 Computer Use Helper 构建号从 **67** 递增为 **68**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.202.0-rc1 - 2026-07-25

### Added

- **侧边栏面板可分离为独立窗口**：Agent 右侧辅助栏（终端、内嵌浏览器、文件、Diff、Preview、Plan、Dev Server、任务监控、媒体任务、短剧、网页组件、图片编辑共 12 种面板）的头部新增「分离成独立窗口」按钮，点击后面板从侧栏搬进一个独立窗口（`WindowGroup(for: AgentSidePanelKind.self)`，同种面板同值去重、重复点击聚焦既有窗口）；窗口头部提供「放回侧栏」按钮，在侧栏菜单重新选中同种面板时分离窗口也会自动让位归位。核心不变量是**同一种面板任何时刻只挂载在一处**——终端的 SwiftTerm NSView 与内嵌浏览器的 WKWebView 都是 model 层单实例，分离/归位是「搬家」而非「镜像」，终端进程、浏览器页面在搬动过程中保持存活（终端 tab/进程本就挂在 `AgentInteractiveTerminalController` 单例上，与 View 生命周期解耦）。配套：终端分离期间侧栏让出常驻挂载（避免双宿主抢 superview）；侧面板资源回收 reaper 对分离中的面板一律豁免（分离窗口不更新任何 session 的 `lastViewedAt`，不豁免会把用户正盯着的终端 tab 收走）；分离窗口沿用 `EditorAppStateRegistry.shared.current` 注入 AppState，随工作区切换整棵重建。新增 `AgentDetachedPanelWindow.swift`（分离窗口根视图 + 计数式 `AgentDetachedPanelRegistry`），侧栏内容分发抽出共用组件 `AgentSidePanelKindContent`，侧栏行为不变。

### Meta

- 版本号从 **1.201.0-rc3** 提升为 **1.202.0-rc1**（新功能提升 MINOR 位、rc 重置为 rc1），内部构建号从 **149** 递增为 **150**，Help 与 Computer Use Helper 构建号从 **66** 递增为 **67**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.201.0-rc3 - 2026-07-25

### Fixed

- **中国区中转用户「检查更新」不再永远弹「更新错误」**：Sparkle 的 appcast 地址（`AppUpdateChecker.managedAppcastURL` / `managedUpdateURL`）此前按用户所选 some.im 模型中转区域的 baseURL 拼 host——选「中国区（api.niuwoai.com）」时更新请求打到 `api.niuwoai.com/api/v1/public/app-updates/appcast.xml`，而中转是纯推理网关、无 app-updates 端点，恒 404，每次检查更新都弹「获取升级信息时出现错误」。现按项目既有 control-plane 约定（登录/订阅同级），更新检查 host 钉死 `some.im`（复用 `SomeIMClient.controlPlaneOrigin`，取消 private），两个 URL 构造函数不再接收 settings 参数、从签名上杜绝回归；单测补上 host 断言（此前只断言路径，恰好放过了这个 bug）。注意：**已装出去的旧客户端仍带旧逻辑**，需服务端在 `api.niuwoai.com` 补 `/api/v1/public/app-updates/*` 路由（302 到 some.im 即可）才能让存量用户收到更新。

### Meta

- 版本号从 **1.201.0-rc2** 提升为 **1.201.0-rc3**（更新源 bugfix，只递增 rc 位），内部构建号从 **148** 递增为 **149**，Help 与 Computer Use Helper 构建号从 **65** 递增为 **66**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.201.0-rc2 - 2026-07-25

### Changed

- **会前准备室两个按钮改为等体量·主次分明**：「继续细化」与「框架可以，选择专家」原来一个描边、一个实心且尺寸不一，视觉一强一弱像不同层级的控件。现统一为大尺寸、等宽成对——「选择专家」保持实心强调色作主操作、「继续细化」用描边作次操作，体量一致、层级清晰。
- **准备室配色由固定紫改为跟随系统强调色**：澄清卡、澄清问题底色、主持人（会前主持）图标与输入框描边原来写死 `.purple`，与 App 其它处的强调色身份不一致；现全部改用 `Color.accentColor`，随用户所选界面强调色统一联动（会前准备室背景的氛围渐变光晕保持不变）。

### Added

- **会前准备室也能选本场 provider / 模型**：原来只有进到「选择专家」页才能选，且入口是个不起眼的小 `cpu` 菜单，很多人找不到。现在会前准备室 footer 顶部新增「本场使用的模型」选择器，选定后实时写回 report、带到「选择专家」页作为初值，两处共用同一个可复用组件 `RoundtableProviderModelPicker`，交互与展示完全一致。provider 库为空时（跟随全局活跃 provider）该选择器不显示，与原行为一致。

### Meta

- 版本号从 **1.201.0-rc1** 提升为 **1.201.0-rc2**（准备室 UI 打磨 + 会前选模型入口，功能同属专家圆桌本轮迭代，按只递增 rc 位处理），内部构建号从 **147** 递增为 **148**，Help 与 Computer Use Helper 构建号从 **64** 递增为 **65**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。抽取 `RoundtableProviderModelPicker` 为选专家页与准备室共用组件，选专家页行为不变。

## 1.201.0-rc1 - 2026-07-25

### Added

- **专家圆桌新增「专家资料页」**：讨论态势看板的专家席现在每行可点击，点进去就是该专家的独立资料页。上半区用专家的定位色统一气质，展示大头像、姓名、角色定位、一句话专长与完整人格设定（`systemPersona`：身份 / 思维模式 / 偏见与执念 / 语言口癖）；下半区列出「这位专家参与过的历史讨论」，每条显示议题标题 + 更新时间，按时间倒序排列，点任意一条即跳进那场对话（完成态进文档、会前态进准备、其余进讨论，与主页历史入口同款相位路由）。专家从没参与过讨论时显示明确空态。导航沿用 `RoundtableRoute` 枚举（新增 `.expertProfile` 分支，记住来路、返回原路回到那场讨论），不用 sheet，与圆桌其它页保持一致。

### Meta

- 版本号从 **1.200.0-rc3** 提升为 **1.201.0-rc1**（新增专家资料页为功能新增，按语义化版本提升 MINOR 位并重置 rc），内部构建号从 **146** 递增为 **147**，Help 与 Computer Use Helper 构建号从 **63** 递增为 **64**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。新增 2 项圆桌单测（按专家筛选历史讨论、全体专家身份/人格字段非空）。

## 1.200.0-rc3 - 2026-07-25

### Fixed

- **专家圆桌发言卡首帧不再"一字一行"**：流式发言卡原用无最小宽度地板的裸 SwiftUI `Text`，首帧行宽未解算时被相邻贪婪 `Spacer` 挤成逐字竖排（CJK 可在任意两字间断行放大此问题）。现改走定稿卡同款 `RoundtableSelectableMessageText`（TextKit `sizeThatFits` 按父容器提议宽度权威声明自身宽度），首帧即占满气泡列，流式→定稿过渡也无缝。
- **主持人「你（主持人）」头像不再是空白占位**：改为复用登录的 some.im 账号头像（与侧栏页脚同一 `CachedAvatarImage`）；用户未在 some.im 设置头像、或远程头像加载失败时回退 App 图标。
- **发言卡配色改用专家定位色，满屏反对不再张张发红**：左侧竖线、描边、底色原按 stance 上色（反对=红），一屋子反对时每张卡都发红、与专家席的颜色身份不符；现统一改用发言专家的定位色，立场改由拇指图标表达。
- **支持/反对图标改为拇指 👍/👎**：`RoundtableVisuals.symbol` 全局改为 `hand.thumbsup.fill` / `hand.thumbsdown.fill`（消息卡立场 pill、专家席、立场光谱一并生效）；中立/未定保留原符号。

### Meta

- 版本号从 **1.200.0-rc2** 提升为 **1.200.0-rc3**（四项圆桌 UI 打磨均为 bugfix，按只递增 rc 位处理），内部构建号从 **145** 递增为 **146**，Help 与 Computer Use Helper 构建号从 **62** 递增为 **63**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.200.0-rc2 - 2026-07-25

### Changed

- **右上角计划小卡改为单行 + 悬停跑马灯**：每条计划步骤不再多行换行，统一压成一行显示，避免小卡被长文案撑高、影响一览。鼠标悬停在某条步骤上时，若文字超出卡片宽度，正文会从右向左缓缓流动（跑马灯），把被截断的后半段完整带出来，移开指针即复位；文字本身可容纳时保持静止、不抖动。同时给每条步骤补上原生 tooltip，直接悬停即可看到整条完整文本。

### Fixed

- **「Workspace 访问」模式下网络访问不再频繁弹窗**：`autoApprovalSource` 里 Workspace 访问的白名单判定原先排在 `canSendToSafetyJudge` 的 escalated 短路**之后**，而该短路只放行 `run_command`，导致被沙盒标为 `.escalated` 的 `web_fetch`、`lark_cli` 网络工具虽已列入 `workspaceAccessCanAutoApprove` 白名单却永远命中不到、每次都弹人工授权。现将 Workspace 访问整块判定上移到「打字确认危险门」之后、escalated 短路之前，让白名单条目真正生效；`rm -rf`/`sudo` 等打字确认硬门、未信任 MCP 服务器仍照旧拦截，smart 模式行为不变。
- **「智能审批」判官不再因缺 key 频繁掉线回退人工**：审计日志显示判官掉线 94 次里 72 次是 `missing api key`，全部为直连 DeepSeek——旧的 key 兜底只读 `agentProviderLibrary.activeID` 单个 entry，当判官用的 `agentConfiguration` 与 activeID 在启动/切换 provider 的窗口不同步时就取到空 key。现改为**按判官自身 providerID 匹配 entry 取 key**（优先 active、否则扫同 provider 的 entry），并只从同 provider 取、绝不跨 provider 串 key（规避「DeepSeek key 串到 OpenAI entry」那类历史坑）。再加**兜底降级**：直连 key 仍为空但用户已登录 some.im 时，判官改走 some.im 托管 `someim-auto-flash`（凭据在共享 session Keychain，恰好在直连 key 为空的窗口仍可用），把"缺 key→弹人工"变成"缺 key→托管判官放行"。未登录 some.im 的直连用户行为不变。新增 3 项测试锁契约。

### Meta

- 版本号从 **1.200.0-rc1** 提升为 **1.200.0-rc2**（计划小卡单行跑马灯 UI 优化 + Workspace 访问网络放行修复，均为 bugfix/UX，按只递增 rc 位处理），内部构建号从 **144** 递增为 **145**，Help 与 Computer Use Helper 构建号从 **61** 递增为 **62**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.200.0-rc1 - 2026-07-25

### Added

- **专家圆桌会前准备室**：用户按 Return 抛出议题后，不再立刻开讲。WillDeep 会先精炼真正要决策的问题、整理 3～5 个讨论维度、提出高价值澄清问题，并给出带理由的专家阵容建议；用户可继续用约三行输入框补充背景，确认框架后再进入组队。
- **可编辑的专家组队流程**：AI 默认建议 2～4 位互补专家，用户可从完整专家池自由增删，正式讨论严格要求 2～6 位且必须显式确认。专家池新增法律合规「沈律」、数据研究「林析」、市场增长「夏野」、组织运营「周衡」，各自拥有独立姓名、定位、提示人格、强调色和矢量头像；心理专家升级为行为心理与决策专家。
- **专家正文真流式发言**：每位专家先以自由文本 provider delta 逐字展示可见正文，再由独立结构化任务提取立场、论据、建议和反问状态。正文与模型推理严格分离，首 token 立即显示、80ms 合并刷新、1 秒持久化检查点；分析失败仍保留已经展示的正文。

### Changed

- 讨论页在专家组织观点时继续提前提示「XX 专家即将发言」；首个正文 token 到达后切换为虚线流式发言卡、实时光标和「正在发言」状态，右侧专家席同步从「思考中」变为「实时发言」。
- 圆桌会话新增可恢复的 `.clarifying` / `.selectingExperts` 阶段、可选准备数据和可选流式草稿，旧报告缺少这些字段时仍可解码；正式引擎在用户确认前拒绝启动。

### Fixed

- **专家圆桌讨论不再把主线程跑满**：连续两轮生产采样分别在 `1.199.0-rc1` 与 `1.199.0-rc2` 稳定命中 `GraphHost.flushTransactions → GeometryReaderLayout → sizeThatFits/lengthThatFits`，确认只读 `NSTextView` 在 `updateNSView` 中异步测高、写回每条消息的 `@State` 高度并再次修改 `.frame`，使 `LazyVStack` 布局持续失效。现移除整条高度 Binding 回写链，改由 `NSViewRepresentable.sizeThatFits` 直接按提议宽度返回 TextKit 高度，并缓存相同宽度的测量结果；窗口缩放仍会正确换行，但布局过程不再制造新的状态事务。
- 原生划词引用保持不变；空选区回调增加值去重，避免 `NSTextView` 初始化富文本时向 SwiftUI 重复写入相同的 `nil` 选区。

### Tests

- `AgentRoundtableTests` 增至 26 项，新增只读正文在宽、窄布局下高度确定且宽度感知的测试。
- `roundtable_interaction_contract_test.rb` 增至 10 项，新增静态守卫：禁止恢复 `measuredTextHeight`、异步主队列测高和 `.frame(height:)` 状态回写链，并要求组件保留 `sizeThatFits` 与测量缓存失效入口。
- 新增专家自由文本流管线与草稿缓冲定向测试，覆盖正文／推理隔离、usage 与 finish 元数据、provider 错误、取消、空正文拒绝、UI 节流、检查点、结束和重置。

### Meta

- 版本号从 **1.199.0-rc2** 提升为 **1.200.0-rc1**（新增会前准备、专家组队、真流式发言与专家库扩展，按 feature 提 MINOR 位并重置 rc），内部构建号从 **143** 递增为 **144**，Help 与 Computer Use Helper 构建号从 **60** 递增为 **61**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.199.0-rc2 - 2026-07-25

### Fixed

- **圆桌终稿不再显示成 Markdown 代码块**：终稿入库、旧会话展示和导出统一经过规范化，自动解开 `markdown` 围栏、移除“只读代理/请父 agent 写文件”等交接话术与重复 H1；同时兼容围栏外尾注及旧版部分清洗后遗留的孤立闭合围栏，标题、强调、列表和表格继续交给现有 Markdown 预览组件真正渲染。
- **圆桌结论由 WillDeep 自动落盘**：终稿生成后直接写入 Application Support 下按报告 ID 隔离的 `.md` 文件，文档页显示「已自动保存」并可在 Finder 中定位；旧会话打开文档页时自动回填，写入失败时保留页面正文并显示错误和重试入口。
- 终稿提示词明确要求只返回 Markdown 正文，不调用工具、不声称只读、不要求其他代理代写，也不使用代码围栏包裹全文，从源头降低格式退化概率。
- **产物识别收紧，普通代码变更不再被当成「产物」**：会话右下角活动气泡的「N 个产物」卡片此前把整个 worktree 的**所有**变更文件无差别纳入（`AgentSessionArtifactScope.urls(from:)`），导致 `performance_monitor.go`、`protector.go` 这类普通源码修改也被算作产物。现在气泡卡与任务监控右栏（Rail）对齐：worktree 变更文件必须先过 `isAgentSessionArtifactPath` 白名单（md/pdf/png/mp4/zip 等用户可消费的交付物扩展名）才计入产物，`.go`/`.swift`/`.ts` 等源码变更归入「工作文件」，不再混进产物卡片。

### Tests

- `AgentRoundtableTests` 增至 25 项，新增只读交接话术清理、Markdown 围栏解包、部分迁移残留清理、正常 Markdown 保真和真实 `.md` 文件写入测试。
- 以签名 arm64 Release 打开用户截图对应的真实历史报告复核：页面只保留渲染后的 Markdown，顶部显示「已自动保存」；会话 JSON 与磁盘 `.md` 的规范化结果、H1/H2 结构和文件存在性均通过。

### Meta

- 版本号从 **1.199.0-rc1** 递增为 **1.199.0-rc2**（bugfix，仅递增 rc），内部构建号从 **142** 递增为 **143**，Help 与 Computer Use Helper 构建号从 **59** 递增为 **60**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.199.0-rc1 - 2026-07-24

### Added

- **专家圆桌沉浸式讨论工作台**：讨论区重构为「发言流 + 实时态势看板」双栏。每位专家拥有独立姓名、职业身份、专属强调色和统一生成风格的真人感头像；当前轮到谁思考时，顶部会提前展示「XX 专家要发言了」动态提示，右侧专家席同步点亮，不再让用户面对无反馈的等待。
- **双层引用发言**：专家气泡支持整段引用；正文改用原生可选文本，用户划选任意片段后可直接「引用选中内容」。引用来源、选段和原消息 ID 会随主持人消息落盘并进入后续讨论 transcript，专家能理解用户具体在回应哪句话。
- **多行快捷输入**：圆桌主页与讨论页统一使用约三行高的原生 AppKit 文本输入框；直接按 Return 发起讨论/发送发言，Shift、Option 或 Control + Return 保留换行，兼顾高频提交与多段输入。

### Changed

- 专家发言卡以支持/反对/中立/待定的语义色、图标、标签和左侧色轨进行多重编码，立场不再埋在正文里；建议独立成行动提示，姓名与角色形成明确层级。
- 右侧态势看板新增阶段进度、立场比例条、专家席实时状态与最新 OSR 信号卡；发言中的头像激活、进度和立场分布会随编排状态同步更新，替代原先大面积空白。
- 用户引用会显示为输入区草稿卡和已发送消息内的来源卡，支持取消引用；中英文 UI 文案全部进入 `Localizable.xcstrings`，未在 SwiftUI 视图中硬编码。

### Tests

- `AgentRoundtableTests` 新增引用 Codable/Transcript、旧会话可选字段兼容、六位专家姓名/角色/头像资产唯一性测试。
- 新增 `scripts/roundtable_interaction_contract_test.rb`，以 Markdown 与 JSON 双报告守护 Return 提交、修饰键换行、专家发言预告、六头像资产、立场看板、三行输入和整段/划词引用；本地测试入口与 GitHub Actions 均已接入。21 项定向 `AgentRoundtableTests` 与 9 项交互契约通过，并以签名 arm64 Release 完成真实模型讨论、发言预告、立场看板和划词引用验收。

### Meta

- 版本号从 **1.198.0-rc2** 提升为 **1.199.0-rc1**（新增沉浸讨论与引用能力，按 feature 提 MINOR 位并重置 rc），内部构建号从 **141** 递增为 **142**，Help 与 Computer Use Helper 构建号从 **58** 递增为 **59**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。
## 1.198.0-rc2 - 2026-07-24

### Changed

- **专家圆桌图标换窄**：侧边栏入口与主页标题的图标从偏宽的 `person.3.sequence` 换成更紧凑的 `bubble.left.and.bubble.right`（讨论气泡），不再把「专家圆桌」四个字挤得偏。
- 圆桌主页新增 **示例议题**：输入框下方给 4 个可点的开放议题（辞职做独立开发者 / 免费增值还是买断 / 35 岁转 AI 工程师 / 租房还是买房），点一下填进输入框（不直接发起，留给用户改），降低「面对空输入框不知道问什么」的启动门槛。

### Fixed

- 补齐 rc1 遗漏的中文本地化：`roundtable.detach`（"Open in new window" → 「在新窗口打开」）、等答复横幅、答复占位符、查看文档、失败/取消说明、等你状态等 7 个键此前只有英文默认值、在中文界面露出英文，现已在 `Localizable.xcstrings` 补上 zh-Hans 翻译；示例议题文案同样中英双语。

### Meta

- 版本号从 **1.198.0-rc1** 递增为 **1.198.0-rc2**（bugfix/打磨，仅递增 rc），内部构建号从 **140** 递增为 **141**，Help 与 Computer Use Helper 构建号从 **57** 递增为 **58**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.198.0-rc1 - 2026-07-24

### Added

- **专家圆桌·交互追问闭环**：专家在讨论中判断「缺关键信息、不问主持人就没法给有价值意见」时，可以发起一次反问——讨论**暂停**到「等你答复」（`.awaitingUser`），右下角气泡下方弹出橙色横幅与 2-3 个可点选项，你点选项或自由作答后讨论**自动续跑**。专家发言结构化输出新增 `needsUserInput` / `userOptions` 两个字段驱动这条闭环，并在 prompt 里明确「信息足够时不要滥用反问打断讨论」。
- **可暂停/续跑的编排引擎**：`AgentRoundtableEngine.run()` 改为返回 `awaitingUser` / `completed` 两态，推荐专家、导播开场、逐轮发言、轮末小结、终稿五个阶段**全部按落盘状态幂等**——续跑时跳过已开场/已发言的专家与已出小结的轮次，只补剩下的，绝不重复已完成的阶段，也不会拿失败噪声重跑。答复后由 `submitRoundtableUserReply` 重启一次驱动接着往下跑。
- **应用内嵌入入口**：侧边栏「专家圆桌」不再只能开独立窗口，改为切到与「已安排」同级的嵌入目的地（`AgentPrimaryDestination.roundtable`），在主窗口内直接讨论；嵌入页仍不干扰主 Agent 会话流。嵌入页主页右上角提供「弹出到独立窗口」按钮，两个宿主共享同一份 AppState 与讨论状态。为兼容两种宿主，讨论/文档页的返回、导出改为「页内 chrome」而非 `.toolbar`。

### Changed

- 圆桌**终稿文档**从占位式 `LocalizedStringKey` 拼接改为复用编辑器的 `MarkdownPreviewParser` + `MarkdownPreviewBlockView` **真渲染**：二级标题、列表、表格、代码块与编辑器视觉一致。
- 讨论页 **footer 按阶段区分**：讨论中/等答复显示输入框（占位随阶段切换），收敛后只留「查看文档」按钮，失败/取消显示对应说明，不再让输入框在已结束的讨论上空转。
- 版本号从 **1.197.0-rc1** 递增为 **1.198.0-rc1**（feat 提 MINOR 位并重置 rc），内部构建号从 **139** 递增为 **140**，Help 与 Computer Use Helper 构建号从 **56** 递增为 **57**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- `AgentRoundtableTests` 新增 3 个用例（共 17 个）：无 `needsUserInput` 时不发起反问、带选项时过滤空白选项、`needsUserInput` 为 true 但无选项时按「自由作答」处理，锁定交互追问闭环的结构化解析不变量。

## 1.197.0-rc1 - 2026-07-24

### Added

- 新增独立功能 **「专家圆桌」**：从侧边栏「已安排」下方进入一个独立窗口，抛出一个开放议题，让内置的领域专家多轮讨论、收敛后产出一份文档。它与 composer 里旧「多专家会诊」是两回事——会诊是外部 CLI 只读评审代码方案、绑工作区；圆桌**不绑工作区、不生成代码**，用主模型分角色扮演领域专家做通用讨论。设计借鉴 joingeng（AI 多角色群聊）的三大机制：隐形导播编排、强制二阶互动（点名回应 + 明确表态）防趋同、OSR 结构化驱动态势看板。
- **专家池**：内置六位鲜明人设的领域专家（产品经理林越、技术架构师陈舟、财务顾问苏明、风险分析师何谨、战略顾问江渡、心理教练白桦），每位写入独立的思维模式、偏见与口癖以防趋同。用户只需输入议题，AI 从池中自动推荐 2-4 位并预选。
- **编排**（`AgentRoundtableEngine`）：推荐专家 → 导播开场 → 多轮串行专家发言（每人产出结构化 OSR：议题/态度/论据/建议）→ 导播每轮判断是否收敛 → 收敛或达 5 轮上限后生成终稿。专家发言被强制要求「点名回应至少一位前序、对分歧明确表态、不复述已有结论」。收敛后的文档结构为：核心结论 / 各方立场 / 已达成共识 / 待你决策 / 建议的下一步。
- **界面**：主页（议题输入 + 历史讨论列表）、讨论中（分角色气泡 + @点名 + 立场高亮 + 右侧态势看板：立场光谱）、文档视图（终稿 + 导出 .md）。每场圆桌落为一个独立 `AgentSession`，复用现有 `WorkflowReport.roundtable` 载体与 `AgentSessionStore` 落盘，历史可回看。
- 移除 composer 里的「多专家会诊」入口按钮（`ConsultationButton`）；会诊引擎、类型、Sheet 全部保留——圆桌复用其编排原语（`inertSection`/`boundedPacket`/主模型单次调用）。
- 版本号从 **1.196.0-rc4** 递增为 **1.197.0-rc1**（feat 提 MINOR 位并重置 rc），内部构建号从 **138** 递增为 **139**，Help 与 Computer Use Helper 构建号从 **55** 递增为 **56**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 新增 `AgentRoundtableTests`（14 个用例）：结构化 JSON 输出的分层解析兜底（剥 markdown 围栏、平衡括号提取、噪声容错，吸取 `<think>` 标签泄漏教训）、立场解析（中英/未知）、专家推荐去重与有效性、transcript 渲染剔除失败发言、六人专家池人设互不相同等不变量。

## 1.196.0-rc4 - 2026-07-24

### Changed

- 把 composer「更多设置」面板里的**「专家」分区改名为「技能包」**（英文 `Experts` → `Skill Packs`），消除与「多专家会诊」里「会诊专家」的命名混淆。两者本是完全无关的概念：会诊专家是外部 CLI 评审者（Claude Code/Codex/Cursor），而这里的「技能包」（`AgentExpert`：短剧制作/Browser Ops/Web Programming）本质是**工具能力开关**，改名后语义准确、不再撞词。
- 涉及文案：分区标题、激活态标题（`技能包 %@`）、说明「为当前会话激活技能包。」、锁定提示，以及 `activate_expert` 工具显示名「激活专家」→「激活技能包」。仅改面向用户的中英文案与一处注释，不动枚举名 `AgentExpert`、方法名、工具 key `activate_expert` 等代码契约。
- 版本号从 **1.196.0-rc3** 递增为 **1.196.0-rc4**，内部构建号从 **137** 递增为 **138**，Help 与 Computer Use Helper 构建号从 **54** 递增为 **55**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.196.0-rc3 - 2026-07-24

### Fixed

- 根据生产进程采样结果，修复 Agent 工作区快照在每轮反复逐文件读取、SHA-256 哈希及遍历产物目录导致的持续 CPU 热点：修订守卫改用 `git status -unormal` 避免先展开整棵未跟踪目录，普通文件再按每批最多 256 个路径调用一次 `git hash-object --no-filters`，减少进程与文件句柄往返，同时保留同尺寸内容变化的精确检测；非普通文件继续使用原有状态捕获。
- 工作区修订捕获复用隐藏缓存目录白名单，`.gocache`、`.venv` 等缓存不再参与快照；产物目录树改为只在明确可能生成产物的工具执行前按需扫描，普通工具与委派工具不再无条件遍历最多 50,000 个节点。
- 桌宠 `TimelineView` 动画刷新率封顶为 30 FPS，降低桌宠空闲或轻动画状态下的持续 CPU 占用，同时保持拖动、说话、行走和粒子动画行为不变。
- 版本号从 **1.196.0-rc2** 递增为 **1.196.0-rc3**，内部构建号从 **136** 递增为 **137**，Help 与 Computer Use Helper 构建号从 **53** 递增为 **54**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 扩展 `AgentWorkspaceMutationGuardTests` 与 `GitWorktreeCoreTests`：覆盖隐藏缓存目录条目不改变修订、300 个普通文件跨批次哈希，以及同尺寸内容变化仍被检出；定向运行工作区守卫、Git 工作区与桌宠测试，共 53 个测试通过。

## 1.196.0-rc2 - 2026-07-24

### Fixed

- 修复 **diff 预览把 `.gocache/` 等隐藏缓存目录整个灌进变更统计**、导致「2514 个文件 / 5487 行超阈值」直接触发降级、把用户真正关心的改动淹没在文件摘要外的问题。根因：`AppStateGitStatus.swift` 的 `loadAgentWorktreeChangeSummary` 用 `git status --porcelain=v1 -uall` 收集变更，`-uall` 会把未被 `.gitignore` 忽略的未跟踪目录（如 `.gocache/`）**递归展开成成百上千个文件**，而收集侧只按变更类型（added/untracked…）过滤，**没有任何按路径/隐藏目录的过滤**。
- 修法：新增 `AppState.isHiddenCacheWorktreePath(_:)` 与白名单 `hiddenCacheDirectoryNames`（`.gocache`/`.cache`/`.gradle`/`.venv`/`.mypy_cache`/`.pytest_cache`/`.ruff_cache`/`.tox`/`.terraform`/`.next`/`.nuxt`/`.svelte-kit`/`.parcel-cache`/`.turbo`/`.yarn`/`.pnpm-store`/`.sass-cache`/`.dart_tool`），在 `loadAgentWorktreeChangeSummary` 与 `AgentGitReview.loadChanges` 两条收集路径里跳过「路径任意**目录段**命中白名单」的文件。
- 刻意用**白名单**而非「凡以 `.` 开头的目录一律排除」：`.github`、`.claude`、`.vscode` 这类隐藏目录里放的常是用户真在改的配置，一刀切会误伤；仓库根下以 `.` 开头的**单个文件**（`.gitignore`、`.env`）也不受影响——只按目录段匹配、大小写不敏感。
- 版本号从 **1.196.0-rc1** 递增为 **1.196.0-rc2**，内部构建号从 **135** 递增为 **136**，Help 与 Computer Use Helper 构建号从 **52** 递增为 **53**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 新增 `testHiddenCacheWorktreePathFiltering`，锁定「`.gocache`/`.venv`/`.mypy_cache`/`.gradle`/`.next` 等隐藏缓存目录段被排除，`.github`/`.claude`/`.vscode` 及根下 `.gitignore`/`.env` 放行，大小写不敏感，且名为 `.gocache` 的顶层文件不误伤」这一不变量。

## 1.196.0-rc1 - 2026-07-24

### Added

- Agent 聊天历史里**每个已结束的「意图句」后面现在都带一枚成/败回执章**。此前一轮里 Agent 吐出的「让我运行下一个生成器」「让我核实一下 OpenAPI 规范」「让我进行最后一次全面验证」等**过程性意图句**是普通 `.assistant` 正文，turn 一结束被烘焙进 TextKit 历史时，它触发的工具执行结果被系统性抹掉——用户只看到「我要去干 X」，看不到「X 到底干成没干成」，满屏悬而未决、心里没底。
- 根因：已结束历史里承载工具终态的 `.tool` 结果消息（带 `toolCallStatus` 成/败/拒）在 `AgentChatTranscript` 的 `visibleMessages` 中被整条 `guard` 过滤掉，而意图句上挂的 `toolCalls` 又在 `resultPresentationMessage` 里被 `copy.toolCalls = []` 清空。两道闸门叠加，结果从没进过渲染管线。
- 修法：`AgentChatTranscript.settledTranscriptMessages` 先从被过滤的 `.tool` 消息里按 `toolCallID` 收集每个调用的终态，注入意图句一个**非持久化的瞬态字段** `AgentMessage.settledToolReceipts`（不进 CodingKeys，零落盘风险）；`AgentChatHistoryRenderer.ToolCallHistoryGroup` 据此计算整组回执 `outcomeBadge`（任一失败/拒绝优先展示，否则全成 `✓ 完成`），由 chrome 渲染器拼在折叠工具组行尾——失败态用醒目红色 + 半粗字重。意图句下面因此恢复了折叠工具组行（默认折叠、点击展开看参数），行尾即 `✓ 完成` / `✗ N 失败` / `✗ N 已拒绝`。
- 同步修复活动态 `AgentToolCallViews.statusSummary`：此前**全部成功时返回空串**——最该给用户确定感的「工具全干成了」状态在 UI 上竟是什么都不显示，现改为明确的 `✓ 全部完成`；运行中/失败/拒绝各状态也统一加上 `✓`/`✗` 前缀。
- 缓存正确性：`settledToolReceipts` 纳入 `AgentChatHistoryRenderer` 渲染缓存 key 与 `AgentChatHistoryTextView` 流式热路径指纹，确保工具从 `running → succeeded/failed` 时回执章能即时刷新、不命中旧的无章缓存。
- 约束：本次只对**当前/新会话**生效（内存态 `.tool` 结果在手）。旧落盘会话虽也持久化了 `toolCallStatus`，本轮不做回填，维持现状。
- 新增 `AgentToolReceiptRenderingTests`（9 个用例）覆盖 `outcomeBadge` 成/败/拒/混合/空判定、端到端渲染断言 ✓/✗ 出现，以及回执变更触发渲染缓存失效。
- 版本号从 **1.195.0-rc28** 递增为 **1.196.0-rc1**（feat 提 MINOR 位并重置 rc），内部构建号从 **134** 递增为 **135**，Help 与 Computer Use Helper 构建号从 **51** 递增为 **52**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.195.0-rc28 - 2026-07-24

### Fixed

- 修复 **dark 模式下「淡雾森林」「水墨宣纸」两个浅色皮肤看不到文字**的问题。根因有二：(1) 设置窗口是独立的 `Settings` scene（`XeditApp.swift` 的 `SettingsRootView`），并**没有**施加 `ContentView` / `AgentWindowRootView` 上那条 `.preferredColorScheme(skin.preferredColorScheme)`——系统处于 dark 时，设置窗口整体仍是深色外观；(2) 皮肤卡片 `InterfaceSkinCard`（`EditorSettingsPrimaryTabs.swift`）的背景用的是**半透明** `panelFill`（如淡雾森林 `Color.white.opacity(0.58)`、水墨宣纸 `opacity(0.52)`），直接画在系统深色窗口材质上时深色透上来，浅色皮肤那套**固定深色**的 `primaryText`（淡雾森林深墨绿、水墨宣纸近黑）就糊在暗背景上、对比度不足看不见。其余皮肤要么本身是深色（文字浅）、要么是 `.system`（跟随系统），所以只有这两个浅色皮肤翻车。
- 修法一（卡片自兜底）：`InterfaceSkinCard` 背景先铺一层**不透明**的皮肤窗口底色（`skin.windowBackground` 渐变），再叠原来的半透明 `panelFill`。这样每张卡片都是自成一体的皮肤缩影，文字对比度不再受设置窗口系统外观影响。
- 修法二（设置窗口整体跟随皮肤）：给 `SettingsRootView` 里的 `EditorSettingsView` 补上 `.tint(skin.palette.accent)` 与 `.preferredColorScheme(skin.preferredColorScheme)`，让设置窗口的明暗与所选皮肤一致，从源头消除系统外观与浅色皮肤冲突。
- 版本号从 **1.195.0-rc27** 递增为 **1.195.0-rc28**，内部构建号从 **133** 递增为 **134**，Help 与 Computer Use Helper 构建号从 **50** 递增为 **51**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.195.0-rc27 - 2026-07-24

### Fixed

- 修复聊天记录里「本轮进度」卡片**收起态**紧贴上方正文、上下没有间距的问题。此前 `applyProgressBlockVerticalMargins`（`AgentChatHistoryTextView.swift` 的 chrome 渲染）无条件把「首段加 12pt 上边距」和「末段加 10pt 下边距」拆成两次 `paragraphStyle` 写入。展开态卡片是多段落（表头 + 明细行 + 查看完整计划），首段末段分属不同 paragraph，两次写入互不干扰，间距正常；但**收起态整张卡片只有表头一行、只有一个 paragraph**，于是第二次写入的末段样式（`paragraphSpacingBefore` 为默认 0）直接覆盖了第一次的 12pt 上边距，导致卡片顶着上方文字、毫无留白。
- 现改为参照代码块 / 表格块的处理方式：当卡片首段与末段是同一 paragraph（即收起态）时，把上边距 12pt 与下边距 10pt 合并写进**同一个** `paragraphStyle`，不再互相覆盖；多段落的展开态维持原先的拆分写法。收起、展开两态上下留白现在一致。

### Changed

- 计划模式（Plan / Goal）的**计划卡从对话正文流顶部改为悬浮到右上角**，与「产物 / 媒体 / Dev Server」活动卡竖排共处（`AgentConversationActivityOverlay`），共用同款 `.regularMaterial` 圆角外壳、描边与阴影；**默认收起**，点击卡头在收起 / 展开间切换。此前计划卡平铺在 `AgentChatTranscript` 的 `ScrollView` 顶部，会占布局高度、随消息滚动、并把正文往下挤。
- 计划卡**收起时贴 214pt**（与其余活动卡同宽、竖排整齐），**展开时放宽到 320pt**，让步骤文本、Approve / Reject / Mark Complete 按钮与 Replan 行不至于挤成一团。完成的计划项仍以绿色对勾（`checkmark.circle.fill`）呈现，步骤状态可点按循环（pending → in_progress → done → skipped）等既有交互不变。
- `AgentPlanCard` 新增 `floating` 开关：悬浮上下文（对话活动区）去掉原橙色半透明底 / 橙色描边、改用与产物卡一致的 material 外壳；对话内联挂载点已移除，侧栏（`AgentSidePanelPlanView`）仍保留橙色外观不受影响。
- 展开 / 收起状态改由 `AppState` 上两个一次性触发令牌驱动（`agentPlanOverlayExpandRequestToken` / `agentPlanOverlayCollapseRequestToken`，纯 UI 瞬态、不落盘）：transcript footer 的「查看计划」由原来的 `scrollTo` 定位改为 bump 展开令牌让悬浮卡展开；助手每开新一轮回复时 bump 收起令牌自动折叠计划卡，沿用原「新回合自动收起」行为。
- 版本号从 **1.195.0-rc26** 递增为 **1.195.0-rc27**，内部构建号从 **132** 递增为 **133**，Help 与 Computer Use Helper 构建号从 **49** 递增为 **50**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.195.0-rc26 - 2026-07-24

### Fixed

- 修复会话「产物」栏把**所有写盘文件都当成产物**的误判。此前判据完全不看是哪个工具、以何种意图产生：只要一次工具执行后工作目录里「新出现」一个文件、扩展名命中白名单（md/pdf/png/json/zip 等）、且不在 build/cache 目录，就无差别并入 `agentArtifactPaths`——导致 `run_command` 跑测试/脚本顺手落盘的 `.json`/`.txt`、`create_file`/`edit_file`/`apply_patch` 改的源码、乃至 `git checkout` 检出的文件都被错塞进「产物」栏，还挤占了本该属于「工作文件」栏的位置（两栏互斥）。
- 现改为**只认显式交付物**：给 `refreshGitStatusAfterAgentTool` 增加 `producesArtifacts` 参数，仅当刚跑完的工具属于「显式生成用户交付物」的白名单（`AppState.toolProducesSessionArtifacts`）时，才从目录 diff 里采集新文件作为产物；其余工具（源码编辑、`run_command`、切工作区、委派 CLI 子 Agent 等）照常更新「工作文件」与 worktree 变更，但一律不并入产物栏。
- 白名单刻意收窄，当前只含真正把交付物写进工作目录的短剧导出工具（`short_drama_export_plan_template`、`short_drama_export_production_package`）。生图/生视频/媒体导入等**不**依赖此路径——它们通过 `AgentMediaTaskRegistry` 显式登记产物并下载到 `~/Downloads/WillDeep-*`（工作目录之外），走的是独立的媒体任务产物通路，不受本次改动影响。
- 版本号从 **1.195.0-rc25** 递增为 **1.195.0-rc26**，内部构建号从 **131** 递增为 **132**，Help 与 Computer Use Helper 构建号从 **48** 递增为 **49**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 新增 `toolProducesSessionArtifacts` 白名单测试，锁定「只有短剧导出类工具能从目录 diff 采集产物」这一不变量：验证 `create_file`/`edit_file`/`apply_patch`/`run_command`/`claude_code`/`change_workspace` 以及生图/生视频/媒体任务工具均不进产物栏。

## 1.195.0-rc25 - 2026-07-24

### Changed

- 调整 Agent 授权/确认卡片里 primary（继续 / 允许 / 为本次会话允许）按钮的视觉：从原来的实心填充（`.borderedProminent`）改为 **实线边框、内部不填充颜色** 的描边样式（accent 色 1.5pt 描边 + 透明背景 + accent 色文字）。新增共用的 `AgentApprovalOutlinedButtonStyle`，覆盖三处入口——软性授权通知（`run_command`「继续」等）、双列「命令确认」review 的「允许」、以及对话内紧凑授权条的「为本次会话允许」，风格统一。`AgentApprovalNoticeDescriptor.usesOutlinedApproveAction` 字段保留（仍描述各工具语义、被视觉测试引用），但 primary 渲染不再依赖它——所有 primary 一律走描边样式。
- 版本号从 **1.195.0-rc24** 递增为 **1.195.0-rc25**，内部构建号从 **130** 递增为 **131**，Help 与 Computer Use Helper 构建号从 **47** 递增为 **48**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.195.0-rc24 - 2026-07-24

### Fixed

- 修复聊天记录里「图文混发」用户消息的贴合问题：用户同时发送图片和文字时，图片与其下方文字气泡此前几乎贴在一起、缺少呼吸感。现将「图片段落 → 文字气泡」的垂直间距 `userImageToBubbleSpacing` 从 **8pt** 调大到 **14pt**，三条渲染路径（TextKit 段落 `paragraphSpacing`、SwiftUI 遗留路径 `AgentMessageView` 与 `AgentPanelCards` 的 `.padding(.bottom)`）复用同一常量、间距保持一致。
- 版本号从 **1.195.0-rc23** 递增为 **1.195.0-rc24**，内部构建号从 **129** 递增为 **130**，Help 与 Computer Use Helper 构建号从 **46** 递增为 **47**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.195.0-rc23 - 2026-07-24

### Changed

- 统一所有对外 HTTP 请求的 client 标识（`User-Agent`）为 `some.im/WillDeep-{version} (macOS)`（如 `some.im/WillDeep-1.195.0-rc23 (macOS)`）：`some.im/` 前缀标明请求来自 some.im 系客户端，版本号便于服务端与反代日志按构建分桶。所有走 `AgentNetworkSupport.applyStandardHeaders` 的请求（含全部 some.im 登录/customer/余额/模型/媒体请求）即时生效。
- 更新检查请求原本自行拼装同款 UA、未复用中心常量，现改为复用 `AgentNetworkSupport.userAgentHeaderValue`，client 标识全仓库单一事实来源。
- some.im 的 `client_id`（登录/OAuth 约定的固定标识 `willdeep`）与 OpenRouter 榜单署名 `X-Title` 维持不变，不受本次统一影响。
- 版本号从 **1.195.0-rc22** 递增为 **1.195.0-rc23**，内部构建号从 **128** 递增为 **129**，Help 与 Computer Use Helper 构建号从 **45** 递增为 **46**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 新增 client 标识格式测试，锁定 `User-Agent` 为 `some.im/WillDeep-{version} (macOS)`、含运行时版本、不再出现旧的 `WillDeep/{version}` 形态，并验证 `applyStandardHeaders` 确将其写入出站请求。

## 1.195.0-rc22 - 2026-07-24

### Changed

- 手机网关现在固定走互联网中继，并在 App 启动时就自动连接、常驻在线，不再需要打开「设置 → 账户与设备 → 手机网关」才拉起连接——配对过的手机在任何网络下都能连上桌面，显著提升可用性。
- 「连接方式（互联网中继 / 局域网）」二选一切换及「应用并重启」的模式切换用途已从界面移除；设置页回归纯中继形态，只展示中继状态、配对二维码与轮换按钮。
- 中继连接改由全局单点（`MobileGatewayAutostart`）维持：无论开多少个编辑器窗口，整个进程只保持一份中继连接，避免多窗口向同一房间重复拨号、重复推送。
- 任何历史持久化或手动改写的 `lanGateway` 配置在归一化时都会强制回到中继，保证唯一线路不被旧配置污染；局域网（Go 子进程）相关代码保留为 dormant，暂不提供，日后可恢复。
- 合并 `codex/ui-activity-polish-rc25`：「当前正在做什么」实时状态行补齐 Codex 式宽松兜底（用户参照 Codex 提出）。此前 transcript 底部的扫光动作行只认少数英文阶段动词（Planning/Verifying…），认不出就整行消失——中文 reasoning 或不吐标准状态句的模型全程无实时反馈。现在识别不出阶段动词时，取模型 reasoning 流的最新一行原话（剥 markdown 前缀、超 140 字符截断）作为扫光文本，阶段名记为“思考下一步”；可见回复正文仍不参与状态扫光，composer 状态条同步受益。（该功能原以 rc17/rc19 独立编号提交，合并进 rc22 版本线，原版本号不再单列。）

### Fixed

- 手机网关桌面 peer 新增系统网络路径监听（`NWPathMonitor`）：网络切换或 Mac 睡眠唤醒后，网络路径一旦恢复即立即重连，把「掉线到重新在线」的空窗从最长约 30 秒的指数退避压缩到数秒，无网络事件时仍保留指数退避兜底。
- 版本号从 **1.195.0-rc21** 递增为 **1.195.0-rc22**，内部构建号从 **127** 递增为 **128**，Help 与 Computer Use Helper 构建号从 **44** 递增为 **45**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 新增测试锁定：`lanGateway` 配置解码后归一化强制回到 `.relay`，以及经 store 落盘再读回也恒为中继，防止局域网线路被历史配置意外重新激活。
- 随 `codex/ui-activity-polish-rc25` 合入 `makeLive(fromReasoning:)` 回归（可识别行照常命中语义阶段、中文原话宽松兜底、markdown 剥除、超长截断、空内容拒绝）与实时动作行断言。

## 1.195.0-rc21 - 2026-07-24

### Fixed

- 修复当前回合活动时间流中的“运行命令失败”只能显示为静态摘要、无法点击查看命令和失败原因的问题。
- 每条失败命令现在都能独立展开，展示完整命令、工作目录、已捕获输出，以及包含退出码与 stderr 的错误信息；若失败命令同时是时间流的折叠入口，首次展开也会保留最近活动上下文。
- 版本号从 **1.195.0-rc20** 递增为 **1.195.0-rc21**，内部构建号从 **126** 递增为 **127**，Help 与 Computer Use Helper 构建号从 **43** 递增为 **44**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 新增失败命令详情呈现测试，锁定命令、工作目录、输出和退出原因在时间流详情中可供审计。

## 1.195.0-rc20 - 2026-07-24

### Fixed

- 修复用户点击补丁卡片 Apply 后，上游模型仍收到旧 `pending` 工具结果并重复要求审批的问题；补丁工具现在等待卡片作出 Apply 或 Reject 决定，再继续当前模型回合。
- 审批结果会同步回写持久化的 `role=tool` 消息与实时工具调用记录；已批准补丁明确标记为 `applied`，拒绝与应用失败也分别携带真实状态，避免后续回放继续传播过期信息。
- 版本号从 **1.195.0-rc19** 递增为 **1.195.0-rc20**，内部构建号从 **125** 递增为 **126**，Help 与 Computer Use Helper 构建号从 **42** 递增为 **43**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 新增手动补丁审批回归测试，覆盖 Apply 写入文件、解除工具等待、上游最终收到 `applied` 结果，以及旧 `pending` 消息和工具记录同步改写为 `applied` 的完整链路。

## 1.195.0-rc19 - 2026-07-24

### Fixed

- 修复 some.im 已有昵称与头像、WillDeep 账号菜单却长期只显示邮箱首字母的问题：账户资料新增独立刷新时间，旧缓存或缺少资料时立即补拉 `customer/me`，不再被每次模型响应写入的余额更新时间错误延后。
- 资料成功同步后按 15 分钟低频校验，接口暂时失败时保留已有昵称与头像，并由 4–7 分钟抖动循环继续恢复。
- 版本号从 **1.195.0-rc18** 递增为 **1.195.0-rc19**，内部构建号从 **124** 递增为 **125**，Help 与 Computer Use Helper 构建号从 **41** 递增为 **42**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 新增当前 some.im `customer/me` 资料结构的昵称/头像水合回归，以及“余额刚更新但资料缺失/过期仍必须刷新”的独立时钟边界测试。

## 1.195.0-rc18 - 2026-07-24

### Fixed

- Composer 上方“委派给子代理”活动条不再使用写死的紫色，文字、图标、浅色背景与描边统一跟随 macOS 系统强调色。
- 展开工具调用后显示的子代理模型与进度徽标图标同步改用系统强调色，避免同一委派状态出现两套色彩语义。
- 版本号从 **1.195.0-rc17** 递增为 **1.195.0-rc18**，内部构建号从 **123** 递增为 **124**，Help 与 Computer Use Helper 构建号从 **40** 递增为 **41**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 新增子代理委派色彩回归测试，锁定活动条与工具卡徽标必须使用系统强调色。

## 1.195.0-rc17 - 2026-07-24

### Fixed

- Token 活动热力图改为按每天真实或估算 Token 总量着色，不再误用消息条数；每日、每周与累计三种视图统一采用 Token 口径。
- 鼠标悬停任意热力格会显示本地化日期与当天 Token 用量，例如“7月10日 使用了 10.3亿 个 Token”；同一文本也作为辅助功能标签。
- 修复 `heatmap-cell.tooltip` 本地化资源缺少格式占位符，导致日期和数值虽已传入却只显示静态“该日期的消息数”的问题。
- 版本号从 **1.195.0-rc16** 递增为 **1.195.0-rc17**，内部构建号从 **122** 递增为 **123**，Help 与 Computer Use Helper 构建号从 **39** 递增为 **40**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Changed

- 将统计面板本地化门面迁入独立 `L10n+StatsDashboard.swift`，使 `L10n.swift` 重新低于 3000 行硬限制，文案键与调用方式保持不变。

### Tests

- 更新热力图聚合测试，锁定跨日期 Token 合计；新增 tooltip 回归测试，确保悬停文案始终包含日期和 Token 数。

## 1.195.0-rc16 - 2026-07-24

### Fixed

- 对话历史中的工具活动摘要不再把“读文件、浏览目录、搜索代码、Git 状态、运行命令”等操作挤进一条点号分隔的长句，改为 Codex 风格的逐类分行时间流，窄窗口也能快速扫读。
- 每类活动使用语义化 SF Symbols 和统一的次要文字层级，行距与助手正文对齐；整行继续支持点击展开原始工具详情，折叠态仍隐藏文件路径、搜索词和命令内容。
- 版本号从 **1.195.0-rc15** 递增为 **1.195.0-rc16**，内部构建号从 **121** 递增为 **122**，Help 与 Computer Use Helper 构建号从 **38** 递增为 **39**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 新增已结束工具活动的分行语义与图标映射测试，并更新折叠/展开、正文对齐和 684×319 生产 TextKit 截图回归；参考图与实现图完成同画布视觉对照。

## 1.195.0-rc15 - 2026-07-24

### Fixed

- 新聊天信息卡按 Codex 个人活动页重新还原：移除重复问候与面板外框，顶部展示 some.im 账号头像、昵称、账号和方案；五格摘要条改为累计 Token、峰值 Token、最长任务时长、当前连续天数与最长连续天数。
- Token 活动区扩展为 52 周 × 7 天热力图，并提供每日、每周、累计三种真实可切换的统计视图；月份标签、格子密度、蓝色强度和分区留白按参考截图校准。
- 底部双栏改为活动洞察与最常用插件排行，展示快速模式占比、推理强度、已探索技能、技能使用总数和任务总数；插件排行保留真实工具账本，使用 SF Symbols 与调用次数呈现。
- 累计 Token 指标可点击进入既有模型用量明细，避免视觉还原导致原功能消失；相关文案补齐英文与简体中文本地化。
- 版本号从 **1.195.0-rc14** 递增为 **1.195.0-rc15**，内部构建号从 **120** 递增为 **121**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 更新新聊天卡视觉常量回归与生产 SwiftUI 截图用例；使用 568pt 生产宽度对齐参考截图，覆盖五格指标条、52 周热力图和五行插件排行。

## 1.195.0-rc14 - 2026-07-24

### Fixed

- 加固三组负载敏感的 flaky 测试，修复 `release_mac_app.rb` 全量并行（1497 用例）时随机红、单独跑必过、两次阻断发布管线的问题：
  - `AgentStopHandlingTests`「cancelling a foreground command terminates its process promptly」：耗时改为从 `task.cancel()` 起算（进程 spawn 在 fork 风暴下不受测试控制），阈值从 3 秒放宽到 15 秒——仍远低于 `sleep 30` 自然结束与 35 秒超时，"TERM 及时生效"的语义不丢（满载实测该用例总耗时 4.4–5.1 秒，旧阈值每轮必红）。
  - `AgentQueueModeTests.queuedMessageCancellationFallbackReleasesStuckTurnSlot`：`scheduleQueuedMessageConsumptionAfterCancellation` 改为返回内部 Task（`@discardableResult`，生产调用方行为不变），测试显式 `await` fallback 扫描完成后再断言，删除满载下等不到扫描执行的 3 秒盲轮询。
  - git 类测试（`GitWorktreeCoreTests` / `AgentGitReviewTests`）随机互扰的根因是 `AppState.gitCommandTimeout` 默认 5 秒在满载 fork/exec 拥塞下被随机击穿，`runGit` 超时静默返回空串导致断言缺文件且失败集合每轮不同；现检测到 XCTest 环境时统一放宽到 60 秒，产品运行时仍为 5 秒。临时仓库本就按 UUID 隔离，无共享状态，两个 suite 保持既有 `.serialized` 不变。
  - 同族低频路径：满载 fork 风暴下 `process.run()`（posix_spawn）可能瞬态失败（EAGAIN），同样被 `runGit` 吞成空串（合并验证轮实测击中 worktree diff preview 用例一次）；`runGitCommand` 现对 spawn 失败做最多 2 次带退避重试，真正跑起来后的失败（非零退出、超时）不重试、语义不变。
- 恢复 rc10 为解锁发布而删除的「Terminal host-verification popover cannot auto-focus its copy action」焦点巡检覆盖：锚点从已不存在的 `Button(action: copyAction)` 更新为 1.194.0-rc1 重构后 `AgentHostIdentityPopover` 的 `tab.extractHostIdentity()` 按钮，`.buttonStyle(.plain)` 后紧跟 `.focusable(false)` 的焦点策略校验原样保留。
- 修复 `AgentHeaderEditorEntryTests` 被 `--skip-tests` 发布漏检的死断言：rc10 起菜单项写法变为 `Button(L10n.Menu.viewShowEditor, action: showEditorAction)`，断言放宽为前缀匹配，「Editor 入口只在应用菜单」的语义不变。
- 版本号从 **1.195.0-rc13** 递增为 **1.195.0-rc14**，内部构建号从 **119** 递增为 **120**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.195.0-rc13 - 2026-07-24

### Changed

- 设置窗口信息架构重组：新增顶层「编辑」标签，收拢编辑行为类设置——行号显示、当前行高亮（原混在「外观」的玻璃效果区）与保存行为（去尾随空白、末行换行，原藏在「工作区」）；「格式与外观」标签保持皮肤/主题/壁纸/字体排印，并把 **Agent 聊天字号**从「AI → Agent」提供商设置深处移入「字体排印」页，与编辑器文本、工作区文本并列成三段。深链（`EditorSettingsTab`）全部保留，旧入口自动解析到新分组。

### Fixed

- 专注模式不再隐藏编辑器标签栏：此前进入专注模式正文首行会顶进窗口红绿灯按钮底下（标签栏自带的红绿灯避让随栏一起消失），且无法切换标签。现在专注模式保留标签栏，只隐藏侧栏/检查器/终端等其余 chrome。

### Changed

- 版本号从 **1.195.0-rc12** 递增为 **1.195.0-rc13**，内部构建号从 **118** 递增为 **119**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- `SettingsInformationArchitectureTests` 更新到新分组结构（含「编辑」组断言）；`EditorTabBarFocusPolicyTests` 新增源码巡检钉住"专注模式不得隐藏 EditorTabBar"。

## 1.195.0-rc12 - 2026-07-24

### Fixed

- 大幅降低自学习的触发频率并提高建议价值门槛（用户实测"随便一句话就弹学习，学的全是废话"）：
  - 框架规则类记忆建议（"Agent should call add_memory/create_user_skill/inspect MCP…"）只认**用户原话**——此前判定文本混入最近 3 条 assistant 消息，助手行文里的"建议/以后/自动/集成"天天把关键词闸门撞开；并删除完全不受强意图闸约束的硬编码套话 "Agent should proactively save necessary memory…"（截图实锤的噪声源，存下来只是把产品自身运行策略当经验）。
  - MCP 发现建议要求**阻塞词、能力词、集成语境词同句共现**——此前全文任意位置"缺少/missing"配任意位置"数据库/mysql"即触发（普通排障对话"该表缺少索引"即中招）；"帮我做 MCP 发现"类泛化指令只认用户原话。同时删除与 MCP 建议事件重复的 external-integration-gap 套话记忆。
  - 自动记忆候选只从**用户句子**里抽取（不再挖 assistant 回复，杜绝把 markdown 表格行拍成记忆），标记词表剔除高误报词（"use "/"should"/"遇到"/"自动"/"自主"/"workflow"/"skill"/"mcp"）。
  - 学习事件按（类型+标题+内容）**会话内去重**，同一条建议不再每回合重复弹 popover。
  - 清理无调用方的 `AgentMemoryState.addAutomaticMemories`（rc16 改为 draft 审批制后遗留的死代码）。

### Changed

- 版本号从 **1.195.0-rc11** 递增为 **1.195.0-rc12**，内部构建号从 **117** 递增为 **118**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- `AgentSelfLearningTests` 更新到新签名并新增回归：排障对话/跨句阻塞词不触发 MCP 建议、日常用户消息不触发框架规则、会话内重复建议被去重；移除已删函数的旧断言。

## 1.195.0-rc11 - 2026-07-24

### Fixed

- 恢复 composer 上方的活动状态条：rc6 曾把「纯响应期」从显示条件里拿掉、且无可识别动作标题时不再兜底，导致不产出状态标题的模型（如 glm-5.2）在工具卡片结算后整个回合再无任何"正在做什么"的反馈（只剩静态的"处理中"页脚）。现在回合响应期间状态条常驻：有可识别 provider 动作时显示其标题，否则回退到泛化"思考中"，两者都带从左到右的扫光动画与回合计时。任务监督栏（rail）维持 rc6 的克制，只显示明确状态、不参与兜底。

### Changed

- 打开 Editor 窗口的默认快捷键从 **⌥⌘E** 改为 **⇧⌘E**（Shift+Command+E），与「Show Editor」菜单项一致。（合并自 main 分支同期改动）
- 新增两个内置备用快捷键 **⌥⌘E** 与 **⌃⌘E** 也能打开（或聚焦）独立 Editor 窗口——用零尺寸隐藏承接按钮承载额外键位，因为 SwiftUI 单个 `Button` 只能绑定一个 `.keyboardShortcut`；三者触发同一个 `showEditor()` 动作。旧的 ⌥⌘E 肌肉记忆得以保留，避免默认键变更后断链。（合并自 main 分支同期改动）
- 版本号从 **1.195.0-rc10** 递增为 **1.195.0-rc11**，内部构建号从 **116** 递增为 **117**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- `AgentThinkingStatusVisualTests` 更新：断言响应期 composer 状态条必须显示（rc6 的反向断言移除），新增源码巡检守住"思考中兜底存在且仅限 composer 样式、监督栏不兜底"的边界。

## 1.195.0-rc10 - 2026-07-24

### Fixed

- 移除过时的源码巡检测试「Terminal host-verification popover cannot auto-focus its copy action」：1.194.0-rc1 已把「验证宿主」弹层整体替换为「提取宿主身份」，`Button(action: copyAction)` 不复存在，该用例自那以后必红并阻断发布管线（CI 停摆期间未被发现）。同套件的 `sidePanelChromeControlsAreNotFocusable` 仍在全量巡检侧栏 chrome 控件的 `.focusable(false)` 焦点策略，覆盖不受影响。

### Tests

- `AgentToolIntegrationTests.swift`（3496 行，超 3000 行硬限）按主题拆分为七个文件：prompt 快照守卫、队列任务工具、some.im 浏览器登录、工具调用分组/审批展示、命令安全分类、用量统计与工具集成本体；所有 @Suite/@Test 语义与断言保持不变，complexity_guard 恢复 hard=0。

### Changed

- 版本号从 **1.195.0-rc9** 递增为 **1.195.0-rc10**，内部构建号从 **115** 递增为 **116**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.195.0-rc9 - 2026-07-23

### Changed

- AIPipe API Key、endpoint 与 topic 改由构建阶段从环境变量或 `.env.local` 读取，生成 DerivedData 内的 Swift 常量并编入可执行文件；Release 包不再依赖 `Info.plist` 携带 AIPipe 凭据。
- AIPipe 初始化优先级调整为运行环境、编译配置、Info.plist 兼容兜底，确保本地覆盖能力和旧构建兼容性保持不变。
- AI 服务商设置的「模型」区默认收起 Flash / Pro 备选模型输入框，改用一个「显示备选模型」开关按需展开——多数服务商只填一个主模型，两个空的多行输入框平时白占垂直空间。备选是活功能（填入的 model id 会出现在聊天模型选择器里供一键切换，并被 routine 模型池收录），因此只收起、不删除；加载服务商时若已存在备选内容（含 vision 模型自动注入场景）开关强制打开、照常显示，绝不隐藏已写入的备选。
- 版本号从 **1.195.0-rc8** 递增为 **1.195.0-rc9**，内部构建号从 **114** 递增为 **115**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 新增构建凭据生成器契约测试，并扩展 AIPipe 初始化测试，覆盖编译配置启用上报、环境变量优先级与无凭据关闭路径。

## 1.195.0-rc8 - 2026-07-23

### Changed

- 空聊天统计面板（Codex 风格活动页）的视觉皮肤对齐 Codex：强调色由原 teal 绿改为 Codex 蓝（浅色 #3B70E0 一族、深色相应提亮），选中态填充、面板底色与热力图未激活格随之改到蓝系；面板结构、指标口径与布局骨架保持不变。
- 概览指标条的两处大数字（交付物英雄数、当前连续天数）改用近黑主色而非强调色，与 Codex 一致——强调色只保留给列表数值与高亮，避免大数字整片染色。
- 「Agent 本轮学到的内容」品牌图标不再硬编码紫色：弹层标题的 `brain.head.profile` 与 transcript 底部「本轮保存了 N 条建议」入口均改为跟随系统强调色（`Color.accentColor`）。此前恰好因系统强调色为紫色而看似正确，强调色变更后即暴露。学习事件卡片内 Memory=蓝 / Skill=紫 / MCP=橙 的三类语义区分色刻意保留。
- 版本号从 **1.195.0-rc7** 递增为 **1.195.0-rc8**，内部构建号从 **113** 递增为 **114**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.195.0-rc7 - 2026-07-23

### Fixed

- 恢复 AIPipe 启动上报：存在有效 `AIPIPE_API_KEY` 环境变量或 `AIPipeAPIKey` Info.plist 配置时，应用会初始化启用状态的 SDK 并记录启动事件；缺少 Key 或仍是未展开的 `$(...)` 占位符时继续保持关闭。
- AIPipe 初始化入口支持注入无网络副作用的测试替身，确保环境变量优先级、Info.plist 回退、默认 endpoint 与无效 Key 拦截均可回归验证。
- 版本号从 **1.195.0-rc6** 递增为 **1.195.0-rc7**，内部构建号从 **112** 递增为 **113**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 新增 3 项 `AIPipeBootstrapTests`，覆盖环境变量启用、Info.plist 启用与缺失/未展开 Key 不初始化。

## 1.195.0-rc6 - 2026-07-23

### Fixed

- 当前动作改为单一状态源：assistant 消息尚未承接动作时才显示临时扫光行，一旦动作进入消息便立即隐藏临时行，避免两个状态及两套起始时间在同一位置交替出现。
- 普通 Provider 响应与任务监督栏不再回退显示泛化“思考中”；只有真实可识别动作、上下文压缩、运行任务或等待用户决定等明确状态才显示活动反馈。
- 临时当前动作行不再附带独立经过时间，动画文字本身承担进行中反馈。
- 版本号从 **1.195.0-rc5** 递增为 **1.195.0-rc6**，内部构建号从 **111** 递增为 **112**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 新增当前动作唯一归属和任务监督栏无泛化兜底的回归测试；活动状态与确认视觉测试共 9 项通过。

## 1.195.0-rc5 - 2026-07-23

### Fixed

- Agent 当前动作保留 Provider 给出的完整单行标题，并以从左到右的轻量扫光反馈执行状态；经过时间不参与动画，系统“减弱动态效果”开启时自动停用扫光。
- 纯 Provider 响应期间不再在 Composer 附近重复显示泛化的“思考中”；上下文压缩、后台任务和等待用户决定仍保留各自的明确状态。
- 已完成的历史动作继续显示稳定的本地化阶段标题，避免动画或原始 Provider 文案污染历史记录。
- 版本号从 **1.195.0-rc4** 递增为 **1.195.0-rc5**，内部构建号从 **110** 递增为 **111**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 新增当前动作完整标题、扫光周期、静态计时、减弱动态效果策略与纯响应不显示泛化状态的回归断言，并生成三个确定动画相位的 SwiftUI 视觉快照。

## 1.195.0-rc4 - 2026-07-23

### Fixed

- 修复发送新消息后的短暂错序：本轮 assistant 占位消息尚未创建时，不再误把上一轮回答当作正在流式输出；新用户消息会立即出现在上一轮回答之后，上一轮 Markdown 也继续保持富文本渲染，代码围栏不会裸露。
- 版本号从 **1.195.0-rc3** 递增为 **1.195.0-rc4**，内部构建号从 **109** 递增为 **110**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 新增“新回合启动但 assistant 尚未插入”和“本轮 assistant 插入后切换为流式消息”两项回归测试。

## 1.195.0-rc3 - 2026-07-23

### Fixed

- 思考状态的无限呼吸动画只作用于星形图标和绿色背景，右侧经过时间每秒直接刷新，不再跟随动画淡变或闪烁。
- 终端发送确认卡的可见性、目标标签与中断方式按内容实际宽度优先排成一行，只有确实放不下时才回退为纵向排列。
- 模型切换提示及其前后短分隔线共用助手正文的左右缩进，短线不会再伸到正文文本列之外。
- 版本号从 **1.195.0-rc2** 递增为 **1.195.0-rc3**，内部构建号从 **108** 递增为 **109**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 补充思考状态计时禁止参与呼吸动画、模型切换提示沿用正文缩进的策略断言，并通过终端确认卡中等宽度 SwiftUI 快照验证三项提示保持单行。

## 1.195.0-rc2 - 2026-07-23

### Changed

- 重构空状态统计面板的信息层级：“概览”以交付物为主视觉，把任务轮次、改动文件、工具调用与连续天数收束为摘要带；活动热力格调整为 8pt 格子、1.5pt 间距，并移除密度图例，减少稀疏感。
- “模型”页新增预估费用、输入/输出 Token 和最高缓存命中率摘要，模型明细改为带轻量分隔线的分组表格，并统一暖白背景、青绿色强调和更充足的区块留白。
- 版本号从 **1.195.0-rc1** 递增为 **1.195.0-rc2**，内部构建号从 **107** 递增为 **108**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 补充统计面板主视觉字号、摘要区圆角、热力格尺寸与间距、最大周数的回归断言，并通过概览与模型页真实 SwiftUI 快照进行设计验收。

## 1.195.0-rc1 - 2026-07-23

### Added

- 为 Claude Code、Codex CLI、Cursor Agent 与 Cline CLI 建立统一的外部委托控制面：WillDeep 在执行前生成带验收标准、路径边界、禁区、验证命令、超时和最多三轮尝试的结构化任务契约，并把每轮状态与证据持久化到会话。
- 外部执行器完成后必须输出逐项证据包，再由一个全新的只读执行器上下文复核；WillDeep 随后独立检查变更范围、敏感路径与安全验证命令。任一层不通过都会进入带具体问题的有限返工，最终未通过的结果不会伪装成成功交付。
- Composer 直接委托与 Goal 模式原生外部工具调用共用同一套双重验收链路；右侧监督栏会展示执行器、阶段、尝试次数、变更文件、问题数与失败原因，App 重启后会把中断中的委托明确收口为已取消。
- 新增外部委托任务协议、证据解析、路径和命令安全边界、宿主验收与会话持久化的专项测试。
- 版本号从 **1.194.0-rc21** 提升为 **1.195.0-rc1**（外部执行器治理能力新增，MINOR +1、rc 重置），内部构建号从 **106** 递增为 **107**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Fixed

- 系统交互通知的授权、确认、问答标题以及常见工具描述改走中英文资源；终端命令通知不再显示 `terminal_send_command` 等内部工具 ID，后台任务的停止、超时和启动失败状态也跟随系统语言。

### Tests

- `AgentDelegatedTaskControlTests` 覆盖契约约束、最后证据包解析、敏感文件拒绝、宿主复验通过、验证命令去重上限与会话 JSON 往返，共 6 项。
- 新增系统交互通知标题、终端命令和文件操作描述本地化的专项测试。

## 1.194.0-rc21 - 2026-07-23

### Fixed

- 为思考状态背景呼吸幅度断言加入等价的浮点计算容差，避免 `0.04` 在二进制浮点表示下被误判为越界。
- 版本号从 **1.194.0-rc20** 递增为 **1.194.0-rc21**，内部构建号从 **105** 递增为 **106**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.194.0-rc20 - 2026-07-23

### Changed

- Agent 响应期间移除 Composer 右下角蓝色排队圆形按钮，避免它与语音、停止操作并排争抢注意力；已有排队消息管理与快捷提交能力保持不变。
- 版本号从 **1.194.0-rc19** 递增为 **1.194.0-rc20**，内部构建号从 **104** 递增为 **105**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.194.0-rc19 - 2026-07-23

### Fixed

- 修复 Composer 在草稿从空变为非空时被底部按钮行本征宽度横向顶大的问题，输入首字符前后始终占满同一段可用聊天内容宽度。
- 将聊天区与右侧终端/工具面板之间的拖拽边界改为真正的 12pt 命中区，同时只保留中央 1pt 视觉分隔线，鼠标正常经过边界即可稳定触发左右拖拽。
- 版本号从 **1.194.0-rc18** 递增为 **1.194.0-rc19**，内部构建号从 **103** 递增为 **104**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 新增 Composer 稳定宽度、右侧面板分隔条命中宽度与视觉线宽分离的回归测试。

## 1.194.0-rc18 - 2026-07-23

### Fixed

- 修复产物右键菜单持续卡顿和高 CPU：可用 App 列表与展示名称改为按文件内容类型缓存，SwiftUI 菜单渲染不再逐项同步读取真实 App 图标，避免反复触发 LaunchServices 与 `syspolicyd`。
- 版本号从 **1.194.0-rc17** 递增为 **1.194.0-rc18**，内部构建号从 **102** 递增为 **103**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 新增“打开方式”缓存只加载一次、扩展名大小写归一且按内容类型复用的回归测试。

## 1.194.0-rc17 - 2026-07-23

### Changed

- “思考中”状态让左侧星形图标以 86%–108%、1.4 秒一程轻量呼吸，同时让绿色背景透明度在 7.5%–11.5% 间同步缓慢变化；文字和计时保持静止，系统开启“减弱动态效果”时不播放。
- 版本号从 **1.194.0-rc16** 递增为 **1.194.0-rc17**，内部构建号从 **101** 递增为 **102**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 补充思考图标缩放幅度与动画周期保持克制的策略覆盖。

## 1.194.0-rc16 - 2026-07-23

### Fixed

- 轮次末尾“来源”入口及同排学习入口改用助手正文统一的左右缩进，左边缘与正文文本列对齐，不再贴近对话区外沿。
- 版本号从 **1.194.0-rc15** 递增为 **1.194.0-rc16**，内部构建号从 **100** 递增为 **101**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 补充来源入口沿用助手正文布局缩进的回归覆盖。

## 1.194.0-rc15 - 2026-07-23

### Changed

- “发送到终端”确认操作由强调色实心按钮改为透明背景、强调色描边与正文色文字，保留操作辨识度并降低视觉重量；其他确认场景的主操作样式保持不变。
- 版本号从 **1.194.0-rc14** 递增为 **1.194.0-rc15**，内部构建号从 **99** 递增为 **100**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 补充终端发送使用描边确认、普通命令继续使用实心确认的样式策略覆盖。

## 1.194.0-rc14 - 2026-07-23

### Changed

- 来源入口按规范化网站域名合并重复图标，`www` 与裸域名不再重复占位；来源弹窗仍保留每一条具体链接。
- favicon 先请求网站根目录图标，失败后回退到公共 favicon 服务，提高来源入口显示真实站点图标的成功率。
- 版本号从 **1.194.0-rc13** 递增为 **1.194.0-rc14**，内部构建号从 **98** 递增为 **99**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 新增同域来源图标合并、直连 favicon 与回退候选地址覆盖。

## 1.194.0-rc13 - 2026-07-23

### Changed

- 对话辅助文字的默认字号从 11pt 提升至 13pt，信息层级改为主要依靠次要颜色与字重表达；“已创建文件”、来源入口、状态栏等不再因过小字号降低可读性。
- Composer 文件变更摘要同步采用 13pt 常规字体，增删数字仅保留等宽数字特性，不再整行使用小号等宽字。
- 版本号从 **1.194.0-rc12** 递增为 **1.194.0-rc13**，内部构建号从 **97** 递增为 **98**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.194.0-rc12 - 2026-07-23

### Fixed

- 未跟踪的 UTF-8 文本文件现在按实际逻辑行数计入变更统计，不再把新增文档错误显示为 `+0 -0`。

### Changed

- 逐文件审阅初始仅渲染每个文件的前 100 行，剩余内容通过“显示更多”按 100 行继续展开，降低大 Diff 首次打开时的渲染负担。
- 版本号从 **1.194.0-rc11** 递增为 **1.194.0-rc12**，内部构建号从 **96** 递增为 **97**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 新增未跟踪文本行数统计，以及 Diff 首屏 100 行、分批展开上限的覆盖。

## 1.194.0-rc11 - 2026-07-23

### Fixed

- 移除引用来源弹窗中来源项的键盘焦点态；来源项保持直接点击打开，不再自动给首项绘制突兀的焦点边框。

### Changed

- 版本号从 **1.194.0-rc10** 递增为 **1.194.0-rc11**，内部构建号从 **95** 递增为 **96**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.194.0-rc10 - 2026-07-23

### Fixed

- Composer 的“第 N / N 步”进度胶囊仅在当前响应仍有未完成计划或 Goal 步骤时显示；轮次结束、步骤全部完成或用户进入下一轮对话后立即隐藏，不再残留上一轮的 `7 / 7` 状态。

### Changed

- 版本号从 **1.194.0-rc9** 递增为 **1.194.0-rc10**，内部构建号从 **94** 递增为 **95**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 新增轮次结束、计划完成及状态尚未归档但步骤已全部终结时隐藏进度胶囊的覆盖。

## 1.194.0-rc9 - 2026-07-23

### Fixed

- 增加 AI 回复正文与“本轮进度”小卡片之间的垂直留白，修复历史消息和流式消息中卡片紧贴上一段文字的问题。

### Changed

- 版本号从 **1.194.0-rc8** 递增为 **1.194.0-rc9**，内部构建号从 **93** 递增为 **94**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 新增本轮进度卡正文间距常量测试，并继续覆盖 TextKit 历史渲染与 SwiftUI 实时渲染路径。

## 1.194.0-rc8 - 2026-07-23

### Changed

- 审阅面板默认改为 Codex 风格的逐文件 Diff 卡片：文件头集中展示路径与增删统计，每个文件可独立折叠，并提供一键全部折叠或展开。
- Diff 行新增旧/新双行号轨道，新增与删除行继续使用语义底色；hunk 之间及文件首个改动前的上下文收束为“未修改 N 行”。
- 保留文件列表、单文件详情、范围切换和提交/推送流程；合并 Diff 超过展示预算或无法解析时继续回退到原生 TextKit 预览。
- 版本号从 **1.194.0-rc7** 递增为 **1.194.0-rc8**，内部构建号从 **92** 递增为 **93**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 新增统一 Diff 到逐文件卡片模型的解析测试，覆盖路径匹配、双行号推进、增删行和首段未修改行收束。

## 1.194.0-rc7 - 2026-07-23

### Fixed

- 当前计划卡支持点击标题行双向展开与收起；从回复中的“查看完整计划”进入时会主动展开，新的 AI 输出轮次开始后自动收起。
- 执行中的计划默认收起，待审批计划仍默认展开，避免隐藏批准与拒绝入口。

### Changed

- 版本号从 **1.194.0-rc6** 递增为 **1.194.0-rc7**，内部构建号从 **91** 递增为 **92**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 新增计划卡初始展开策略与新 AI 轮次自动收起策略测试，并补充中英文展开/收起辅助文案。

## 1.194.0-rc6 - 2026-07-23

### Added

- Composer 上方新增可点击的 Git 变更摘要胶囊，集中展示变更文件数与增删行数，点击后直接打开右侧“审阅”面板。
- 审阅面板新增未提交、未暂存、已暂存和上一轮提交四种范围，可在合并差异、文件列表和单文件差异之间快速切换。
- 审阅面板新增 Git 提交区，支持填写提交信息、选择是否包含未暂存更改，以及“提交”和“提交并推送”；提交成功但推送失败时会保留准确的分段结果。

### Changed

- 原 Composer 变更摘要的独立 Diff 弹窗入口改为右侧面板工作流，审阅与对话可以并排进行。
- 审阅面板打开时采用 520pt 可读宽度基线；合并 Diff 提升为 12pt 等宽字，并用强调背景区分每个文件起点。
- Git 命令执行器支持按调用设置超时，提交与推送使用更适合 hooks 和网络操作的 120 秒预算。
- 版本号从 **1.194.0-rc5** 递增为 **1.194.0-rc6**，内部构建号从 **90** 递增为 **91**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 新增 Git name-status 解析、各审阅范围参数、范围快照隔离和真实临时仓库提交测试。

## 1.194.0-rc5 - 2026-07-23

### Fixed

- 桌面宠物旁的消息卡片改为与宠物垂直居中，展开卡片和折叠入口都不再偏向宠物底部。
- Composer 的任务步骤圆环按“当前步骤 / 总步骤”绘制实际进度，第 3 / 7 步会显示约 43% 的环形进度。
- 用户主动停止回复时，事件文案改为“用户已停止生成”，并移除文案前的停止符号。

### Changed

- 版本号从 **1.194.0-rc4** 递增为 **1.194.0-rc5**，内部构建号从 **89** 递增为 **90**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 补充步骤圆环百分比、停止事件文案与无图标渲染的回归断言。

## 1.194.0-rc4 - 2026-07-23

### Fixed

- 终端确认卡的三项状态说明优先保持单行展示，仅在可用宽度确实不足时退回纵向排列。
- 移除终端确认卡中与已展示命令、目标终端及风险提示重复的“查看终端详情”入口，避免无意义的二次展开。

### Changed

- 版本号从 **1.194.0-rc3** 递增为 **1.194.0-rc4**，内部构建号从 **88** 递增为 **89**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 补充终端确认文案回归断言，确保终端类审批不再暴露重复的详情入口。

## 1.194.0-rc3 - 2026-07-23

### Fixed

- 修复侧边栏终端命令偶发在审批后发送失败：继续操作当前可见标签时不再保留容易过期的显式 `terminal_tab_id`；只有明确操作非当前标签时才要求刷新并携带 ID。
- 终端标签在审批期间被关闭或进程退出时，错误会明确说明命令没有执行，并引导重新列举标签、读取快照后重试；不会把命令静默发送到其他终端或机器。
- 收紧当前回合活动时间线与上方正文的垂直距离：抵消 20pt 消息间距，改为 6pt 正常行距，“此前还有 N 项操作”不再悬空。

### Changed

- 版本号从 **1.194.0-rc2** 递增为 **1.194.0-rc3**，内部构建号从 **87** 递增为 **88**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 新增过期显式终端标签、审批期间终端退出和命令不得误投其他标签的回归测试；补充工具描述与活动行距设计令牌断言。

## 1.194.0-rc2 - 2026-07-23

### Changed

- 版本号从 **1.194.0-rc1** 递增为 **1.194.0-rc2**，内部构建号从 **86** 递增为 **87**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 修正统计面板视觉回归测试的外层宽度，使扣除测试 padding 后与生产环境 `AgentChatEmptyState` 的 560pt 仪表盘宽度一致，避免在错误视口上生成基准截图。

## 1.194.0-rc1 - 2026-07-23

### Added

- 新增终端标签工具：`terminal_list_tabs` 列出全部侧栏终端标签（含 id、类型、目标、运行状态、是否活跃、是否本会话打开），`terminal_select_tab` 切换活跃标签；Agent 现在可以按用户指令操作指定终端标签。
- 终端「验证主机」升级为「提取主机标识」：向当前标签的实际 Shell（含手动 SSH 会话）发送一条兼容 Debian/Ubuntu/macOS 的探测命令，读取 hostname、IP 和系统类型，展示在弹层中并把标签名自动改为主机名。

### Changed

- 终端工具路由从「会话绑定标签」改为「活跃标签」：`terminal_snapshot` / `terminal_send_command` / `terminal_send_control` 默认作用于用户当前看到的标签页；显式 `terminal_tab_id` 仍可一次性指向其他标签且不抢占活跃标签。新开标签仍从属于打开它的会话（用于会话切换时的标签激活与清理），但不再决定命令去向。委托 `/bin/sh` 池标签与自动化占用中的标签不会成为隐式目标。
- 终端「开始录制」在没有可用标签时不再置灰：自动激活已有的本地 Shell 标签，或直接新开一个本地 Shell 标签并开始录制。
- 系统提示词稳定前缀升级到 `willdeep-agent-system-v11`，同步描述活跃标签路由与新工具。
- 版本号从 **1.193.0-rc25** 递增为 **1.194.0-rc1**（新增终端标签工具与主机标识提取，MINOR +1、rc 重置），内部构建号从 **85** 递增为 **86**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 终端路由回归测试改写为活跃标签语义（跨会话读取活跃标签、显式 tab id 不抢占活跃标签、空面板引导语），新增录制自动开本地 Shell 标签、`terminal_select_tab` 切换路由与主机标识探测命令不含输出标记的测试。

## 1.193.0-rc25 - 2026-07-22

### Fixed

- 新聊天统计面板不再用 9–11pt 小号标签区分信息层级：页签、范围、指标标签、活动摘要、洞察行、常用能力和模型表格统一提升到 13pt 可读基线，分区标题使用 14pt、关键数字使用 16pt。
- 指标区增加克制的描边、留白和稳定分隔线，面板各区块扩大垂直间距；主次关系改由字重、颜色、空间和结构共同表达，而不是让辅助信息缩成“蚂蚁字”。

### Changed

- 版本号从 **1.193.0-rc24** 递增为 **1.193.0-rc25**，内部构建号从 **84** 递增为 **85**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 新增统计面板字号层级常量回归断言，并生成生产 SwiftUI 概览截图用于与参考界面进行视觉 QA。

## 1.193.0-rc24 - 2026-07-22

### Changed

- 当前回合的工具活动默认只显示最新操作这一行，并以箭头提示可展开；用户点击后才显示最近 3 项操作与更早操作摘要。有实时工具活动时不再额外重复一行阶段文案，减少运行过程对正文的视觉干扰。
- 等待审批、确认或用户回复的交互卡仍直接展示，不会被单行摘要隐藏。
- 版本号从 **1.193.0-rc23** 递增为 **1.193.0-rc24**，内部构建号从 **83** 递增为 **84**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 新增活动时间线默认单行、展开恢复最近 3 项的回归测试，并更新生产组件视觉截图。

## 1.193.0-rc23 - 2026-07-22

### Fixed

- 当前回合的活动时间线默认只展开最近 3 项操作，其余折叠为中性摘要；同一文件的精确编辑失败若已被后续成功编辑、补丁或明确的修改命令修复，不再继续以橙色失败行惊扰用户，未解决失败仍保留醒目提示。
- 产物摘要卡禁用标题与副标题的文本选择命中，鼠标经过整张卡片时统一使用普通箭头，不再出现用于选文字的 I-beam 光标。

### Changed

- 更早操作摘要从“此前已完成”调整为“此前还有”，避免把失败、跳过或等待操作错误描述成已经成功完成。
- 版本号从 **1.193.0-rc22** 递增为 **1.193.0-rc23**，内部构建号从 **82** 递增为 **83**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 新增“同文件后续修复会收起旧失败”和“无后续修复仍展示失败”的活动时间线回归测试，并继续生成生产组件视觉截图验证紧凑布局。

## 1.193.0-rc22 - 2026-07-22

### Fixed

- 将侧边栏中难以辨认的 Goal/Plan 迷你图标改为明确的本地化文字标签：简体中文显示 `目标 0/1` / `计划 2/3`，英文显示 `Goal 0/1` / `Plan 2/3`；继续保持单行、无胶囊底色和低对比度常态配色。

### Changed

- 版本号从 **1.193.0-rc21** 递增为 **1.193.0-rc22**，内部构建号从 **81** 递增为 **82**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 更新 Goal 单摘要回归用例并重新生成 228pt 生产侧边栏截图，确认模式名称无需依赖图标即可识别。

## 1.193.0-rc21 - 2026-07-22

### Fixed

- 收敛 Goal/Plan 会话在侧边栏中的进度展示：移除标题下方重复的当前步骤行，所有会话恢复统一的 31pt 单行高度；Goal 模式同时存在临时 Plan 时只展示 Goal 清单进度，不再并排堆叠两个计数。
- 进度状态改为无胶囊底色的次要文字色，仅等待处理或失败状态使用橙色提醒；当前步骤仍可通过悬停提示和辅助功能标签读取，实时运行中的进度继续自动刷新。

### Changed

- 版本号从 **1.193.0-rc20** 递增为 **1.193.0-rc21**，内部构建号从 **80** 递增为 **81**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 侧边栏与进度摘要共 14 项测试通过；新增 Goal + 临时 Plan 不重复显示的回归覆盖，并用 228pt 生产侧边栏截图复核单行布局与低对比度配色。

## 1.193.0-rc20 - 2026-07-22

### Fixed

- 修复 Agent 界面辅助文字被统一放大到聊天正文字号后，统计卡、Composer、状态标签和元数据失去视觉层级、中文界面显得粗重拥挤的问题；正文仍跟随用户字号设置，辅助文字恢复 11pt 基准，标题与关键数字保留各自 12–16pt 语义层级。
- 工具摘要、历史分段标题、消息页脚 Token 信息和重试图标恢复紧凑固定字号，不再随聊天正文字号一起膨胀。

### Changed

- 版本号从 **1.193.0-rc19** 递增为 **1.193.0-rc20**，内部构建号从 **79** 递增为 **80**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 更新字体层级回归断言；新聊天视觉层级 10 项测试和聊天历史渲染 73 项测试通过，并生成同视口生产组件截图复核。

## 1.193.0-rc19 - 2026-07-22

### Fixed

- 修复侧边栏终端"光标停在中屏、下方还有更新内容、提示符行混着两代文本"的显示错乱。诊断结论：渲染管线无辜（feed→updateDisplay→draw 已证明不可能持久错帧），错乱内容是被真实写进 buffer 的——根因是 app 侧把终端逼进了 resize 风暴：`updateNSView` 随面板每秒重算的 TimelineView 每次渲染都强制刷新，`refreshVisibleTerminalDisplay` 又在每个 PTY chunk 上同步 `layoutSubtreeIfNeeded`，布局在行高边界一抖就触发 `terminal.resize` + 立即 SIGWINCH，本地 reflow 搬移光标叠加远端 readline 的"上移+CR+重印提示符（不清行尾）"重绘，混代行就此固化。修复三件套：
  - `updateNSView` 不再逐次渲染强刷（挂载路径 makeNSView/viewDidMoveToWindow 保留刷新，数据到达本就自排显示）；
  - `refreshVisibleTerminalDisplay` 热路径去掉强制同步 layout（仅 viewDidMoveToWindow 重挂时保留）；
  - 终端几何变化加 120ms 防抖：尺寸风暴合并为一次"稳定尺寸"提交（PTY winsize/SIGWINCH、快照镜像、process delegate 三者一起），过渡期的退化尺寸（cols/rows < 2）直接忽略。
- 版本号从 **1.193.0-rc18** 递增为 **1.193.0-rc19**，内部构建号从 **78** 递增为 **79**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 新增 caret-模型不变量测试（WINCH 式"上移+CR+重印提示符"序列后 caret 可见行必须等于模型光标行）、winsize 防抖测试（尺寸突发合并为一次稳定提交、退化尺寸不传播）、ZMODEM 检测器负样本测试（纯文本 `rz`/`**B`/kubectl 输出不触发吞流、二进制头跨 chunk 拆分的现状行为锁定）。

## 1.193.0-rc18 - 2026-07-22

### Fixed

- Agent 顶部产物卡的文件列表支持逐文件动作：可用默认 App 打开、在 Finder 中显示、文本产物用内置编辑器打开，并在可预览时直接送入右侧 Preview 面板。
- 终端/工具授权卡移除最外层描边，仅保留内部命令内容边界，减少确认组件在窄聊天区里的“卡套卡”视觉噪音。
- “以后允许同类操作”新增可复用 shell 分类：`kubectl`/`k`/`oc` 归为 Kubernetes 类，纯 `curl` GET/HEAD 归为 HTTP GET 类，`cat`/`echo`/`ps` 等无重定向查看命令归为只读查看类；已有精确终端命令永久允许规则仍继续匹配。

### Changed

- 版本号从 **1.193.0-rc17** 递增为 **1.193.0-rc18**，内部构建号从 **77** 递增为 **78**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 新增授权签名分类与产物文本预览候选判断的回归测试，覆盖 k8s 长链路、curl GET/POST 边界、只读查看命令、旧精确签名兼容和基础文本/图片扩展名识别。

## 1.193.0-rc17 - 2026-07-22

### Fixed

- 聊天区历史保留窗口从最近 **60** 条可见消息扩大到 **240** 条，普通多轮任务不再很快出现“对话前面还有多条消息”的存档提示，更接近 Codex 的长聊天可读性。
- 顶部旧历史折叠卡的展开预览从 **4,000** 字扩大到 **12,000** 字；极长会话仍保留折叠保护和完整 transcript reader，避免一次性渲染无边界历史拖慢主线程。

### Changed

- 版本号从 **1.193.0-rc16** 递增为 **1.193.0-rc17**，内部构建号从 **76** 递增为 **77**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 新增聊天区历史保留阈值回归测试，锁定 240 条内联历史和 12,000 字旧历史预览上限，避免后续回归到过早存档。

## 1.193.0-rc16 - 2026-07-22

### Fixed

- Goal 模式把 Provider/工具循环视为一个用户可见回合：执行中仍展示语义化活动，回合结束后聊天区只保留最终交付小结与真实图片/文档产物；中间尝试、命令正文和阶段短句不再沉积成历史正文，原始消息与工具记录仍完整保留给审计、重试和模型上下文。
- 已结束 Goal 回合会从展示副本中移除内部 `progress` / `goal-check` 协议，避免最终小结下方再出现一张重复的“本轮进度”卡；处理时长、Token、模型信息与复制内容仍按完整原始回合聚合。
- 重做 Agent 当前回合的状态展示：最近的文件读取、代码搜索、编辑与命令逐条使用语义图标展示，较早操作收束为一行摘要；移除原先把本轮命令强行合成带框大卡片的过度聚合。
- `Planning …`、`Inspecting …`、`Verifying …` 等 Provider 阶段短句不再作为裸英文正文直接显示，而会归一为本地化的“正在规划下一步 / 正在检查相关实现 / 正在验证修改”等阶段标题；原始 reasoning 不再摊在聊天界面。
- 对齐模型用量表的表头与正文列轨道，Provider/模型、输入/输出、缓存和费用现在共享同一组列宽与水平内边距。
- 新聊天统计卡、侧边栏计划/目标进度和 Composer 上下文标签不再使用小于聊天正文的文字；它们会跟随用户设置的聊天正文字号，视觉层级改由字重与语义色承担。
- 聊天正文中的灰色工具活动摘要、运行进度、附件提示、处理状态和消息页脚统一采用聊天正文字号下限，避免关键信息因 9–12pt 小字难以辨认。

### Changed

- 版本号从 **1.193.0-rc15** 递增为 **1.193.0-rc16**，内部构建号从 **75** 递增为 **76**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 新增 Goal 结束态历史收口、产物保留、无最终小结兜底、单条回复内部协议隐藏、完整回合计量聚合与提示词交付契约测试；113 项四套定向回归通过，其中 72 项聊天历史渲染测试通过，并完成 773 × 578 同视口生产 TextKit 对比验收。
- 新增阶段短句归一、实时动作明细上限、审批不被折叠、命令正文不进入紧凑状态行等回归断言，并补充生产状态时间线截图；继续覆盖辅助字号下限、折叠工具摘要、消息页脚、侧边栏和聊天历史渲染。

## 1.193.0-rc15 - 2026-07-22

### Fixed

- 修复侧边栏终端接收远端 `sz` 文件时，本地 `rz` 退出竞态可能丢失最后一段 ZMODEM 收尾握手、导致远端命令一直等待的问题；子进程结束前现在会串行排空 stdout。
- 修复本地 ZMODEM 子进程已退出但主线程尚未清理会话时，远端 shell 提示符被写进关闭管道并吞掉的问题；退出边界后的字节会恢复交给终端显示。
- 新增 512 KiB 子进程尾部输出回归测试，覆盖“完整转发后才完成”与“退出后不再接受远端协议字节”。

### Changed

- 版本号从 **1.193.0-rc14** 递增为 **1.193.0-rc15**，内部构建号从 **74** 递增为 **75**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.193.0-rc14 - 2026-07-22

### Fixed

- 命令确认卡改为按可用宽度真实响应：右侧终端等侧边栏打开后，元数据与操作区会切换为纵向布局，长命令在卡片内部横向滚动，卡片和按钮不再被侧边栏裁掉。
- Composer 主动停止会保留已经输出的正文或思考内容，并以简洁的“已停止继续”事件替代“请求被取消”错误；前台命令会随本轮直接 TERM→KILL，后台任务与子代理按精确回合归属清理。
- 后台进程清理由轻量 AI 裁判只在本轮候选中决定是否停止；裁判不可用时安全回落为停止本轮任务。更早回合启动的 dev server、watcher 和后台任务不会进入候选，也不会被误杀；连续停止多轮时各轮清理互不覆盖。
- 版本号从 **1.193.0-rc13** 递增为 **1.193.0-rc14**，内部构建号从 **73** 递增为 **74**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 新增停止裁判候选范围、无效输出兜底、URLSession 取消桥接、流式内容保留和跨回合后台进程隔离测试；命令确认卡视觉回归覆盖 1040pt、520pt 与 400pt 三档宽度，并通过停止/队列、后台任务、Goal 恢复和移动网关相关回归。

## 1.193.0-rc13 - 2026-07-22

### Tests

- compact 与 extended 两档稳定提示词补上字节级哈希护栏（`compactPrefixSnapshotHash` / `extendedPrefixSnapshotHash`），与 standard 档共用同一套快照流程：三档中任何一档的意外文本漂移（合并冲突吃掉半句、误删段落）现在都会在测试层被拦下；有意修改提示词时需 bump `stablePrefixVersion` 并按测试失败输出重录三个哈希。
- 版本号从 **1.193.0-rc12** 递增为 **1.193.0-rc13**，内部构建号从 **72** 递增为 **73**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.193.0-rc12 - 2026-07-22

### Fixed

- Anthropic 回复上限（`max_tokens`）从写死的 **4096** 提升为默认 **32K**，长文档与大型重构回复不再以 `finish_reason: length` 被拦腰截断；新增 Settings → AI「Anthropic 回复上限」滑杆（1K–128K，步进 1024）兑现"设置里可调"的承诺。旧的 Claude 3.x 系列（3-opus/3-haiku/3-sonnet → 4096；3.5/3.7 → 8192）会在请求时自动收紧到其 API 上限，避免超限直接 400。
- 根级项目规则的 `product-overview.md` 兼容大写命名：`PRODUCT_OVERVIEW.md` 在大小写敏感的卷（外接盘、Linux 远端工作区）上不再被无声跳过；大小写不敏感的卷上保证只收录一次。
- 版本号从 **1.193.0-rc11** 递增为 **1.193.0-rc12**，内部构建号从 **71** 递增为 **72**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 新增 `AnthropicMaxOutputTokensTests`：现代模型透传配置值、Claude 3.x 各系按 API 上限收紧、低于上限的配置原样通过、设置存储边界夹取与默认值锁定。新增大写 PRODUCT_OVERVIEW 收录且不重复的回归测试。

## 1.193.0-rc11 - 2026-07-22

### Fixed

- Provider API Key 与 Agent/MCP 凭据按 Debug/Release 构建隔离 Keychain service；Release 保留既有服务名和凭据，Debug 改用 `.debug` 命名空间，避免 Apple Development 与 Developer ID 签名轮流访问同一条目时持续弹出钥匙串密码确认。
- Provider 可用性检查改为先只物化当前项；仅当当前 Provider 确实不可用时，才按顺序读取候选项并在首个可用项停止。打开模型面板不再批量读取全部历史 Provider 凭据。
- 移除主聊天记录末尾重复的“正在思考 · 时长”状态，只保留紧贴输入框上方的绿色语义活动条。
- 版本号从 **1.193.0-rc10** 递增为 **1.193.0-rc11**，内部构建号从 **70** 递增为 **71**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 新增 Debug/Release Keychain service 映射断言、非活动 Provider 保持懒加载断言，以及主聊天记录不再挂载重复思考状态的结构回归；视觉 QA 改为渲染输入框活动条。

## 1.193.0-rc10 - 2026-07-22

### Fixed

- 提示词/路由审计修复第四批（长尾收尾，13 项）：
  - 路由/质检裁判传输层显式带 `enable_thinking:false`，并在 `content` 为空时回落解析 `reasoning_content`；输出质检裁判不可用时写警告日志（此前完全无痕）。
  - 路由裁判输入补上 `has_images` / `has_text_attachments` 真实取值（此前恒为 false）。
  - 回合上下文附着时对 memory 块等后拼内容转义 `</system-reminder>`，堵住提前闭合 reminder 的注入口子；流失败/取消/空回复后回收本次插入的隐藏载体，不再永久携带死上下文。
  - Workspace Access 模式恢复尊重用户手工 pin 的"总是允许"（自动放行仍限白名单；被降级为不受信的 MCP pin 除外）。
  - 稳定提示词升级 **v10**：extended 段的 chrome_*/embedded_browser_* 宣称改为"仅专家激活时存在"；工具契约去掉 "Codex skills" 品牌残留；Plan 模式不再注入会话改名指令段（rename_session 本会被 plan gate 拒绝）。
  - 默认全局规则模板不再自称约束 "Codex"，改为约束"AI 编程助手"；locale 指令新增仲裁句：用户全局/项目规则指定回复语言时以规则为准。
  - 审批解释提示词接入 locale 指令，回复语言跟随用户偏好而非硬编码简体中文。
  - token 估算（圆环与 75% 自动压缩阈值）改用与真实请求一致的专家/模式过滤工具集，不再把 short-drama/chrome/委派 CLI 的固定块计入。
  - `gemini-3-flash` 落 compact 档，不再被 `gemini-3` 旗舰匹配拖进 extended。
  - BugHunt 猎手空结果改为强制字面哨兵 `NOTHING FOUND` 并按前缀过滤，中文/自由格式的"没发现"不再混进汇总，提及该短语的真实发现也不再被误丢。
- 版本号从 **1.193.0-rc9** 递增为 **1.193.0-rc10**，内部构建号从 **69** 递增为 **70**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 稳定前缀快照哈希随 v10 更新；新增 `gemini-3-flash` 档位断言；全局规则模板测试改为断言不含 "Codex"。

## 1.193.0-rc9 - 2026-07-22

### Fixed

- 提示词/路由审计修复第三批：
  - 目录级项目规则（活动文件目录链上的 AGENTS.md/CLAUDE.md）移出稳定 system 前缀、改随动态回合上下文下发；根级规则（product-overview.md + 根 AGENTS.md/CLAUDE.md）留在稳定区。切换不同目录的文件不再改变 system prompt 字节、不再打爆 provider 前缀缓存。
  - 上下文压缩的 head/tail 切分改为配对感知：切点落在孤儿 tool 结果上时自动回退到发起该组调用的 assistant 消息，压缩后 providerReadyMessages 不再静默丢弃最近的工具证据。
  - 路由裁判模板的 confidence 占位改为「刻意非法」的尖括号占位（照抄即整体解析失败、走本地 fallback），字段缺失时缺省从 1.0 改为 0.0——偷懒裁判触发当轮保守升档而非静默满信任；输出质检裁判的 confidence 不参与门槛、维持原样。
  - 输出质检升档写入会话 floor 时封顶在「裁判显式判定 + 一档」：低置信度 hedge 抬到 high 后再触发质检升档，不再把 premium 写进只升不降的 floor。
  - Goal Teams 提案校验失败不再静默死锁：解析成功但校验失败时，把逐条失败原因（表头/Member 连字符格式/关键词/隐形标记等此前 prompt 未写明的硬要求）以 host 通知回灌并立即给模型一轮重发机会，最多两次；仍失败则转 blocked 相位并给出用户可见错误与重试入口。
- 版本号从 **1.193.0-rc8** 递增为 **1.193.0-rc9**，内部构建号从 **68** 递增为 **69**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 新增/更新：nested 项目规则测试断言 scoped 规则落入动态区且 requestComponents 切分正确；压缩切分纯函数四断言 + 无可压内容返回 0；裁判模板无可照抄数字锚点、缺省 confidence=0 触发当轮升档但不进 floor；Goal 提案 validationFailures 对合法提案为空、对坏提案给出可执行原因、generation 标记缺失点名精确注释。

## 1.193.0-rc8 - 2026-07-21

### Fixed

- 提示词/路由审计修复第二批（隐藏 host 载体连带问题）：路由裁判、输出质检裁判、design-to-code 图片判定与自学习/自动记忆的"最新 user 消息"选择器全部改用 `isOperatorInput`——唤醒回合不再把空内容的 host 载体当成用户消息（此前路由裁判每个唤醒回合都拿到空串、退化为本地启发式，自学习会把整段 turn-context reminder 当作用户话语存档）。
- 动态回合上下文改为"全会话只保留最新一份完整快照"：`attachTurnContextIfNeeded` 写入新上下文时，把历史 user 消息上的旧完整快照（每份最多约 1.8 万字符）改写为确定性小占位，历史不再随回合数线性膨胀，旧回合过期的 PLAN/审批指令块也不再与当前状态互相矛盾。
- 无新用户消息、无系统通知的重新派发（切换模式后重试等）不再复用冻结的旧上下文：首轮检测到 turn context 变化即插入新的隐藏载体，模型总能收到当前模式指令；回合内第 2 轮起（`allowRefresh: false`）完全不触碰历史，回合中途到达的 Plan 续跑/后台完成通知不会再各自催生一份完整上下文载体。
- 审批裁判的 `<verdict>` 标签获得机械中和：`judgeUserPayload` 对命令内嵌的 `<verdict>`/`</verdict>` 插入零宽空格，通用注入标记表也新增这两个标记（覆盖历史样本与工具载荷）——命令里埋 `<verdict>YES</verdict>` 借裁判复述直通 auto-approve 的口子被堵上。
- 版本号从 **1.193.0-rc7** 递增为 **1.193.0-rc8**，内部构建号从 **67** 递增为 **68**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- attach 测试组重写并扩充：唤醒载体插入 + 旧快照回收、同上下文不重复附着、变更上下文插入刷新载体且全史仅存一份完整快照、`allowRefresh: false` 时含通知也不触碰历史。新增 `<verdict>` spoof 三用例：judgeUserPayload 打断内嵌 verdict 标签且解析器读不出 YES、通用中和器覆盖 verdict 标记、历史样本不透传 spoof。

## 1.193.0-rc7 - 2026-07-21

### Fixed

- Agent 壁纸层延伸至 macOS 全尺寸窗口的标题栏、圆角边缘和底部安全区，修复自定义背景图四周露出窗口底色、无法铺满的问题；会话等前景内容仍遵守安全区布局。
- 版本号从 **1.193.0-rc6** 递增为 **1.193.0-rc7**，内部构建号从 **66** 递增为 **67**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 通过 macOS App 构建与版本一致性守门，并针对 Agent 窗口全尺寸标题栏结构完成布局回归检查。

## 1.193.0-rc6 - 2026-07-21

### Fixed

- Editor 关闭 macOS 智能引号、智能破折号、文本替换、拼写纠正、智能插入删除、数据检测与链接检测，避免 JSON、代码或命令中的 ASCII 半角标点在输入或粘贴时被系统改成弯引号等排版字符。
- 版本号从 **1.193.0-rc5** 递增为 **1.193.0-rc6**，内部构建号从 **65** 递增为 **66**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 新增 Editor 写作辅助策略回归测试，锁定所有会改写源码或改变智能插入行为的 NSTextView 开关必须保持关闭。

## 1.193.0-rc5 - 2026-07-21

### Fixed

- 为正在执行的原生 Goal Plan 增加持久化恢复检查点；退出 WillDeep 后重新打开，会在原会话、原工作区和原模型上从未完成步骤安全续接，不再只恢复静态清单却把执行回合留在半路。
- 启动时识别被进程退出打断的 Goal Teams 规划并创建新规划代次；普通未完成计划、手动停止、待 Plan 确认、已归档、已完成和真实阻塞状态不会被误判为可自动执行。
- 恢复提示要求先核对工作区与外部状态，再决定是否重做中断前的写入、命令或网络副作用；工具授权和用户确认仍走原有门禁，不因恢复而获得额外权限。
- 版本号从 **1.193.0-rc4** 递增为 **1.193.0-rc5**，内部构建号从 **64** 递增为 **65**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 新增 Goal 启动恢复与会话持久化测试，覆盖执行续接、无检查点保持暂停、规划中断重启、显式停止清权、待确认不越权、归档/完成/阻塞不恢复，以及旧会话兼容解码。

## 1.193.0-rc4 - 2026-07-21

### Fixed

- Agent 自主回合的底部活动反馈固定为左对齐的“正在思考 · 时长”文字计时；首个正文 token 到达后不再替换为居中的呼吸星星，消除两种视图交替造成的界面闪动。
- 等待用户确认、授权或回答时隐藏通用活动标记，只保留对应交互卡片，避免把“正在输出”和“正在等你”混为一谈。
- 版本号从 **1.193.0-rc3** 递增为 **1.193.0-rc4**，内部构建号从 **63** 递增为 **64**；App、Go agent、Help、Helper、浏览器扩展、响应头契约与产品文档保持一致。

### Tests

- 新增活动文字状态回归测试，覆盖正文流式输出后继续显示文字，以及待确认、待授权、待回答和上下文压缩状态下隐藏活动标记。

## 1.193.0-rc3 - 2026-07-21

### Fixed

- 历史区“已执行 N 次终端操作”等紧凑活动摘要改为复用助手正文的左右缩进，修复摘要比正文向左错开 10pt 的视觉问题。
- 版本号从 **1.193.0-rc2** 递增为 **1.193.0-rc3**，内部构建号从 **62** 递增为 **63**；App、Go agent、Help、Helper、浏览器扩展、响应头契约与产品文档保持一致。

### Tests

- 在终端工具摘要渲染测试中新增正文与摘要 `headIndent`、`firstLineHeadIndent`、`tailIndent` 完全一致的回归断言，并补充同画布视觉对比。

## 1.193.0-rc2 - 2026-07-21

### Fixed

- 同一用户回合中的命令调用改为跨 assistant 消息聚合：provider 分段输出或中途切换模型时，历史区不再出现多条“已运行 N 条命令”，所有 `run_command` 统一收进一个可展开组，且不会跨越下一条用户输入。
- 模型切换提示从贯穿对话区的整行分隔线改为标签两侧各 96pt 的短线，宽窗口下仍保持居中里程碑语义，不再形成过强的章节切割。
- 版本号从 **1.193.0-rc1** 递增为 **1.193.0-rc2**，内部构建号从 **61** 递增为 **62**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 新增当前回合跨消息聚合、模型事件穿插、下一用户回合隔离、跨工具类型命令合并和短分隔线几何测试；66 项聊天历史渲染测试通过，并生成用户截图与真实 TextKit 实现的同画布视觉对比。

## 1.193.0-rc1 - 2026-07-21

### Added

- Agent 执行计划或 Goal 清单时，Composer 上方新增紧凑的“第 N / M 步”进度胶囊；悬停可临时展开、点击可固定完整步骤列表，并区分待处理、执行中、完成、跳过和失败状态。
- 进度摘要优先采用已接受或执行中的计划，过滤提议中与已拒绝计划；没有计划时回退到 Goal 清单，让当前执行位置始终贴近输入区可见。
- 新增中英文国际化文案与 VoiceOver 描述，胶囊和浮层均提供稳定的辅助功能标识。
- 版本号从 **1.192.0-rc20** 提升为 **1.193.0-rc1**，内部构建号从 **60** 递增为 **61**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 新增 7 个任务进度测试，覆盖显式/推断当前步骤、失败阻塞、提议与拒绝过滤、Goal 回退、计划优先级和真实 Composer 渲染；同时保存参考图与实现图的同画布视觉对比记录。

## 1.192.0-rc20 - 2026-07-21

### Fixed

- 修复 macOS Editor 无法使用中文输入法打字的问题：输入法存在 marked text 时暂停 SwiftUI 文本同步、脏状态回调、选择/括号刷新和语法高亮，并取消已经排队或正在回调的整段高亮；候选文字上屏后再执行正常同步，避免 `setAttributedString` 提前终止拼音组合并留下原始字母。
- Editor 的 SwiftUI representable 更新在 marked text 期间整体延后，防止流式状态、设置或诊断刷新把尚未提交的输入法缓冲区覆盖掉。
- 版本号从 **1.192.0-rc19** 递增为 **1.192.0-rc20**，内部构建号从 **59** 递增为 **60**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 新增 Editor IME 回归测试：覆盖 marked text 在 600ms 高亮防抖窗口内不被取消、binding 与脏状态不提前发布，以及候选提交后恢复正常同步。

## 1.192.0-rc19 - 2026-07-21

### Fixed

- 更新 `testApplyPatchPromptAndRegistrySurface` 的过期文本断言：测试现在锁定 `edit_file` 优先、`apply_patch` 仅作 legacy fallback，以及补丁卡片位于对话内且不得引导用户前往右侧面板的现行契约。
- 版本号从 **1.192.0-rc18** 递增为 **1.192.0-rc19**，内部构建号从 **58** 递增为 **59**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- `AgentToolIntegrationTests.testApplyPatchPromptAndRegistrySurface` 改为校验当前工具描述与 extended system prompt，不再依赖已删除的早期 unified-diff 文案。

## 1.192.0-rc18 - 2026-07-21

### Fixed

- 动态回合上下文不再附着到"仅存在于请求副本的转换消息"上：后台任务/工作流通知唤醒的回合，回合上下文会持久化到一条隐藏的 host 载体 user 消息（插入在流式占位消息之前），请求历史与下一回合的回放保持逐字节一致，Anthropic 显式缓存与 OpenAI/DeepSeek 隐式前缀缓存不再被唤醒回合打爆；同时删除请求副本上的第二次附着，杜绝同一请求携带两份动态上下文。
- 省心托管路由：会话档位 floor 只接受裁判显式的 complexity 判定，低置信度保守升档只影响当轮模型选择，不再被写进只升不降的 floor（此前裁判一次照抄模板 `confidence:0.0` 就会把会话永久锁死在 high 档）；裁判提示词模板的 confidence 占位值改为带说明的示例，明确要求填写真实置信度。
- 系统提示词档位判定改用 token 边界匹配：`gemini-3` 不再因包含子串 `mini` 被误判进 compact 档，旗舰 Gemini 恢复 extended 提示词；`flash-lite`、`4o-mini` 等真小模型仍正确落 compact。
- Gemini 适配器的合成工具调用 ID 加入每响应流 nonce（`gemini_fcall_<nonce>_<idx>`）：多个 assistant 回合不再都从 `gemini_fcall_0` 重编号，历史编码的 id→工具名映射不再把后续回合的调用解析成会话里第一次出现的工具，functionResponse 配对恢复正确。
- 版本号从 **1.192.0-rc17** 递增为 **1.192.0-rc18**，内部构建号从 **57** 递增为 **58**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 新增通知唤醒回合的 host 载体附着与幂等测试、无通知续跑不重复附着测试；省心托管低置信度升档不进 floor、显式 high 判定仍升 floor、裁判模板不含 `confidence:0.0` 占位测试；提示词档位 gemini-3/4o-mini/flash-lite 边界测试；Gemini 合成 ID 跨流唯一与历史映射测试。

## 1.192.0-rc17 - 2026-07-21

### Fixed

- Sparkle 发布元数据的 `release_notes_url` 不再指向 WillDeep 产品介绍页，改为 some.im 的轻量更新日志页；该页直接展示 stable appcast 当前发布记录里的 `release_notes`，更新窗口只呈现本次版本变化。
- 发布脚本仍从当前版本的 `CHANGELOG.md` 自动提取说明写入 appcast，因此后续发版无需重复维护整份更新历史。
- 版本号按线上已发布的 **1.192.0-rc16 (56)** 继续递增为 **1.192.0-rc17 (57)**，避免本地工作树复用已发布版本与构建号。

### Tests

- 发布契约测试新增 changelog URL 锁定检查，并继续覆盖 appcast 元数据生成。

## 1.192.0-rc16 - 2026-07-21

### Fixed

- 修复 Workspace Access 模式下标准或未信任 MCP 写入工具误入 LLM judge 自动审批的问题。
- 稳定队列取消 fallback 的 Release 测试调度，避免异步时序导致误报。
- 为队列取消 fallback 释放 provider slot 的调度增加测试可控参数；生产默认延迟不变，release 测试可立即覆盖同一释放路径，避免全量并发测试下主线程调度抖动导致误报。

### Changed

- 版本号从 **1.192.0-rc15** 递增为 **1.192.0-rc16**，内部构建号从 **55** 递增为 **56**。

## 1.192.0-rc15 - 2026-07-21

### Fixed

- Onboarding 左侧步骤导航补齐 `.focusable(false)`：点击“继续”切换步骤后，已完成的“欢迎”等上一项不再残留 macOS 自动绘制的紫色焦点边框。
- 放宽 release 环境下最小 headless `run_command` 回归测试的超时阈值，并将队列取消 fallback 释放 provider slot 的测试改为条件轮询，避免高负载构建机把正常命令或主线程调度抖动误判为失败。
- 版本号从 **1.192.0-rc14** 递增为 **1.192.0-rc15**，内部构建号从 **54** 递增为 **55**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 新增 Onboarding 导航焦点策略回归测试，锁定步骤行必须在 `.buttonStyle(.plain)` 后应用 `.focusable(false)`。

## 1.192.0-rc14 - 2026-07-21

### Changed

- Composer 贴入图片后，图片缩略图恢复为独立整行；“生成界面代码”不再以固定宽度强调卡片挤占图片区，改为紧跟在缩略图下方的无背景小字提示，仍可一键准备实现提示、挂载对应技能并进入视觉验收流程。
- Workspace Access 审批模式只自动放行明确属于当前工作区的白名单操作；未信任或标准 MCP 写工具会回到人工确认，不再继续落入 LLM judge 自动审批分支。
- 版本号从 **1.192.0-rc13** 递增为 **1.192.0-rc14**，内部构建号从 **53** 递增为 **54**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 重新构建 WillDeep，并检查图片附件区域在贴图状态下的布局与“生成界面代码”交互。
- 重新运行 release 前置测试，用于覆盖 Workspace Access / MCP 审批边界。

## 1.192.0-rc13 - 2026-07-21

### Fixed

- Workspace Access 审批模式现在只自动放行明确属于当前工作区的白名单操作；未命中的 MCP 写工具会回到人工确认，不再继续落入 LLM judge 自动审批分支。
- 集成终端（SwiftTerm）字体解析链补上 CJK fallback：`withNerdFontFallback` 之后追加与 Editor 相同的 `withEditorCJKCascade()`（PingFangSC / Hiragino Sans GB / STHeiti / Apple Color Emoji）。此前当终端字体设为 Nerd Font（本身无汉字字形）时，解析链是 Nerd Font → Nerd Font，汉字落到 .notdef 被直接丢弃、终端里中文不可见；现在任意基础字体（含自定义字体名）都会级联到中文字体。该修复原编号 rc12，因与另一并行会话已推送打 tag 的 editor 修复（下方 1.192.0-rc12）撞号，合并时并入 rc13。
- 版本号从 **1.192.0-rc12** 递增为 **1.192.0-rc13**，内部构建号从 **52** 递增为 **53**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 修复 release 前置测试 `approval mode controls write-tier auto approval` 覆盖到的 Workspace Access / MCP 审批边界。
- 新增 `EditorTerminalFontCascadeTests`：覆盖默认设置字体含 CJK cascade、自定义字体名保留 cascade、基础字体即 Nerd Font 时仍追加 CJK、Nerd Font fallback 排在 CJK 之前、重复应用 cascade 去重五个用例。

## 1.192.0-rc12 - 2026-07-21

### Fixed

- 修复 1.192.0-rc5 引入的 editor 重绘失效回归：输入含汉字的内容后文字已进入 text storage 但界面不绘制新内容，需 cmd+A 全选或窗口 resize 等全量重绘才显示（纯文本/Untitled 下最明显，与所选字体无关）。根因是 live CJK fallback 字体 pass 在 `textDidChange` 回调内直接改写 `.font` 属性，既没包 `beginEditing()/endEditing()` 也没有对受影响 range 做布局/显示失效，纯文本模式又没有语法高亮回填兜底。现改为：pass 包裹 begin/endEditing，只改写字体确实需要变化的 CJK 段（已是 fallback 字体的段跳过，纯 ASCII 输入零开销），并对实际改写的 range 显式 `invalidateLayout` + `invalidateDisplay`；IME 组合（marked text）期间整体跳过，不打扰输入法，提交后由下一次 `textDidChange` 正常补跑。
- 版本号从 **1.192.0-rc6** 递增为 **1.192.0-rc12**（跳过并行会话在途的 rc7–rc11，避免版本号撞车），内部构建号从 **46** 递增为 **52**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 新增 `EditorCJKLiveRedrawTests`：断言 live pass 对实际改写的 CJK range 调度了 layout/display invalidation 且 `ensureLayout` 无需额外事件即可完成；断言纯 ASCII 与已应用 fallback 字体的文本为零改写零失效；断言 marked text 组合期间 pass 完全跳过、提交后恢复正常改写。三个用例本地 `xcodebuild test-without-building`（CODE_SIGNING_ALLOWED=NO）全部通过。

## 1.192.0-rc11 - 2026-07-21

### Fixed

- App 菜单的“关于 WillDeep”改由 SwiftUI `CommandGroup(replacing: .appInfo)` 直接接管，不再启动后异步 patch AppKit 默认菜单，避免有时弹出系统简版 About、有时弹出自定义推荐页。
- “检查更新”入口与“关于 WillDeep”共用同一个 App Info 菜单替换组，移除多 Scene `after: .appInfo` 带来的重复菜单项；Sparkle 检查会记录 appcast URL 与失败错误详情，方便定位网络、appcast、签名或版本比较问题。
- 版本号从 **1.192.0-rc10** 递增为 **1.192.0-rc11**，内部构建号从 **50** 递增为 **51**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.192.0-rc10 - 2026-07-21

### Fixed

- Assistant 页脚的 input/output token 达到 100 万后改用 `M` 为单位并固定保留两位小数，例如 `26725.8k/43.5k` 显示为 `26.73M/43.5k`；千级数值继续使用一位小数的 `k`。
- 版本号从 **1.192.0-rc9** 递增为 **1.192.0-rc10**，内部构建号从 **49** 递增为 **50**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 新增百万级 token 页脚格式回归测试。

## 1.192.0-rc9 - 2026-07-21

### Fixed

- `AgentMessage.modelContent` 在没有文本附件和隐藏上下文时继续原样返回可见正文，保留首尾空格、换行和纯空白消息的既有兼容语义。
- Assistant 页脚继续按当前用户轮次汇总所有模型请求的 input/output token，并新增缓存命中率；缓存未上报与真实 0% 现在可以区分，Anthropic 分列返回的未缓存、缓存读取和缓存写入 token 会先统一为总 input 再参与统计。
- 版本号从 **1.192.0-rc8** 递增为 **1.192.0-rc9**，内部构建号从 **48** 递增为 **49**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 新增正文空白兼容、Anthropic input 归一化、用户轮次 token 聚合边界和缓存率格式回归测试。

## 1.192.0-rc8 - 2026-07-21

### Fixed

- 主 Agent 将动态 turn context 从 system 移到最新 user message，并作为不展示的 `modelContext` 随该消息持久化，确保下一轮仍复现相同 history 字节；历史宿主通知不再污染稳定 system，工具结果也改用不随轮次变化的确定性摘要。
- Anthropic 主请求为 system、稳定历史边界和请求尾部补齐显式 `cache_control`；全局规则内容按路径、修改时间与文件大小缓存，减少主线程重复读盘。
- 稳定提示词升级至 v9：compact profile 精简长尾工具规则，去除语言冲突和重复约束，README 不再作为项目规则注入，选区/文件/压缩摘要标记为不可信参考数据，设计转代码提示最多执行三轮校正。
- 版本号从 **1.192.0-rc7** 递增为 **1.192.0-rc8**，内部构建号从 **47** 递增为 **48**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 新增稳定提示词 v9 哈希快照、compact 契约长度、动态上下文消息位置、Anthropic 缓存断点、项目规则来源和工具结果跨轮稳定性测试。

## 1.192.0-rc7 - 2026-07-20

### Fixed

- 发布脚本的前置单测改用 release 工作目录下的独立 DerivedData / SourcePackages，不再复用全局 Xcode DerivedData，避免旧 Debug 宿主或 `WillDeep.debug.dylib` 残留污染 release 流程。
- XCTest 宿主启动时跳过 Chrome Native Host 注册、Fn 语音监听、语音模型生命周期预热和首次引导弹窗，避免纯单测还未建立连接就被启动期外部副作用中断。
- 版本号从 **1.192.0-rc6** 递增为 **1.192.0-rc7**，内部构建号从 **46** 递增为 **47**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.192.0-rc6 - 2026-07-20

### Added

- 关于页的“Rocky 的其他 App”新增 GitWise、像界（Xomo）与 BearCleaner 三个产品入口；GitWise 指向新建的 `https://83d.me/zh/products/gitwise`，Xomo 与 BearCleaner 分别指向现有中文产品页。
- 版本号从 **1.192.0-rc5** 递增为 **1.192.0-rc6**，内部构建号从 **45** 递增为 **46**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

## 1.192.0-rc5 - 2026-07-20

### Fixed

- Editor 设置里的字体菜单不再只显示 System Monospace、Menlo、Monaco、Courier，会从系统已安装字体中补充等宽/编程字体，并保留已选 installed 字体 ID 的解析能力。
- Editor 正文在用户输入或编辑后会立即给 CJK 字符应用中文 fallback 字体；plain text 模式和语法高亮延迟期间也能显示汉字，不再等高亮回填后才修正。
- 版本号从 **1.192.0-rc4** 递增为 **1.192.0-rc5**，内部构建号从 **44** 递增为 **45**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 新增 editor 字体菜单识别测试，覆盖编程字体关键字、固定宽度字体判断、 installed 字体 ID 解析与菜单 ID 去重。
- `xcodebuild build-for-testing -scheme Xedit -destination platform=macOS ENABLE_DEBUG_DYLIB=NO -only-testing:XeditTests/EditorCoreBehaviorTests` 通过；`xcodebuild test` 当前被 Xcode 测试宿主启动阶段的 `WillDeep.debug.dylib` 缺失问题阻断，未进入断言执行。

## 1.192.0-rc4 - 2026-07-20

### Fixed

- WillDeep 作为当前执行器时，普通模式和计划模式不再向模型暴露 Claude Code、Codex、Cursor Agent、Cline 这类外部委派工具；Goal 模式仍保留这些工具作为原生方式无效后的兜底。
- 外部执行器选择扩展到 Cursor Agent 与 Cline；选择 Claude Code、Codex、Cursor Agent 或 Cline 时，会直接路由到对应 CLI 工具，并只暴露该执行器对应的委派工具。
- 系统提示新增委派执行器策略，明确 WillDeep 普通/计划模式不随意外包、Goal 模式只兜底、外部执行器只走所选工具。
- 版本号从 **1.192.0-rc3** 递增为 **1.192.0-rc4**，内部构建号从 **43** 递增为 **44**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 新增委派工具可见性回归测试，覆盖 WillDeep 普通/计划/Goal 模式和 Codex、Cursor Agent、Cline 外部执行器。
- 扩展外部执行器参数与后台任务识别测试，覆盖 Cursor Agent 与 Cline。

## 1.192.0-rc3 - 2026-07-20

### Fixed

- 顶部活动条的委派状态会直接显示目标工具：`spawn_agent` 显示“委派给子代理”，外部委派分别显示“委派给 Claude Code / Codex / Cursor Agent / Cline”，避免所有委派任务都只写成笼统的“委派中”。
- `spawn_agent` 继续保留原有实时轮次与工具次数，例如“委派给子代理 · 第 5/12 轮 · 11 次工具”；外部 CLI 委派不伪造轮次，只展示真实目标工具。
- 版本号从 **1.192.0-rc2** 递增为 **1.192.0-rc3**，内部构建号从 **42** 递增为 **43**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 新增委派活动标签回归测试，覆盖子代理、Claude Code、Codex、Cursor Agent、Cline 及子代理轮次进度拼接。

## 1.192.0-rc2 - 2026-07-20

### Added

- 终端配色新增 Paper Light、Harbor Light、Mist Mint、Rose Quartz、Daylight、Solarized Light、GitHub Light 等浅色背景方案，并补充 Raster Grid、Aurora Night、Ember Glow 等与深色皮肤更匹配的方案。
- 新终端默认改为“跟随应用皮肤”，每套 App 皮肤都会映射到对应的终端配色；浅色 App 皮肤默认得到浅色终端，深色 App 皮肤仍保持深色高对比终端。
- 版本号从 **1.192.0-rc1** 递增为 **1.192.0-rc2**，内部构建号从 **41** 递增为 **42**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 新增终端配色回归测试，覆盖默认跟随 App 皮肤、浅色配色集合存在，以及每个 App 皮肤都能解析到有效终端配色。

## 1.192.0-rc1 - 2026-07-20

### Added

- 终端录制捷径开始回放后，会把所用捷径名称作为小标签显示在对应终端 tab 标题旁，便于区分线上、beta、自跳转等环境入口。
- 终端 tab tooltip 会补充显示“捷径：名称”，长捷径名在 tab 胶囊内截短，避免窄侧栏被撑开。
- 版本号从 **1.191.0-rc15** 提升为 **1.192.0-rc1**，内部构建号从 **40** 递增为 **41**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 新增终端捷径 tab 标签回归测试，覆盖快捷名去空白、空名忽略与长名称按 24 字符截短。

## 1.191.0-rc15 - 2026-07-20

### Fixed

- Editor 模式的等宽字体统一附加中文/日文/韩文 fallback cascade，避免 Menlo、Monaco、Courier 或系统等宽字体缺少中文字形时，中文字符占位但不绘制。
- 纯文本加载、全量语法高亮和大文件视口高亮都会对 CJK 字符段显式套用 PingFang fallback 字体，括号内中文、中文注释与中文配置说明不再显示为空白。
- 版本号从 **1.191.0-rc14** 递增为 **1.191.0-rc15**，内部构建号从 **39** 递增为 **40**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 新增 Editor 字体 cascade 与语法高亮 CJK 字体回归测试，覆盖 `10.0.131.7:28080 (内网地址)` 这类混合 ASCII / 中文文本。

## 1.191.0-rc14 - 2026-07-20

### Fixed

- `create_file` / `apply_patch` 直接落盘时按目标 Agent runtime 的 workspace 解析路径，不再因当前活动会话或编辑器根目录漂移而把文件写到别处却显示已 applied。
- 文件写入后会立即从磁盘读回校验内容一致；无法验证时 patch 状态会变为 failed，避免“报 applied 但文件没落盘”的误导。
- 自动应用 clean tracked patch、写入后的编辑文件 ledger 与 worktree 刷新都绑定到目标 runtime，避免后台任务污染当前活动任务的文件变更状态。
- 版本号从 **1.191.0-rc13** 递增为 **1.191.0-rc14**，内部构建号从 **38** 递增为 **39**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 新增 `create_file` 回归测试，覆盖目标 runtime 非活动时仍写入目标 workspace、更新目标任务 ledger，且不污染当前活动 workspace / runtime。

## 1.191.0-rc13 - 2026-07-20

### Fixed

- 队列消息的“立即发送”会真正取消当前卡住的 Agent turn，并在旧 turn 未及时收尾时释放其 provider 并发槽，避免“验证中”长时间占用导致新消息一直排队发不出去。
- preflight 阶段被取消后会继续消费队列，不再因为图片描述、验证准备等前置步骤中断而把队首消息遗留在“已排队”状态。
- 版本号从 **1.191.0-rc12** 递增为 **1.191.0-rc13**，内部构建号从 **37** 递增为 **38**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 新增队列强制接管回归测试，覆盖取消后旧 turn 不退出时 provider 槽释放与响应状态清理。

## 1.191.0-rc12 - 2026-07-20

### Fixed

- 模型选择器不再展示缺少 API Key 的远程 provider 模型；DeepSeek provider 没有 key 时，其 `deepseek-v4-*` 不会再被误当成 some.im 可用模型。
- 新会话、发送前预检和模型切换都会跳过不可用 provider；如果 some.im 已登录且当前 DeepSeek provider 没有 key，会自动回落到 some.im provider，避免默认卡在无 key 的 DeepSeek。
- TextKit 历史消息中的行内代码和文件路径保持一致行高；文件路径识别不会把 `hub-beta.tsingfly.com` 里的 `hub-beta.ts` 误判成 `.ts` 文件链接。
- 版本号从 **1.191.0-rc11** 递增为 **1.191.0-rc12**，内部构建号从 **36** 递增为 **37**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 新增 provider 可用性、无 key DeepSeek 回落到已登录 some.im、模型选择器拒绝激活无 key provider 的回归测试。
- 新增 TextKit 行内代码行框回归测试，覆盖中文正文夹 `hub-beta.tsingfly.com` / `tokenhub` 时不撑高行高或被路径链接拆段。

## 1.191.0-rc11 - 2026-07-20

### Fixed

- TextKit 历史消息中的行内代码和文件路径改用略小一号的 monospace 字体，避免 SF Mono 在同字号下把含代码的中文正文行框撑高，修复聊天记录行高忽宽忽窄的问题。
- 文件路径识别不再把 `hub-beta.tsingfly.com` 中的 `hub-beta.ts` 误判成 `.ts` 文件链接，避免行内代码胶囊被拆成两套样式。
- 版本号从 **1.191.0-rc10** 递增为 **1.191.0-rc11**，内部构建号从 **35** 递增为 **36**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 新增 TextKit 行内代码行框回归测试，覆盖中文正文夹 `hub-beta.tsingfly.com` / `tokenhub` 这类代码胶囊时不再撑高行高或被路径链接拆段。

## 1.191.0-rc10 - 2026-07-20

### Fixed

- 命令等工具确认卡底部的拒绝与继续按钮恢复为更紧凑的 28pt 高、124pt 最大宽，延续当前皮肤的强调色体系，降低确认区视觉重量。
- 右上角产物、媒体和 Dev Server 摘要卡的可点击主体、菜单、关闭按钮与整卡 hover 区域显式使用箭头 cursor，避免悬停到标题或文件名文字时显示文本插入光标。
- 右上角产物卡主体与单文件菜单项会把当前 worktree 已改动文件直接打开到 Diff 面板并聚焦该文件；未改动产物仍进入 Preview，“查看全部文件”和显式 HTML 预览入口保持原语义。
- 会话列表行的 pin/archive hover 操作区始终预留 40pt，避免带 Plan/Goal 进度徽章的长会话标题在鼠标移入移出时重新压缩并闪动。
- 版本号从 **1.191.0-rc9** 递增为 **1.191.0-rc10**，内部构建号从 **34** 递增为 **35**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 更新确认卡视觉、工具审批布局、产物文件点击路由与会话列表 hover 几何断言，覆盖紧凑按钮尺寸、Diff 直达和标题闪动回归。

## 1.191.0-rc9 - 2026-07-20

### Fixed

- 同目录并发会话提醒补齐简体中文文案与操作提示，不再在中文界面显示英文警告。
- 一键隔离到 worktree 只切换当前会话的执行 checkout，并保留原会话、原侧边栏 workspace 分组和 workspace 标签；不再新建对话或把 worktree 当成独立 workspace。
- worktree 隔离与退出完成后立即重算同目录冲突；执行目录已隔离时自动关闭提示条。
- 版本号从 **1.191.0-rc8** 递增为 **1.191.0-rc9**，内部构建号从 **33** 递增为 **34**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 新增 worktree 隔离后的冲突清除、原 workspace 分组保留与会话持久化回归覆盖；定向 13 项测试通过。

## 1.191.0-rc8 - 2026-07-20

### Fixed

- 行内代码中的长文件名、函数名统一抬高 1pt 基线，避免 SF Mono 位于最低像素行的下划线在 SwiftUI 实时消息和 TextKit 历史消息中被裁掉。
- 版本号从 **1.191.0-rc7** 递增为 **1.191.0-rc8**，内部构建号从 **32** 递增为 **33**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 新增长文件名下划线基线回归覆盖，并扩展 Plan Markdown 测试验证 SwiftUI 行内代码样式。

## 1.191.0-rc7 - 2026-07-20

### Fixed

- Plan 卡片的步骤序号使用稳定单行列宽，`10.` 等双位数序号不再把句点挤到下一行；步骤正文改为内联 Markdown 富文本，加粗、斜体和行内代码不再显示原始标记符。
- 带工具调用的每个模型回合结束后立即消费显式 `progress` 状态，长计划中已完成的步骤会及时打勾，不必等到最终无工具回复；无明确完成证据时仍不会猜测勾选。
- 版本号从 **1.191.0-rc6** 递增为 **1.191.0-rc7**，内部构建号从 **31** 递增为 **32**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 新增 Plan 步骤 Markdown、双位数序号列宽与即时进度提示契约回归覆盖。

## 1.191.0-rc6 - 2026-07-20

### Fixed

- Agent 执行过程中的已修改文件引用现在会直接打开右侧 Diff 面板并聚焦对应文件，不再跳到文件树或只打开普通预览。
- Diff 面板会消费指定文件并在刷新、切换文件时保持一致的聚焦状态；普通未修改文件引用仍沿用 Preview，无法解析的路径仍回退到 Files。
- 源文件超过 1MB 时会在执行 `git diff` 前直接降级；超过 32KB 或 600 行预算的单文件 Diff 也不再渲染截断样本，统一显示明确的过大提示，避免侧栏处理大文本。
- 版本号从 **1.191.0-rc5** 递增为 **1.191.0-rc6**，内部构建号从 **30** 递增为 **31**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 新增改动文件点击直达 Diff、嵌套路径精确聚焦、普通引用保留 Preview、超大源文件预拦截以及超大 Diff 拒绝渲染的回归覆盖。

## 1.191.0-rc5 - 2026-07-20

### Fixed

- 修复长计划执行中从其他审批模式切换到「Workspace 访问」后，当前已挂起的普通写级工具仍沿用旧决策并持续等待的问题；模式切换现在会按实时安全策略重评待审批调用并唤醒执行循环。
- 重评不会放宽硬性门禁：危险级命令、未批准计划、会话/工作区身份变更以及不受信任 MCP 调用仍需用户确认。
- 版本号从 **1.191.0-rc4** 递增为 **1.191.0-rc5**，内部构建号从 **29** 递增为 **30**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 新增执行中权限模式切换回归测试，覆盖普通工作区命令立即续跑与危险命令继续保持强确认两条路径。

## 1.191.0-rc4 - 2026-07-20

### Fixed

- 修复带计划或目标进度的会话行在 hover 显示固定、归档操作后，模式徽章被横向压缩并导致 SF Symbol 与进度数字变形的问题；徽章现保持固有宽度，会话标题按剩余空间截断。
- 版本号从 **1.191.0-rc3** 递增为 **1.191.0-rc4**，内部构建号从 **28** 递增为 **29**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 新增侧栏计划进度徽章的横向抗压缩回归测试，覆盖 hover 操作区占用空间时的布局约束。

## 1.191.0-rc3 - 2026-07-20

### Changed

- 命令等工具确认卡底部的拒绝与继续按钮最小高度由 42pt 收紧为 36pt，保留原有宽度、字号、圆角和按钮间距，使主操作区更轻巧。
- 版本号从 **1.191.0-rc2** 递增为 **1.191.0-rc3**，内部构建号从 **27** 递增为 **28**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 更新审批操作度量与视觉回归契约，锁定 36pt 的紧凑按钮高度。

## 1.191.0-rc2 - 2026-07-20

### Fixed

- 修复侧栏“新建项目”、Composer“选择文件夹”和菜单“打开文件夹”点击后只短暂卡顿、却不显示目录选择器的问题；目录面板恢复为独立异步呈现，不再附着到可能隐藏、已有 sheet 或不属于当前入口的全局关键窗口。
- 版本号从 **1.191.0-rc1** 递增为 **1.191.0-rc2**，内部构建号从 **26** 递增为 **27**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 新增目录选择器呈现策略回归测试，锁定工作区入口必须使用独立面板，防止再次退回全局 `keyWindow` sheet。

## 1.191.0-rc1 - 2026-07-20

### Added

- 对话中的 `progress` 协议新增原生“本轮进度”摘要：收起时呈现完成、进行中与失败计数，展开后只列仍在进行或失败的步骤，并支持跳转到完整计划。

### Changed

- 原始 `progress` 代码块从流式 SwiftUI 和历史 TextKit 两条消息渲染链路中隐藏；同一条回复内的多次更新按步骤合并并以最后状态为准，普通代码块不受影响。
- 功能版本提升到 **1.191.0-rc1**，内部构建号从 **25** 递增为 **26**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 新增进度协议解析、重复状态合并、普通代码块保留、历史富文本交互属性与真实 SwiftUI 视觉渲染测试。

## 1.190.0-rc1 - 2026-07-19

### Added

- Composer 在新会话中支持整句精确输入 `#1983#` 打开本地确认面板预览，一次展示命令执行、网页读取、内置浏览器与 Computer Use 四类真实审批界面；带前后空白仍可识别，夹带其他正文、附件、运行中会话或已有对话时均不触发。

### Changed

- 预览工具卡仅保存在当前运行时内存，不创建用户/助手消息、不进入会话持久化或模型上下文；开始真实输入前会自动清理，审批、拒绝、“始终允许”“本会话允许”和审核解释均走本地安全短路，不执行工具、不访问网络，也不修改权限规则。
- 功能版本提升到 **1.190.0-rc1**，内部构建号从 **24** 递增为 **25**；App、Go agent、Help、Helper、浏览器扩展、README、响应头契约与产品文档保持一致。

### Tests

- 新增 Composer 本地面板口令策略与发送链路测试，覆盖精确匹配、新会话限定、附件/运行态/重复触发拦截、零消息零请求、本地审批安全短路，以及真实输入前清理预览。

## 1.189.0-rc4 - 2026-07-19

### Changed

- 首次启动流程调整为“欢迎 → some.im 登录 → 自有 AI Provider → 本机语音 → 完成摘要”，some.im 浏览器登录成为第一配置路径，自有 Provider 明确作为可选补充。
- Onboarding 窗口重构为左侧进度导航与右侧单任务内容，复用 WillDeep 企鹅品牌资产，并统一推荐、可选、连接成功、下载进度、跳过与完成状态；后续步骤保持可读但不可提前跳转。
- Provider 表单收进独立配置卡，已连接 some.im 时给出可安全跳过的提示；语音页明确本机处理与隐私边界，完成页汇总 AI、语音和设置状态。
- Onboarding 文案从接近 3000 行的主本地化文件拆到独立模块，中英文资源同步补齐；版本号从 **1.189.0-rc3** 递增为 **1.189.0-rc4**，内部构建号从 **23** 递增为 **24**，App、Go agent、Help、Helper、浏览器扩展、响应头契约与产品文档保持一致。

### Tests

- 新增步骤顺序回归测试，锁定 some.im 必须位于自有 Provider 之前；新增欢迎页与 some.im 登录页的隔离数据视觉渲染测试，并扩展首次启动 UI 测试验证点击欢迎页主按钮后进入 some.im。

## 1.189.0-rc3 - 2026-07-19

### Fixed

- Diff 侧栏的单文件详情改为直接生成 AppKit 原生富文本属性，避免 SwiftUI `AttributedString` 桥接到 `NSTextView` 时丢失颜色；新增行、删除行恢复红绿前景色与浅色行背景，hunk 和元数据继续跟随当前界面皮肤。
- 保留并明确大 diff 资源预算：单文件详情超过 32KB 或 600 行时只渲染 24KB 有界样本，未跟踪单文件超过 64KB 时降级为摘要；Git 输出收集仍受 512KB 与 5 秒超时上限约束。
- 版本号从 **1.189.0-rc2** 递增为 **1.189.0-rc3**，内部构建号从 **22** 递增为 **23**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README、移动网关响应头契约与产品文档同步。

### Tests

- 新增 TextKit 原生 diff 着色回归测试，断言新增、删除、hunk 的前景色以及新增/删除行背景色不会在 AppKit 渲染链路中丢失；既有 UTF-8 字节、行数、非连续布局和按文件延迟加载保护继续覆盖。

## 1.189.0-rc2 - 2026-07-19

### Fixed

- 待发消息左侧新增独立状态图标与可拖拽把手，并支持直接调整 FIFO 发送顺序；Goal 卡片改用稳定的左侧目标图标布局，与 Codex 的状态消息层级保持一致。
- 后台命令的显式终止、超时触发与两秒 SIGKILL 升级改由专用高优先级串行队列驱动，避免冷编译或共享 CI 高负载时全局 utility 队列饥饿，导致任务长期停留在 `running`。
- 版本号从 **1.189.0-rc1** 递增为 **1.189.0-rc2**，内部构建号从 **21** 递增为 **22**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README、移动网关响应头契约与产品文档同步。

### Tests

- 新增待发消息双向重排测试，覆盖从队首移到队尾以及移回队首的顺序变化。
- 后台任务终止与超时恢复为硬断言；正式发布门禁必须在高负载下同时通过 `longRunningCommandCanBeKilled` 与 `timeoutSurfacesTimedOutStatus`，不再把超时波动记作 known issue。

## 1.189.0-rc1 - 2026-07-19

### Added

- Goal 模式新增计划先行的 Goal Teams 编排：宿主固定并行启动需求边界、架构路径和测试失败路径三个独立只读身份，全部终态后进行证据仲裁，再生成十列 Teams 表与完整 fenced Plan。
- Goal Teams 状态、成员证据、错误、仲裁结果与修订意见可随会话持久化；旧会话或未知状态恢复时会保守进入 blocked，不扩大权限。

### Changed

- Goal 从 setup 起锁定写级和危险级工具；只有用户显式批准当前 Plan 后，普通写级工具才进入既有审批流程，danger-tier 仍须逐次确认。Goal 执行每轮同时要求 `progress` 与 `goal-check`；Plan 完成但 Goal checklist 未完成时自动回到新一轮只读规划。
- 子进程输出改由系统派发队列持续排空，超时由 WillDeep 独立的高优先级串行队列驱动，避免高并发测试或长任务占满 Swift 协作线程池与全局派发队列时把 100ms 超时拖到子进程自然结束。
- 版本号从 **1.188.0-rc1** 提升为 **1.189.0-rc1**，内部构建号从 **20** 递增为 **21**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README、移动网关响应头契约与产品文档同步。

### Tests

- 新增 Goal Teams 状态恢复、提案结构、计划门禁、独立报告降级、仲裁失败、确认/拒绝/修订、旧模式回归与完成后再规划测试；同步侧栏退役任务监视器的源码契约断言，覆盖新“已安排”主页面下的等价归一化实现。最终无筛选回归报告 1316/1316 通过，详见 `build/ci/report.md` 与 Goal Teams 验收文档。

## 1.188.0-rc1 - 2026-07-19

### Added

- Agent 左侧栏新增单一“已安排”导航入口，周期任务不再随数量增长无限占用侧栏；主区域新增独立的已安排任务页面，集中展示现有任务与每日简报、每周回顾、项目监控模板。
- 已安排任务页面支持按名称、提示词、计划摘要和工作区搜索；任务行可继续编辑、立即运行、暂停或启用，并保留删除上下文菜单。

### Changed

- 聊天中的已安排任务卡现在跳转到独立页面并打开对应编辑器；选择新聊天、历史会话或工作区后会明确返回对话页面。版本号从 **1.187.0-rc2** 提升为 **1.188.0-rc1**，内部构建号从 **19** 递增为 **20**。

### Tests

- 新增已安排任务多字段搜索、完整页面渲染及侧栏与主页面同视口视觉回归测试；Debug 构建与定向 Swift 测试通过。

## 1.187.0-rc2 - 2026-07-19

### Fixed

- 执行器语义图标回归测试同步 WillDeep 当前的锤子图标，修复产品实现已更新但旧断言仍期待 `person.fill` 导致的发布测试失败。
- 版本号从 **1.187.0-rc1** 递增为 **1.187.0-rc2**，内部构建号从 **18** 递增为 **19**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README、移动网关响应头契约与产品文档同步。

### Tests

- 发布前完整测试套件暴露执行器图标旧断言与一次高负载下的子进程超时时序波动；修正断言后重新执行完整发布门禁。

## 1.187.0-rc1 - 2026-07-19

### Added

- “关于 WillDeep”窗口按 QTerm 关于页重构为 700×500 产品介绍页：页首展示企鹅形象、实时版本、产品简介和作者主页，下方以整卡链接推荐 QTerm、TimeBill、QPic、QMarkView、QEcho、QMailMate 与 QNote，并提供完整中英文文案。

### Changed

- 版本号从 **1.186.0-rc1** 提升为 **1.187.0-rc1**，内部构建号从 **17** 递增为 **18**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README、移动网关响应头契约与产品文档同步。

## 1.186.0-rc1 - 2026-07-19

### Added

- 受保护密钥弹窗新增本机已保存密钥列表，整行点击即可把对应占位符插入 Composer 当前光标位置；密钥值仍只保存在 macOS 钥匙串，列表仅展示别名和安全占位符。升级前创建、尚无别名索引的旧 UUID 密钥也会以短编号列出并继续可复用。
- 新密钥别名会规范为可读的小写短横线标识，例如“Production SSH Password”输出 `${secret:production-ssh-password}`；再次保存相同规范别名会更新原密钥值，旧版随机 UUID 占位符继续兼容解析。
- Composer 中的受保护密钥占位符使用强调色圆角标签展示；标签内部不可逐字编辑，删除任一部分会原子删除整个占位符，随后可从密钥弹窗重新插入。

### Changed

- 版本号从 **1.185.0-rc9** 提升为 **1.186.0-rc1**，内部构建号从 **16** 提升为 **17**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

### Tests

- 新增别名规范化、同别名更新、已保存密钥索引、旧 UUID 密钥发现、可读占位符与 Unicode 范围识别回归测试；AgentToolsCoreTests 定向测试与 Debug 构建通过。

## 1.185.0-rc9 - 2026-07-18

### Fixed

- Agent 窗口尚未选择工作区、甚至尚未有活动会话时，选择执行器、对话模式、审批级别、专家包、插件或右侧辅助栏会自动创建一个可在随后原地绑定工作区的无工作区草稿会话，选择立即生效，不再出现点击无反馈。
- Files 与 Diff 仍需本地工作区，但空态现在明确说明限制，并提供“选择工作区”按钮；终端、浏览器、预览与普通聊天继续可在无工作区状态直接使用。版本号从 **1.185.0-rc8** 递增为 **1.185.0-rc9**，内部构建号从 **15** 递增为 **16**。

## 1.185.0-rc8 - 2026-07-18

### Fixed

- 执行器菜单选择外部 CLI 后，pill 现在立即显示新执行器的图标、名称、选中标记和配色；切换会话时同步已保存的会话选择，不再一直显示 WillDeep。版本号从 **1.185.0-rc7** 递增为 **1.185.0-rc8**，内部构建号从 **14** 递增为 **15**。

## 1.185.0-rc7 - 2026-07-18

### Fixed

- Composer 执行器入口将本地 Agent 明确标为 **WillDeep**，并以锤子图标表达实际执行任务；菜单说明和悬浮提示不再使用“我们”。版本号从 **1.185.0-rc6** 递增为 **1.185.0-rc7**，内部构建号从 **13** 递增为 **14**。

## 1.185.0-rc6 - 2026-07-18

### Fixed

- 将已在 `main` 修复的审核解释模型路由和 provider 错误详情展示完整纳入当前发布线，并保留既有 some.im 凭据自愈逻辑；版本号从 **1.185.0-rc5** 递增为 **1.185.0-rc6**，内部构建号从 **12** 递增为 **13**。

### Tests

- 合并后运行贴图生成代码、Chrome、Computer Use、授权视觉与审核解释共 28 项定向 Swift 测试，全部通过。

## 1.185.0-rc5 - 2026-07-18

### Fixed

- `/screenshot-to-code` 根据 `framework` 在有效图片校验后确定性挂载 Web Programming 与 Browser Ops 专家并打开内置浏览器；HTML/React 等 Web 目标不再因自动技能判定遗漏而丢失 `embedded_browser_*` 工具，SwiftUI/AppKit/UIKit 目标保持原生路径。
- 版本号从 **1.185.0-rc4** 递增为 **1.185.0-rc5**，内部构建号从 **11** 递增为 **12**；全部版本暴露位点同步更新。

### Tests

- 扩充 Slash 直接执行回归测试，覆盖 Web 专家挂载、默认 Web 路由与 SwiftUI 原生路由。

## 1.185.0-rc4 - 2026-07-18

### Fixed

- `/screenshot-to-code` 在直接执行前显式退出遗留 Plan 模式并清理旧计划，避免写入与内置浏览器验收被计划门禁拆断；Goal 模式仍按用户选择保留。
- 版本号从 **1.185.0-rc3** 递增为 **1.185.0-rc4**，内部构建号从 **10** 递增为 **11**；全部版本暴露位点同步更新。

### Tests

- 新增贴图生成 Slash 命令退出 Plan 模式回归测试。

## 1.185.0-rc3 - 2026-07-18

### Fixed

- 视觉验收的 OCR 覆盖率改为对响应式换行不敏感的字符片段比较；同一文案在窄视口重新换行时不再误判失败，同时无关文案仍会被拒绝。
- 版本号从 **1.185.0-rc2** 递增为 **1.185.0-rc3**，内部构建号从 **9** 递增为 **10**；全部版本暴露位点同步更新。

### Tests

- 新增 OCR 换行等价与无关文案拒绝回归测试。

## 1.185.0-rc2 - 2026-07-18

### Changed

- Computer Use、Chrome 与内置浏览器的普通写操作审批改为 Codex 风格紧凑授权卡，保留左侧“始终允许”和右侧“拒绝 / 允许此对话”的清晰操作分组。
- “允许此对话”只在当前 Agent runtime 内按 Computer Use、Chrome、内置浏览器工具族生效；“始终允许”按相同工具族持久化，danger 级调试操作继续要求严格确认。
- 版本号从 **1.185.0-rc1** 递增为 **1.185.0-rc2**，内部构建号从 **8** 递增为 **9**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

### Tests

- 新增工具族授权签名、会话授权隔离与 Computer Use / 浏览器原生授权卡快照测试；相关 17 项 Swift 定向测试通过。

## 1.185.0-rc1 - 2026-07-18

### Added

- Composer 粘贴或附加 UI 图片后新增“一键生成 UI 代码”入口；Web 目标自动启用 Browser 工具专家，SwiftUI 目标启用原生视觉实现技能，原图文件路径随执行契约传给模型。
- 新增 `design_to_code_acceptance` 视觉验收工具，对真实渲染截图执行像素相似度、OCR 文案覆盖率与主色板比较，并生成 `design-qa.md` 和 `.willdeep/design-to-code/visual-diff.png`。

### Changed

- “生成界面代码”入口现在按工作区类型确定性挂载 Web 或 SwiftUI 实现技能；Web 路径同时启用编码与浏览器操作专家，不再因本地化文案未命中关键词或缺少 `browserOps` 而偶发关闭验收面板。
- `/screenshot-to-code` 从只返回 starter code 的只读子工作流改为主 Agent 完整实现链路：直接编辑生产文件、构建运行、自动打开内置 Browser 工作台并按 Browser/Chrome/Computer Use 顺序截图、视觉比较与循环修正；静态页面在开发服务器受限时可直接验收 `file://` 渲染结果。
- 贴图后的生成入口与缩略图改为同一行自适应布局，避免矮窗口中操作按钮被裁掉；Slash 命令从旧工作流注册表中显式移除并由主 Agent 独占，杜绝同名入口误路由。
- 宿主新增贴图生成代码完成门禁；缺少成功文件写入、真实界面截图或最新视觉验收 `PASS` 时会自动续跑，禁止把分析、代码片段或未渲染结果冒充完成。
- Chrome 标签页截图结果补充本地文件路径，供视觉验收工具可靠消费；版本号从 **1.184.0-rc1** 提升为 **1.185.0-rc1**，内部构建号从 **7** 递增为 **8**。

### Tests

- 新增执行契约、完成门禁、工具注册与同图视觉验收的 Swift 定向测试，并对中英文字符串目录执行 JSON/Xcode 编译校验。

## 1.184.0-rc1 - 2026-07-18

### Added

- Computer Use 新增无截图的只读 AX 语义检查工具，不需要 Screen Recording 权限；新增按新鲜控件 ref、控件值与窗口标题轮询等待的能力，默认不截图并限制最长等待时间。
- Chrome 浏览器控制新增 DOM ref/唯一选择器悬停、按 value 或可见 label 选择原生下拉选项；按键控制补齐 Tab 焦点移动、Escape 失焦、Backspace/Delete 文本编辑及 Enter 激活/表单提交回退。

### Changed

- Computer Use Helper 与 Chrome Native Host 协议同步升级到 v3，能力声明、工具注册、界面摘要和模型执行提示完整贯通；动作链优先使用语义状态与条件等待，减少无意义截图和盲等。
- 将 `AgentComposerPickers.swift` 的运行上下文/审批 picker 拆到独立文件，将 `L10n.swift` 的工作区相关资源拆到扩展文件；两个主文件均降到 3000 行以内，复杂度守门硬性违规归零。
- 版本号从 **1.183.0-rc1** 提升为 **1.184.0-rc1**，内部构建号从 **6** 递增为 **7**。

### Tests

- 扩展 Computer Use 与 Chrome 的 Swift 单测、Ruby Markdown/JSON 合约报告和浏览器本地闭环夹具，覆盖无截图状态、条件等待、悬停、下拉选择及键盘语义回退。
- 通过 Swift 编译测试、Go Native Host 测试、JavaScript 语法检查、版本一致性检查、复杂度守门，并使用真实 macOS 应用与真实 Chrome 页面进行闭环验证。

## 1.183.0-rc1 - 2026-07-18

### Added

- Computer Use 新增前台激活应用、控件聚焦、悬停与文本选择动作；无障碍树补充控件 identifier、help、选中/展开状态、屏幕 frame 与中心点，`AXPress` 失败时可回退到控件中心点击。
- Chrome 浏览器控制新增标签页列表与切换、HTTP(S) 导航、前进/后退/刷新、结构化 DOM 快照、按键、滚动和页面条件等待；快照返回新鲜 element ref、可访问名称、角色、状态、选择器提示与视口坐标。
- Chrome 截图现在作为真正的图片附件返回给模型，不再把整段 base64 塞进文本结果；新增 Computer Use Helper 与 Chrome 扩展 Markdown/JSON 契约报告并接入一键测试。

### Changed

- Chrome 点击与输入优先接受 DOM 快照 ref，CSS selector 仅作为兼容回退且多匹配会直接拒绝；表单输入改用框架兼容的原生 value setter，并继续隐去密码、Token、OTP、信用卡等敏感字段值。
- Browser Ops 与 Computer Use 系统提示更新为“先列标签页/抓新快照、动作后等待并重抓”的闭环；版本号从 **1.182.0-rc1** 提升为 **1.183.0-rc1**，内部构建号从 **5** 递增为 **6**。

### Tests

- 新增 Chrome 工具风险等级、DOM ref 参数、缺失/冲突目标与等待条件校验测试；扩展脚本语法、16 项 Chrome 契约、5 项 Computer Use 契约和 Go Native Host 测试通过。
- 使用真实 macOS 应用与真实 Chrome 页面完成 Computer Use 和浏览器操作闭环验证。

## 1.182.0-rc1 - 2026-07-18

### Added

- Agent 侧边栏新增跨工作区的全局“置顶”分区；置顶会话统一显示在所有工作区之前，并按最近置顶时间排序。

### Changed

- 置顶会话不再重复出现在所属工作区内；取消置顶后会话回到原工作区，工作区绑定、选中状态、悬停操作与归档行为保持不变。
- 全局置顶会话采用一级导航缩进，与 Codex 的置顶层级一致；工作区内普通会话继续沿用原有子级缩进。
- 版本号从 **1.181.0-rc2** 提升为 **1.182.0-rc1**，内部构建号从 **4** 递增为 **5**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

### Tests

- 新增跨工作区置顶聚合、置顶空会话可见、归档置顶不进入全局分区及工作区列表不重复显示的回归测试。
- 更新生产侧边栏视觉快照，覆盖来自不同工作区的全局置顶会话及 12pt 一级标题列。

## 1.181.0-rc2 - 2026-07-18

### Fixed

- 修复默认启动界面切换为独立 Agent 窗口后，新用户首次启动不再展示 Onboarding 的回归；引导现在由 Agent 根窗口触发，并在弹出前准备好 some.im 登录与 Provider 配置所需的 AppState。
- 移除编辑器窗口对全局 Onboarding 弹窗状态的重复绑定，避免首次启动同时出现多个窗口时重复展示引导。

### Changed

- 版本号从 **1.181.0-rc1** 递增为 **1.181.0-rc2**，内部构建号从 **3** 递增为 **4**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

### Tests

- 新增默认 Agent 冷启动必须展示欢迎引导的 UI 回归测试；启动参数隔离首次启动标记，不读取或改写开发机的既有偏好。
- 通过版本一致性检查、macOS Debug 构建及设置导航定向测试。

## 1.181.0-rc1 - 2026-07-18

### Added

- App 菜单与“设置 → 通用 → 更新”新增“检查更新”入口，统一交由 Sparkle 展示当前状态、可用版本和安装流程。
- “格式与外观”新增“背景”子页，集中工作区与 Agent 全局背景设置，并提供可直接选中的“无背景图”卡片。
- macOS 发布脚本新增 `--publish-metadata-only` 恢复模式，可校验既有 DMG 的签名、公证票据、OSS 对象和 Sparkle 签名后补发 appcast 元数据。

### Changed

- 设置导航按通用、格式与外观、工作区、AI Agents、Agent 工具、账户与设备、运行时、集成等用户任务重新归类；过长侧栏改为可滚动，AI Provider 与 Skills/MCP/Tools 不再挤在同一二级分段中。
- 发布流程完整覆盖测试、Release Archive、App/DMG 双重公证、Sparkle Ed25519 签名、OSS 版本/latest 上传、some.im appcast 元数据和 JSON/Markdown 报告。
- 版本号从 **1.180.0-rc1** 提升为 **1.181.0-rc1**，内部构建号从 **2** 提升为 **3**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

### Fixed

- appcast 发布的 `published_at` 改用 MySQL `TIMESTAMP` 兼容的 UTC 格式，避免 RFC 3339 时间导致生产元数据写入失败。

### Tests

- 补充发布脚本恢复模式与数据库时间格式契约测试，并验证设置页本地化资源、版本一致性和 Release 构建。

## 1.180.0-rc1 - 2026-07-17

### Added

- 接入 Sparkle 2 自动更新：WillDeep 可通过 some.im 动态 appcast 检查更新、下载已签名 DMG、校验 Ed25519 签名，并在当前进程退出后由独立安装 helper 原子替换应用；安装失败自动回滚，成功后重新启动新版。
- 发布脚本在签名、公证后调用 Sparkle `sign_update`，上传 DMG 并自动向 muchtoken 写入语义版本、递增构建号、文件大小、SHA-256 与 Ed25519 签名元数据。

### Changed

- 侧边栏仍使用 JSON 更新接口展示新版本提示，点击更新改为交给 Sparkle 标准界面处理，不再把 DMG 下载到“下载”目录后让用户手动拖拽替换。
- 版本号从 **1.179.0-rc10** 提升为 **1.180.0-rc1**，内部构建号从 **1** 提升为 **2**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

### Security

- Sparkle 私钥仅保存在发布机器登录钥匙串；客户端只内置公钥，服务端拒绝缺少有效 Ed25519 签名、文件大小或正整数构建号的 macOS 更新记录。

### Tests

- 新增动态 appcast URL、Sparkle 发布签名参数和元数据发布契约测试；App 更新定向 Swift 测试通过，并隔离 XCTest 启动期间的线上更新请求。

---

## 1.179.0-rc10 - 2026-07-17

### Added

- Agent 会话在实际切换具体模型、跨供应商切换模型或切入省心托管时，都会插入一条带立方体图标与分隔线的提示，明确显示旧选择和新选择；重复选择当前模型不会产生重复提示。
- 模型切换提示作为本地会话事件持久化，保持可追溯，但不会进入任何模型供应商的请求上下文。

### Tests

- 新增模型切换提示、重复选择去重及本地提示不进入请求历史的回归测试。

---

## 1.179.0-rc9 - 2026-07-17

### Changed

- 将命令审批与二次确认合并为同一套柔和的圆角授权通知：移除红色危险强调和棱角分栏，以当前皮肤的面板、控件、描边与强调色呈现通知、内容、元信息和主次操作。
- 执行命令、侧边栏终端命令、终端控制键、网页抓取及其他工具按场景展示不同标题、说明、元信息和按钮语义；超长命令、网页地址或参数继续支持滚动查看与复制。
- 审批按钮提升到 42pt 最小高度和 14pt 连续圆角；“以后允许同类操作”降为次要文字操作，避免与本次允许争夺视觉层级。
- 版本号从 **1.179.0-rc8** 递增为 **1.179.0-rc9**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

### Tests

- 新增命令、侧边栏终端与网页访问授权文案回归测试，以及全部 7 套界面皮肤和宽窄布局的真实 SwiftUI 渲染测试。
- Debug 构建成功；授权通知目标测试及七套皮肤视觉渲染测试通过。

---

## 1.179.0-rc8 - 2026-07-17

### Fixed

- 修复重选当前工作区时仍重复触发 Quick Open、编辑器 Git 状态、Agent Git 状态与会话持久化的问题，并移除新工作区创建链路中的第二次重复 Git 刷新。
- 工作区首次 Git 快照不再使用 `git status -uall` 递归展开所有未跟踪文件，避免未忽略的依赖、构建产物或生成目录让 Git 在选目录时产生数 GB 内存峰值；Agent 工作区身份刷新也不再重复执行完整状态扫描。
- 工作区 Git 刷新按目录合并并在目标目录变化时取消旧任务；目录选择面板优先附着到当前窗口，降低大型仓库和部分 macOS 环境下的界面卡顿概率。
- 修复部分用户电脑上 `$` 技能选择框只显示一行的问题；候选数量充足时至少完整显示三行。

### Changed

- 知识文件夹在普通模式和计划模式中附加后保持待索引，由用户手动开始；目标模式继续自动在后台索引。目录内容变化后，普通/计划模式回到待索引，目标模式自动刷新。
- 版本号从 **1.179.0-rc7** 递增为 **1.179.0-rc8**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

### Tests

- 新增知识文件夹模式策略、技能选择框三行最小高度、重复选择当前工作区保持原会话，以及工作区首次 Git 状态仅汇总未跟踪目录的回归测试。

---

## 1.179.0-rc7 - 2026-07-17

### Fixed

- 修复未选择工作目录时点击“选择省心托管”或具体模型静默无反馈的问题；模型选择会先建立未绑定工作区的空会话，用户之后选择目录时原地绑定并保留所选模型。
- 省心托管状态卡整块均可点击启用，不再只有右上角的小按钮响应操作。

### Changed

- 版本号从 **1.179.0-rc6** 递增为 **1.179.0-rc7**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

### Tests

- 新增无工作目录模型选择回归测试，覆盖具体模型和省心托管均可先选、且会建立未绑定工作区的空会话。

---

## 1.179.0-rc6 - 2026-07-17

### Fixed

- 修复品牌从 VeilWriter 改为 WillDeep 时只切换 Application Support 目录、未迁移历史 Agent 会话的问题；启动和首次打开统计时会校验并幂等导入旧会话 JSON，恢复历史消息、token 总量、活跃天数与连续使用统计。
- 迁移不会删除旧文件，也不会覆盖当前目录中同 ID 的新会话；单个损坏 JSON 会被跳过，不影响其他历史记录恢复。

### Changed

- 版本号从 **1.179.0-rc5** 递增为 **1.179.0-rc6**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

### Tests

- 新增旧目录导入回归测试，覆盖首次恢复、重复执行幂等、当前数据优先及损坏文件隔离。

---

## 1.179.0-rc5 - 2026-07-17

### Fixed

- 将 Agent 全局壁纸设置从 AI Agents 配置页迁移到“编辑器 → 格式”，避免把视觉外观设置误归类为 Agent 能力配置。
- 合并重复的壁纸选择界面：内置图库、自定义图片与布局参数只在工作区壁纸区维护，Agent 区仅保留启用开关、界面遮罩透明度与毛玻璃控制。

### Changed

- 版本号从 **1.179.0-rc4** 递增为 **1.179.0-rc5**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

### Tests

- 设置页源码边界、JSON 资源与版本一致性检查通过；Debug 构建成功，`WorkspaceWallpaperTests` 共 6 项测试通过。

---

## 1.179.0-rc4 - 2026-07-17

### Fixed

- 修复 macOS Release 导出包中的 `willdeep-agent` 与 `WillDeepComputerUseHelper` 未启用 Hardened Runtime，导致本地严格签名校验通过但 Apple 公证返回 `Invalid` 的问题。
- 发布脚本现在使用 Developer ID、可信时间戳和 runtime 选项按嵌套层级重签两个辅助可执行文件，并保留主 App 的 identifier、entitlement、requirements 和签名 flags 后重新封装。
- 修复 `create-dmg --app-drop-link` 与预建 `Applications` 符号链接重复执行，导致已公证 App 无法继续生成 DMG 的问题；预建链接现在仅供 `hdiutil` 回退路径使用。

### Changed

- Ruby 发布脚本版本从 **1.0.0** 递增为 **1.0.2**；应用版本从 **1.179.0-rc3** 递增为 **1.179.0-rc4**，所有前后端版本面与文档同步。

### Tests

- 发布脚本合约测试新增 Hardened Runtime、时间戳、嵌套签名顺序、主 App 元数据保留及 `create-dmg` 链接职责断言。

---

## 1.179.0-rc3 - 2026-07-17

### Fixed

- 修复计划尚未批准时，公开网页 `web_fetch` 调研请求被直接标记为拒绝的问题；通过公网 URL 校验的 GET 抓取现在按静态安全策略自动执行，私网、localhost、link-local、危险命令和真实写操作仍保持拦截。

### Changed

- 计划模式提示词与网页工具说明同步明确：可在起草计划前使用 `web_search` 和经过校验的公开网页抓取进行只读调研，计划发出后仍必须停止并等待用户批准。
- 版本号从 **1.179.0-rc2** 递增为 **1.179.0-rc3**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

### Tests

- 新增计划门与自动审批回归测试，覆盖公开 URL 自动放行、私网 URL 拒绝及普通写命令继续等待计划批准；网页工具与计划进度两组定向测试共 39 项通过。

---

## 1.179.0-rc2 - 2026-07-17

### Fixed

- 修复完整 Release 测试集中超大 Diff 截断用例仍断言旧版中文提示的问题；测试改为校验字节/行预算、保留样本与完整 Diff 命令，不再依赖具体界面语言或易变文案。

### Changed

- 版本号从 **1.179.0-rc1** 递增为 **1.179.0-rc2**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

### Tests

- 重新执行项目级 Release 全量测试守门，覆盖 1245 项 XeditTests。

---

## 1.179.0-rc1 - 2026-07-17

### Added

- 悬浮语音转写条新增正弦波、余弦波和心电图 3 种连续动态波形；振幅跟随实时输入音量，设置页预览与实际录音悬浮条共用同一渲染实现。
- 新增天空玻璃、薄荷奶油、薰衣草雾、蜜桃冰沙、玫瑰晶石、柠檬奶油、水色玻璃和暖沙金 8 种明亮背景预设，并为浅色背景配置高对比波形色与描边。

### Changed

- 版本号从 **1.178.0-rc1** 提升为 **1.179.0-rc1**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

### Tests

- 新增连续信号采样、波形数量、浅色预设数量、背景不透明度与本地化名称回归断言，并输出三种连续波形与八种浅色背景的设计 QA 快照。

---

## 1.178.0-rc1 - 2026-07-17

### Added

- 设置 → AI Agent 新增全局背景设置，可直接选用 8 张内置 4K 壁纸或自定义图片，并支持填充、适应、拉伸、居中、平铺和缩放。
- 新增 Agent 壁纸透明度、内容表面透明度与毛玻璃开关；毛玻璃支持材质和强度调整，并覆盖会话栏、聊天区及右侧工具面板。

### Fixed

- some.im 设置页与 Agent 左下角账号区统一使用“共享 API 凭据 + 账号资料”的认证快照；退出登录或共享凭据失效后，两处会同步显示未登录，不再把残留账号缓存误报为 Connected。

### Changed

- 版本号从 **1.177.0-rc3** 提升为 **1.178.0-rc1**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

### Tests

- 新增认证快照、Agent 壁纸开关、平铺模式、透明度边界与内置壁纸资源回归断言；完成 Debug 构建和定向测试验证。

---

## 1.177.0-rc3 - 2026-07-17

### Changed

- 将单轮 Agent 工具调用安全上限从 64 轮提高到 256 轮，长时间排查、开发和验证任务可连续执行更久；达到上限时仍会暂停，继续保留意外循环保护。
- 版本号从 **1.177.0-rc2** 递增为 **1.177.0-rc3**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

### Tests

- 新增工具轮次安全上限回归断言，锁定实际运行常量为 256。

---

## 1.177.0-rc2 - 2026-07-17

### Fixed

- 修复 some.im 账号状态与 Agent Provider 凭据分裂的问题：App 启动、新消息发送、错误重试及后台续跑前都会从共享会话补齐当前 Provider 的 API Key，区域探测失败不再阻断凭据同步。
- 侧边栏不再把残留的账号资料缓存误判为已登录；共享 API 凭据缺失时会正确显示未登录状态，引导用户重新登录。
- 修复命令确认卡“查看解释与解决建议”在 Coding Plan 有效时请求不存在模型、导致服务返回 HTTP 400 的问题；解释请求改用已配置的 `someim-coding-plan-low`，失败时自动回退 `someim-auto-flash`。
- 解释失败提示改用统一的 provider 错误解析，直接展示脱敏、截断后的服务端原因，不再只留下缺少上下文的 HTTP 状态码。

### Changed

- 版本号从 **1.177.0-rc1** 递增为 **1.177.0-rc2**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

### Tests

- 新增共享凭据启动同步、发送前自愈、区域探测失败保留凭据、账号缓存不可冒充登录及启动顺序回归测试。
- 新增审核解释路由回归测试，锁定 Coding Plan 模型名称、`someim-auto-flash` 回退顺序、非套餐路由和 provider 错误正文展示。

---

## 1.177.0-rc1 - 2026-07-17

### Added

- 新增内置 `mac-app-docs-site` 技能：可通过 WillDeep 或 Codex Desktop 的 Computer Use 能力采集真实 macOS App 界面与流程截图，生成带 front matter、章节导航、相对图片和安全说明的图文 Markdown 教程，并按目标项目既有模式接入文档网页。
- 技能附带教程首页/章节模板、双宿主 Computer Use 适配说明、Markdown 与网页接入规范，以及 Ruby 文档审计器；审计器会检查章节顺序、链接、图片、本机绝对路径和孤儿资源，并同时生成 Markdown 与 JSON 报告。

### Changed

- 版本号从 **1.176.0-rc8** 提升为 **1.177.0-rc1**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

### Tests

- 通过 `skill-creator` 官方结构校验；以现有 `docs/willdeep-tutorial` 作为真实样例运行文档审计，9 个 Markdown 页面与 13 张界面图片全部通过，0 错误、0 警告；`AgentSkillDirectoryTests` 12 项定向测试通过，确认技能会被打包、发现并读取。

---

## 1.176.0-rc8 - 2026-07-17

### Fixed

- 命令确认卡的“拒绝 / 允许”按钮降低高度并限制最大宽度，避免窄屏上下布局中横向铺成两块大按钮；左右、上下两种布局的按钮间距统一扩大到 24pt。

### Changed

- 版本号从 **1.176.0-rc7** 递增为 **1.176.0-rc8**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

### Tests

- 补充命令确认按钮高度、最大宽度、间距及宽窄双布局视觉快照回归断言。

---

## 1.176.0-rc7 - 2026-07-17

### Fixed

- 修复右侧 Diff 面板在工作区变更较多、尤其包含大量中文内容时明显卡顿的问题：入口先加载轻量文件清单，只有选中单个文件后才读取对应 diff；正文改由支持非连续布局的 TextKit `NSTextView` 渲染，避免 SwiftUI 在首帧同步排版整份大文本。
- Diff 显示预算统一按 UTF-8 字节数与行数双重限制，未跟踪文件继续纳入清单与按需预览；超限内容展示有界样本，避免多字节文本绕过原字符数阈值。

### Changed

- 版本号从 **1.176.0-rc6** 递增为 **1.176.0-rc7**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

### Tests

- 新增 Diff 性能回归测试，覆盖中文 UTF-8 字节预算、超长行数、Unicode 标量安全截断、按文件延迟加载、未跟踪文件预览以及 TextKit 非连续布局契约。

---

## 1.176.0-rc6 - 2026-07-17

### Fixed

- 桌面宠物拖动改为基于鼠标按下位置与窗口起点的全局坐标直接定位，避免移动窗口导致 SwiftUI 局部累计位移漂移；拖动状态只在开始时发布一次，减少逐帧重绘，使宠物在保留走路动画的同时平滑、及时跟随鼠标。

### Changed

- 版本号从 **1.176.0-rc5** 递增为 **1.176.0-rc6**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

### Tests

- 新增桌面宠物全局拖动坐标测试，覆盖快速跨距离移动与 SwiftUI/AppKit 纵轴方向转换，防止累计误差和迟滞回归。

---

## 1.176.0-rc5 - 2026-07-17

### Fixed

- 终端捷径录制说明改为“录制常用命令，之后可快捷执行”，并将用户可见的“回放”术语统一调整为“执行”，准确表达快速运行常用命令的核心用途。

### Changed

- 版本号从 **1.176.0-rc4** 递增为 **1.176.0-rc5**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

### Tests

- 新增终端捷径文案契约测试，确保说明突出快捷执行命令，并防止“重复播放 / 回放”术语回归。

---

## 1.176.0-rc4 - 2026-07-17

### Fixed

- 终端“最近捷径”的执行按钮移除圆形底板与描边，缩小图标占位并收紧行间距；列表在原 84pt 可视高度内由 2 行提升为 3 行，保留停止态颜色和完整点击区域。

### Changed

- 版本号从 **1.176.0-rc3** 递增为 **1.176.0-rc4**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

### Tests

- 新增终端捷径紧凑布局契约测试，校验三行容量、28pt 行高、22pt 执行图标占位以及无圆形外框。

---

## 1.176.0-rc3 - 2026-07-17

### Fixed

- 助手消息顶部“已处理 / 处理中”状态行改为与正文使用完全一致的系统字体、字号和常规字重，仅通过三级文本颜色维持弱化层级，不再显得比正文更粗。

### Changed

- 版本号从 **1.176.0-rc2** 递增为 **1.176.0-rc3**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

### Tests

- 扩展助手状态分隔线渲染测试，断言“已处理”与正文的字体描述符和字号完全一致。

---

## 1.176.0-rc2 - 2026-07-17

### Fixed

- 会话通过 Claude Code、Codex CLI、Cursor Agent 或 Cline 发起可见终端委托时，新建或复用的委托标签页保持为当前活跃标签页，不再被侧边终端面板的延迟初始化切回旧会话终端。

### Changed

- 版本号从 **1.176.0-rc1** 递增为 **1.176.0-rc2**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

### Tests

- 新增侧边终端初始化回归测试，覆盖委托执行期间保留委托标签页、委托结束后恢复会话绑定终端的行为。

---

## 1.176.0-rc1 - 2026-07-16

### Fixed

- 桌面宠物随机红心从高饱和纯红调整为更柔和的珊瑚粉与浅粉双色，降低视觉刺激，同时保留红心辨识度。

### Changed

- 版本号从 **1.176.0** 递增为 **1.176.0-rc1**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

### Tests

- 重新生成桌宠六场景视觉快照，检查嘴唇、泡泡、柔和红心与星星的独立显示效果。

---

## 1.176.0 - 2026-07-16

### Added

- 桌面宠物待机彩蛋改为互斥随机事件：每次只出现嘴唇、星星、红心或泡泡中的一种；嘴唇既可能单独出现，也可能成群出现。
- 所有彩蛋粒子按错峰节奏从小变大、回缩并淡出；宠物空闲时每 14–32 秒会自主短跳一次，忙碌或拖动时不会抢占当前动作。

### Changed

- Agent 统计概览移除“本周交付物”和“失败工具调用复盘”卡片，保留核心指标、活动热力图、使用洞察和能力统计。
- 版本号从 **1.175.0-rc4** 提升为 **1.176.0**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

### Tests

- 新增桌宠特效类型覆盖、嘴唇单个/成群分布、粒子缩放淡出曲线与自主跳跃间隔边界测试。

---

## 1.175.0-rc4 - 2026-07-16

### Performance

- 会话保存时同步维护版本化的轻量目录 sidecar；正常启动只读取标题、工作区、更新时间等列表元数据，不再逐个解析可能包含长文本与图片的完整聊天 JSON。
- 用量统计移出 App 启动链路，仅在统计面板首次显示时后台按需加载；加载期间产生的实时统计优先于磁盘旧快照。

### Fixed

- 轻量目录缺失、损坏或与完整会话的文件大小/修改时间签名不一致时，会自动回退到完整会话并重建目录，避免旧版本写入、跨进程修改或手动恢复导致列表信息陈旧。

### Documentation

- 新增覆盖快速开始、工作区与会话、模型与审批、侧栏、自动化、媒体、编辑器、设置及排错的 WillDeep 图文教程，并配套脱敏后的真实界面截图。

### Changed

- 版本号从 **1.175.0-rc3** 递增为 **1.175.0-rc4**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

### Tests

- 新增轻量目录体积、元数据加载、用户消息标记及陈旧目录自动修复回归测试；会话存储定向测试共 43 项通过。

---

## 1.175.0-rc3 - 2026-07-16

### Fixed

- 命令确认卡按实际可用宽度稳定切换布局：宽屏使用左右双栏，窄屏回退为上下结构，不再被长命令的理想宽度误导。
- “拒绝 / 允许执行”在两种布局下均保持同一行，拒绝在左、允许在右；命令视口收紧为约 2 行，长内容继续支持纵向滚动。

### Changed

- 版本号从 **1.175.0-rc2** 递增为 **1.175.0-rc3**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

### Tests

- 更新命令视口高度契约，新增确认卡宽窄布局断点回归断言与双尺寸视觉快照测试。

---

## 1.175.0-rc2 - 2026-07-16

### Fixed

- 移除右上角产物、媒体与 Dev Server 浮动摘要卡中无必要的大于号，保留卡片主体点击行为。
- 移除聊天工具活动摘要最前面的展开三角形；摘要文字本身仍可点击展开或收起详细调用记录。
- 宽 Markdown 表格改为在聊天白色表格区域内尾部省略，并扩展底板至实际文字裁切边界，避免右侧长内容越界；点击表格仍会打开支持横向滚动的原生表格窗口，底层全文保持可复制。

### Changed

- 版本号从 **1.175.0-rc1** 递增为 **1.175.0-rc2**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

### Tests

- 更新无三角形工具摘要断言，并新增浮动卡无大于号、表格尾部省略及底板覆盖裁切边界回归测试。

---

## 1.175.0-rc1 - 2026-07-16

### Fixed

- 修复连续创建或编辑文件时实时执行区重复显示多条活动摘要的问题；相邻文件写入现在聚合为一条，并显示合计文件数。
- 实时工具摘要卡片复用助手正文的水平缩进，左边缘与上方回答内容对齐。

### Changed

- 版本号从 **1.175.0** 递增为 **1.175.0-rc1**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

### Tests

- 新增连续文件创建聚合与交互式 Patch 保持独立的回归测试。

---

## 1.175.0 - 2026-07-16

### Added

- **Agent 流式思考支持 Markdown。** 思考内容在生成过程中使用单一富文本视图增量渲染标题、列表、强调、链接和代码样式，避免逐段视图抖动，并与正式回答保持一致的阅读体验。
- **Git worktree 默认隔离到应用目录。** 新建 worktree 统一存放在 `~/.willdeep/worktrees/<repository-hash>/<branch>`，不再污染仓库父目录；相同仓库和分支仍可稳定复用路径。

### Fixed

- 修复聊天 Markdown 表格与后续段落间距不足的问题，避免表格和正文视觉粘连。

### Changed

- 版本号从 **1.174.0** 提升为 **1.175.0**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

### Tests

- 补充流式思考 Markdown、表格块间距和 Git worktree 路径隔离回归测试。

---

## 1.174.0 - 2026-07-16

### Added

- **附件解析正文改用内容寻址 sidecar。** 会话文档和知识文件夹解析出的全文按 SHA-256 写入 Application Support，相同内容自动复用；session JSON 只保留分段摘要、文件引用与哈希，避免大量附件正文常驻会话快照并在每次持久化时重复编码。

### Changed

- 附件列表、分段勾选与状态统计只读取轻量摘要；发送、引用与导出时才按需加载全文并验证 SHA-256。旧版内联会话保持兼容，并在下次保存时自动外置迁移；外置失败时安全保留内联正文。
- 版本号从 **1.173.0-rc1** 提升为 **1.174.0**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

### Tests

- 新增附件 sidecar 往返、内容去重、旧 JSON 兼容、会话与知识文件夹快照外置，以及篡改内容拒绝回归测试。

---

## 1.173.0-rc1 - 2026-07-16

### Fixed

- **Workflow 可取消生命周期与 Agent 结果闭环。** 运行卡片提供实时耗时与“停止”操作，`/stop` 同时取消当前模型轮次和活动工作流；工作流任务归属实际 Agent runtime，会话清空、删除、裁剪或闲置驱逐时同步取消。
- **工作流运行上下文不再串会话。** `run_workflow` 按工具调用所在会话、工作区与远端 runtime 启动，缺少必要参数时返回真实拒绝；完成、失败或取消结果以一次性 system 通知进入模型上下文并触发后续处理。
- **声明式并行步骤可控执行。** `workflow.yaml` 中连续的 `parallel: true` 步骤按 `max_agents` 并发执行，父任务取消会传播到所有子任务；未声明并行的工作流继续保持串行语义，重启后遗留运行态归一为 Cancelled。

### Changed

- 版本号从 **1.173.0** 递增为 **1.173.0-rc1**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

### Tests

- 新增工作流精确 runtime 路由、缺参数拒绝、取消生命周期、结果通知只消费一次、父任务取消传播、恢复中断状态，以及 declarative parallel 解析回归。

---

## 1.173.0 - 2026-07-16

### Added

- **摘要卡支持独立关闭。** 产物、媒体与 Dev Server 卡片右上角新增小型关闭按钮；关闭只隐藏当前摘要，不删除文件、不取消媒体任务，也不停止工作区服务。相同内容保持隐藏，出现新产物、媒体生命周期变化或 Dev Server 重启后会自动重新展示。

### Changed

- **摘要卡统一淡灰描边。** 卡片边框改用系统自适应分隔色，选中态只提升灰色描边强度，不再使用高饱和强调色；浅色与深色外观均保持低对比度。
- 版本号从 **1.172.0-rc2** 提升为 **1.173.0**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

### Tests

- 新增摘要关闭键稳定性测试，验证普通轮询输出不会让已关闭卡片反复出现，而新增文件、媒体状态变化与新 Dev Server 任务会生成新的摘要状态；补充淡灰边框和关闭按钮源码契约。

---

## 1.172.0-rc2 - 2026-07-16

### Fixed

- **“春庭旗韵”改为高颜值半身主视觉。** 重制内置旗袍壁纸，人物由远景全身改为腰胸以上构图，显著放大并锐化面部焦点，同时保留江南春庭氛围和右侧桌面留白。
- 4K 主图与 480×270 设置页缩略图同步替换，沿用原有稳定资源标识，已选择该壁纸的用户无需重新设置。

### Changed

- 版本号从 **1.172.0-rc1** 递增为 **1.172.0-rc2**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

---

## 1.172.0-rc1 - 2026-07-16

### Fixed

- **单字符 inline code 背景不再蹭到前文。** TextKit 历史消息的代码胶囊横向外扩从 4pt 收紧为 2pt；像“以下是 `/` 目录”这样的短标记仍保留左右留白，但背景不会越过普通空格叠到前一个汉字。

### Tests

- 新增“中文 + 空格 + 单字符 `/`”字形几何回归测试，锁定胶囊覆盖代码字形且左边界不越过前文字形。

### Changed

- 版本号从 **1.172.0** 递增为 **1.172.0-rc1**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

---

## 1.172.0 - 2026-07-16

### Added

- **聊天区右上角事件摘要卡。** 会话产生文件、媒体产物或当前工作区启动 Dev Server 时，聊天区右上角按需展示小型摘要卡；没有变化时不占界面空间。点击文件可直接打开文件侧栏或 HTML 预览，点击媒体进入集中式媒体工作台，点击 Dev Server 可直接预览或进入服务管理。
- **工作区共享 Dev Server 控制。** Dev Server 摘要跨同一 workspace 的会话聚合运行任务，明确标注“工作区共享”，并提供预览、管理、全部重启和全部停止；文件与媒体摘要仍严格按当前会话隔离。

### Changed

- **媒体侧栏整合编辑工作流。** 媒体任务筛选、状态摘要、批量刷新与任务回传集中到侧栏顶部；图片缩略图操作收拢为菜单，继续提供局部重绘、擦除蒙版、放大、发送到聊天、设为分镜主图和设为人物/场景参考图。
- **移除任务监控常驻侧栏。** 旧“任务监控”入口不再显示，也不会因后台任务或媒体完成自动抢开侧栏；历史持久化值仅保留兼容读取并在进入界面时归一化关闭。
- 版本号从 **1.171.0** 提升为 **1.172.0**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

### Fixed

- 修正终端捷径受保护输入检测的谓词调用，并补齐 Release Notes Workflow 的异步 GitHub CLI 预检等待，恢复当前工作树的完整编译。

### Tests

- 新增会话级媒体隔离、工作区级 Dev Server URL 解析与命令端口回退测试；更新侧栏焦点和短剧媒体契约，锁定“完成后只提示、不自动开侧栏”的交互。

---

## 1.171.0 - 2026-07-16

### Added

- **桌面宠物新增“宇宙响指官”。** 新增 1254×1254 透明像素角色素材，以原创紫色光头宇宙壮汉、夸张裸手响指姿势和午夜蓝礼服呈现恶搞气质；不使用角色原名、宝石手套、影视盔甲或现代科技道具。
- **响指角色完整接入宠物系统。** 设置 → 桌面宠物可直接选择“宇宙响指官”，并自动继承行走、打字、跳跃、提醒、庆祝和呼吸动画；待机彩蛋替换为贴合手势位置的紫色蓄力光圈、闪光与回弹效果。

### Fixed

- **数据库探索 Workflow 恢复编译。** `/db-explore` 调用异步数据库工具预检时补上 `await`，确保 CLI 与目标文件检查完成后再继续执行 schema 探索，并消除 Swift 并发检查报错。

### Tests

- 桌面宠物测试补充新素材稳定名称、25 个外观总数及透明角像素断言，并把响指角色加入动画视觉回归画布。

### Changed

- 版本号从 **1.170.0-rc1** 提升为 **1.171.0**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

---

## 1.170.0 - 2026-07-16

### Added

- **WillDeep 官方内置 8 张 4K 工作区壁纸。** 新增柔光渐变、环形星球、原创卡通天空花园、古典旗袍庭院、雪山镜湖、草原长河、热带鱼珊瑚海和极光科幻峡湾八个主题；成品统一为 3840×2160 JPEG，并配套 480×270 设置缩略图，完整资源约 9.7 MB。
- **设置页直接预览并选择内置壁纸。** 设置 → 编辑器 → 格式以响应式缩略图网格展示内置图库；选择后继续复用填充、适应、拉伸、居中、缩放与透明度控制，自定义图片选择入口保持不变。
- **内置选择跨安装路径稳定。** 设置保存稳定的 `willdeep-builtin-wallpaper://` 标识，运行时再解析当前 App Bundle 资源，避免 Debug、Release 或应用升级后旧绝对路径失效。

### Tests

- 新增内置壁纸目录契约测试，锁定 8 个唯一稳定 ID、持久化标识往返，以及全部 4K 原图和缩略图的文件数量与像素尺寸；自定义文件路径解析继续覆盖。

### Changed

- 版本号从 **1.169.0-rc1** 提升为 **1.170.0**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

---

## 1.169.0-rc1 - 2026-07-16

### Fixed

- **折叠工具摘要不再透出调用细节。** 工具组未展开时只展示聚合后的活动描述，不再显示文件路径、命令、查询、提示词、工具原始 ID 或结果摘要；展开后仍保留完整调用参数供审计。
- **工具活动描述更具体。** 新增文件生成、文件修改、图片读取、图片生成、图片处理和截图等分类，例如连续创建三个文件会显示“生成了 3 个文件”；无法识别的工具统一回退为“执行了 N 次工具调用”。

### Tests

- 新增文件生成、图片读取和未知工具兜底的折叠态回归测试，并验证折叠文本不包含路径、参数与工具 ID。

### Changed

- 版本号从 **1.169.0** 递增为 **1.169.0-rc1**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

---

## 1.169.0 - 2026-07-16

### Added

- **终端捷径支持克隆。** 右键更多菜单新增“克隆”，会创建名称为“原名字-副本”的独立持久化副本；新副本使用新的捷径 ID 和事件 ID，受保护输入也使用独立的本地凭据引用。

### Fixed

- **编辑只打开当前终端捷径。** 不再把所有捷径的 `shortcuts.json` 一股脑塞进编辑器，而是为所选捷径生成单对象 JSON；其他捷径不会出现在本次编辑内容中。
- **JSON 保存后立即生效。** 保存单条捷径 JSON 时按文件名中的稳定 ID 合并回内存列表和总存储，重新打开会展示刚保存的内容，不再被旧内存状态覆盖。

### Changed

- 用户界面的功能名、最近列表、空状态及 Agent 工具展示统一使用“终端捷径”；“开始录制 / 停止录制”继续作为动作描述。
- 版本号从 **1.168.0-rc8** 提升为 **1.169.0**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

### Tests

- 新增单条 JSON 隔离、保存合并、重新打开，以及克隆 ID/事件独立和持久化回归测试。

---

## 1.168.0-rc8 - 2026-07-16

### Fixed

- **Editor 标签关闭图标不再抢键盘焦点。** 标签名右侧的关闭按钮显式应用 `.focusable(false)`，Tab 导航会跳过该快捷操作；鼠标关闭与无障碍标签保持原有行为。

### Tests

- 新增 Editor 标签栏焦点策略契约测试，锁定关闭按钮在 plain 样式后紧邻不可聚焦策略，防止后续样式重构重新把它加入焦点链。

### Changed

- 版本号从 **1.168.0-rc7** 递增为 **1.168.0-rc8**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

---

## 1.168.0-rc7 - 2026-07-16

### Fixed

- **“未打开文件”空窗口彻底移除。** 删除残留的 `EmptyProjectEditorView`、按钮样式及专属本地化词条；新建 Editor 或打开文件夹时始终先创建可编辑的 Untitled 标签，关闭最后一个标签时直接关闭整个 Editor 窗口，不再进入空态页面。

### Tests

- 新增 Editor 窗口生命周期策略回归测试，锁定仅从“有标签”切换到“零标签”时关闭窗口，普通创建和标签切换不会误关。

### Changed

- 版本号从 **1.168.0-rc6** 递增为 **1.168.0-rc7**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

---

## 1.168.0-rc6 - 2026-07-16

### Fixed

- **实时工具组不再重复报命令数量。** 移除截图中第二层“已运行 N 条命令”标题及其图标；工具组标题行直接从具体命令摘要或执行状态开始，仍保留折叠箭头、逐条状态和完整明细。

### Changed

- 版本号从 **1.168.0-rc5** 递增为 **1.168.0-rc6**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

---

## 1.168.0-rc5 - 2026-07-16

### Fixed

- **连续工具活动合并为一层。** assistant 正文携带的工具调用与紧随其后的 tool-only 消息不再拆成两行“已运行 / 已读取”摘要；TextKit 历史与旧侧栏聊天都按同一批活动聚合为一个可展开层，展开后仍保留每次调用明细。
- **思考内容改用正文展示。** reasoning 不再压成灰色两行尾部预览，而是使用与流式回答相同的字号、行距和正文渲染；主聊天与旧侧栏行为一致。
- **思考到正文原子切换。** reasoning 与 answer 增量继续共用 100 ms 防抖窗口，但同一批次只发布一次消息更新；首个正文 token 到达时，思考区在同一渲染帧移除并由正文接替，不做交叉淡入或双层闪动。

### Tests

- 新增“正文内工具 + 后续 tool-only 工具”单层折叠/展开回归测试，以及 reasoning 与正文同批 flush 只触发一次发布的原子性测试。

### Changed

- 版本号从 **1.168.0-rc4** 递增为 **1.168.0-rc5**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

---

## 1.168.0-rc4 - 2026-07-16

### Fixed

- **命令确认不再像“红色警报现场”。** 高风险命令审批改为单层边框的左右审阅布局，移除上方“已运行 N 条命令”汇总行、重复工具标题与夸张危险色；说明文案改为中性授权语气，仍明确提示用户检查命令。
- **长命令保持可读。** 命令视口固定展示约 3 行，超出部分支持纵向滚动，并保留复制、工作目录、可能修改文件与命令说明入口。
- **审批操作跟随皮肤。** 卡片底色、分隔线、正文、状态点及允许/拒绝按钮统一使用当前界面皮肤的语义色，不再硬编码红色；当前实现没有绑定 `⌘↩`，因此不展示虚假的快捷键提示。

### Tests

- 新增命令确认布局契约测试，锁定 3 行可视区、横向布局宽度、操作栏尺寸与快捷键提示关闭状态。

### Changed

- 版本号从 **1.168.0-rc3** 递增为 **1.168.0-rc4**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

---

## 1.168.0-rc3 - 2026-07-16

### Fixed

- **工具审批按钮恢复 macOS 13.7 兼容。** 三处按钮边框统一走兼容修饰器：macOS 14+ 使用 9pt 自定义圆角，macOS 13.7 回退到系统圆角矩形，不再直接调用仅 macOS 14 可用的 `roundedRectangle(radius:)`；按钮的最小尺寸、完整命中区域和视觉层级保持不变。
- 审批工具组拆分出的 `collapsibleGroupBody` 补充显式返回值，消除局部常量存在时 `some View` 无法推断底层类型的编译错误。

### Tests

- `AgentToolCallViews.swift` 已通过项目 `arm64-apple-macos13.7` 目标编译，原三处 API 可用性错误不再出现；完整定向测试继续编译工作树其他文件时，被 `DBExploreWorkflow.swift` 现有的异步调用缺少 `await` 错误阻断。

### Changed

- 版本号从 **1.168.0-rc2** 递增为 **1.168.0-rc3**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

---

## 1.168.0-rc2 - 2026-07-16

### Fixed

- **左侧栏“新聊天”入口适度上移。** 保留 30pt macOS 交通灯安全区，将其下方额外顶部内边距由 8pt 收紧为 3pt，入口整体上移 5pt，同时继续保留舒适留白并避免与窗口控制按钮重叠。

### Changed

- 版本号从 **1.168.0-rc1** 递增为 **1.168.0-rc2**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

---

## 1.168.0-rc1 - 2026-07-16

### Fixed

- **工具审批按钮不再“看得见、点不中”。** “拒绝 / 始终允许 / 允许”移除 caption 小字号与 small 控件尺寸，按钮完整可见表面都参与命中测试，最小高度提升到 36pt；拒绝改为红色描边，允许保留主题色主操作，并统一加入语义图标、9pt 圆角和更舒展的间距。

### Tests

- 新增审批操作区尺寸契约测试，锁定按钮最小宽高、间距和圆角，避免后续样式整理又把关键操作压回难点击的小控件。

### Changed

- 版本号从 **1.168.0** 递增为 **1.168.0-rc1**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

---

## 1.168.0 - 2026-07-16

### Added

- **WillDeep 工作区正式支持自定义壁纸。** 设置 → 编辑器 → 格式中的背景图升级为“工作区壁纸”，同一张图片会同时应用到编辑器详情区和独立 Agent 窗口；支持填充裁剪、适应、拉伸、居中、缩放与透明度调节，Agent 中央画布使用半透明皮肤承载内容，导航侧栏与工具面板继续保持稳定对比度。
- **壁纸改为应用托管副本。** 选图后在后台校验图片格式、64 MB 文件上限与 8000 万像素上限，再以仅当前用户可读写的权限复制到 WillDeep Application Support；原图移动、重命名或位于临时目录时，重启后仍可正常显示。清除或替换壁纸会一并清理旧托管副本。
- **壁纸设置完整支持中英文。** 工作区壁纸标题、说明、选图面板、四种显示模式和失败提示全部接入 String Catalog。

### Tests

- 新增壁纸托管安装、清理、非法图片拒绝、持久化路径兼容与 Agent 内容表面对比度回归测试；背景图片改为仅在路径变化时异步读取，避免流式聊天重绘期间反复从磁盘解码。

### Changed

- 版本号从 **1.167.0-rc9** 提升为 **1.168.0**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

---

## 1.167.0-rc9 - 2026-07-16

### Fixed

- **独立转录阅读窗口不再一次性渲染完整长会话。** 阅读器按 60 条消息分页、默认定位最新页，并提供前后翻页与当前页提示；数千条消息及多图会话任一时刻只构建当前页的 `NSAttributedString`，刷新时若用户停留在最新页会继续跟随新消息，否则保留正在阅读的历史页。
- **拖拽窗口不再每变化 1pt 就全量重建聊天富文本。** TextKit 布局宽度向下量化到 8pt 桶，渲染缓存 key 与 `setFrameSize` 重绘门槛共享同一分桶结果；桶内尺寸变化直接复用缓存，最大排版宽度偏差为 7pt，且不会超出实际可用宽度。

### Tests

- 新增转录分页的空会话、整页、尾页、越界页回归断言，以及 8pt 布局桶的桶内稳定、跨桶变化和非法宽度回退断言。
- 会话存储回归测试的清理逻辑改为只删除用例明确创建的会话 ID，避免后台目录索引完成后把真实用户会话误判为测试数据。

### Changed

- 版本号从 **1.167.0-rc8** 递增为 **1.167.0-rc9**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

---

## 1.167.0-rc8 - 2026-07-16

### Fixed

- **侧边栏底部用户卡片不再呈现突兀的纯白底。** 卡片背景改为皮肤控件底色、强调色与前景色的轻量分层混合；浅色皮肤略微压暗并保留主题色相，深色皮肤自动提亮形成同等层级，悬停与选中反馈保持不变。

### Tests

- 账户页脚视觉指标测试新增背景分层参数断言，并保留浅色皮肤截图渲染入口用于视觉回归。

### Changed

- 版本号从 **1.167.0-rc7** 递增为 **1.167.0-rc8**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

---

## 1.167.0-rc7 - 2026-07-16

### Fixed

**稳定性（崩溃/死锁/竞态）**

- **MCP 服务器 / Computer Use helper 死亡后写 stdin 不再崩整个 App。** 两处 legacy `FileHandle.write(_:)` 在 broken pipe 上会抛不可捕获的 ObjC 异常；改用 `write(contentsOf:)`，失败转为可展示的工具错误。
- **LSP 服务器 stderr 管道从不排水导致的整体冻结。** 话痨型语言服务器（rust-analyzer、tsserver verbose）写满 64KB 管道缓冲后会卡死且不退出，之后所有补全/诊断请求永久悬挂；现挂排水 handler 丢弃 stderr。
- **Computer Use helper 同款 stderr 排水缺失**（累积日志超 64KB 后所有 computer-use 调用超时且不自愈）一并修复；两处 stdout EOF 后 readabilityHandler 空转烧 CPU 的问题也已置 nil 退出。
- **本地模型下载完成后间歇性 "no such file"。** `downloadTask` 的临时文件必须在 completion handler 返回前搬走，原实现先异步跳主线程再 move，和系统删除临时文件赛跑；现同步搬运后再更新 UI 状态。
- **cursor 模型列表探测的管道死锁。** 原"先等退出再读 stdout"在输出超 64KB 时子进程永不退出；改走 `AgentSubprocess.runSynchronously`（并发排水 + 超时升级 SIGKILL）。
- **新建会话落盘不再同步等待跨进程文件协调。** 四处主线程 `AgentSessionStore.save()` 改为 `saveAsync`，避免另一 WillDeep 实例持有 NSFileCoordinator 时 beachball。
- **引用阅读窗口每次打开泄漏一个 NotificationCenter observer**；**媒体任务轮询在宿主释放后每 2 秒空转不退出**——均已修复。

**性能（主线程/内存）**

- **Agent 文件工具（grep/search/read/list/glob/git_status）移出主线程。** 项目开启默认 MainActor 隔离后这些工具一直在主线程同步扫盘（大仓库单次 grep 秒级冻结 UI + 流式转圈），现通过 `Task.detached` 在后台执行。
- **流式渲染不再每 100ms 对 file-backed 图片整文件读盘。** 渲染指纹与缓存 key 原先调用 `dataBase64.count`（对文件后备图片=整文件读盘+base64 编码后即弃），带截图的会话在流式期间每秒产生几十 MB 瞬时分配；改用现成 `byteCount` 字段。聊天历史缩略图同样改为 inline 数据直读 / `CGImageSourceCreateWithURL`，不再绕 base64。
- **桌宠 0.4s 轮询降耗。** 新鲜度检查前置（先比时间戳再碰消息全文）、presentation 同值短路（`@Published` 同值也发通知导致 overlay 恒定 2.5Hz 重渲染）。
- **移动网关停止/失败路径不再 `usleep` 冻主线程 250ms**；SIGKILL 升级挪到后台队列。
- **GitHub CLI / 数据库工具 workflow 预检改为后台执行**（`gh auth status` 走代理时单次可卡 1-10 秒主线程）。

### Changed

- 版本号从 **1.167.0-rc6** 递增为 **1.167.0-rc7**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

---

## 1.167.0-rc6 - 2026-07-16

### Fixed

- **侧边栏终端未绑定时不再误报「终端没开」。** 会话没有绑定终端标签时，`terminal_snapshot` 等工具的报错会列出侧边栏当前所有标签（id、标题、本地/SSH 目标、哪个正显示），并引导 Agent 向用户确认「是否就在当前显示的标签里执行」后带 `terminal_tab_id` 重试；用户在聊天里回一句即可，无需去侧边栏点选标签。系统提示词与工具描述同步禁止 Agent 声称「侧边栏/终端没有打开」。
- **确认一次即粘住。** 显式 `terminal_tab_id` 命中且会话尚无绑定时自动绑定该标签，后续调用可省略 `terminal_tab_id`，不会再静默新开本地 Shell；已有绑定不会被一次性的跨标签读取挪动。

### Tests

- 新增未绑定会话报错列出全部标签并标记当前可见标签、显式指定标签后自动绑定、已有绑定不被跨标签读取挪动的回归测试；提示词契约断言同步新增。

### Changed

- 版本号从 **1.167.0-rc5** 递增为 **1.167.0-rc6**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

---

## 1.167.0-rc5 - 2026-07-16

### Fixed

- **会话切换不再因历史文件缺失而静默失效。** 点击无法从磁盘加载的元数据会话时会保留侧边栏条目并明确提示可从备份恢复，不会切到空会话或覆盖原历史；自动清理空白“新对话”的永久删盘路径已移除，空白占位仅由侧边栏可见性规则隐藏。
- **侧边栏高 CPU 与布局抖动收敛。** 工作区分组改为 `LazyVStack` 惰性挂载，移除未被界面使用却每分钟刷新整栏的 `TimelineView`，运行状态点改为静态颜色，不再由每行 `symbolEffect(.breathe)` 持续触发 AttributeGraph 与显示列表更新。

### Tests

- 新增空白会话启动新聊天后仍保留磁盘文件、历史文件缺失时拒绝覆盖且产生可恢复错误提示的回归测试。

### Changed

- 版本号从 **1.167.0-rc4** 递增为 **1.167.0-rc5**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

---

## 1.167.0-rc4 - 2026-07-16

### Fixed

- **侧边栏终端不再跨会话串台。** 新会话首次打开 Terminal 时，即使其他会话已有活动标签，也会创建并绑定自己的本地 Shell；切换会话会恢复各自绑定的终端标签和屏幕内容，顶部“最近录制”仍保持全局共享。

### Tests

- 新增新会话终端隔离、会话切换恢复及重复打开不重复建标签的回归测试。

### Changed

- 版本号从 **1.167.0-rc3** 递增为 **1.167.0-rc4**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

---

## 1.167.0-rc3 - 2026-07-16

### Fixed

- **去除重复的“思考中”提示。** 全屏 Agent 会话在 Composer 已显示绿色“思考中”状态条与实时耗时后，不再于消息区额外显示灰色小字“正在思考”；旧侧栏聊天仍保留原有状态提示。

### Changed

- 版本号从 **1.167.0-rc2** 递增为 **1.167.0-rc3**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

---

## 1.167.0-rc2 - 2026-07-16

### Fixed

- **修复 some.im 图片请求 400。** 图片生成、编辑与短剧入口不再发送 relay 端模型不接受的 `response_format` 参数，统一使用服务端默认响应格式。
- **修复高输出子进程挂死。** ffmpeg、ffprobe、截图、本地模型查找、CLI 预检与安装流程统一并发排空 stdout/stderr，限制捕获内存，支持取消、超时、`TERM` 后 `KILL`，避免 pipe 写满后父子进程互等。
- **修复 ONNX Runtime C 字符串悬空指针。** 推理输入/输出名称在 C API 调用期间使用显式持有的内存，消除随机崩溃与未定义行为。
- **降低启动、保存与退出假死。** 历史会话索引移到后台并单次读盘；同步保存不再等待语言服务器；退出时异步排空会话写队列并使用 AppKit 延迟终止协议。
- **补齐大文件与大目录资源预算。** Office 解压条目、共享字符串、工作表、文本输入、图片压缩体积/像素、知识库索引、文件树、定义跳转、工作区指纹与制品扫描均增加字节、像素、条目或遍历上限。

### Tests

- 新增高输出双管道排空与子进程超时强杀回归测试；保存测试显式使用默认编辑器设置，避免读取用户偏好导致结果漂移。

### Changed

- 版本号从 **1.167.0-rc1** 递增为 **1.167.0-rc2**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

---

## 1.167.0-rc1 - 2026-07-16

### Fixed

- **Debug 不再读取正式版的远程 Runtime 凭据。** Debug 构建使用独立的 `com.willdeep.agent.debug` Keychain service 保存 daemon token，Release 继续使用 `com.willdeep.agent`，避免开发签名与正式签名交替访问同一钥匙串项目时反复要求输入 macOS 登录密码。
- 新增 Keychain service 映射回归测试；版本号从 **1.167.0** 递增为 **1.167.0-rc1**，同步 Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档。

---

## 1.167.0 - 2026-07-16

### Added

- **新增 WillDeep macOS 一体化发布脚本。** `scripts/release_mac_app.rb` 从 `.env.local` 白名单加载构建凭据，依次执行测试、Release Archive、Developer ID 导出、App 公证与装订、DMG 生成与签名、DMG 公证与装订，以及版本化对象和 `latest` 对象的 OSS 上传；敏感值不会出现在命令行或发布日志中。
- **新增可审计的发布合约测试与双格式报告。** 发布脚本和合约测试分别生成 JSON、Markdown 结果，覆盖 dotenv 白名单、凭据脱敏、CLI 安全参数和 OSS 对象命名。

### Changed

- 版本号从 **1.166.0-rc4** 提升为 **1.167.0**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

---

## 1.166.0-rc4 - 2026-07-16

### Fixed

- **Release 构建不再因同名开发证书失败。** Computer Use Helper 与 ONNX 重签阶段优先使用 Xcode 已解析的证书指纹；仅获得通用证书名时按 `DEVELOPMENT_TEAM` 解析唯一身份，禁用签名的 CI/诊断构建则使用 ad-hoc 签名，避免钥匙串存在多张 `Apple Development` 证书时出现 `ambiguous`。

### Changed

- 版本号从 **1.166.0-rc3** 递增为 **1.166.0-rc4**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

---

## 1.166.0-rc3 - 2026-07-16

### Changed

- **Composer 图标语义更明确。** 模型选择入口由服务器机柜图标改为大脑图标；内置“我们”执行器增加人物图标，区分模型选择与实际干活的执行器。
- **外部 CLI 获得原图与视觉描述双保险。** Codex 委托通过 `--image` 接收原始图片，Claude Code 获得权限受控的临时图片目录与明确文件路径；两者同时保留 WillDeep VL 生成的文字描述，任务完成、失败或取消后自动清理权限为 `0700/0600` 的临时目录与图片。
- 版本号从 **1.166.0-rc2** 递增为 **1.166.0-rc3**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

---

## 1.166.0-rc2 - 2026-07-16

### Fixed

- **Composer“审查”不再被多个未跟踪文件拖住。** 小型 UTF-8 新文件直接生成有界 diff，不再逐文件串行启动 `git diff --no-index`；大型、二进制和特殊文件提前降级为摘要，避免 `+0 -0` 绕过现有文件数与行数保护。
- **diff 准备与渲染不再伪装成界面卡死。** “审查”按钮在后台准备期间显示进度并阻止重复点击，弹窗的语法着色移出 SwiftUI 主线程，长 diff 打开时仍能保持交互响应。

### Changed

- 版本号从 **1.166.0-rc1** 递增为 **1.166.0-rc2**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

---

## 1.166.0-rc1 - 2026-07-16

### Added

- **自动识别 ChatGPT 内置 Codex CLI。** Codex 执行器探测优先检查 `/Applications/ChatGPT.app/Contents/Resources/codex`，同时保留旧 Codex App 与 PATH 等现有发现方式。
- **外部委托改用可见的专用 Shell 标签页。** Claude Code、Codex 等外部执行器直接在 Agent 右侧栏新建 `/bin/sh` 终端标签页执行完整命令，不再生成用户看不见的临时 `.sh`；空闲标签页会复用，最多同时保留 3 个自动化标签页，全部繁忙时排队等待。

### Changed

- 执行器选择入口移到输入框顶部工作区信息行右侧，并将内置执行器名称从 “WillDeep” 改为支持中英文 i18n 的“我们 / Us”；审批入口紧跟普通、计划与目标模式选择器，底部更多菜单只保留插件与专家设置。
- 版本号从 **1.165.0-rc2** 提升为 **1.166.0-rc1**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

---

## 1.165.0-rc2 - 2026-07-16

### Fixed

- **中国区 Coding Plan 状态不再误判。** 客户资料、登录和套餐订阅等控制面请求固定发送到 `some.im`，不再跟随模型推理网关切换到不提供客户接口的 `api.niuwoai.com`；中国区模型转发配置仍保持不变。
- **套餐查询失败不再冒充“未购买”。** 缺少或过期的客户会话会提示重新登录，网络或服务异常会提示重新查询；只有服务端明确返回空订阅时才展示“当前没有有效的 Coding Plan”。

### Changed

- 版本号从 **1.165.0-rc1** 递增为 **1.165.0-rc2**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

---

## 1.165.0-rc1 - 2026-07-15

### Added

- **Composer 扩展工程文本附件识别。** `Procfile`、`Dockerfile`、`.env.*`、`Makefile` 等无扩展名工程文件，以及更多常见源码、配置和文档格式现在可以正常附加、解析并发送。
- **未知小文件增加确认发送流程。** 无法识别类型且不超过 8 KB 的文件不会先混入附件栏，而是询问用户是否按纯文本发送；确认后会保存该解析选择，后续刷新附件仍按文本处理。

### Changed

- **桌面宠物取消转圈动画。** 新输出就绪时改为温和待机动作，不再进行 3D 旋转；保留偶发的红唇飞出与闪光彩蛋。
- **附件入口统一执行安全分流。** 文件选择器、拖放和 Composer 的 `@文件` 都使用同一套判定；未知类型超过 8 KB 或无法读取大小时，直接在 Composer 上方提醒且不加入附件栏、不会发送。
- 版本号从 **1.164.0-rc1** 提升为 **1.165.0-rc1**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

---

## 1.164.0-rc1 - 2026-07-15

### Added

- **省心托管标签改为独立信息页。** 无论 some.im 是否登录都可查看省心托管说明；页面明确显示当前会话是否已选中省心托管，并解释“裁判负责选型与校验、干活模型成本优先且必要时自动升档”的双模型协作方式。已登录但未选中时可直接切回省心托管，未登录时可直达登录。
- **Coding Plan 权益展示与购买入口。** Coding Plan 明确标注为 some.im 提供的可选编程套餐，与省心托管解耦；已购买时展示套餐名和到期日期，未购买或未登录时说明套餐价值并提供购买链接，同时明确不购买也能使用省心托管。

### Fixed

- **省心托管胶囊不再泄露内部档位名。** 无论用户手动升档还是系统自动升档，输入区始终只显示“省心托管”，不再出现 Auto Flash 等内部模型名称；省心托管信息页也不再列 Low / High / Premium 或提供直接升档控件。
- **聊天正文行距与段落空白恢复一致。** 普通 Markdown 段落边界从整行空白收敛为正常换行，代码块后的正文继续使用与前文一致的字号和 5pt 行距；实时 SwiftUI 与历史 TextKit 渲染同步修复。

### Changed

- 版本号从 **1.163.0-rc3** 提升为 **1.164.0-rc1**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

---

## 1.163.0-rc3 - 2026-07-15

### Fixed

- **处理中的流式光标不再无输出时常驻。** 助手正文每次新增或替换可见内容时会重新显示光标并重置 500ms 计时；连续 500ms 没有新字符后自动隐藏，不再在模型停顿、工具调用或普通输出结束后持续闪烁。长消息预览按实际内容而非固定字符数识别更新。

### Changed

- 版本号从 **1.163.0-rc2** 递增为 **1.163.0-rc3**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

---

## 1.163.0-rc2 - 2026-07-15

### Fixed

- **Composer 的 `@文件名` 恢复当前工作区检查与附件挂载。** `@` 文件候选不再复用 Editor 的 Quick Open 根目录，而是异步扫描当前 Agent 会话绑定的本地工作区；按文件名或相对路径搜索后可用 Enter/Tab 或点击候选挂载为附件。搜索尚未完成时 Enter/Tab 会保留在附件选择流程，不再把裸 `@文件名` 误发为普通消息；依赖目录、构建目录和隐藏文件继续跳过。
- **修复 CI complexity guard 红：拆分超长的 `L10n.swift`。** `Xedit/L10n.swift` 长期累积到 3015 行，超出 complexity guard 的 3000 行硬限，导致该步骤失败、后续 version consistency / XeditTests / Go 测试全被跳过、汇总步骤 `cat` 不到 `version_report.md` 报错。将其中的 `AgentTerminal` 文案枚举按既有 `L10n+DesktopPet.swift` 模式拆到新文件 `Xedit/L10n+AgentTerminal.swift`（保留 `nonisolated` 隔离语义，纯移动不改逻辑），`L10n.swift` 降至 2890 行，本地 complexity guard 恢复 `hard=0`，编译通过。

### Changed

- 版本号从 **1.163.0-rc1** 递增为 **1.163.0-rc2**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

---

## 1.163.0-rc1 - 2026-07-15

### Added

- **当前 worktree 可一键安装 Debug App。** 新增根目录 `dev_install.rb`，只从本 worktree 的 `.env.local` 读取 `WILLDEEP_CLIENT_LOGIN_SECRET`，以隐藏值完成 Debug 编译、Apple Development 签名和 `/Applications/WillDeep.app` 原子安装；安装前后会校验版本、签名与 Debug dylib 密钥注入，支持 `--dry-run` 和构建/安装路径覆盖。
- **Composer 模型选择器升级为完整目录。** 点击输入区模型胶囊会打开双栏选择面板，支持全局搜索模型与供应商、切换任意已配置供应商、浏览完整模型目录、查看编程推荐和最近使用；目录异步加载、失败重试、无结果状态与当前会话选中态均有明确反馈。
- **省心托管支持会话级手动升档。** 托管模型胶囊右侧提供独立升档按钮，可按 Flash → Pro → Premium 提升当前会话最低档；已经升无可升时按钮自动消失，裁判或质检触发自动升档时会显示轻量状态提示。

### Changed

- **Coding Plan 仅作用于编程任务。** 裁判判定为通用任务时，无论账户是否有 Coding Plan，都继续使用 `someim-auto-flash/pro/premium`；只有编程任务会按权益选择 `someim-coding-plan-*` 或 `someim-code-*`。
- 版本号从 **1.162.0-rc1** 提升为 **1.163.0-rc1**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

---

## 1.162.0-rc3 - 2026-07-15

### Fixed

- **修复 CI complexity guard 红：拆分超长的 `L10n.swift`。** 将 `AgentTerminal` 文案枚举移动到 `Xedit/L10n+AgentTerminal.swift`，使 `L10n.swift` 从 3015 行降到 2890 行；纯文件拆分，不改变文案键或运行逻辑。

### Changed

- 版本号从 **1.162.0-rc2** 递增为 **1.162.0-rc3**，同步前后端、扩展、帮助包与版本文档。

---

## 1.162.0-rc2 - 2026-07-15

### Fixed

- **Composer 的 `@文件名` 恢复当前工作区检查与附件挂载。** `@` 文件候选改为异步扫描当前 Agent 会话绑定的本地工作区，支持文件名和相对路径搜索，并在搜索过程中拦截 Enter/Tab，避免把未解析的文件提及误发为普通消息。

### Changed

- 版本号从 **1.162.0-rc1** 递增为 **1.162.0-rc2**，同步前后端、扩展、帮助包与版本文档。

---

## 1.162.0-rc1 - 2026-07-15

### Added

- **桌面宠物新增「冬眠 5 分钟」「冬眠到明天」右键菜单。** 位于「桌面宠物设置…」与「隐藏桌面宠物」之间；点击后宠物窗口暂时隐藏，「冬眠 5 分钟」5 分钟后自动醒来，「冬眠到明天」睡到次日早上 9:00 自动醒来。冬眠不写 UserDefaults（区别于「隐藏」），重启 App 即恢复显示；期间在设置里显式开关宠物会提前结束冬眠。

### Changed

- 版本号从 **1.161.0-rc5** 递增为 **1.162.0-rc1**（新功能提升 MINOR 位并重置 rc）；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

---

## 1.161.0-rc5 - 2026-07-15

### Fixed

- **侧边栏委托任务不再被用户 Shell 语法卡住。** Claude Code、Codex CLI、Cursor Agent 与 Cline CLI 改由权限为 `0600` 的临时 `/bin/sh` runner 执行；侧边栏只接收短启动命令，不再让 fish、zsh 或 bash 解析完整 prompt、zsh 分组语法与状态包装器，同时消除超长 PTY 单行阻塞风险。
- **未启动的委托任务不再长时间假运行。** runner 会先写入独立启动标记，并在 `tee` 完整冲刷输出后发布最终退出状态；15 秒内没有真正启动会返回明确错误，任务结束、取消或失败后统一清理 runner、日志和状态文件。

### Changed

- 新增跨 Shell 与超长 prompt 回归测试，实际覆盖 sh、bash、zsh、本机 fish，以及中文、单引号、反引号、命令替换文本、换行和约 12 万字节输入。
- 版本号从 **1.161.0-rc4** 递增为 **1.161.0-rc5**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

---

## 1.161.0-rc4 - 2026-07-15

### Fixed

- **some.im 账户入口恢复浏览器跳转。** 设置页已连接账户区域的 “Open some.im / 在浏览器打开” 不再依赖额外的 handoff-link 网络请求；点击后立即通过系统默认浏览器打开 `https://some.im/customer`。

### Changed

- 版本号从 **1.161.0-rc3** 递增为 **1.161.0-rc4**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

---

## 1.161.0-rc3 - 2026-07-15

### Fixed

- **账户弹出菜单不再自动获得键盘焦点。** 剩余点数、桌面宠物、设置和退出登录共用的菜单按钮退出焦点链，打开菜单时不再给首项绘制紫色焦点框，鼠标悬停与点击行为保持不变。

### Changed

- 版本号从 **1.161.0-rc2** 递增为 **1.161.0-rc3**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

---

## 1.161.0-rc2 - 2026-07-15

### Fixed

- **“正在思考”状态不再显示上方细线。** 全屏对话与紧凑侧栏共用无分隔线的思考状态样式，保留耗时计数和实时 reasoning 预览；排队、上下文压缩等其他状态提示不受影响。

### Changed

- 版本号从 **1.161.0-rc1** 递增为 **1.161.0-rc2**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

---

## 1.161.0-rc1 - 2026-07-15

### Added

- **Git 工作树改为一键创建并展示实时进度。** 创建入口不再要求手动确认分支名；WillDeep 会优先根据当前会话生成 `xedit-<语义名>-<短标识>`，标题不具备语义时使用易读的随机名称。创建期间在 Composer 上方持续显示 Git 输出、检出百分比与取消入口，取消后会清理未完成的工作树和临时分支。

### Fixed

- **成功的终端操作不再重复展示第二张详情卡。** 对话正文保留首次紧凑摘要；只有仍在运行、等待授权/确认、执行失败或被拒绝的终端操作才继续显示详细状态卡，且不会留下空白占位。

### Changed

- 版本号从 **1.160.0-rc3** 提升为 **1.161.0-rc1**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

---

## 1.160.0-rc3 - 2026-07-15

### Fixed

- **连续本地路径链接不再蓝底粘连。** Agent 历史消息中的本地目录与文件路径改用随深浅外观适配的正文色、中等字重和低对比度下划线；路径即使写在 Markdown 行内代码中也不再绘制圆角或矩形背景，并通过不污染复制文本的字偶距为相邻路径保留稳定间隔。

### Changed

- 版本号从 **1.160.0-rc2** 递增为 **1.160.0-rc3**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

---

## 1.160.0-rc2 - 2026-07-15

### Fixed

- **工作区内 Go 构建缓存命令可安全自动审批。** 命令授权会先识别前置环境变量，并仅把精确的 `$(pwd)` 替换为当前工作区路径用于策略判断；`GOCACHE` / `GOMODCACHE` 指向工作区时可走 workspace-write 自动审批，包含命令替换、敏感变量名、凭据路径或工作区外路径时仍会升级确认。

### Changed

- 将剩余 5 个本地分支全部纳入 `main` 历史；对已经由主线更新实现覆盖的桌面宠物、移动端 workspace workflow、任务监控本地化和 CI 测试改动保留主线版本，避免旧代码倒灌，并补回 Android live acceptance 记录。
- 版本号从 **1.160.0-rc1** 递增为 **1.160.0-rc2**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

---

## 1.160.0-rc1 - 2026-07-15

### Added

- **Chrome Native Messaging 宿主自动注册。** WillDeep 启动时会使用 App 内置 `willdeep-agent` 创建或修复当前用户的 Chrome Native Messaging launcher 与 manifest；扩展通过公开 manifest key 固定 ID，移动或替换解压目录后不会再让 `allowed_origins` 失效。

### Fixed

- **Chrome 扩展断连不再累积未处理异常。** Service Worker 会读取 native port 断开时的 `runtime.lastError`，宿主尚未安装或 App 正在升级时返回可诊断状态，不再产生 `Unchecked runtime.lastError`。

### Changed

- README 将产品定位更新为围绕任务、工作区、会话和可验证交付物组织的原生 Agent 工作台；新增 Xomo 接入 some.im 生图能力的设计草案。
- 版本号从 **1.159.0-rc1** 提升为 **1.160.0-rc1**；Xcode App、Go agent、Help bundle、Computer Use Helper、Chrome 扩展、README badge、移动网关响应头契约与产品文档同步。

---

## 1.159.0-rc1 - 2026-07-15

### Added

- **some.im credits 自动刷新与低余额提示。** 左侧会话栏底部账户区直接展示剩余 credits；低于 1000 万时使用随深浅外观适配的低饱和赭石棕提醒。AI 请求可从响应 header 即时吸收余额快照，无请求时以 4–7 分钟随机周期兜底刷新。
- **余额快照防旧值倒灌。** credits header 必须与服务端账本/预占变更的 Unix 微秒时间点成对出现；客户端仅接受严格更新的时间点，手动刷新、并发 AI 响应和边缘旧快照都不能覆盖更新余额。

### Changed

- 版本号从 **1.158.0-rc5** 提升为 **1.159.0-rc1**；Xcode App、Go agent、Help bundle、Computer Use Helper、README badge、移动网关响应头契约与产品文档同步。

---

## 1.158.0-rc5 - 2026-07-15

### Fixed

- **对话滚动不再抢位置或在发送后上跳。** 主对话与紧凑侧栏会记录操作人是否仍在底部：底部状态下流式文本、工具与任务信息持续吸底；上滚回看历史后，任务追加和回合结束不会强拉到底；操作人主动发送新消息时仍会回到最新位置。
- **宿主计划执行指令不再冒充用户输入。** 点击执行计划后自动生成的英文执行提示新增宿主来源标记，只保留在模型上下文中，并从用户气泡、输入历史、对话缩略导航和移动端消息摘要中过滤；旧会话中已持久化的同类提示也会自动隐藏。

### Changed

- 版本号从 **1.158.0-rc4** 递增为 **1.158.0-rc5**；Xcode App、Go agent、Help bundle、Computer Use Helper、README badge、移动网关响应头契约与产品文档同步。

---

## 1.158.0-rc4 - 2026-07-15

### Fixed

- **桌面宠物输入动画移除电脑道具。** 输入状态不再在宠物前方叠加像素电脑、屏幕辉光和电脑浮动，只保留宠物本体的输入动作；无用电脑素材与动画状态同步删除。

### Changed

- 版本号从 **1.158.0-rc3** 递增为 **1.158.0-rc4**；Xcode App、Go agent、Help bundle、Computer Use Helper、README badge、移动网关响应头契约与产品文档同步。

---

## 1.158.0-rc3 - 2026-07-15

### Fixed

- **高风险 Git 操作不再沿用过期工作区状态。** Agent 每轮模型请求前记录仓库、HEAD、分支、暂存区、合并状态及已改文件内容；执行 `git add`、`git commit`、`git merge`、`git push` 等变更命令前，在跨会话仓库锁内重新核对。若人类或其他会话期间改过代码，会拦截命令并列出变化与活跃会话，要求重新检查和测试；同一命令中的多次 Git 变更及后台 Git 变更也会被拒绝。
- **构建排队后不再复用旧指纹。** 项目构建守卫取得 workspace 锁后会重新计算 Git、文件和命令指纹，再判断缓存或启动构建，避免等待期间源码变化却错误命中旧产物；报告同步记录初始指纹和是否发生刷新。
- **仓库自动化脚本兼容当前 Ruby 运行时。** 构建队列、短剧交接/证据报告和移动网关验收脚本不再依赖较新 Ruby 才提供的 `filter_map`；契约测试覆盖缓存复用及持锁等待期间的源码变化。

### Changed

- 版本号从 **1.158.0-rc2** 递增为 **1.158.0-rc3**；Xcode App、Go agent、Help bundle、Computer Use Helper、README badge、移动网关响应头契约与产品文档同步。

---

## 1.158.0-rc2 - 2026-07-15

### Fixed

- **短剧源码契约恢复与当前实现一致。** 更新媒体任务快捷入口、短剧视频参考图、批量媒体生成及通用候选图组件的静态契约断言，兼容全量侧栏快捷入口与 Seedance/可灵双路由，消除 4 条由旧源码字符串造成的基线误报；其余 288 条短剧契约保持原约束。

### Changed

- 同步 Xedit App、Computer Use Helper、Help bundle、willdeep-agent 与产品文档版本到 `1.158.0-rc2`。

---

## 1.158.0-rc1 - 2026-07-15

### Added

- **账户状态菜单与帮助入口**：Agent 左下角新增可点击账户状态栏，支持余额/用量、设置、退出登录子菜单，以及独立问号帮助入口；中英文文案统一走本地化资源。
- **WillDeep Browser 扩展更新链路**：扩展新增 Options 页面、some.im 公开更新计划轮询、NEW 角标和版本通知；发布器输出无 macOS 资源叉的干净 ZIP，并补齐契约与版本比较测试。

### Changed

- 同步 Xedit App、Computer Use Helper、Help bundle、willdeep-agent 与产品文档版本到 `1.158.0-rc1`（新增账户菜单与 Chrome 扩展管理能力，提升功能版本）。

---

## 1.157.0 - 2026-07-15

### Added

- **Agent 输入框上方新增运行上下文栏。** 新对话与既有会话都会清楚展示当前项目、运行位置和 Git 分支；运行位置可在本地主工作区与新建 worktree 之间切换，分支信息始终按当前 Agent 会话的真实工作目录刷新，不再借用 Editor 的仓库状态。
- **Claude Code / Codex 委派任务改为侧边栏终端可见执行。** 发起任务时会打开并绑定当前对话专属的本地终端标签，用户可实时查看命令和输出；长时间无输出的执行标签不会被闲置回收，也不能在任务完成前误关。

### Changed

- **终端工具改为精确多标签路由。** `terminal_snapshot`、`terminal_send_command` 与 `terminal_send_control` 优先使用显式 `terminal_tab_id`，否则只使用当前会话绑定的标签；不存在绑定时创建该会话自己的本地标签，严禁回退到任意 active 标签。标签切换会显式更新当前会话绑定，并新增跨会话和显式标签覆盖的回归测试。
- 版本号从 **1.156.0-rc4** 提升为功能版本 **1.157.0**，Xcode App、Go agent、Help bundle、Computer Use Helper、README badge、移动网关响应头契约与产品文档同步。

---

## 1.156.0-rc4 - 2026-07-15

### Fixed

- **Plan 不再把局部样品当成完整交付。** Plan 生成与批准提示现在要求逐项覆盖用户请求的最终产物；除非用户明确只要局部结果，否则大纲、样章、首文件或首阶段不能被标为完整完成。
- **Plan 多段进度状态不再卡在第一步。** 进度解析器会读取一条回复中的所有 `progress` fenced block，并按出现顺序合并状态，后出现的状态覆盖同一步骤的旧状态。
- **Plan 未完成时自动续跑。** 执行回复结束后若仍有非终态步骤，Agent 会通过隐藏系统消息继续同一执行轮；排队中的用户消息始终优先，连续两轮无状态进展或达到 8 次自动续跑上限时会明确暂停，避免静默结束或无限循环。

### Changed

- 版本号从 **1.156.0-rc3** 递增为 **1.156.0-rc4**；Xcode App、Go agent、Help bundle、Computer Use Helper、README badge、移动网关响应头契约与产品文档同步。

---

## 1.156.0-rc3 - 2026-07-15

### Changed

- **Agent 顶栏侧栏入口改为全部直接展示。** 任务监控、媒体任务、网页组件、图片编辑及其他当前可用侧栏不再收进省略号菜单，统一按现有可用性规则平铺为单击图标；Plan 入口仍只在当前会话存在计划时出现。
- **移除 Agent 顶栏“回到 Editor”按钮。** 删除蓝色铅笔图标、专属分隔线及无用本地化资源，Editor 只保留在应用菜单；Finder/外部 URL 打开文本文件、Agent 文件跳转和 Editor 编辑能力不变。Header 本地化接口同步拆至独立文件，使 `L10n.swift` 回到 3000 行硬限制以内。
- 新增顶栏入口策略回归测试；版本号从 **1.156.0-rc2** 递增为 **1.156.0-rc3**，Xcode App、Go agent、Help bundle、Computer Use Helper、README badge、移动网关响应头契约与产品文档同步。

---

## 1.156.0-rc2 - 2026-07-15

### Added

- **复杂任务发送前自动建议进入 Plan 模式。** Normal 模式发送任务时会用保守的本地评分识别多步骤、跨文件/模块、架构重构、迁移与测试验证等组合任务；命中后保留输入与附件，显示“直接执行 / 进入 Plan”提示条和 8 秒倒计时进度条。用户未操作时由会话 runtime 自动切换到 Plan 并发送，不依赖 composer 必须保持可见。
- 用户继续编辑会取消提示，重复发送不会绕过待决选择，明确写出“不用 Plan / 直接做”等意图时继续按 Normal 模式执行；提示文案已接入中英文 i18n。

### Changed

- 新增复杂度策略与发送前停放行为的自动化测试；版本号从 **1.156.0-rc1** 递增为 **1.156.0-rc2**，Xcode App、Go agent、Help bundle、Computer Use Helper、README badge、移动网关响应头契约与产品文档同步。

---

## 1.156.0-rc1 - 2026-07-15

### Added

- **桌面宠物新增“代码柴犬”和“月兔工程师”。** 两套新形象采用与现有素材一致的高精度像素画、透明背景与选择卡片规则，宠物总数从 22 增至 24，并补齐中英文名称。
- **桌面宠物新增精细打电脑与待机卖萌动画。** 输入状态使用现有高细节电脑素材，完整呈现屏幕代码、键盘和机身，叠加身体前倾、交替敲击、压缩回弹、电脑轻晃与屏幕辉光；待机状态周期性加入歪头、弹跳、爱心与闪光，庆祝状态同步增强情绪特效。

### Changed

- 桌面宠物场景提取为可独立渲染组件，新增电脑显示、待机卖萌和 24 种形象的回归测试及真实 SwiftUI 视觉快照；版本号从 **1.155.0-rc14** 提升为功能版本 **1.156.0-rc1**，Xcode App、Go agent、Help bundle、Computer Use Helper、README badge、移动网关响应头契约与产品文档同步。

---

## 1.155.0-rc14 - 2026-07-15

### Added

- **复杂任务发送前可自动建议进入 Plan 模式。** Normal 模式发送任务时会用保守的本地评分识别多步骤、跨文件/模块、架构重构、迁移与测试验证等组合任务；命中后先保留输入与附件，显示“直接执行 / 进入 Plan”提示条和 8 秒进度条，用户未操作时自动切换到 Plan 并发送。自动切换由会话运行时兜底，不依赖 composer 当时必须显示在屏幕上。
- 用户继续编辑会取消本次提示；重复按发送不会绕过提示；明确写出“不用 Plan / 直接做”等意图时不会弹出。新增中英文 i18n 资源和复杂度策略单元测试。

### Changed

- 版本号从 **1.155.0-rc13** 递增为 **1.155.0-rc14**，Xcode App、Go agent、Help bundle、Computer Use Helper、README badge、移动网关响应头契约与产品文档同步。

---

## 1.155.0-rc13 - 2026-07-15

### Fixed

- **桌面宠物设置页恢复正文普通字号。** 显示开关、宠物形象标题、全部宠物名称和底部说明统一使用 14 pt 系统正文；移除宠物名称最低缩放至 82% 的规则，长名称改为稳定的两行排版，不再越长越小。

### Changed

- 新增桌面宠物设置字号回归断言与真实 SwiftUI 渲染用例；版本号从 **1.155.0-rc12** 递增为 **1.155.0-rc13**，Xcode App、Go agent、Help bundle、Computer Use Helper、README badge、移动网关响应头契约与产品文档同步。

---

## 1.155.0-rc12 - 2026-07-15

### Fixed

- **自动化区域恢复侧栏正文普通字号。** 自动化名称、计划摘要、空状态与模板入口统一使用 14 pt 系统常规字体，与工作区和会话正文一致，不再混用 10–12 pt 小字。
- **移除左侧栏顶部重复区域。** 删除交通灯安全区下方的“聊天”标题和 some.im Provider 状态条，侧栏从“新聊天”直接开始，减少无效占高；Provider 选择能力仍保留在现有模型与设置入口。
- **恢复桌宠首击行为测试的可编译性。** 将首击接受逻辑提取为无状态策略，生产窗口行为保持不变，测试不再引用私有 Hosting View 类型。

### Changed

- 新增自动化字号回归断言，并把真实自动化数据纳入侧栏视觉渲染用例；版本号从 **1.155.0-rc11** 递增为 **1.155.0-rc12**，Xcode App、Go agent、Help bundle、Computer Use Helper、README badge、移动网关响应头契约与产品文档同步。

---

## 1.155.0-rc11 - 2026-07-15

### Fixed

- **Agent 右侧栏不再自动出现紫色键盘焦点环。** 侧栏壳体、主机验证 popover 的“复制 hostname 命令”以及终端录制、标签、媒体任务、短剧、嵌入浏览器、网页组件、预览和图片编辑操作控件统一应用 `.focusable(false)`；打开弹层时不会再自动聚焦第一个按钮。
- **文本输入能力保持不变。** 终端模拟器、浏览器地址栏、快捷指令重命名和图片编辑表单仍可正常获取输入焦点，鼠标点击、菜单、复制、折叠和选择操作不受影响。

### Changed

- 新增 Agent 侧栏焦点策略回归测试；版本号从 **1.155.0-rc10** 递增为 **1.155.0-rc11**，Xcode App、Go agent、Help bundle、Computer Use Helper、README badge、移动网关响应头契约与产品文档同步。

---

## 1.155.0-rc10 - 2026-07-15

### Fixed

- **同一次用户输入触发的多轮 AI 输出现在合并为一个可视回合。** 工具调用、文件编辑与中间文字不再各自重复绘制“处理中 / 已处理”状态、分隔线和 token 操作栏；每个用户回合只在首条可见 AI 输出前显示一次状态，只在最终输出后显示一次复制与用量统计。
- **回合统计改为整体聚合。** 处理耗时从用户消息发出起计算到最终 AI 调用结束，包含中间工具执行等待；prompt、completion、cache 与 reasoning token 汇总同一回合的所有 provider 调用，复制操作也覆盖该回合全部可见 AI 文本。

### Changed

- 新增已完成回合与进行中回合的渲染回归测试；版本号从 **1.155.0-rc9** 递增为 **1.155.0-rc10**，Xcode App、Go agent、Help bundle、Computer Use Helper、README badge、移动网关响应头契约与产品文档同步。

---

## 1.155.0-rc9 - 2026-07-15

### Fixed

- **Workflow 卡片重新可见：`/research` 等 slash workflow 不再"发出去就没了"** —— rc16 聊天历史折进单个 NSTextView 后，workflow 卡片的 SwiftUI 挂载点只剩「流式 assistant 消息」一个入口，`.workflowReport` 消息在 TextKit 历史里只画一个光秃秃的 WFL 头像行：进度、失败原因、最终研究报告全部不可见（跑成功了结果也无处显示）。现在运行中的卡片走 SwiftUI「工作态表面」（与 tool call group 同款，进度/子 agent 状态实时刷新），结束后由 formatter 把状态行 + 最终报告 markdown 烘进 TextKit 历史，并带 copy 按钮（复制 report.summary）。
- **TextKit 渲染缓存对 workflow report 变更失效** —— `messageHash` 此前不含 `workflowReport` 字段，report 从 running 变 done、summary 填入后 render cache 仍命中旧渲染；现已纳入 hash，新增回归单测锁定。
- **省心托管会话的 workflow 子 agent 接入托管模型解析** —— 主循环每回合跑 routing judge 解析 some.im 虚拟模型，workflow 子 agent 之前直接拿原始配置里的静态模型、完全绕过托管路由（与 5dd9273a 修的 someIMContext 缺失同族）。现在按「会话 floor 与 high 取高者 + workflow 声明的任务域（code-review / bug-hunt / pr-review / screenshot-to-code 为 coding，其余 general）」解析为具体虚拟模型，coding plan 生效时走 coding-plan 梯子；纯函数 `AppState.managedWorkflowModel` 单测覆盖。
- **workflow 状态更新与 displayWidget 改用 `runtime(for:)` 兜底** —— 裸 `agentRuntimes[...]` 查找在会话被 idle-runtime 驱逐后会让所有状态更新静默 no-op（卡片永久冻结）/ widget 静默丢失；与后台作业回调同款兜底。

- **左侧工作区与会话列表精确对齐 Codex 的排版密度。** 项目名和会话名统一为 14 pt 系统常规字重与 31 pt 行高，文字列统一从侧栏左侧 40 pt 起排；项目图标、组间距、选中态 10 pt 圆角和 8 pt 外侧留白按参考截图校准。
- **移除会话列表中的常驻视觉噪声。** 普通空闲会话不再显示左侧状态圆点和右侧时间戳；运行、等待或当前会话状态移至尾部按需显示，选中与悬浮背景改用各内置皮肤的 `selectionFill` / `hoverFill`，避免米纸皮肤出现突兀的粉红强调条。

### Changed

- 新增 workflow、托管模型与侧栏视觉度量回归测试，并补充真实 SwiftUI 渲染截图用例；版本号从 **1.155.0-rc8** 递增为 **1.155.0-rc9**，Xcode App、Go agent、Help bundle、Computer Use Helper、README badge、移动网关响应头契约与产品文档同步。

---

## 1.155.0-rc8 - 2026-07-15

### Fixed

- **修复 Release 归档在 x86_64 切片上的编译器崩溃。** `DesktopPetFirstMouseHostingView` 原为 `NSHostingView<Content>` 泛型子类，swift-frontend 6.3.1 的 `EarlyPerfInliner` SIL 优化 pass 在特化其合成 deinit 时段错误，导致 `xcodebuild archive` 失败（仅 `-O` Release 触发，Debug 与 arm64 不受影响）。改为固定 `NSHostingView<DesktopPetOverlayView>` 非泛型子类绕开编译器 bug，运行时行为不变。

## 1.155.0-rc7 - 2026-07-15

### Fixed

- **终端录制区改为双层信息架构。** 顶层只保留开始/停止录制和简短说明，最近录制在独立列表中展示播放、名称、时长、输入段数、回放状态与更多操作；移除“外框套胶囊”的嵌套结构，并让窄侧栏自动把元数据折到第二行。
- **修复深色录制栏的文字对比度。** 录制按钮文字与状态信息统一使用终端前景色，红色只保留给录制图标/活动状态，绿色与橙色只用于完成/中断的小图标，不再整段染色。

### Changed

- 录制区新增“录制说明 / 最近录制”等中英文资源，时长改用系统本地化格式；版本号从 **1.155.0-rc6** 递增为 **1.155.0-rc7**，Xcode App、Go agent、Help bundle、Computer Use Helper、README badge、移动网关响应头契约与产品文档同步。

---

## 1.155.0-rc6 - 2026-07-15

### Changed

- **处理状态分隔线精确对齐 Codex。** 在“处理中 / 已处理 Ns”与回复正文之间新增 1 pt 细线；按参考截图与 SF 字体墨迹边界校准为线上 9 pt、线下 18 pt，并以 7.5% 动态中性色绘制（经 AppKit / SwiftUI 合成后，白色表面为 `#F0F0F0`）。实时 SwiftUI 与 TextKit 历史消息共享同一组布局和颜色常量。
- 版本号从 **1.155.0-rc5** 递增为 **1.155.0-rc6**；Xcode App、Go agent、Help bundle、Computer Use Helper、README badge、移动网关响应头契约与产品文档同步。

---

## 1.155.0-rc5 - 2026-07-15

### Changed

- **用户消息气泡更接近 Codex。** 用户输入区域改用专用 14 pt 连续圆角，替代此前 8 pt 卡片圆角；背景填充透明度从约 3.5% 降至 2.6%，视觉更柔和。实时 SwiftUI、TextKit 历史记录与紧凑侧栏统一，工具卡片及系统消息保持原样。
- 版本号从 **1.155.0-rc4** 递增为 **1.155.0-rc5**；Xcode App、Go agent、Help bundle、Computer Use Helper、README badge、移动网关响应头契约与产品文档同步。

---

## 1.155.0-rc4 - 2026-07-15

### Changed

- **处理耗时状态进一步降低对比度。** “处理中 / 已处理 Ns”从 secondary label 调整为更浅的 tertiary label，实时 SwiftUI 消息与 TextKit 历史消息保持一致；字号、字重和正文行距不变。
- 版本号从 **1.155.0-rc3** 递增为 **1.155.0-rc4**；Xcode App、Go agent、Help bundle、Computer Use Helper、README badge、移动网关响应头契约与产品文档同步。

---

## 1.155.0-rc3 - 2026-07-15

> 本条目合并了两条并行分支各自发布的 1.155.0-rc3（聊天排版分支与 Files 侧栏修复分支），内容均已进入 main。

### Fixed

- **Agent 侧栏 Files 双击改为「在 Finder 中显示」** —— 之前双击（乃至单击）会把文件装进 agent 跟随的无窗口 AppState、再 `openWindow(id:)` 拉起一个空白 AppState 的编辑器窗口，表现为莫名弹出「未打开文件夹」欢迎窗。现在双击直接 `revealInFinder`，单击只做选中/预览。
- **右键「在编辑器中打开」不再弹空白窗口** —— 已有编辑器窗口时聚焦它并装载文件；没有时改走 URL-backed WindowGroup（新窗口自己加载该文件）；二进制文件直接转 Finder 定位。
- **关闭临时编辑器窗口后 Agent 窗口不再被重置成「新聊天」** —— `EditorAppStateRegistry` 现在保留冷启动 mint 的 headless AppState，最后一个编辑器窗口关闭时 `current` 回退到它，agent 会话原样恢复。

### Removed

- **「未打开文件夹」欢迎页（EmptyWorkspaceView）整体删除** —— 纯启动已直接进 Agent 窗口；新开的纯编辑器窗口（⌘N / 菜单「显示编辑器」）现在自动带一个空白 untitled tab，可立即输入。附带删除 hero / Recent Folders / Recent Files 子视图、`openRecentFile` / `openRecentFolder` 帮手与对应 i18n key。

### Changed

- **聊天正文行距小幅放宽。** 用户输入与 AI 正文的行距从 4 pt 调整为 5 pt，实时 SwiftUI 消息、流式输出与 TextKit 历史消息共用同一排版常量，长段落更容易扫读，同时保持当前紧凑密度。
- 版本号从 **1.155.0-rc2** 递增为 **1.155.0-rc3**；Xcode App、Go agent、Help bundle、Computer Use Helper、README badge、移动网关响应头契约与产品文档同步。

---

## 1.155.0-rc2 - 2026-07-15

### Changed

- **“处理中 / 已处理 Ns”恢复正文基准字号。** Agent 回复上方的处理状态不再固定为 11 pt，而是与 AI 输出、用户输入共同跟随聊天正文基准字号；实时 SwiftUI 消息与 TextKit 历史消息统一，保留次级灰色和中等字重。

### Fixed

- 为 TextKit 历史渲染补充状态字体与正文同字号的回归断言，避免后续再次把处理状态降成辅助小字。
- 版本号从 **1.155.0-rc1** 递增为 **1.155.0-rc2**；Xcode App、Go agent、Help bundle、Computer Use Helper、README badge、移动网关响应头契约与产品文档同步。

---

## 1.155.0-rc1 - 2026-07-15

### Added

- **内置 Design to Code Skill** —— 新增 WillDeep 兼容的 `design-to-code` 内置技能，可将选中的截图、视觉稿、Figma frame 或生成式设计还原为高保真、响应式、可交互的 Web 前端；在新项目中优先 React + TypeScript，在既有项目中遵循原技术栈、组件库、设计 token 与 i18n 约定。
- **视觉稿自动路由** —— 发送消息时综合判断视觉附件、Figma URL、实现意图与工作区技术栈：Web/React 任务自动附加 `design-to-code`，Swift/Xcode 工程中的视觉实现任务优先附加 `figma-swiftui`；显式选择技能时不再被竞争技能覆盖，禁用技能后不会自动加载。
- **设计还原 QA 门禁** —— 内置实现工作流与 Design QA 引用资源，要求对源视觉和浏览器渲染结果进行同视口、同状态比较，检查布局、字体、颜色、素材、文案、交互、响应式与无障碍，并用 `design-qa.md` 记录 `passed` 或 `blocked`。

### Changed

- 版本号从 **1.154.0-rc2** 提升为 **1.155.0-rc1**；Xcode App、Go agent、Help bundle、Computer Use Helper、README badge、移动网关响应头契约与产品文档同步。

---

## 1.154.0-rc2 - 2026-07-15

### Fixed

- 用户消息包含图片时，图片缩略图改为独立的无背景右对齐行，文字和文本附件另起一行进入浅色气泡，不再把图片包进整块用户消息背景。
- 实时 SwiftUI 消息、TextKit 历史消息和紧凑侧栏统一采用图片在上、文字在下的结构；图片仍可点击预览，并继续参与整条用户消息的 hover 操作。

### Changed

- 版本号从 **1.154.0-rc1** 递增为 **1.154.0-rc2**；Xcode App、Go agent、Help bundle、Computer Use Helper、README badge、移动网关响应头契约与产品文档同步。

---

## 1.154.0-rc1 - 2026-07-15

### Added

- **内置 Figma ↔ SwiftUI Skill** —— 新增 WillDeep 兼容的 `figma-swiftui` 内置技能，覆盖 Figma 设计转 SwiftUI 与 SwiftUI 回写 Figma 两个方向；优先使用已配置的 Figma MCP，缺少读取能力时可基于用户附件安全降级，缺少写入能力时不会伪报已修改 Figma。
- **必要场景自动触发** —— 发送消息前会轻量识别“Figma/设计稿 + SwiftUI/iOS/Xcode 语境 + 实现/转换意图”，自动附加该技能；显式 `$figma-swiftui` 始终触发，纯 Swift 问题、概念比较或 React 设计任务不会误触发，用户在技能设置中禁用后也不会自动加载。
- **Skill 引用资源读取** —— `read_skill` 新增安全的 `resource` 参数，可继续读取选中 Skill 内的 `references/...` 文件，并拒绝目录穿越与 Skill 目录外文件。

### Changed

- 版本号从 **1.153.0-rc4** 提升为 **1.154.0-rc1**；Xcode App、Go agent、Help bundle、Computer Use Helper、README badge、移动网关响应头契约与产品文档同步。

---

## 1.153.0-rc4 - 2026-07-15

### Fixed

- “正在思考”“正在自动压缩上下文”和并发排队提示改为与 AI 正文左边缘一致的轻量状态组，上方使用低对比度分隔线，文字和图标使用更克制的灰色，不再居中夹在两段横线之间。
- 思考阶段不再同时渲染居中的呼吸动画，避免同一过程出现两套相互争抢视觉焦点的反馈；压缩状态改用静态语义图标，思考计时继续保留。

### Changed

- 过程状态文案接入现有 String Catalog，补齐英文与简体中文资源。
- 版本号从 **1.153.0-rc3** 递增为 **1.153.0-rc4**；Xcode App、Go agent、Help bundle、Computer Use Helper、README badge、移动网关响应头契约与产品文档同步。

---

## 1.153.0-rc3 - 2026-07-15

### Fixed

- 用户消息正文缩进改为随实际聊天容器宽度和气泡边缘动态计算，窄窗口下不再出现过大的左侧空白，窗口宽度变化时同步重排。
- 用户气泡上下内边距由 13 pt 收紧为 8 pt，并为上一轮输出到用户输入、悬浮时间/复制尾栏到下一条输入分别保留稳定间距，避免内容和操作图标贴边。

### Changed

- 版本号从 **1.153.0-rc2** 递增为 **1.153.0-rc3**；Xcode App、Go agent、Help bundle、Computer Use Helper、README badge、移动网关响应头契约与产品文档同步。

---

## 1.153.0-rc2 - 2026-07-15

### Changed

- **助手输出改用处理耗时分隔** —— 历史与流式消息移除重复的 `✦ Assistant` 标题，改为灰色“处理中 / 已处理耗时”开头；耗时不再重复占用消息底栏。
- **token 统计与正文排版更紧凑** —— 输入/输出 token 从 `in 54.2k · out 59` 精简为 `54.2k/59`；聊天默认正文字号从 13 pt 调整为 14 pt，并放松正文行高和段间距以贴近 Codex 默认阅读密度。

### Fixed

- **复制状态图标不再跳到左边缘** —— TextKit 在复制图标切换为打勾、再恢复时会保留原 footer 段落缩进；复制与打勾统一使用固定尺寸 SF Symbol，占位与基线不再变化。
- **用户消息 hover 信息远离气泡边界** —— 时间和复制图标增加顶部间隔与右侧内缩，不再压在浅色背景方框边界上，SwiftUI 流式路径与 TextKit 历史路径同步。
- 版本号从 **1.153.0-rc1** 递增为 **1.153.0-rc2**；Xcode App、Go agent、Help bundle、Computer Use Helper、README badge、移动网关响应头契约与产品文档同步。

## 1.153.0-rc1 - 2026-07-14

### Added

- **some.im 托管联网搜索兜底** —— Web Search 工具在本机未配置 Exa / Brave API Key 且已登录 some.im 时，会调用 some.im 托管搜索接口；托管接口也失败时再明确提示用户去 Web tools 填写本地搜索 API Key。
- **some.im 更新服务集成** —— WillDeep 启动后延迟 1 分钟查询 some.im 公开更新接口，此后每 17 分钟轮询；发现新版本时在侧栏 some.im 账号区上方展示更新提示，支持下载完成后询问是否退出并打开安装包。
- **some.im 客户端服务 Skill** —— 新增 `some-im-client-services` bundled skill，记录 WillDeep 与 some.im 后端协同时的托管搜索、更新服务、鉴权、i18n、版本与验证流程。

### Changed

- 版本号从 **1.152.0-rc31** 提升为 **1.153.0-rc1**；Xcode App、Go agent、Help bundle、Computer Use Helper、README badge、移动网关响应头契约与产品文档同步。

### Fixed

- **some.im 更新说明正确解码** —— 更新接口返回 `release_notes` 时会映射到客户端更新提示，不再丢失版本说明。

## 1.152.0-rc31 - 2026-07-14

### Fixed

- **AI Agents 子标签切换不再同步扫描磁盘** —— Skills 页的目录枚举与 `SKILL.md` 解析、MCP 页的 Cursor/Codex 配置发现、Rules 页的规则文件读取，以及 Memory/学习审阅数据解码全部改为后台加载，页面先展示轻量加载态再更新内容。
- **设置数据刷新防止重复堆叠** —— Skills 与 MCP 的刷新请求会在当前加载完成后合并补跑，避免快速切换、启停或安装操作叠加多轮目录扫描并重新拖高主线程 CPU。
- **设置响应性回归契约** —— 新增 Ruby 检查并输出 Markdown/JSON 报告，锁定轻量初始化、后台磁盘读取和刷新合并三类性能约束。
- **some.im 托管搜索编译兼容** —— 搜索结果 provider 的空值回退改用文件内判断，不再跨文件访问 `fileprivate` 字符串辅助属性。
- 版本号从 **1.152.0-rc30** 递增为 **1.152.0-rc31**；Xcode App、Go agent、Help bundle、Computer Use Helper、README badge、移动网关响应头契约与产品文档同步。

## 1.152.0-rc30 - 2026-07-14

### Added

- **本地终端主机验证弹层** —— Agent 侧边终端的本地标签新增“验证主机”入口，说明手动 SSH 可能改变真实主机，并提供一键复制 `hostname` 命令；切换标签时自动关闭弹层并清除复制反馈。

### Changed

- **终端标签与会话身份改为紧凑双层设计** —— 会话类型、当前路径、运行状态和主机验证拆成清晰字段，移除原先低对比度的第二行警告文字；SSH 标签继续直接展示已配置目标。
- **终端标签完整适配七套界面皮肤** —— 标签选中底色、正文/次级文字、边线、状态胶囊、验证入口和弹层均改用当前 `EditorInterfaceSkinPalette`，避免深色皮肤与自定义浅色皮肤出现文字不可读。
- **命令审核框隐藏内部布局说明** —— 命令内容仍保持约三行高度并在超出时支持横向/纵向滚动，但不再向用户展示“最多显示 3 行，超出可滚动”这类实现文案。
- 版本号从 **1.152.0-rc29** 递增为 **1.152.0-rc30**；Xcode App、Go agent、Help bundle、Computer Use Helper、README badge、移动网关响应头契约与产品文档同步。

## 1.152.0-rc29 - 2026-07-14

### Fixed

- **审核/用户输入按钮保持箭头鼠标** —— 工具审核、危险确认、`ask_user` 选项和提交按钮 hover 时显式使用系统箭头，避免被周围可选文本区域带成文本光标。
- **聊天图片 hover 保持箭头鼠标** —— TextKit 历史聊天里的图片缩略图与内部可点击附件统一使用箭头 cursor，点击预览能力不变。
- 版本号从 **1.152.0-rc28** 递增为 **1.152.0-rc29**；Xcode App、Go agent、Help bundle、Computer Use Helper、README badge、移动网关响应头契约与产品文档同步。

## 1.152.0-rc28 - 2026-07-14

### Fixed

- **用户输入小横线贴近 Codex 样式** —— 左侧用户输入 minimap 刻度缩短为更轻量的短横线，常态下按从上到下逐步加深并在下方钳制深度，hover 时只轻微拉长与加深。
- **短对话不再过早显示输入 minimap** —— 聊天区现在至少 6 段用户输入后才显示左侧用户输入导航刻度，避免两三轮对话就出现多余视觉噪声。
- 版本号从 **1.152.0-rc27** 递增为 **1.152.0-rc28**；Xcode App、Go agent、Help bundle、Computer Use Helper、README badge、移动网关响应头契约与产品文档同步。

## 1.152.0-rc27 - 2026-07-14

### Fixed

- **助手消息移除圆角卡片背景** —— 流式 SwiftUI 消息与历史 TextKit 消息统一改为直接铺在对话底面上，保留正文、Markdown、图片和页脚能力，不再用圆角矩形包裹整段 AI 输出。
- **用户消息改为极淡无描边气泡** —— 移除用户消息上方重复的 `You` 标题与强调色背景，主聊天和紧凑侧栏统一使用低对比度中性色底。
- **用户页脚仅在 hover 时显示** —— 时间、复制等信息和操作图标默认透明且不可点击，但继续占据原有高度；鼠标移入消息后整体显现，避免气泡尺寸和后续内容发生跳动。图片消息也纳入同一规则，并增加历史渲染回归断言。
- 版本号从 **1.152.0-rc26** 递增为 **1.152.0-rc27**；Xcode App、Go agent、Help bundle、Computer Use Helper、README badge、移动网关响应头契约与产品文档同步。

## 1.152.0-rc26 - 2026-07-14

### Fixed

- **聊天图片支持点击放大查看** —— 用户发送图片、助手生成图片以及历史 TextKit 消息中的缩略图统一增加点击入口，打开独立可调整大小的图片预览窗口。
- **原图预览与缩放控制** —— 预览优先读取文件落盘的原始图片，内联图片回退 base64；支持适应窗口、25%–400% 缩放、双击切换和双向滚动，并补齐中英文文案与历史图片链接回归测试。
- **本地化门面文件拆分** —— 将图片编辑器文案从 `L10n.swift` 拆到独立扩展，主文件降至 3000 行硬门槛以内，调用 API 保持不变。
- 版本号从 **1.152.0-rc25** 递增为 **1.152.0-rc26**；Xcode App、Go agent、Help bundle、Computer Use Helper、README badge、移动网关响应头契约与产品文档同步。

## 1.152.0-rc25 - 2026-07-14

### Fixed

- **桌宠零输出不再显示计数圆圈** —— 消息卡片与收起计数现在同时要求 WillDeep 位于后台且存在至少一个最近输出会话；输出会话数为 `0` 时，数字与圆形背景均不渲染。
- **桌宠空输出可见性回归覆盖** —— 补充前台、后台零输出和后台有输出三种状态测试，防止空计数徽标再次出现。
- 版本号从 **1.152.0-rc24** 递增为 **1.152.0-rc25**；Xcode App、Go agent、Help bundle、Computer Use Helper、README badge、移动网关响应头契约与产品文档同步。

## 1.152.0-rc24 - 2026-07-14

### Fixed

- **WillDeep 不在前台时仍可直接拖动桌面宠物** —— 桌宠宿主视图显式接受 inactive App 的第一次鼠标事件，在保留 non-activating panel、不抢前台焦点的同时，让 SwiftUI `DragGesture` 能从第一次按下开始收到完整拖拽序列。
- **桌宠后台拖动回归覆盖** —— 新增宿主视图 `acceptsFirstMouse` 测试，防止后续窗口重构再次吃掉后台第一下鼠标事件。
- 版本号从 **1.152.0-rc23** 递增为 **1.152.0-rc24**；Xcode App、Go agent、Help bundle、Computer Use Helper、README badge、移动网关响应头契约与产品文档同步。

## 1.152.0-rc23 - 2026-07-14

### Fixed

- **桌面宠物改为大卡片网格** —— 设置页移除重复的宠物形象下拉框与横向滚动缩略图，改用随窗口宽度自动增列的网格；单个宠物预览、名称区域和点击范围整体放大，并保留描边与右上角选中标记。
- 版本号从 **1.152.0-rc22** 递增为 **1.152.0-rc23**；Xcode App、Go agent、Help bundle、Computer Use Helper、README badge、移动网关响应头契约与产品文档同步。

## 1.152.0-rc22 - 2026-07-14

### Fixed

- **任务监控文件可在 Finder 中定位** —— 右侧栏“产物”与“工作文件”统一使用整行点击区域；单个工作文件会在 Finder 中选中，同目录多文件分组会直接打开对应目录，已删除文件则回退到其所在目录。
- **Finder 目标回归覆盖** —— 新增单文件、多文件分组与已删除文件的目标解析测试。
- **some.im 账号展示同步头像与昵称** —— WillDeep 读取 some.im 返回的 `nickname` 与 `avatar_url`，侧栏、设置页和 onboarding 优先显示客户昵称；侧栏头像有图片时显示圆形头像，无图时回退首字母。
- 版本号从 **1.152.0-rc21** 递增为 **1.152.0-rc22**；Xcode App、Go agent、Help bundle、Computer Use Helper、README badge、移动网关响应头契约与产品文档同步。

## 1.152.0-rc21 - 2026-07-14

### Fixed

- **Coding Plan 已购状态提示** —— Agent 模型面板打开时主动刷新 some.im 套餐状态；已购用户展示套餐名称、“已订阅”和有效期，并把“购买套餐”改为“管理套餐”；首次查询期间显示加载态，避免已购用户看到误导性购买入口。
- **复用现有套餐接口** —— 继续使用 `/api/v1/customer/plan/subscription` 返回的 `plan_display_name`、`period_end` 和 `status`，无需扩展 `/api/v1/customer/me`。
- 版本号从 **1.152.0-rc20** 递增为 **1.152.0-rc21**；Xcode App、Go agent、Help bundle、Computer Use Helper、README badge、移动网关响应头契约与产品文档同步。

## 1.152.0-rc20 - 2026-07-14

### Fixed

- **模型选择面板全部禁用焦点抢占** —— 模型与托管方式弹窗里的关闭、托管、套餐、模型行和滚动内容统一补齐 `.focusable(false)`，避免 SwiftUI popover 内控件进入键盘焦点链后出现焦点框或抢焦点。
- **模型选择面板改为先选 Provider 再选模型** —— 面板从单列长列表重排为左侧 provider/托管来源、右侧模型详情的两栏结构；用户先选服务商或省心托管，再在右侧选择路由默认、Flash、Pro、Coding Plan、推荐或更多模型。
- **设置侧边栏整行可点击** —— 设置窗口左侧 tab 行改为显式撑满宽度，文字后面的空白区域也能切换 tab，不再只有图标和文字附近响应。
- **桌面宠物空状态卡片可进入新聊天** —— 没有活跃对话时，点击桌面宠物的“守望中 / 暂无活跃对话”卡片会打开 Agent 窗口并进入新聊天状态。
- 版本号从 **1.152.0-rc19** 递增为 **1.152.0-rc20**；Xcode App、Go agent、Help bundle、Computer Use Helper、README badge、移动网关响应头契约与产品文档同步。

## 1.152.0-rc19 - 2026-07-14

### Fixed

- **Git/远程命令尾部输出读取更可靠** —— Git 状态命令与远程 SSH 命令在子进程退出后改用 EOF drain 读取 stdout/stderr 尾部数据，避免 `readabilityHandler` 事件尚未派发时被置空导致输出偶发丢失。
- 版本号从 **1.152.0-rc18** 递增为 **1.152.0-rc19**；Xcode App、Go agent、Help bundle、Computer Use Helper、README badge、移动网关响应头契约与产品文档同步。

## 1.152.0-rc18 - 2026-07-14

### Fixed

- **桌面宠物前台消息卡片隐藏** —— WillDeep 位于前台时，小桌面宠物只保留宠物本体，不再展示最近 3 个会话输出卡片或折叠计数；App 切到后台后继续显示最近输出提醒。
- 版本号从 **1.152.0-rc17** 递增为 **1.152.0-rc18**；Xcode App、Go agent、Help bundle、Computer Use Helper、README badge、移动网关响应头契约与产品文档同步。

## 1.152.0-rc17 - 2026-07-14

### Changed

- **Agent 模型选择大面板** —— Composer 模型入口从小型菜单升级为弹出配置面板：未绑定 some.im 时只展示用户自己配置的 Flash / Pro 模型；已绑定 some.im 时展示省心托管、Coding Plan 订阅入口、Plan Low/High 快捷选择和重点推荐模型。
- **some.im 模型推荐与购买引导** —— 面板突出 deepseek-v4-flash/pro、glm / glm-5.1 / glm-5.2、grok-4.5 的适用场景，并提供 `https://some.im/customer/plan` 订阅链接；不熟悉模型选择的用户可直接选「省心托管」。
- 版本号从 **1.152.0-rc16** 递增为 **1.152.0-rc17**；Xcode App、Go agent、Help bundle、Computer Use Helper、README badge、移动网关响应头契约与产品文档同步。

## 1.152.0-rc16 - 2026-07-14

### Fixed

- **专家介入锁定提示** —— 专家工具包在会话未产生用户消息前可以关闭；一旦专家已参与对话，专家弹窗顶部会显示提示条说明本会话内不能再关闭，避免用户面对禁用开关时不明所以。

### Changed

- 版本号从 **1.152.0-rc15** 递增为 **1.152.0-rc16**；Xcode App、Go agent、Help bundle、Computer Use Helper、README badge、移动网关响应头契约与产品文档同步。

## 1.152.0-rc15 - 2026-07-14

### Added

- **Workspace 会话查询工具** —— 新增 `list_workspace_sessions` 只读工具，可列出当前 workspace 分组下的会话标题、活跃/置顶/归档状态、模式、排队消息数与 provider 等候状态。
- **Flash 标题建议工具** —— 新增 `suggest_session_title`，复用 WillDeep 标题总结 flash 配置，为当前会话基于最新输入生成短标题候选；Agent 可随后调用 `rename_session` 发起改名。

### Changed

- **新输入后的会话改名策略** —— 系统提示要求每次新用户输入后检查当前会话名是否仍匹配任务；普通模式下 `rename_session` 继续走用户确认卡，Goal 模式下 `rename_session` 自动通过且不再打断目标执行，`change_workspace` 在 Goal 模式仍禁用。
- 版本号从 **1.152.0-rc14** 递增为 **1.152.0-rc15**；Xcode App、Go agent、Help bundle、Computer Use Helper、README badge、移动网关响应头契约与产品文档同步。

## 1.152.0-rc14 - 2026-07-14

### Added

- **当前会话排队任务工具** —— 新增 `list_queued_tasks` 只读工具，汇总当前会话排队用户消息、provider 槽位等待、后台 job、媒体任务和 `.codex-build/queue` 项目构建队列，并返回 `defer_heavy_actions_recommended`，让 Agent 在用户未明确要求时可先推迟完整编译、发布或上线等重操作。

### Fixed

- **同会话后续请求待办刷新** —— Plan 模式下已完成的计划不再继续解锁后续写操作；同一会话里用户提出新要求时，系统提示会重新要求生成 `plan`，最新助手消息里的新 `plan` 块会替换旧计划并刷新右侧待办。

### Changed

- **重操作前队列感知提示词** —— 系统提示要求 Agent 在非显式要求的 compile/test/archive/release/deploy 前先调用 `list_queued_tasks`；若当前会话还有排队用户任务，则优先简短回复并把重操作留到后续确认。
- 版本号从 **1.152.0-rc13** 递增为 **1.152.0-rc14**；Xcode App、Go agent、Help bundle、Computer Use Helper、README badge、移动网关响应头契约与产品文档同步。

## 1.152.0-rc13 - 2026-07-14

### Changed

- **Agent 主界面视觉排版优化** —— 聊天区增加横向留白与更稳定的顶部承托，侧边栏标题增强识别度，右侧任务监控模块改为卡片化分区，整体层次更清楚。
- **工具审核卡重设计** —— 待审核/高风险确认卡增加独立标题区、风险徽标和三行内滚动命令预览，长命令不再把审核框撑高；卡内新增“查看解释与解决建议”入口。
- **审核解释模型路由** —— some.im 已绑定且有 Coding Plan 订阅时优先使用 `someim-coding-plan-low/flow`；无订阅时使用 `someim-auto-flash`；未绑定 some.im 时回退当前 provider 的默认 flash 模型。
- 版本号从 **1.152.0-rc12** 递增为 **1.152.0-rc13**；Xcode App、Go agent、Help bundle、Computer Use Helper、README badge、移动网关响应头契约与产品文档同步。

## 1.152.0-rc12 - 2026-07-14

### Changed

- **省心托管档位菜单** —— 模型菜单在启用「省心托管」后显示「托管档位」子菜单，提供 Flash / Pro / Premium 三档并勾选当前档位；用户可直接把当前会话的托管最低档切到任意档，不再使用单独的“降回基础托管档”按钮。
- 版本号从 **1.152.0-rc11** 递增为 **1.152.0-rc12**；Xcode App、Go agent、Help bundle、Computer Use Helper、README badge、移动网关响应头契约与产品文档同步。

## 1.152.0-rc11 - 2026-07-14

### Added

- **项目级构建守卫** —— 新增 `scripts/project_build_guard.rb`，按 workspace 串行化 Xcode/项目级构建任务，后续会话进入本地队列；相同 fingerprint 且产物存在时可复用上次成功结果，并输出 JSON 与 Markdown 报告。

### Changed

- **Xedit 构建入口接入队列** —— `scripts/run_tests.sh` 的 XeditTests 与 `scripts/release.sh` 的测试、dry-run build、archive 阶段接入项目构建守卫，避免多会话同时抢占 DerivedData、SwiftPM resolve 和 `.xcresult`。
- 版本号从 **1.152.0-rc10** 递增为 **1.152.0-rc11**；Xcode App、Go agent、Help bundle、Computer Use Helper、移动网关响应头契约与产品文档同步。

## 1.152.0-rc10 - 2026-07-14

### Fixed

- **Agent 模型菜单勾选与分组文案** —— 路由默认值、省心托管和具体模型不再同时显示勾选；只有显式选中的具体模型才在模型行显示勾。模型尾部分组从“最近获取”改为“所有模型”，省心托管升档后的降档操作改为更直白的“降回基础托管档”。

### Changed

- 版本号从 **1.152.0-rc9** 递增为 **1.152.0-rc10**；Xcode App、Go agent、Help bundle、Computer Use Helper、移动网关响应头契约与产品文档同步。

## 1.152.0-rc9 - 2026-07-14

### Fixed

- **Agent 产物区目录聚合与 Finder 打开** —— 同目录下的多个文件产物会折叠成目录项展示，产物区点击文件会在 Finder 中显示，点击目录会在 Finder 中打开目录，避免长产物列表逐文件刷屏。

### Changed

- 版本号从 **1.152.0-rc8** 递增为 **1.152.0-rc9**；Xcode App、Go agent、Help bundle、Computer Use Helper、移动网关响应头契约与产品文档同步。

## 1.152.0-rc8 - 2026-07-14

### Fixed

- **桌面宠物输入电脑道具移除** —— Agent 输入时不再在桌宠前方显示像素笔记本和敲键盘手部叠层，只保留桌宠本体的轻微晃动反馈。

### Changed

- 版本号从 **1.152.0-rc7** 递增为 **1.152.0-rc8**；Xcode App、Go agent、Help bundle、Computer Use Helper、移动网关响应头契约与产品文档同步。

## 1.152.0-rc7 - 2026-07-14

### Fixed

- **桌面宠物输出卡片新鲜度** —— 左侧对话卡片只列出最近 1 分钟内仍有助手输出的会话，超过 1 分钟的旧输出不再继续展示或计入收起数字。

### Changed

- 版本号从 **1.152.0-rc6** 递增为 **1.152.0-rc7**；Xcode App、Go agent、Help bundle、Computer Use Helper、移动网关响应头契约与产品文档同步。

## 1.152.0-rc6 - 2026-07-14

### Fixed

- **工作区空项目保留** —— Agent 侧边栏添加多个项目时，即使前一个项目还没有任何用户对话，也会保留该项目的一条空新对话占位，避免添加第二个项目后第一个项目看起来被替换。

### Changed

- 版本号从 **1.152.0-rc5** 递增为 **1.152.0-rc6**；Xcode App、Go agent、Help bundle、Computer Use Helper、移动网关响应头契约与产品文档同步。

## 1.152.0-rc5 - 2026-07-14

### Fixed

- **桌面宠物原地转圈轴向** —— 回复就绪后的转圈动画改为绕竖直轴原地转身，避免角色整张图在平面内翻滚到头朝下。

### Changed

- 版本号从 **1.152.0-rc4** 递增为 **1.152.0-rc5**；Xcode App、Go agent、Help bundle、Computer Use Helper、移动网关响应头契约与产品文档同步。

## 1.152.0-rc4 - 2026-07-14

### Fixed

- **桌面宠物拖动动画再降速** —— 拖动桌面宠物时的行走摆动与步态起伏频率继续降低，让拖动反馈更从容。

### Changed

- 版本号从 **1.152.0-rc3** 递增为 **1.152.0-rc4**；Xcode App、Go agent、Help bundle、Computer Use Helper、移动网关响应头契约与产品文档同步。

## 1.152.0-rc3 - 2026-07-14

### Fixed

- **设置窗口焦点框禁用** —— 设置窗口根视图、左侧分类标签、二级分段标签与内容容器统一使用 `focusable(false)`，避免 tab 标签和设置内容出现键盘焦点高亮框。

### Changed

- 版本号从 **1.152.0-rc2** 递增为 **1.152.0-rc3**；Xcode App、Go agent、Help bundle、Computer Use Helper、移动网关响应头契约与产品文档同步。

## 1.152.0-rc2 - 2026-07-14

### Fixed

- **桌面宠物拖动动画节奏** —— 拖动桌面宠物时的行走摆动与步态频率放慢，保留拖动反馈但减少快速抖动感。

### Changed

- 版本号从 **1.152.0-rc1** 递增为 **1.152.0-rc2**；Xcode App、Go agent、Help bundle、Computer Use Helper、移动网关响应头契约与产品文档同步。

## 1.152.0-rc1 - 2026-07-14

### Fixed

- **some.im 浏览器登录 Keychain 兜底** —— 浏览器登录拿到 some.im app API key 后，若共享 Keychain access group 写入失败，WillDeep 会退回本 App 私有 Keychain 保存并读回验证，避免网页已登录但客户端提示“已返回凭据但保存失败”后无法继续使用；只有共享 Keychain 与私有兜底都失败时才显示本地保存失败。

### Changed

- 版本号从 **1.152.0** 递增为 **1.152.0-rc1**；Xcode App、Go agent、Help bundle、Computer Use Helper、移动网关响应头契约与产品文档同步。

## 1.152.0 - 2026-07-14

### Added

- **桌面宠物多会话输出卡片** —— 桌面宠物旁的文字卡片现在最多展示 3 个最新有助手输出的会话，每条可点击回到对应会话；卡片右上角新增收起按钮，收起后在宠物旁显示带输出会话数的圆形入口，点击数字或圆圈即可展开。

### Fixed

- **暂时停用 AIPipe 上报** —— `AIPipeBootstrap` 当前直接跳过初始化，不再读取或使用 `AIPIPE_API_KEY` / `AIPipeAPIKey` 发起 AIPipe 上报；保留 SDK 接入代码，后续需要时可重新打开开关。

### Changed

- 版本号从 **1.151.0-rc1** 提升为 **1.152.0**；Xcode App、Go agent、Help bundle、Computer Use Helper、移动网关响应头契约与产品文档同步。

## 1.151.0-rc1 - 2026-07-14

### Fixed

- **some.im 浏览器登录保存失败诊断** —— WillDeep 现在区分“some.im 没有返回凭据”和“some.im 已返回凭据但本地 Keychain/共享 session 保存失败”；后者会显示本地保存失败提示，不再误导为 web 端没有回传。
- **some.im 当前返回结构覆盖测试** —— 补充 `status=connected`、`api_key`、`token` 与 `account` 的浏览器登录状态测试，覆盖当前 some.im 线上 payload。
- **发布包签名前置自检** —— `scripts/release.sh` 导出 `.app` 后会立即校验 app 签名，并拒绝包含 `AIPipeAPIKey` 或 some.im 客户端登录密钥的 `Info.plist`；DMG 的 Gatekeeper 自检失败也会中止发布，不再被 `|| true` 吞掉。

### Changed

- 版本号从 **1.151.0** 递增为 **1.151.0-rc1**；Xcode App、Go agent、Help bundle、Computer Use Helper、移动网关响应头契约与产品文档同步。

## 1.151.0 - 2026-07-14

### Added

- **桌面宠物双击跳跃** —— 双击桌面宠物本体会触发一次短跳动画；气泡点击继续用于打开当前会话，拖动摆放不受影响。

### Changed

- 版本号从 **1.150.0-rc3** 提升为 **1.151.0**；Xcode App、Go agent、Help bundle、Computer Use Helper、移动网关响应头契约与产品文档同步。

## 1.150.0-rc3 - 2026-07-14

### Fixed

- **桌面宠物右键菜单本地化与设置直达** —— 补齐「桌面宠物设置…」和「桌面宠物」标签的 `xcstrings` 中英文资源；右键入口改走稳定的设置 fallback 窗口并强制选中宠物设置，避免打开设置后停在上一次标签。
- **Developer ID 证书选择约束** —— `scripts/release.sh` 不再依赖整段固定证书名，而是在钥匙串中强制解析唯一的 `Developer ID Application`、名称包含 `Beijing Alibaba`、Team ID 为 `ZH2S7D6PL6` 的证书；未找到或匹配多个都会停止发布。

### Changed

- **设置窗口左侧栏化** —— 设置窗口改为左侧一等分类、右侧内容页的两栏结构；桌面宠物提升到左侧独立入口，编辑器 / AI / 运行时 / 集成等分类继续保留二级分段切换。
- **发布手册对齐 WillDeep** —— `docs/RELEASE.md` 的标题、产物路径和 notarytool profile 示例统一为 WillDeep / `willdeep-notary`。
- 版本号从 **1.150.0-rc2** 递增为 **1.150.0-rc3**；Xcode App、Go agent、Help bundle、Computer Use Helper、移动网关响应头契约与产品文档同步。

## 1.150.0-rc2 - 2026-07-13

### Fixed

- **Release helper 构建耗时可观测性** —— `Build WillDeep Computer Use Helper` Run Script 现在按阶段输出 `START` / `DONE` / `FAILED` 和秒级耗时，覆盖 bundle 准备、arm64/x86_64 编译、lipo、codesign 与 verify；签名失败时会补充 bundle 结构和 `codesign --display` 诊断，避免 release archive 十几分钟后只剩一个 `errSecInternalComponent`。

### Changed

- 版本号从 **1.150.0-rc1** 递增为 **1.150.0-rc2**；Xcode App、Go agent、Help bundle、Computer Use Helper、移动网关响应头契约与产品文档同步。

## 1.150.0-rc1 - 2026-07-13

### Fixed

- **Release archive 编译器崩溃规避** —— `WorkflowWatchdogRace` 新增显式空析构函数，绕开 Swift 6.3.1 在 Release 优化时对泛型类合成析构路径的 `SIL EarlyPerfInliner` 偶发崩溃；该修复需随工具链升级重新验证。

### Changed

- 版本号从 **1.150.0** 递增为 **1.150.0-rc1**；Xcode App、Go agent、Help bundle、Computer Use Helper、移动网关响应头契约与产品文档同步。

## 1.150.0 - 2026-07-13

### Added

- **宠物输入动作** —— Agent 输入框含有内容时切换为“陪你敲字中”，显示打包的原创像素笔记本；宠物抬身、双手、键盘和屏幕光依节拍敲击/闪烁。拖动时的走路动画与位置记忆继续保留。

### Changed

- 版本号从 **1.149.0** 提升为 **1.150.0**；Xcode App、Go agent、Help bundle、Computer Use Helper、移动网关响应头契约与产品文档同步。

## 1.149.0 - 2026-07-13

### Added

- **桌面宠物默认开启** —— 首次启动即陪伴。关闭状态仍会写回本地偏好，用户的显式选择不会被默认值覆盖。
- **桌面宠物可拖动** —— 直接拖拽宠物即可摆放到屏幕任意位置，落点写回本地偏好、下次显示时恢复；若保存的位置落在已断开的显示器上则自动退回右下角默认位。
- **宠物设置升为一等标签** —— 设置窗口新增独立的「桌面宠物」标签（爪印图标），不再挤在「AI Agents」里；宠物右键菜单新增「桌面宠物设置…」，一键跳转到该标签。

### Changed

- 版本号从 **1.148.0-rc2** 提升为 **1.149.0**；Xcode App、Go agent、Help bundle、Computer Use Helper、移动网关响应头契约与产品文档同步。

### Fixed

- **Agent 主窗口最小尺寸约束** —— 此前窗口可被拖成没法用的竖窄条（侧栏自动隐藏、右面板关闭时下限掉到只剩聊天舒适宽 ~320）。现在钉了绝对最小宽 720 / 最小高 480 的硬地板，并补齐了此前完全缺失的最小高度约束。

## 1.148.0-rc2 - 2026-07-13

### Fixed

- **桌面宠物浮窗文字在深色壁纸上看不清** —— 宠物气泡背景用的是 `.ultraThinMaterial`，透明度太高，深色桌面壁纸会透上来，把「守望中」状态、会话标题（`.secondary`）等文字冲淡到几乎不可读。改为 `.regularMaterial`：材质本身足够不透明、自带对比衬底，语义色文字在任意深/浅壁纸下都清晰。

### Changed

- 版本号从 **1.148.0-rc1** 递增为 **1.148.0-rc2**。

## 1.148.0-rc1 - 2026-07-13

### Fixed

- **Composer 的「搜索技能」面板漏接 skill 本地化** —— 仓库早已有 `AgentSkillLocalization`（中英文 name/description/别名表 + 多语言召回池），设置页、`list_skills` 工具、移动网关都用了，唯独 composer 的 `$` 技能面板没接：说明直接显示英文原始 `description`，搜索只匹配英文 `identifier/name/description`，中文用户搜「日报」「浏览器」命中不了 `daily-report`/`browser`。现在：
  - **展示**：面板每行的说明改走 `AgentSkillLocalization.displayDescription`，按用户语言本地化（`$identifier` 调用名保持原样，因为那是要输入的调用 token）。
  - **搜索召回**：过滤改用 `AgentSkillLocalization.searchableText`，把 skill 的多语言 name/description/别名都纳入命中池；且 `searchableText` 现在**同时拼英文和中文两张表**（不再只拼当前语言那张），实现真正双向召回——中文关键词命中英文原文 skill，英文关键词对中文用户也照常命中。

### Changed

- 版本号从 **1.148.0** 递增为 **1.148.0-rc1**。

## 1.148.0 - 2026-07-13

### Added

- **恢复六个宠物形象** —— 恢复天线植物学家、宇宙学者、爪痕硬汉、植能机器人、云锻工程师和红帽客服英雄六个原创像素宠物，设置页形象库从 16 个扩充为 22 个；所有形象继续复用待机、走路、跳跃、转圈、提醒和庆祝动画。

### Changed

- 版本号从 **1.147.0** 提升为 **1.148.0**；Xcode App、Go agent、Help bundle、Computer Use Helper、移动网关响应头契约与产品文档同步。

## 1.147.0 - 2026-07-13

### Added

- **桌面宠物与会话浮窗** —— Agent 顶栏新增爪印开关；设置页可启用宠物并在 16 个打包的原创像素形象中选择。浮窗显示当前会话最新用户/助手消息，点击跳回相应会话；宠物会按真实会话状态待机、走路、跳跃、转圈、抖动提醒和任务完成庆祝。
- **两张科幻梗新形象** —— 新增蓝色义体流浪者与蓝皮哨箭船长两个原创像素形象；只取科幻类型气质，不复刻特定电影角色、演员肖像、名称或标识。

### Changed

- 版本号从 **1.146.0-rc4** 提升为 **1.147.0**；Xcode App、Go agent、Help bundle、Computer Use Helper、移动网关响应头契约与产品文档同步。

## 1.146.0-rc4 - 2026-07-13

### Fixed

- **会话落盘跨进程竞态导致数据丢失** —— 双开 App（或设置窗口第二个 AppState、routine 进程）读写同一会话目录时，此前的写入编排（串行写队列、合并/排序 ticket、metadata-only 追踪）全是进程内 `static`，对另一个进程零保证，存在两类隐患：
  - **启动 prune 误删**：进程 B 启动扫描目录，把进程 A 刚 append 用户消息、还没落盘的会话判成“空占位”而删除，A 的真实历史随之丢失。现在 prune 的删除动作改走新的 `deleteIfStillEmpty(id:)`——在文件协调（`NSFileCoordinator`）下**重新读一次磁盘文件**，只有当磁盘副本此刻仍无用户消息才删，否则跳过并保留在会话列表里。
  - **同 id 覆写（lost update）**：两进程写同一 `<uuid>.json` 是 last-writer-wins。现在 `save` / `saveAsync` / `delete` 的文件读写统一经 `NSFileCoordinator` 跨进程串行协调（协调失败时降级为原子写，不丢操作），并保留原有进程内串行写队列与 `.atomic` 语义。
  - 额外加了 **90s 最近修改宽限窗口**：prune 会跳过 mtime 很新的会话文件（很可能是另一进程正在使用的活会话），确实被遗弃的空占位在后续启动超窗后照常清理。

### Changed

- 版本号从 **1.146.0-rc3** 递增为 **1.146.0-rc4**。

## 1.146.0-rc3 - 2026-07-13

### Fixed

- **Workflow watchdog 真正按时返回** —— `/code-review` 等 workflow 的超时兜底改为非结构化竞速实现；当子 agent/provider stream 卡在不响应取消的网络读取里时，卡片会按 watchdog 转为失败并显示原因，不再被卡死子任务拖住。

### Changed

- 版本号从 **1.146.0-rc2** 递增为 **1.146.0-rc3**。

## 1.146.0-rc2 - 2026-07-13

### Fixed

- **发消息后 AI 侧「无返回、无报错、界面像死了」不再静默** —— 修复两类静默无回应：
  - **空流被当成功**：provider 返回 HTTP 2xx 但 SSE 流没有任何事件（中继 token 失效被回成空 body、上游抖动、限流表现为空流）时，四个流式适配器（OpenAI Chat / Anthropic / OpenAI Responses / Gemini）现在会抛出明确的 `emptyStream` 错误并弹出可「重试」的错误卡片，而不是悄悄丢掉整轮、删掉占位消息后一言不发。流正常结束但模型零输出的情况在主循环里也补了同款反馈。
  - **排队等并发槽时全屏聊天无指示**：消息发出后没抢到 provider 并发槽（同一 provider 已跑满 `perProviderConcurrencyLimit`，如多会话/双开/routine 并发）时，`isResponding` 仍为 false，全屏 `AgentChatTranscript` 之前对这个状态没有任何渲染——用户只看到自己的消息、界面像死了，直到某个槽空出来才「又开始输出」。现在全屏主聊天也会显示「正在排队，等待空闲的并发槽位…」提示条（此前仅侧栏有）。

### Changed

- 版本号从 **1.146.0-rc1** 递增为 **1.146.0-rc2**。

## 1.146.0-rc1 - 2026-07-13

### Fixed

- **Workflow 超时不再被卡死子任务拖住** —— workflow watchdog 改为非结构化竞速实现；当 provider stream 或子 agent 网络请求不响应取消时，`/code-review` 等 workflow 会按超时转为失败卡片并给出原因，不再一直空转无返回。

### Changed

- 版本号从 **1.146.0** 递增为 **1.146.0-rc1**。

## 1.146.0 - 2026-07-13

### Added

- **媒体任务产物生成中占位** —— 活跃的图片/视频媒体任务现在会显示横向产物条，即使暂时还没有文件落地也会给出与缩略图同尺寸的“生成中”占位卡；已有部分产物时，占位卡保留在列表末尾，提示后续产物仍在生成。

### Changed

- 版本号从 **1.145.0** 提升为 **1.146.0**。

## 1.145.0 - 2026-07-13

### Added

- **Computer Use 最新画面悬浮预览** —— 当前任务执行 `computer_use_*` 工具并取得应用截图后，聊天区右上角显示响应式缩略图；后续动作会更新同一预览，任务停止后自动隐藏悬浮入口。
- **Agent 全窗口截图蒙版查看** —— 点击缩略图可在 Agent 当前窗口内放大最新截图，支持右上角关闭按钮、点击背景与 Escape 退出；展开期间收到新截图时保持打开并实时更新。
- **Agent 新对话工作进展页** —— 空白新对话中的统计面板升级为紧凑数据总览：展示任务轮次、工具调用、改动文件、交付物和当前连续使用天数，并保留活动热力图。
- **真实工作数据与常用能力洞察** —— 统计会从持久化会话读取工作区、工作流、Agent 改动/交付物账本和实际工具名；工具按工作区、代码、终端、调研、浏览器、媒体、自动化与 MCP 等能力分组，避免把仅启用但未使用的 Skill/MCP 伪装成使用记录。
- **本周工作台** —— 新对话概览增加“本周交付物”和“失败工具调用复盘”两张紧凑卡片：前者只读取本周有更新会话的交付物账本；后者只展示显式执行失败，不把用户拒绝或文案猜测误算为失败。

### Changed

- **截图状态限定在当前会话与执行轮次** —— 切换会话或开始新任务时重置 Computer Use 展示状态；截图继续使用本地文件附件和现有缩略图缓存，不扩大辅助功能、录屏、工具审批或永久授权边界。
- **模型用量单独保留在模型页** —— Token、缓存与成本等诊断数据不再挤占新对话概览，仍可通过“模型”标签查看。
- **工具失败结果结构化持久化** —— 工具结果会保存执行状态和脱敏错误摘要，让历史会话重开后仍能准确复盘失败原因。
- 版本号从 **1.144.0** 提升为 **1.145.0**。

## 1.144.0 - 2026-07-13

### Added

- **Agent 新对话工作台** —— 空白新对话以真实会话账本呈现任务、工具、文件、交付物与活动洞察，并增加“本周交付物”和“失败工具调用复盘”。

### Changed

- **失败调用结构化持久化** —— 工具结果保存执行状态及脱敏错误摘要；复盘只统计明确执行失败，不将用户拒绝误算为失败。
- 版本号从 **1.140.0-rc6** 提升为 **1.144.0**。

## 1.142.0-rc3 - 2026-07-13

### Fixed

- **侧边栏终端快照标明当前光标行** —— `terminal_snapshot` 现在返回当前光标行、光标行列以及带 `=>` 标记的可见屏幕；模型会明确区分“当前 prompt/input”和上方历史输出，避免把 SSH 前残留的本地目录误判为当前远端环境。本地 tab 也会提示可能存在手动嵌套 SSH，需要用 prompt、`hostname` 或 `pwd` 验证。
- **终端录制/回放控制更清楚** —— 侧边栏顶部改为可读的录制按钮与计时状态，录制列表提供直接播放/停止和省略号更多操作；终端区域新增会话身份条，持续显示本地/SSH、目标与运行状态，降低回放中或远端操作时的误解成本。
- 版本号从 **1.142.0-rc2** 递增为 **1.142.0-rc3**。

## 1.142.0-rc2 - 2026-07-13

### Fixed

- **专家会诊议题可再次编辑** —— “多专家会诊 / 专家圆桌群聊”配置面板里的会诊议题从只读文本改为可编辑文本区，启动时使用用户在面板中修改后的讨论内容，不再只能回到 Composer 改原输入。
- **专家模型改为下拉建议 + 手填兜底** —— Claude Code、Codex CLI、Cursor Agent 每行模型输入旁新增建议模型菜单，可直接选常用模型 ID；Cursor Agent 会异步尝试读取本机 CLI 的当前模型列表，失败时回退内置建议。留空仍使用 CLI 默认模型，列表没有覆盖到的新模型仍可手动输入。
- 版本号从 **1.142.0-rc1** 递增为 **1.142.0-rc2**。

## 1.142.0-rc1 - 2026-07-13

### Fixed

- **顶部侧栏快捷按钮恢复原生点击并校正终端独立光标** —— Diff / 终端 / 预览 / 文件快捷按钮改用标题栏环境下可稳定激活的原生 `NSButton`；终端在重画 SwiftTerm 正文之外，额外触发其自身 display 更新周期，使独立 caret 子视图重新定位，避免输出已推进但光标仍停留在旧提示符、视觉上出现“光标下面还有内容”。
- 版本号从 **1.142.0** 递增为 **1.142.0-rc1**。

## 1.142.0 - 2026-07-13

### Added

- **新增专家圆桌群聊模式** —— 与结构化会诊并列提供“圆桌群聊”：WillDeep 主持开场，所选 Claude Code、Codex CLI、Cursor Agent 按顺序逐个发言，每位专家都能看到此前完整公共对话；用户可配置 2–5 轮，WillDeep 在轮次之间归纳争议并在最后统一定稿。
- **群聊过程实时可见并持久化** —— 会诊卡片按气泡展示 WillDeep 与各专家发言、当前轮次、专家失败信息和最终结论；群聊记录随会话保存，中途停止或应用退出沿用现有中断恢复机制。

### Changed

- **会诊入口增加模式选择** —— 输入议题后点击 Composer 的听诊器按钮，可选择“结构化会诊”或“圆桌群聊”，并继续为每位本机专家单独指定模型。两种模式都固定使用外部 CLI 的只读权限。
- 版本号从 **1.141.0-rc1** 提升为 **1.142.0**。

## 1.141.0-rc1 - 2026-07-13

### Fixed

- **Agent 顶部侧栏快捷按钮恢复稳定打开右侧面板** —— 顶部 diff / terminal / preview / files 等快捷图标点击时，现在会同时更新当前面板状态并发出统一的 side-panel open request；按钮命中区同步放大，避免看得到图标但点击后右侧栏不出现。
- **侧边栏终端切换/输出后主动刷新 SwiftTerm 画面** —— SwiftTerm 终端在重新挂载、尺寸变化和收到 PTY 输出后会主动触发 NSView layout/display，减少旧光标残影和“光标下面还有旧内容”的绘制错位。
- 版本号从 **1.141.0** 递增为 **1.141.0-rc1**。

## 1.141.0 - 2026-07-13

### Added

- **新增“多专家会诊”MVP** —— Composer 新增会诊入口，可选择已安装的 Claude Code、Codex CLI、Cursor Agent 中至少两位专家，并为每位专家单独指定模型；WillDeep 先给出初版，专家并行独立评审，WillDeep 归纳争议后再发起第二轮互评，最后由 WillDeep 汇总为自包含结论。
- **会诊过程可见且可恢复** —— 聊天卡片实时展示当前阶段、专家进度、两轮意见、模型和失败原因，支持停止与复制最终结论；会诊报告随会话持久化，应用异常退出后未完成会诊会明确恢复为“已取消”，不再留下永久转圈。

### Fixed

- **some.im 供应商显示名固定为域名本身** —— 模型供应商 preset、Provider Library 读写、轮次报告和用量统计统一把 `some-im` 展示为 `some.im`；历史会话中已持久化的旧 `some.im (Rocky's relay)` 也会在展示层自动归一，避免侧边栏/统计页继续露出括号昵称。

### Changed

- **外部专家固定只读执行** —— Claude Code 与 Codex CLI 使用 `plan` 权限模式，Cursor Agent 使用 `ask` 权限模式；会诊不会自动编辑文件。各轮输入使用有界惰性数据区封装，降低共享意见中的提示注入和上下文失控风险。
- 版本号从 **1.140.0-rc6** 提升为 **1.141.0**。

## 1.140.0-rc6 - 2026-07-13

### Fixed

- **文档附件「发送预览」弹窗空白** —— 选中 .md（或任意文档）附件后点「发送预览」，弹出的 modal 只有一个空白窗、没有标题也没有内容。根因是 `AgentDocumentContextControls` 用 `.sheet(isPresented:)` + 另一个 `@State preview` 双状态：按钮在同一 tick 里先 `preview = makePreview()` 再置 `isPreviewPresented = true`，而 sheet 的 `if let preview` body 在 `preview` 赋值被观察到之前就先构建了 → 取到 nil → 整个 sheet 内容为空。改用 `.sheet(item: $preview)`，只在 `preview` 非空时呈现并把解包后的值直接传给 body，消除竞态；`AgentDocumentSendPreview` 补 `Identifiable`。预览文本本身没问题（附件存在时 `composeAttachedPrompt` 即使输入框为空也会产出非空内容）。
- 版本号从 **1.140.0-rc5** 递增为 **1.140.0-rc6**。

## 1.140.0-rc5 - 2026-07-13

### Changed

- **用量统计：省心托管流量单列为「省心托管」，不再混进 `unknown-model`** —— 省心托管是每轮由裁判自动路由、没有单一 session 模型，持久化时 `modelID` 被主动清空（`AppStateAgentSessions.swift:1577`），于是它和"老会话/迁移会话的空模型"一起掉进匿名的 `unknown-model` 桶里，看不出是谁。现给用量快照 `AgentUsageSessionSnapshot` 透传 `isManagedRouting`（源自 `session.managedRouting != nil`），托管会话在"模型"分组里聚成一行「省心托管」（从用户视角它本就是一个模型）；**只认托管标记**，老会话的空 `modelID` 仍归 `unknown-model`，不误伤。新增单测覆盖两种空模型的分流。
- **顶部监控条「委派中」接上子代理轮次进度** —— 输入框上方的活动条（`AgentTaskMonitorRail`）此前派子代理时只显示「委派中」+ 计时，和 rc4 加在卡片上的轮次进度没打通。现把子代理的 `subagentProgress` 折进相位标签，显示「委派中 · 第 3/12 轮 · 5 次工具」；不点开卡片也能看出子代理在往前走。仅 `spawn_agent` 有此进度，外部 CLI 委派仍是纯「委派中」。

### Fixed

- 版本号从 **1.140.0-rc4** 递增为 **1.140.0-rc5**。

## 1.140.0-rc4 - 2026-07-13

### Added

- **子代理卡片现在显示"用的哪个子代理"** —— `spawn_agent` 派生的子代理实际跑在哪个模型上（父模型或 `model` 覆盖）此前只在注册表里采集、UI 从不展示，用户点开卡片也看不到底层用谁。现将有效模型 stamp 到工具调用记录并在卡片上以「模型 xxx」徽标呈现（折叠态的分组预览也追加 `· <model>`）。顺带澄清：子代理是 App 进程内、只读工具集的 headless 子 agent loop，走与主循环同一个 provider 网关，**不是**调用 Claude / Codex / Cursor 等外部 CLI。
- **同步派生子代理显示实时轮次进度** —— 默认（前台）`spawn_agent` 会 `await` 整个子 loop 跑完（最多 12 轮 LLM 往返）才返回，期间「委派中」只有一个不动的转圈，像卡死。现每进入一轮就把「第 N/12 轮 · M 次工具」刷到卡片上，让长任务读起来是"在往前走"而非"死掉了"。这不是主线程死锁——是 `async/await` 挂起等待网络 I/O，本次只把等待过程变透明。

### Fixed

- 版本号从 **1.140.0-rc3** 递增为 **1.140.0-rc4**。

## 1.140.0-rc3 - 2026-07-13

### Fixed

- **破坏性命令审批卡片的「拒绝 / 确认执行」按钮点击区放大** —— 原来「拒绝」是裸文字、「确认执行」内边距很小，在小卡片里很难点中。现将两个按钮统一放大：字号 `caption → subheadline`、内边距加大到 16×8，并给「拒绝」补上等大的描边点击区与 `contentShape`，两键点击热区一致、更好点。
- 版本号从 **1.140.0-rc2** 递增为 **1.140.0-rc3**。

## 1.140.0-rc2 - 2026-07-13

### Fixed

- **some.im 登录后新聊天始终默认省心托管** —— 手动选择具体模型仅覆盖当前会话，不再通过全局偏好让后续新聊天退出托管；历史会话仍保持原有选择，不被自动改写。
- **托管领域标签不再被 Coding Plan 权益误导** —— 页脚“通用/编程”改为展示裁判实际 `domain`，能力等级仍取实际选中模型；即使通用任务因 Coding Plan 权益使用 `someim-coding-plan-*`，也不会再伪装成“裁判判定为编程”。裁判提示词同时明确 Workspace、工具开关和开发应用环境本身不是编程证据，降低环境字段造成的分类偏置。
- 版本号从 **1.140.0-rc1** 递增为 **1.140.0-rc2**。

## 1.140.0-rc1 - 2026-07-13

### Fixed

- **Goal 模式不再触发会话改名或 Workspace 切换** —— Goal 请求的工具列表会移除 `rename_session` 和 `change_workspace`；执行层同时拒绝缓存或异常生成的同名调用且不展示确认卡，保证目标任务持续运行在当前会话与 Workspace 中。
- **省心托管在 some.im 未登录时不再“静默无响应”** —— 会话使用「省心托管」（或 provider 为 some.im）但 some.im 共享登录态已丢失（本机或其它共享 App 登出、token 过期）时，发送不再打出未鉴权中继请求、拿回空流后被静默丢弃（用户看不到回复也无报错）。改为发送前登录门禁：保留用户已输入的消息、弹出可操作错误提示「some.im 未登录，「省心托管」无法工作，请先登录」，并在错误卡片提供「去登录 some.im」按钮一键打开登录页；登录后点「重试」原样重发。`retryLastAgentTurn` 同路径复检，避免仍未登录时再次静默失败。
- 版本号从 **1.140.0** 递增为 **1.140.0-rc1**。

## 1.140.0 - 2026-07-13

### Added

- **Agent 可提议会话改名与 Workspace 切换** —— 新增 `rename_session` 和 `change_workspace` 两项会话级工具，模型仅在标题明显失真或当前 Workspace 缺失、错误时使用；两项操作始终展示逐次确认卡，Goal 模式、智能审批和始终允许规则均不能绕过。
- **Workspace 切换后的旧上下文隔离** —— 当前会话获批切换到新的本地目录后，本轮其余工具调用会被安全跳过并完整补齐工具响应，随后结束该轮；下一条用户消息才会在新 Workspace 中继续，避免文件或命令误落到旧目录。

### Changed

- 版本号从 **1.139.0-rc3** 提升为 **1.140.0**。

## 1.139.0-rc3 - 2026-07-13

### Fixed

- **无工作区的附件 Source 不再打开空 Files 侧栏** —— 点击精确来源时会把模型引用的行号子范围映射到本地较大的文本块，并在引用窗口中只展示对应行；若章节无法精确解析但原附件仍存在，则直接在 Finder 中选中文件。普通附件路径链接在当前会话未选择工作区时也采用 Finder 降级。
- 版本号从 **1.139.0-rc2** 递增为 **1.139.0-rc3**。

## 1.139.0-rc2 - 2026-07-13

### Fixed

- **发送预览不再只显示圆形残影** —— 文档“发送预览”改用独立预览窗口承载，不再受 Composer 圆角与聊天列裁切影响；窗口完整展示实际外发文档上下文、敏感信息检测提示和脱敏结果，并提供明确的关闭入口。
- 版本号从 **1.139.0-rc1** 递增为 **1.139.0-rc2**。

## 1.139.0-rc1 - 2026-07-13

### Fixed

- **附件安全标签不再泄漏到用户气泡** —— 文档正文中的 Markdown 分隔线 `---` 不再被误判为用户输入起点；聊天记录只显示附件摘要和用户真实输入，`untrusted-attachment` 安全信封仍完整发送给模型。新增专用用户正文边界并对附件/技能内容中的同名边界进行转义，同时兼容已有会话。
- 版本号从 **1.139.0** 递增为 **1.139.0-rc1**。

## 1.139.0 - 2026-07-12

### Added

- **会话级资料库** —— 本地文档解析完成后会持久保留在当前会话，后续提问自动按问题召回相关来源；重新打开会话无需再次解压 Office 文件或执行 OCR。Composer 显示“本会话资料”，可逐份启用、停用、预览来源范围或移除。
- **附件增量复用** —— 会话资料记录源文件大小与修改时间；未变化的文件直接复用既有解析结果，发生变化时会在发送前自动重新解析并保留用户输入，避免拿旧内容回答。
- **可点击精确引用** —— Assistant 输出的 `[Source: 文件; page/sheet/section/lines]` 来源标记会渲染为可点击链接；点击打开本地“文档引用”窗口，定位并高亮对应抽取原文，同时可打开原文件或在 Finder 中显示。
- **文件夹知识源** —— 文件选择器和拖放支持把目录加入当前会话知识库；本地递归索引支持的文档类型，遵守 `.gitignore` 与自定义排除规则，默认跳过构建目录、依赖目录、隐藏文件和常见密钥文件。目录变化通过递归文件系统 watcher 防抖后增量重建，未变化文档复用原解析/OCR 结果。
- **智能文档任务模式** —— Composer 可选择自动、总结、比较、电子表格分析、代码审查或证据提取；自动模式会根据问题与附件类型选择专用提示，并强制文档事实使用精确来源标记。
- **发送前隐私预览与本地脱敏** —— “发送预览”展示实际会传给模型的文档片段；默认在本机识别并脱敏私钥、常见 API Key、Bearer/JWT、邮箱、手机号和身份证号。原文件、本地预览与引用窗口仍保留原文，只有外发上下文被替换。
- **引用证据导出** —— 文档引用窗口可把当前定位原文导出为 Markdown、纯文本、PDF 或 DOCX；导出完全在本机完成。

### Changed

- 版本号从 **1.138.0-rc11** 提升为 **1.139.0**。

## 1.138.0-rc11 - 2026-07-12

### Fixed

- **Office 附件解析兼容 Swift 6 并发检查** —— DOCX/XLSX 的 XML 解析数据结构和 delegate 显式声明为非 actor 隔离，消除后台解析路径的主 actor 警告，避免这些警告在 Swift 6 语言模式下升级为编译错误。
- 版本号从 **1.138.0-rc10** 递增为 **1.138.0-rc11**。

## 1.138.0-rc10 - 2026-07-12

### Fixed

- **附件解析预览弹层不再出现红色焦点边框** —— Composer 文档附件 chip、预览弹层、全选/全不选按钮、分块选择行和滚动区域补齐 `.focusable(false)`，打开预览或点击分块时不再抢键盘焦点。
- 版本号从 **1.138.0-rc9** 递增为 **1.138.0-rc10**。

## 1.138.0-rc9 - 2026-07-12

### Added

- **附件解析预览与范围选择**：Composer 文件芯片显示本地解析状态，点击可预览抽取内容，并逐页、逐工作表或逐章节选择是否加入本轮上下文；解析期间发送按钮会等待，避免附件尚未准备好就发出请求。
- **macOS Vision 本地 OCR**：PDFKit 发现页面没有文本层时，自动把该页渲染为图像并通过 Apple Vision 离线识别中英文；OCR 页在预览中单独标记，模型上下文继续保留原始 PDF 页码。OCR provider 采用协议抽象，为后续可选 PaddleOCR 适配器预留接入点。
- **精确来源引用**：PDF 页、XLSX Sheet、DOCX 标题章节和文本行块都生成稳定来源标记；大附件按当前问题在本地召回相关块，模型收到的每块内容均带 `[Source: 文件; page/sheet/section/lines]`，便于回答时引用原文位置。
- **附件提示注入防护**：所有文档内容放入明确的 `untrusted-attachment` 边界，提示模型不得执行文档内指令、泄露机密或把附件当作系统提示；常见中英文覆盖指令会触发可疑内容警告。

### Changed

- **Office 结构抽取增强**：DOCX 保留 Heading 层级；XLSX 标出隐藏工作表，并同时提供公式与缓存计算结果；`unzip` 输出改为及时排空，避免大 OOXML 条目填满管道导致解析阻塞。
- 版本号从 **1.138.0-rc8** 递增为 **1.138.0-rc9**。

## 1.138.0-rc8 - 2026-07-12

### Added

- **Agent Composer 通用文件附件**：加号文件选择器不再仅限图片，新增本地附加 `txt`、`md`、常见代码文件、`csv`、`tsv`、`json`、PDF、DOCX 和 XLSX；支持多选，并让文件拖放复用同一套附件判断。
- **Office/PDF 本地上下文抽取接线**：纯文本文件直接读取，PDF 使用 PDFKit 抽取文本层，DOCX/XLSX 使用现有本地 OOXML 解析器转为紧凑文本后加入当轮上下文；扫描版 PDF 无文本层时明确提示需要 OCR。

### Changed

- **附件安全边界**：Composer 文件入口采用扩展名白名单，并为非图片文档设置 50 MB 上限；不支持或过大的拖放文件会显示本地错误，不会静默塞入模型上下文。
- 版本号从 **1.138.0-rc7** 递增为 **1.138.0-rc8**。

## 1.138.0-rc7 - 2026-07-12

### Changed

- **Agent 侧边栏开关贴合原生窗口控件**：把会话侧边栏的显示/隐藏图标从聊天内容区上方移到 macOS 红黄绿窗口控制按钮的右侧；按钮与原生标题栏同高、保留悬停提示和 `Command+\\` 快捷键，避免遮挡侧边栏标题。
- 版本号从 **1.138.0-rc6** 递增为 **1.138.0-rc7**。

## 1.138.0-rc6 - 2026-07-12

### Added

- **短剧视频生成引擎选择**：`generate_video_from_image`、`short_drama_generate_shot_media` 和 `short_drama_generate_batch_media` 新增 `video_engine` 参数；不传时默认使用 **Seedance 2.0**，用户指定 `kling` / `可灵` 时改为返回 Kling MCP handoff。
- **Kling MCP 视频生成接线说明**：可灵路径会给出 `who_am_i`、`file_upload`、`image_to_video` / `text_to_video`、`query_tasks` 的执行顺序，以及完成后通过 `import_media_manifest` 导回短剧分镜/媒体任务侧栏的参数。
- **媒体任务 provider 支持 Kling**：导入或登记可灵生成结果时，侧栏 provider 可显示为 `Kling`，不再归入未知来源。

### Changed

- **短剧视频提示默认口径统一**：候选图、媒体任务行、storyboard widget 和制作包文档中的视频生成提示改为“默认 Seedance 2.0，可指定 Kling/可灵”，避免旧文案强制引导到 some.im。
- 版本号从 **1.138.0-rc5** 递增为 **1.138.0-rc6**。

## 1.138.0-rc5 - 2026-07-12

### Changed

- **侧边栏产物按系统方式打开**：Agent 媒体任务侧栏与短剧产物缩略图点击后改为用 macOS 默认 App 打开对应文件，不再把图片强制留在内置预览或把非图片只定位到 Finder。
- **产物右键菜单增强**：产物缩略图右键菜单新增“打开方式”子菜单，可选择系统可用 App 或手动选择其他 App 打开；同时保留“在 Finder 中显示”。
- 版本号从 **1.138.0-rc4** 递增为 **1.138.0-rc5**。

## 1.138.0-rc4 - 2026-07-12

### Changed

- **Agent 聊天布局更紧凑**：缩小聊天正文与 composer 的左侧横向留白，让窄窗口下内容更靠近左侧会话区。
- **窄窗口自动收起会话侧栏**：Agent 模式在窗口缩到阈值以下时会临时隐藏左侧会话侧栏，并显示左侧最近会话 rail；窗口变宽后按用户原本偏好自动恢复。
- 版本号从 **1.138.0-rc3** 递增为 **1.138.0-rc4**。

## 1.138.0-rc3 - 2026-07-11

### Added

- **编辑器 macOS 行首/行尾快捷键**：Editor 模式支持 `Command+←` / `Command+→` 跳转至当前行首/行尾，`Command+Shift+←` / `Command+Shift+→` 可扩展选区；行为与原生 TextKit 文本编辑一致。
- 版本号从 **1.138.0-rc2** 递增为 **1.138.0-rc3**。

## 1.138.0-rc2 - 2026-07-11

### Changed

- **保护机密入口后置**：Agent composer 的锁形“插入保护机密”按钮移到发送区附近，不再紧跟附件按钮占用高频操作位。
- **需要输入时自动弹窗**：Agent 创建终端快捷操作后，如存在尚未填写的受保护输入，会自动弹出安全输入框；明文只写入本机加密终端保险库，AI 不会收到。取消后仍可在原工具卡补填。
- 版本号从 **1.138.0-rc1** 递增为 **1.138.0-rc2**。

## 1.138.0-rc1 - 2026-07-11

### Added

- **悬浮转写条扩展为可定制视觉系统**：新增经典波条、均衡器、频谱、脉冲、数字矩阵和霓虹天际线 6 种波形；圆角可独立选择微圆角、圆润、柔和或胶囊。
- 新增量子青、霓虹东京、极光薄荷、离子风暴、等离子核心、太阳耀斑、全息投影、激光网格、深空、赛博日落、月面信号、宇宙葡萄等 12 套双霓虹科幻主题，预览与实际转写浮窗一致。
- **原生 Computer Use Helper**：新增单独签名并随 App 打包的 `WillDeepComputerUseHelper.app`，不依赖 Alma；它拥有独立的 Accessibility 与 Screen & System Audio Recording 权限。修改系统权限后只需重启 helper，无需重启 WillDeep。
- Agent 新增原生 macOS 应用发现、后台启动、AX 状态快照、窗口截图、点击、右键、滚动、拖拽、非敏感文本输入、按键与 AX 设值工具；每次操作均回传新的 AX 状态和压缩截图，AX 不足时支持以截图坐标为后备。
- 所有会读屏或控制外部 App 的动作都强制进入审批边界；密码、验证码、API Key 等敏感数据禁止由 Computer Use 自动输入。
- 新增 Computer Use 工具风险边界回归测试。
- 版本号从 **1.137.0-rc6** 递增为 **1.138.0-rc1**。

## 1.137.0-rc6 - 2026-07-11

### Fixed

- **连续天数不再受统计范围影响**：无论选择 24 小时、7 天、30 天还是全部，“当前连续天数”和“最长连续天数”都始终按完整使用历史计算；会话数、消息数、活跃天数与图表仍按所选范围过滤。
- 新增 31 天连续使用历史在 24 小时筛选下仍保持 `31d / 31d` 的回归测试。
- 版本号从 **1.137.0-rc5** 递增为 **1.137.0-rc6**。

## 1.137.0-rc5 - 2026-07-11

### Fixed

- **已登录 some.im 时默认省心托管**：未做过模型选择的用户创建新聊天时默认进入“省心托管”；登录对账仅允许尚未开始的空聊天采用该模式，历史会话不会被改写。
- 模型模式偏好持久化为“未选择 / 省心托管 / 具体模型”三态；用户手动选择具体模型或路由默认值后，后续新聊天不再自动切回托管，再次手动选择“省心托管”即可恢复。
- 兼容旧版本：已有最近使用模型记录的用户视为曾手动选择模型，升级后继续保留原选择；相关 11 项模型选择测试全部通过。
- 版本号从 **1.137.0-rc4** 递增为 **1.137.0-rc5**。

## 1.137.0-rc4 - 2026-07-11

### Fixed

- **带参数 Slash 命令不再选中即误触发**：无参数命令继续即时执行；必填或可选参数的 workflow 命令选中后改为填入 `/<command> `，保持 composer 焦点并将光标置于末尾，等待用户补充参数后再按 Enter。
- Slash 菜单直接展示各 workflow 的参数格式；必填参数为空时保留已输入命令并显示原有缺参错误，可选参数命令可直接再按一次 Enter 使用默认行为。
- 新增命令参数模式与精确 invocation 解析测试，相关 2 项测试全部通过。
- 版本号从 **1.137.0-rc3** 递增为 **1.137.0-rc4**。

## 1.137.0-rc3 - 2026-07-11

### Fixed

- **托管消息页脚按 Judge 最终实际模型显示**：`someim-auto-flash/pro/premium` 分别显示“托管-通用-flash/pro/premium”；`someim-coding-*` 与 `someim-code-*` 显示“托管-编程-flash/pro/premium”，其中 `low/high` 统一映射为 `flash/pro`。质量升级后的最终模型也会同步反映在页脚。
- 历史 TextKit 消息与流式 SwiftUI 消息统一使用完整标签，保留质量升级 `↑` 和 Judge 回退 `~` 标记；悬停提示继续展示实际模型标识。
- 新增实际模型族、等级映射与状态标记回归测试；相关 39 项测试全部通过。
- 版本号从 **1.137.0-rc2** 递增为 **1.137.0-rc3**。

## 1.137.0-rc2 - 2026-07-11

### Fixed

- **聊天选文入口改为贴选区悬浮 tooltip**：选中文字后不再自动弹出原生 `NSMenu`，改为在选区上方显示单按钮圆角浮层；上方空间不足时自动落到下方，并约束在当前可见区域内。点击空白处、重新选择或历史内容刷新时会自动收起，右键菜单仍保留“添加到任务”作为备用入口。
- 相关 `AgentChatHistoryRendererTests` 34 项全部通过。
- 版本号从 **1.137.0-rc1** 递增为 **1.137.0-rc2**。

## 1.137.0-rc1 - 2026-07-11

### Added

- **聊天历史选文添加到任务**：在历史用户输入或 AI 输出中选中文字后，选区旁会弹出仅含“添加到任务”的菜单；点击后原文作为“对话摘录”文本附件进入底部 composer，可删除、继续补写问题，并随下一条用户消息持久化及发送给模型。右键选区也保留同一入口；不实现截图中的“更多详情”和“在侧边聊天中提问”。
- 新增选区传递与空选区保护回归测试；`AgentChatHistoryRendererTests` 34 项全部通过。
- 版本号从 **1.136.0-rc52** 提升为 **1.137.0-rc1**。

## 1.136.0-rc52 - 2026-07-10

### Added

- **终端 Shell 选项**：终端设置新增 zsh、bash、sh、fish、ksh、tcsh 等常见 Shell 路径菜单，同时保留自定义路径输入；编辑器底部终端和 Agent 侧栏本地终端统一读取该设置。
- 版本号从 **1.136.0-rc51** 递增为 **1.136.0-rc52**。

### Fixed

- **some.im 国家综合探测**：客户端并发查询 Cloudflare 代理后的 `https://some.im/api/v1/public/client-location`、`myip.ipip.net` 与 `api.myip.la/en?json`，任一路明确返回中国即使用国内 API；没有中国但至少一路有效返回非中国时使用国际 API，三路均失败则保留上次线路。探测不会因当前推理线路已切到 `api.niuwoai.com` 而改用国内 API Host。
- **已登录 some.im 账号入口**：会话列表底部的账号名称与小齿轮统一通过可靠的设置窗口深链打开「some.im 整合」标签，不再依赖可能停留在旧标签或未显示窗口的系统 `showSettingsWindow:` 动作；刷新按钮仍仅刷新账户状态。

## 1.136.0-rc51 - 2026-07-10

### Changed

- **some.im 按远端国家自动选路**：启动时访问 some.im 公共客户端位置接口；中国（`CN`）自动使用 `https://api.niuwoai.com/v1`，其余地区或位置接口暂不可用时使用全球线路或保留上次可用线路。
- **移除手工“some.im 整合”设置**：不再让用户选择开关、地区、Base URL 或编辑 API Key；登录状态与 Keychain 凭据自动驱动接入，只保留图片/视频模型偏好并自动拉取模型。
- **视频默认模型**：新旧空配置统一补齐为 `seedance-2.0`。

### Fixed

- **设置页点数格式统一**：some.im Account 中的大额 credits 与会话列表左下账户区共用 `M/B` 两位小数紧凑格式，避免再次显示十位超长数字。
- 版本号从 **1.136.0-rc50** 递增为 **1.136.0-rc51**。

## 1.136.0-rc50 - 2026-07-10

### Fixed

- **修复 Debug 包缺少共享 Keychain 签名权限**：为 Xedit Debug 配置补上 `Xedit/WillDeep.entitlements`，让浏览器登录回传的 some.im 凭据可以写入共享 session；未被本地签名授权时仍保留普通 Keychain 回退。
- 版本号从 **1.136.0-rc49** 递增为 **1.136.0-rc50**。

## 1.136.0-rc49 - 2026-07-10

### Fixed

- **修复无签名 Debug 包无法保存 some.im 登录凭据**：检测到共享 Keychain access group entitlement 不可用时，Debug 包回退到当前 App 的普通 Keychain；正式签名包继续使用共享 Keychain。
- 版本号从 **1.136.0-rc48** 递增为 **1.136.0-rc49**。

## 1.136.0-rc48 - 2026-07-10

### Changed

- **打包脚本自动读取 some.im 客户端密钥**：`debug_install_mac_apps.rb` 与 `release_mac_apps.rb` 在本地未设置 `WILLDEEP_CLIENT_LOGIN_SECRET` 时，通过 SSH 从 `root@h1.niuwoai.com:/etc/niuwo/niuwo.env` 读取；值只在当前构建进程内传递，不写日志或本地文件。
- 版本号从 **1.136.0-rc47** 递增为 **1.136.0-rc48**。

## 1.136.0-rc47 - 2026-07-10

### Fixed

- **some.im 客户端登录密钥不再写入 Info.plist**：保留编译期 Swift 常量注入，移除旧的 Info.plist 占位符，避免同一密钥在 App 包中重复保存。
- 版本号从 **1.136.0-rc46** 递增为 **1.136.0-rc47**。

## 1.136.0-rc46 - 2026-07-10

### Fixed

- **some.im 客户端登录密钥改为编译期 Swift 常量**：Xcode 从 `WILLDEEP_CLIENT_LOGIN_SECRET` 生成 DerivedData 源文件，`debug_install_mac_apps.rb` 与 `release_mac_apps.rb` 在缺少变量时拒绝打包；真实密钥不写入源码仓库。
- 版本号从 **1.136.0-rc45** 递增为 **1.136.0-rc46**。

## 1.136.0-rc45 - 2026-07-10

### Fixed

- **修复 some.im 浏览器登录包漏注入客户端密钥**：Release 打包现在要求构建环境提供 `WILLDEEP_CLIENT_LOGIN_SECRET`；运行时若 bundle 仍缺少该值，会在打开登录前直接提示构建配置问题，不再让浏览器登录后才显示“没有返回凭据”。密钥值不写入仓库、日志或 UI。
- 版本号从 **1.136.0-rc44** 递增为 **1.136.0-rc45**。

## 1.136.0-rc44 - 2026-07-10

### Fixed

- **some.im 浏览器登录状态不再静默卡在等待**：兼容 `success`、`completed`、`authorized`、`logged_in` 等完成态；轮询遇到 401/404 或网络错误时立即在登录卡片显示原因，同时继续重试，不再把请求失败伪装成“正在等待浏览器登录”。
- 新增 completed-style 浏览器登录状态回归测试。
- 版本号从 **1.136.0-rc43** 递增为 **1.136.0-rc44**。

## 1.136.0-rc43 - 2026-07-10

### Fixed

- **复杂一次性命令不再推荐“总是允许”**：审批卡把“已有永久规则如何匹配”和“当前调用是否值得新建永久规则”拆成两层。常规、短小且可复用的命令（如 `git push origin branch`）仍显示“总是允许”；参数过多、命令过长、SSH 套远端命令、shell/解释器内联脚本和参数过深的 Lark CLI 调用只显示本次允许，避免为低复用命令制造永久授权规则。
- **不为按钮展示额外消耗模型调用**：长期复用价值先由本地确定性策略判断，安全判官继续只负责“当前命令能否自动执行”；已保存的旧规则仍按原签名匹配，不会因 UI 收紧而失效。
- **侧边栏终端 ZMODEM 支持工具预选本机路径**：`terminal_send_command` 新增 `zmodem_upload_paths` 和 `zmodem_download_directory` 参数，Agent 可在远端 `rz` / `sz` 握手前直接指定本机文件或目录；参数缺省时仍由用户通过 macOS 文件面板选择，并限制为一次性、方向匹配的预选。
- 新增授权推荐边界测试，覆盖可复用 `git push`、多参数 `go test`、SSH 远端层、`ruby -e` 内联脚本和短终端命令。
- **远程媒体任务默认免审批**：`some_im_create_media_task` / `some_im_poll_media_task` / `some_im_cancel_media_task` 及对应的 `replicate_*` 预测工具是异步渲染任务的提交·轮询·取消，无本地副作用，却在每次提交（乃至每次轮询同一任务）时都弹「允许/拒绝」。现按静态白名单默认放行（仍保持 `.write` 语义与只读沙箱），仅 `requestEveryTime` 模式仍强制手动确认。
- 版本号从 **1.136.0-rc42** 递增为 **1.136.0-rc43**。

## 1.136.0-rc42 - 2026-07-10

### Fixed

- **右侧「产物」不再等同于 Git 未提交文件**：新增会话级 `agentArtifactPaths` 产物清单，只记录当前 AI 会话新建的用户可交付文档、图片、音视频等文件，并与同一会话的媒体任务输出合并展示；已提交到 Git 的产物仍会保留，其他会话、旧脏文件、已有源码修改、`build`/缓存目录不会再混入。
- **「产物」与「工作文件」口径明确分离**：产物区直接标明“当前会话产生的文件与媒体”，工作文件区标明“当前会话关联的未提交变更”；同一会话的产物从工作文件分组中去重，避免一份文件在右栏重复出现。
- 新增会话产物归因测试，覆盖新建 PDF/视频应进入产物、已有源码修改和构建/缓存输出应排除的边界。
- 版本号从 **1.136.0-rc41** 递增为 **1.136.0-rc42**。

## 1.136.0-rc41 - 2026-07-09

### Fixed

- **省心托管下 `spawn_agent` 子 agent 悄悄跑基础 tier**：当轮实际生效的模型由 judge 路由（及无 tool_call 时的输出质量升档）写入 `turnConfiguration.model`，但 `spawn_agent` 的调用处一直传的是没被路由过的基础 `configuration`。结果 some.im 省心托管开启时，父 agent 在跑升档后的 tier（如 `someim-code-premium`），子 agent 却继承 base flash tier，输出无声变差。现改为向 `executeSpawnAgentToolCall` 传 `turnConfiguration`，子 agent 与父 agent 同 tier。非托管场景 `turnConfiguration == configuration`，行为不变。
- 版本号从 **1.136.0-rc40** 递增为 **1.136.0-rc41**。

## 1.136.0-rc40 - 2026-07-09

### Fixed

- **Workflow（`/code-review` 等）在 some.im 模型下空转卡死**：workflow 的子 agent 此前建 client 时漏传 `someIMContext`（会话/工作区上下文头），而主循环每个 some.im 请求都会带。结果在**经 some.im 连接的模型**（如 gpt-5.5）上，子 agent 请求缺合法会话上下文被 some.im stall，卡片只剩一个「Workflow」图标、无进度无报错。现按主循环同样逻辑构造 `someIMContext` 并透传到 `WorkflowEngine → AgentSubagentRunner`。
- **Workflow 看门狗超时**：新增单次运行 360s 看门狗（`AppStateAgentWorkflows.runWorkflowWithWatchdog`）。子 agent 的 provider 请求 stall 时不再无限挂起，超时即把卡片转为 `.failed` 并给出「模型/网关可能没响应」的原因。
- **`/code-review` 全维度失败不再伪装成功**：4 个 review 维度全失败时，此前会返回一句成功字符串让卡片变绿勾；现改为抛 `WorkflowError.allTasksFailed`，卡片正确显示 `.failed`。
- 版本号从 **1.136.0-rc39** 递增为 **1.136.0-rc40**。

## 1.136.0-rc39 - 2026-07-09

### Fixed

- **some.im 浏览器登录卡死自恢复**：当 browser-status 返回 `connected` 却没有可识别的 WillDeep API Key 时，现在会丢弃这个已被服务端标记为 connected 的一次性登录 `code`（此前保留在内存里，导致再点「在浏览器打开」复用死 code、被秒回同一条“已登录但没有返回凭据”，只能重启 App 才能恢复）。清空后再次打开即会 mint 全新 `code`。设置页与 Onboarding 两处轮询均已修复。
- **some.im 登录诊断日志**：`connected` 却无凭据时，记录响应里出现的字段名（仅字段名、不含任何值，避免泄露 token / 邮箱），便于比对 some.im 实际返回的 key 命名或确认是否根本没下发凭据。
- 版本号从 **1.136.0-rc38** 递增为 **1.136.0-rc39**。

## 1.136.0-rc38 - 2026-07-09

### Fixed

- **some.im 浏览器登录协议兼容**：浏览器登录 URL 和状态轮询同时携带 `code` / `device_code` / `willdeep_device_code` 与 `pair_token` / `willdeep_pair_token`，兼容按新旧参数名实现的 some.im 控制面。
- **some.im 扁平凭据回写兼容**：browser-status 返回 `connected` 且携带 app API key 时，不再强制要求嵌套 `account` 对象；支持扁平 `email` / `credits` / `default_model` 与 `api_token` / `customer_session_token` 字段，避免误报“已登录但没有返回凭据”。
- 版本号从 **1.136.0-rc37** 递增为 **1.136.0-rc38**。

## 1.136.0-rc37 - 2026-07-09

### Fixed

- **修正 some.im auto 托管模型命名**：无 coding plan 且裁判域为 general 时，low/high/premium 分别解析为 `someim-auto-flash/pro/premium`，不再使用不存在的 `someim-auto-low/high`。
- 版本号从 **1.136.0-rc36** 递增为 **1.136.0-rc37**。

## 1.136.0-rc36 - 2026-07-09

### Changed

- **some.im Coding Plan 感知托管路由**：登录 some.im 后会定期查询 `/customer/plan/subscription` 并缓存 coding plan 状态；省心托管路由在每轮裁判后根据该状态选择模型族。
- **托管模型族按权益拆分**：有 coding plan 时，low/high/premium 统一解析为 `someim-coding-plan-low/high/premium`；没有 plan 时，编程域解析为 `someim-code-low/high/premium`，通用域解析为 auto 家族。
- 版本号从 **1.136.0-rc35** 递增为 **1.136.0-rc36**。

## 1.136.0-rc35 - 2026-07-09

### Changed

- **本地模型辅助任务拆分**：设置页将“标题和上下文压缩先用本地”拆成“会话标题先用本地”和“上下文压缩先用本地”两个独立开关；旧配置只迁移到标题偏好，上下文压缩默认保持远端 provider。
- **本地模型 composer 备选**：新增“加入 composer 模型备选”和显示名称输入框；勾选后自动维护一个固定 ID 的 Ollama / Local OpenAI provider 条目，让本地聊天模型进入 composer 模型菜单，取消勾选时只移除这个自动条目。
- **委派 coding agent 默认免审核**：`claude_code` / `codex_cli` / `cursor_agent` / `cline_cli` 在默认 smart 模式下不再逐次弹人工审批，直接放行（`.staticAllowlist`）——它们各自自带审批 + 沙箱审核，视为可信。`requestEveryTime`（每次都问）模式仍会逐次询问；子进程自身的沙箱边界不变（不提权）。
- 版本号从 **1.136.0-rc34** 递增为 **1.136.0-rc35**。

## 1.136.0-rc34 - 2026-07-09

### Fixed

- **some.im 浏览器登录凭据落库校验**：浏览器配对返回 connected 后，WillDeep 现在必须先把 app API Key 写入共享 session 并读回验证，成功后才保存 account 与启用 some.im；如果 some.im 没返回 key，或本机 Keychain / 共享 session 写入失败，不再把设置页显示成已连接但 API Key 为空。
- **some.im 设置页同步共享登录态**：设置页订阅 some.im account/session 变更通知，通知到达时会重新读取 account、settings 与 API Key，并同步 Agent provider / 图片理解配置，避免跨 App 登录或浏览器回调后只刷新账号摘要、不刷新 API Key 输入框。
- 版本号从 **1.136.0-rc33** 递增为 **1.136.0-rc34**。

## 1.136.0-rc33 - 2026-07-09

### Changed

- **Agent 左侧输入 minimap 悬停对齐 Codex**：hover 某条刻度时改为“鱼眼”放大——被悬停的刻度最长、颜色最深（accent 满强度），临近的几条按距离渐次变短、颜色渐次变浅，平滑过渡到静止态，不再只有单独一条突变。
- **minimap 悬停缩略卡直接出现**：卡片从“自左侧滑出 + 渐显”改为直接出现（`.identity`），在不同刻度间快速切换时不再有卡片一边滑出一边滑入的花哨效果；刻度鱼眼仍保留 0.12s 平滑动画。
- 版本号从 **1.136.0-rc32** 递增为 **1.136.0-rc33**。

## 1.136.0-rc32 - 2026-07-09

### Fixed

- **Agent 会话切换延迟优化**：点击左侧会话列表时先切换 `activeAgentSessionID`，再以不刷新 `updatedAt`、不移动列表位置的方式保存旧会话，避免保存和会话重排挡在选中态反馈前。
- **Agent 侧栏分组热路径减负**：工作区分组预先缓存 display name 与远端 runtime 描述，排序比较不再反复 `URL(fileURLWithPath:)` 或 JSON decode UserDefaults，降低 SwiftUI body 重算时的主线程开销。
- **Agent context ring 估算减半**：`estimatedAgentSystemMessage` 新增与两个 token 估算值同款的 `(messageCount, sessionID, 1s)` 缓存。此前 `estimatedAgentTokens` 与 `estimatedAgentBaselineTokens` 会在会话切换（两个值缓存同时失效）时各自完整构建一遍 system prompt 并跑一遍内存检索，两次都压在点击主线程上；现在两个估算器共享一次构建，切换时最重的“system prompt 构建 + 内存检索”从 2 次降到 1 次。
- **Agent 切换跳过重复工作区 stat**：`syncWorkspaceContext` 在目标会话工作区已经激活过安全域时直接返回，不再每次会话切换都对同一目录做一次 `isExistingDirectory` 文件系统 stat（同工作区内多会话来回切时最明显）。
- 版本号从 **1.136.0-rc31** 递增为 **1.136.0-rc32**。

## 1.136.0-rc31 - 2026-07-09

### Fixed

- **some.im 浏览器登录控制面固定**：浏览器登录页与配对状态轮询固定使用 `https://some.im` 控制面，不再从当前推理 Base URL 推导 `/customer/login`，避免选择国内推理节点 `https://api.niuwoai.com/v1` 时打开错误网页登录域名。配对码继续统一使用 some.im 端接受的 `WD-` 前缀。
- 版本号从 **1.136.0-rc30** 递增为 **1.136.0-rc31**。

## 1.136.0-rc30 - 2026-07-09

### Added

- **对话区左侧「用户输入刻度尺」**:Agent 对话区左边缘中部新增一列等大、等距的短横线,每条对应一次用户输入。鼠标移到某条横线上:横线变长,旁边浮出小卡片(这一轮用户说了啥 / AI 回了啥 / 改了哪些文件);点击则把对话区滚动到该用户输入处(复用历史 NSTextView 的 `agentChatHistoryUserMessageID` 锚点 + `scrollRangeToVisible`,纯原生无新依赖)。

### Changed

- **对话区显示轮数上限从 20 条提升到 60 条**(约 30 个用户轮)。历史烘焙进单个增量布局的 NSTextView,放大窗口不会重新引入长列表卡顿;单条内容仍由 `messageContentRenderCap` 兜底。
- 版本号从 **1.136.0-rc29** 递增为 **1.136.0-rc30**。

## 1.136.0-rc29 - 2026-07-09

### Added

- **Markdown inline code 胶囊与 Hex 色块渲染**:Agent 聊天 Markdown 里的 inline code 继续保持轻量胶囊观感;`#RGB` / `#RRGGBB` / `#RRGGBBAA` 这类颜色字面量会自动追加同色小方块。流式 SwiftUI 消息和落定后的 TextKit 历史消息共用同一套 inline 语义增强,避免刚生成时好看、滚进历史后变素颜。
- **归档带活跃定时任务的会话前会确认**:归档一个仍拥有活跃定时任务的会话时,弹确认框提示「该会话有 N 个活跃定时任务,归档会停止并移除它们」;确认后先删掉这些任务再归档(归档后本就不该再跑)。取消则不动。
- **会话列表活跃定时任务时钟图标**:会话行最前面新增一个小时钟图标(仅当该会话拥有 enabled 的定时任务时显示),一眼看出哪些会话挂着在跑的定时任务。
- 版本号从 **1.136.0-rc28** 递增为 **1.136.0-rc29**。

## 1.136.0-rc28 - 2026-07-09

### Added

- **会话内定时任务(schedule_task)**:Agent 现在能在对话里直接安排一个定时任务——新增 `schedule_task` 工具(支持 `interval_minutes` 或 `daily_at`,可选 `goal` 目标),安排后 transcript 底部会出现一张**定时任务卡片**,点击可打开该任务详情(侧栏编辑器)。定时任务复用既有 Routine 调度器,每次在后台新会话里跑给定 prompt。
- **达成目的自动消失**:给任务设 `goal` 后,每次触发的那次 agent 会被要求判断目标是否达成;达成则调用新增的 `complete_scheduled_task` 工具移除自己(卡片转为「已完成」灰态、侧栏条目消失)。`AgentRoutine` 新增 `originSessionID` / `goal` 字段(向后兼容)。卡片消息以新的 `.scheduledTask` role 持久化随会话保留,且不发给 LLM。
- 版本号从 **1.136.0-rc27** 递增为 **1.136.0-rc28**。

## 1.136.0-rc27 - 2026-07-08

### Changed

- **Agent 侧栏 some.im 账号入口点击行为**：已登录时点击账号位改为打开「设置 → some.im」整合 tab（不再跳浏览器），图标随之从外链箭头改为齿轮；未登录时保持点击进入浏览器登录。移除了已登录点击走浏览器 handoff 的死代码。
- 版本号从 **1.136.0-rc26** 递增为 **1.136.0-rc27**。

## 1.136.0-rc26 - 2026-07-08

### Added

- **some.im 登录态跨 App 共享**：apiKey / sessionToken 改存共享 Keychain 访问组（Team `ZH2S7D6PL6`，entitlement `keychain-access-groups`），通过独立私有 Swift 包 [`SomeIMSharedSession`](https://github.com/xurenlu/SomeIMSharedSession) 收拢读写。一处登录、本机所有签名 App 都登录；一处登出、大家一起登出（登录/登出经 `DistributedNotificationCenter` 广播不含任何密钥的变更通知，各 App 收到后重读凭据并对账 agent provider）。首次启动把旧的 per-app Keychain 凭据一次性迁移进共享组、验证读回后删旧。`saveAPIKey("")` 由「删 key」改为 no-op，杜绝设置页空串误覆盖导致的「登录一会儿就掉」。
- **some.im 设置页「退出登录」按钮**：账户区新增带二次确认的退出登录，清共享会话（广播全 App）+ 本地缓存 + agent provider；文案 en / zh-Hans 齐备。
- **CI 私有包鉴权**：`test.yml` 用只读 deploy key（secret `SOMEIM_DEPLOY_KEY`）解析私有 `SomeIMSharedSession` 包，https→ssh 重写仅限定该包仓，公开依赖 SwiftTerm 不受影响。

### Changed

- 版本号从 **1.136.0-rc25** 递增为 **1.136.0-rc26**。

## 1.136.0-rc25 - 2026-07-08

### Changed

- **some.im 生图默认异步化**：`generate_image` 现在复用 `some_im_create_media_task`，普通 Agent 生图会提交到媒体任务中心并由轮询下载产物，不再阻塞等待同步 `/images/generations` 返回。
- **some.im 图片媒体任务默认端点** 从 `images/generations` 改为 `images/async-generations`；短剧分镜/资产图片生成等复用 `SomeIMAsyncMediaClient.defaultEndpointSuffix` 的入口同步走异步生图接口，视频仍默认 `videos/generations`，图片编辑仍默认 `images/edits`。
- **some.im 媒体任务请求超时**：提交、轮询、取消请求的单次 `URLRequest.timeoutInterval` 明确设为 `AgentNetworkSupport.resourceTimeout`（600 秒），避免默认 request timeout 120 秒先取消长耗时请求。
- 版本号从 **1.136.0-rc24** 递增为 **1.136.0-rc25**。

## 1.136.0-rc24 - 2026-07-08

### Added

- **some.im「省心托管」动态路由（Phase 1 + Phase 2 + Phase 3）**：composer 模型菜单在 some.im provider 下新增「省心托管」入口。选中后每个用户轮先用轻量裁判模型 `someim-judge`（底层非思考 DeepSeek）判断任务域（coding/general）与复杂度（low/high），结合会话级「只升不降」能力档位动态选择本轮实际模型（`someim-coding-plan-low/high/premium`、`someim-auto-flash/pro`）；裁判失败自动回退本地启发式。无 tool call 的输出会做质检（本地确定性重复/空输出检测 + `someim-judge` 复核），命中明确生成故障时清掉本轮输出并升一档重试一次（每用户轮至多一次）。some.im 请求附带 `x-willdeep-session-id` 与本机随机 `x-willdeep-workspace-id`（只发随机 UUID，不含任何本地路径）。裁判与主模型共用同一 provider 并发槽；路由锁定每用户轮一次，tool 循环内不重判。可观测性：每条 assistant 消息记录本轮 route 决策（选中模型/档位/domain/complexity/是否 fallback/是否升档），消息 footer 显示「托管 · Low/High/Premium」标记（升档 ↑、fallback ~）。设计文档：`docs/SOME_IM_MANAGED_ROUTING_DESIGN.md`。

### Changed

- 版本号从 **1.136.0-rc23** 递增为 **1.136.0-rc24**。

## 1.136.0-rc23 - 2026-07-08

### Fixed

- `cursor_agent` 外部委派工具现在能发现官方独立安装的 `cursor-agent`（`curl https://cursor.com/install | bash` 装在 `~/.local/bin/cursor-agent`，且不提供 `cursor` 命令）。此前发现逻辑只查 `cursor` 编辑器启动器，只装了独立 Agent CLI 的用户会被误判为"未安装"、调用直接失败。发现优先级：独立 `cursor-agent` → `cursor` 编辑器启动器（后者会把 `agent` 子命令转发给同一个 headless agent）。`LocalAgentCLI` 设置页发现目录同步更新。
- 委派给外部 CLI（claude / codex / cursor / cline）时，子进程 PATH 补上 `~/.local/bin` 与 `~/.cargo/bin`。从 Finder/Dock 启动 App 只继承最小 launchd PATH，外部 CLI 再 fork 的 `node` / `uv` / `python` / `git` 若装在用户级前缀里会 `command not found`，导致委派任务跑到一半失败。

### Changed

- 版本号从 **1.136.0-rc22** 递增为 **1.136.0-rc23**。

## 1.136.0-rc22 - 2026-07-08

### Fixed

- 智能审批 LLM 判官不再因 API key 时序竞态而静默掉线：`configurationForSafetyJudge()` 在运行时配置的 apiKey 为空时，直接从当前激活的 provider library 条目的 Keychain 密钥补齐（读本地副本、不触发 provider-library 的 didSet 级联），消除审计日志里大量 `unavailable / missing api key` 导致的"判官没上岗、直接退回人工"。

### Changed

- Goal 模式不再对所有写操作"一刀切"自动放行。沙箱内、非破坏性的文件写与已校验的公网 `web_fetch` 仍然快速放行以保持自主；命令类调用（`run_command` / `terminal_send_command` / `terminal_send_control` / `call_mcp_tool`）改为走与 smart 模式相同的「静态分类 → LLM 判官」闸门（Goal 模式隐式启用判官）。判官判为危险、判官不可用，或属于需打字确认的破坏性操作时，暂停等待人工，而非盲目执行——按风险分级，向 Codex 的 auto-review 语义靠拢。
- 版本号从 **1.136.0-rc21** 递增为 **1.136.0-rc22**。

## 1.136.0-rc21 - 2026-07-08

### Fixed

- `generate_image` / some.im 图片任务产出的生成图会挂到最终 assistant 消息，在 Markdown 下方直接显示缩略图，不再只藏在工具结果里。
- 生成图默认保存到当前 workspace 根目录，可通过 `output_directory` 指定 workspace 内子目录，不再落到下载目录。
- 聊天区生成图支持右键“引用”，会向 composer 写入 `<generated-image-reference ... />` 标记；后续修改该图时可通过 `edit_generated_image` 发送给 `gpt-image-2` 作为参考图，不需要重新上传图片。
- 版本号从 **1.136.0-rc20** 递增为 **1.136.0-rc21**。

## 1.136.0-rc20 - 2026-07-08

### Fixed

- Agent 会话区右上 Diff、Terminal、Preview、Files 快捷入口移除外层胶囊框和选中图标底框，避免图标外再套一层圆角矩形。
- 选中态改用图标强调色与字重表达，保持可点击热区和侧栏切换行为不变。
- 版本号从 **1.136.0-rc19** 递增为 **1.136.0-rc20**。

## 1.136.0-rc19 - 2026-07-08

### Added

- Agent 聊天会话新增 `Command+F` 会话内搜索：右上角显示悬浮搜索入口，输入后高亮所有命中，并提供上一条/下一条和当前命中计数。
- 搜索模式会临时纳入当前会话完整可见历史，不再只覆盖默认渲染的最近消息；当前命中会自动滚入视口，搜索时不会被自动到底滚动打断。
- 新增搜索匹配与活动高亮回归测试，锁定大小写无关匹配和当前命中特殊高亮。
- 版本号从 **1.136.0-rc18** 递增为 **1.136.0-rc19**。

## 1.136.0-rc18 - 2026-07-08

### Fixed

- Agent 左下 some.im 账号区改用紧凑 credits 展示，百万/十亿级数字显示为 `46.00M` / `4.21B`，避免长余额挤爆侧栏。
- 补齐 some.im 账号区 credits、打开账号、刷新余额等文案的中英文本地化，中文环境不再显示英文 `credits`。
- 新增回归测试，锁定 some.im credits 紧凑格式保留两位小数。
- 版本号从 **1.136.0-rc17** 递增为 **1.136.0-rc18**。

## 1.136.0-rc17 - 2026-07-08

### Fixed

- Agent 右侧 Diff 面板的彩色 diff 渲染改为后台生成 `AttributedString`，避免打开面板时主线程同步拆行和着色导致窗口卡顿。
- Diff 面板在侧栏渲染前会截断超大 diff 并提示如何查看完整内容，防止长文本直接进入 SwiftUI `Text`。
- 新增回归测试，锁定超大 diff 会在进入侧栏显示前降级。
- 版本号从 **1.136.0-rc16** 递增为 **1.136.0-rc17**。

## 1.136.0-rc16 - 2026-07-08

### Fixed

- `generate_image` 现在作为无需用户审核的 read-tier Agent 工具直接执行；some.im 启用、API key 和 prompt 校验仍在实际调用前保留。
- 新增回归测试，锁定通用图片生成工具不会进入审批等待。
- 版本号从 **1.136.0-rc15** 递增为 **1.136.0-rc16**。

## 1.136.0-rc15 - 2026-07-08

### Added

- 新增 `docs/SOME_IM_MAC_APP_INTEGRATION.md`，系统说明 macOS App 接入 some.im 的浏览器登录、Keychain 存储、provider library 同步、VL fallback、onboarding/settings 入口和验证清单。
- 新增 `BundledSkills/some-im-mac-integration`，让 Agent 在修改或审查 some.im Mac 接入时优先使用该工作流和安全边界。
- 版本号从 **1.136.0-rc14** 递增为 **1.136.0-rc15**。

## 1.136.0-rc14 - 2026-07-08

### Changed

- Onboarding 的 some.im 步骤改为浏览器登录优先：进入步骤自动准备登录请求，用户点击“在浏览器打开”完成 some.im 登录后回到 WillDeep 继续流程。
- Onboarding 移除 some.im 邮箱验证码表单；该步骤仍可跳过，用户可以在 AI provider 步骤手动填写 API key 和模型。
- AI provider onboarding 在所选主模型不支持图片输入时，会要求补充 VL/视觉 provider、Base URL、API key 和模型，并再次建议直接集成 some.im 以省掉多模态兜底配置。
- 版本号从 **1.136.0-rc13** 递增为 **1.136.0-rc14**。

## 1.136.0-rc13 - 2026-07-08

### Changed

- some.im 设置页的浏览器登录体验简化为进入页面自动准备登录请求，只保留“在浏览器打开”入口；用户在浏览器完成 some.im 登录后，页面提示回到 WillDeep 继续使用。
- 移除 Settings → some.im 里的邮箱验证码表单、二维码、随机码、URL 展示和复制按钮，避免用户在多个登录入口之间来回猜。
- 版本号从 **1.136.0-rc12** 递增为 **1.136.0-rc13**。

## 1.136.0-rc12 - 2026-07-08

### Fixed

- Agent 空白页统计面板的“当前连续天数”在今天尚未开始写时不再直接清零，会保留截至昨天的连续写作天数；只有今天和昨天都没有记录时才显示 0。
- 新增连续天数回归测试，覆盖“今天空但昨天连续”和“昨天也断档”两种场景。
- 版本号从 **1.136.0-rc11** 递增为 **1.136.0-rc12**。

## 1.136.0-rc11 - 2026-07-08

### Fixed

- Agent 左下未绑定 some.im 账号区现在直接打开 fallback Settings 窗口，绕过系统 `showSettingsWindow:` 偶发吞掉程序化打开请求的问题。
- 未绑定 some.im footer 增加整块点击与 simultaneous tap 兜底，点击头像、文字、空白或齿轮区域都能触发 Settings → some.im 并自动生成浏览器登录链接。
- 版本号从 **1.136.0-rc10** 递增为 **1.136.0-rc11**。

## 1.136.0-rc10 - 2026-07-08

### Fixed

- 普通启动不再先创建空 Editor 主窗口再延迟切到 Agent；Agent 单例窗口现在作为默认启动 Scene 直接打开。
- 显式打开文件/目录、`willdeep://open?path=...` 和手动“显示 Editor”仍走 Editor 窗口，不改变 editor mode 入口。
- 版本号从 **1.136.0-rc9** 递增为 **1.136.0-rc10**。

## 1.136.0-rc9 - 2026-07-08

### Fixed

- Agent 左下未绑定 some.im 的头像/账号区现在点击后会直达 Settings → some.im，并自动生成浏览器登录链接和二维码。
- some.im 设置页会消费来自导航入口的自动生成请求；如果页面已存在未完成链接，会恢复同一随机码的轮询而不是重新生成。
- 版本号从 **1.136.0-rc8** 递增为 **1.136.0-rc9**。

## 1.136.0-rc8 - 2026-07-08

### Fixed

- some.im 浏览器登录轮询不再因设置页暂时消失而取消；用户跳到浏览器完成登录后，WillDeep 仍会继续等待并自动接收 `connected` 状态。
- 已生成的浏览器登录链接在再次点击“在浏览器打开”时会恢复同一随机码的轮询，避免浏览器已完成但 App 停在二维码状态。
- 浏览器登录卡片现在显示真实轮询状态，不再在 watcher 停止后误导性显示“链接已生成”。
- 版本号从 **1.136.0-rc7** 递增为 **1.136.0-rc8**。

## 1.136.0-rc7 - 2026-07-08

### Fixed

- About 菜单现在由 AppDelegate 在启动和重新激活时直接接管系统 App 菜单项，避免 SwiftUI commands 只挂在 URL WindowGroup 上导致普通启动或 Agent 窗口里仍打开系统默认 About 面板。
- 版本号从 **1.136.0-rc6** 递增为 **1.136.0-rc7**。

## 1.136.0-rc6 - 2026-07-08

### Fixed

- some.im 浏览器登录轮询在服务端返回 `connected` 但缺少 WillDeep 凭据时，现在会保留 `connected` 状态并让设置页立即显示明确错误，不再降级为 `unknown` 后继续显示“正在等待浏览器完成登录”。
- 新增 browser-status `connected` 缺凭据场景的回归测试。
- 版本号从 **1.136.0-rc5** 递增为 **1.136.0-rc6**。

## 1.136.0-rc5 - 2026-07-08

### Fixed

- some.im 浏览器登录状态回写兼容嵌套 `credentials`、camelCase 凭据字段，以及 `account` / `customer` / `user` 账号字段，避免浏览器显示登录完成但桌面端继续等待。
- 浏览器登录状态为 connected 但缺少 WillDeep API key / 账号信息时，设置页会立即停止等待并显示明确错误，不再静默转圈到超时。
- 新增 some.im browser-status 兼容响应单测。
- 版本号从 **1.136.0-rc4** 递增为 **1.136.0-rc5**。

## 1.136.0-rc4 - 2026-07-07

### Fixed

- Mobile Gateway H5 QR now uses compact `r` / `t` relay parameters or `b` / `k` LAN parameters instead of base64url-wrapped full JSON, reducing QR density for system camera recognition.
- Kept legacy `p` payload compatibility while making the generated QR URL short by default.
- 版本号从 **1.136.0-rc3** 递增为 **1.136.0-rc4**。

## 1.136.0-rc3 - 2026-07-07

### Fixed

- Agent 左下 some.im 未登录账号入口现在整行可点击，并在打开 Settings 后补一次目标 pane 选择，避免只弹出设置窗口却没有落到 some.im 页面。
- Mobile Gateway 从 Settings → Runtimes 的子 tab 提升为顶层设置分区，和 some.im、Voice 等入口保持同级。
- 版本号从 **1.136.0-rc2** 递增为 **1.136.0-rc3**。

## 1.136.0-rc2 - 2026-07-07

### Fixed

- Mobile Gateway QR now renders an H5 URL with a base64url `p` payload instead of raw JSON, so Android App scanners can extract credentials while system camera/browser scanners open the H5 page.
- Added H5 QR URL wrapping tests to keep relay credentials recoverable from the `p` parameter.
- 版本号从 **1.136.0-rc1** 递增为 **1.136.0-rc2**。

## 1.136.0-rc1 - 2026-07-07

### Added
- **自定义关于窗口** —— App 菜单的 About 入口改为 WillDeep 自己的 SwiftUI 关于窗口，采用 museterm 的单例窗口打开方式和紧凑信息布局；内容只展示 WillDeep 图标、版本、构建号、Bundle ID、官网与复制版本信息操作，不搬 MuseTerm 的产品介绍和推荐应用清单。

### Changed
- 版本号从 **1.135.0-rc1** 提升为 **1.136.0-rc1**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness 位点。

## 1.135.0-rc1 - 2026-07-07

### Changed
- **少量数据默认少用 Markdown 表格** —— Agent 系统提示词新增回答格式偏好：当数据量不多（约 6 条以内）且用户没有主动要求表格时，优先使用短段落或项目符号，减少小表格在当前聊天渲染里的阅读负担。
- **Agent stable prompt 前缀升为 v8** —— 系统提示词稳定前缀版本随格式规则调整同步更新，避免 prompt cache 继续复用旧回答格式约束。
- 版本号从 **1.134.0** 提升为 **1.135.0-rc1**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness 位点。

## 1.134.0 - 2026-07-07

### Added
- **语音输入支持 AI 轻度整理** —— Settings → Voice 新增“AI 整理”选项，可选择关闭、补标点分段或整理成要点。麦克风按钮与 Fn push-to-talk 共用同一条转写后处理链路；默认关闭以保持本机转写原行为，开启后只把转写文本发给当前配置的 AI provider，音频仍留在本机。

### Changed
- 版本号从 **1.133.0-rc2** 提升为 **1.134.0**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness 位点。

## 1.133.0-rc2 - 2026-07-07

### Fixed
- **some.im 浏览器登录状态自动回写** —— 浏览器登录链接现在携带隐藏的长配对 token；WillDeep 设置页生成链接后会轮询 some.im 的 browser-status 接口，浏览器端完成登录后通过 browser-complete 标记连接完成，WillDeep 会自动保存 app 专用 API key / customer session / 账号余额并把当前窗口从二维码切换为已登录状态。

### Changed
- 版本号从 **1.133.0-rc1** 提升为 **1.133.0-rc2**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness 位点。

## 1.133.0-rc1 - 2026-07-07

### Added
- **some.im 账号入口升为一等公民** —— Settings 顶层新增独立 some.im 分区；Agent 左侧栏底部常驻 some.im 账号位，已登录时展示头像/credits 并可打开后台，未登录时展示匿名头像与未登录提示，点击直达 some.im 集成设置。
- **some.im 浏览器登录链接** —— some.im 设置页可生成带短随机码的浏览器登录链接与二维码，支持复制链接/随机码或直接在浏览器打开；用户在 some.im 页面登录完成后按页面提示回到 WillDeep 继续使用。
- **收起会话列表后可从左边缘呼出最近会话** —— Agent 会话侧栏收起时，鼠标靠近窗口左边缘会滑出最近活跃会话浮层；列表只展示有真实用户消息的最近会话，并在每行前方用明显区分样式显示 workspace 前两个字符（并入 main 同版本改动）。

### Changed
- 版本号从 **1.132.0-rc3** 提升为 **1.133.0-rc1**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness 位点。

## 1.132.0-rc3 - 2026-07-07

### Fixed
- **Editor 入口不再停在未打开文件夹空态** —— 从 Agent 顶部图标或菜单“显示 Editor”切回编辑器时，如果当前没有任何标签，会自动创建一个 Untitled 空白编辑 tab，直接进入可输入状态。

### Changed
- 版本号从 **1.132.0-rc2** 提升为 **1.132.0-rc3**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness 位点。

## 1.132.0-rc2 - 2026-07-07

### Fixed
- **Agent 工具审批卡片点击不再丢失** —— 审批决定现在按 runtime + tool call ID 暂存和投递；用户在执行循环注册等待者之前先点 Allow / Deny / Confirm / Send 时，决定会被后续等待者消费，不再出现 terminal command 审批卡片看似可点但没有反应的状态。
- **多个 pending 工具审批不再串线** —— continuation 记录当前等待的工具 ID，点击其它 pending 卡片只会暂存对应决定，不会唤醒错误的工具调用。
- **已提交审批显示等待态** —— 工具卡片在决定已记录但执行循环尚未接收时隐藏操作按钮，显示“已提交决定，等待执行循环接收”，避免继续展示不可重复交付的按钮。

### Changed
- 版本号从 **1.132.0-rc1** 提升为 **1.132.0-rc2**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness 位点。

## 1.132.0-rc1 - 2026-07-06

### Added
- **Mobile Gateway 接入友盟远程推送触发** —— Android 通过 `push.register` 上报友盟 device token 后，局域网 Go gateway 会在 `tool.pending` / `patch.upsert` 等需要用户注意的桌面事件出现时调用友盟 U-Push；默认互联网中继模式下，Swift desktop peer 会本地保存 token 并直接触发同样的友盟自定义 payload，确保两种连接模式都能把审批、补丁审查和 `ask_user` 输入提醒推到手机。
- **本机友盟配置读取** —— Mac 端会从环境变量或本机 `local.properties` 读取 `UMENG_PUSH_ENABLED`、`UMENG_APPKEY`、`UMENG_APP_MASTER_SECRET` / `UMENG_MASTER_SECRET`，并兼容 `UMENG_MESSAGE_SECRET` 作为本地调试兜底；`.gitignore` 已忽略 `local.properties`，避免把密钥提交进仓库。

### Changed
- 版本号从 **1.131.0-rc9** 提升为 **1.132.0-rc1**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness 位点。

## 1.131.0-rc9 - 2026-07-06

### Fixed
- **Agent 侧边栏重资源会在长时间未查看后释放** —— 会话侧边栏记录最后查看时间；终端、嵌入浏览器、Widget 和图片编辑器等重面板在所属会话超过 1 小时未被查看后会自动收起并释放对应资源，其中终端会关闭该会话打开的 tab，嵌入浏览器会重置不可见 WebView 状态。
- **Dev Server 面板改为 workspace 共享视角** —— 同一工作区内不同 Agent 会话会看到同一组 dev server / tail 后台任务，避免每个会话各自认为要启动一套服务而造成端口占用冲突。

### Changed
- 版本号从 **1.131.0-rc8** 提升为 **1.131.0-rc9**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness 位点。

## 1.131.0-rc8 - 2026-07-06

### Fixed
- **Agent 右侧侧边栏状态改为跟随会话** —— 侧边栏打开的面板类型、文件/预览选择、媒体任务 scope 和图片编辑器输入现在保存到当前会话 runtime；切到另一个会话会按目标会话自己的状态显示（未打开过则收起），切回原会话会恢复原侧栏与关联数据，不再被其它会话覆盖或清空。

### Changed
- 版本号从 **1.131.0-rc7** 提升为 **1.131.0-rc8**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness 位点。

## 1.131.0-rc7 - 2026-07-06

### Fixed
- **文本模型带图不再把 VL 描述暴露在聊天记录里** —— 当前模型不支持图片输入时，Image Understanding 生成的图片描述仍会作为模型上下文发送，但用户气泡、TextKit 历史记录、旧历史预览和复制按钮只展示用户原文与图片缩略图，不再显示 `[Image description generated...]` 或 `Image 1:` 这类内部转写内容。

### Changed
- 版本号从 **1.131.0-rc6** 提升为 **1.131.0-rc7**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness 位点。

## 1.131.0-rc6 - 2026-07-06

### Changed
- **普通启动默认只显示 Agent 窗口** —— App 冷启动不带文件/目录意图时，会自动打开 Agent 单例窗口并关闭 SwiftUI 先创建的空 Editor 窗口；通过命令行通用打开命令、`willdeep://open?path=...`、Finder 右键打开文件或目录时仍保留 Editor 模式。Agent 顶部“进入 Editor”图标入口不变。
- 版本号从 **1.131.0-rc5** 提升为 **1.131.0-rc6**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness 位点。

## 1.131.0-rc5 - 2026-07-06

### Fixed
- **最后一条用户气泡底部不再被裁掉** —— TextKit 历史聊天视图的本征高度现在为气泡背景额外预留底部绘制余量，避免最后一条用户输入的下圆角和 footer 区域贴近滚动容器底部时被裁切。

### Changed
- 版本号从 **1.131.0-rc4** 提升为 **1.131.0-rc5**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness 位点。

## 1.131.0-rc4 - 2026-07-06

### Fixed
- **展开旧聊天历史不再默认渲染完整富文本** —— transcript 顶部“对话前面还有多条消息”现在点击后先展示最多 4000 字符的纯文本预览，只保留角色与正文，避免长会话一次性把完整历史烤成富文本导致内存和主线程压力飙升；完整详情仍可通过预览里的“完整详情”按钮打开独立窗口查看。

### Changed
- 版本号从 **1.131.0-rc3** 提升为 **1.131.0-rc4**，并同步 Xcode / Go agent / Help / product overview / Mobile Gateway / Agent Harness 位点。

## 1.131.0-rc3 - 2026-07-06

### Fixed
- **干净 tracked 文件的 Agent 编辑直接落盘** —— `edit_file` / `apply_patch` 修改已存在文件时，如果所有目标文件都已经被 git 跟踪、当前对 HEAD 干净，并且 App 内没有未保存编辑，补丁会直接应用，不再要求用户再点一次 Apply。未跟踪文件、已有未提交改动的文件、打开但未保存的文件仍保留 inline patch 卡片等待用户确认。

### Changed
- 版本号从 **1.131.0-rc2** 提升为 **1.131.0-rc3**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness 位点。

## 1.131.0-rc2 - 2026-07-06

### Fixed
- **AI 回复结束后聊天区补滚到底部** —— 自动滚动此前只在「消息/工具调用条数变化」时触发（防逐 token 滚动钉死主线程的既有设计），而 assistant 消息在流式开始、内容还近乎空白时就已 append 并完成那次滚动；之后长回复在视口下方持续长高、条数不变、再无滚动，输出结束时视口停在答案中段。现在监听回合结束（`isAgentResponding` true→false），等布局落定后一次性滚到底部哨兵，用户总能看到最新内容；流式期间行为不变、零逐 token 开销。

### Changed
- **Dev Server 面板改为可直接操作项目 dev 环境** —— 面板现在会扫描当前工作区根目录与常见前端/后端目录，发现 Vite/Next/React/Vue、Node API、Go、Rails、FastAPI 和静态 HTML 的启动候选；前端与后端分区支持直接启动、停止、重启，并继续复用后台 job 注册表。
- **实时日志 tail 不再只回填提示词** —— Dev Server 面板可直接对用户指定的 workspace/tmp/本地日志路径启动 `tail -f` 后台任务，输出尾部与 AI 通过 `run_command(run_in_background=true)` 启动的任务统一展示。
- 版本号从 **1.131.0-rc1** 提升为 **1.131.0-rc2**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness 位点。

## 1.131.0-rc1 - 2026-07-06

### Added
- **Web 编程专家** —— 新增 `webCoding` 专家，覆盖截图生成 UI、本地 HTML/CSS/图片资源预览、Vite/Next/React/Vue 项目预览、浏览器截图 QA 与 dev server 编排；Agent 提示词会在短剧/Web 编程等场景引导用户确认激活对应专家。
- **专家激活工具** —— 新增 `activate_expert`，模型可在 `ask_user` 确认后为当前会话激活专家，而不是只提示用户手动找开关。
- **Dev Server 侧栏面板** —— 新增右侧 `Dev Server` tab，激活 Web 编程专家后可查看当前会话的前端/后端 dev server 与 `tail -f` 后台任务，读取输出尾部、停止任务，并把启动/重启/tail 日志请求回填给 Agent。

### Changed
- **本地 HTML 预览资源增强** —— `show_widget(html_path:)`、widget action 预览和 widget 源文件重载都会把 HTML 所在目录作为 WebView baseURL，允许用户引用同目录下的 CSS、JS 和图片文件，同时继续禁止网络连接和任意本地跳转。
- 版本号从 **1.130.0-rc4** 提升为 **1.131.0-rc1**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness 位点。

## 1.130.0-rc4 - 2026-07-06

### Fixed
- **Agent 右侧面板「…」菜单不再重复列出快捷入口** —— 顶部快捷条已有的 Diff / Terminal / Preview / Files 从更多菜单中移除；更多菜单只展示非快捷面板入口，当前已有面板打开时仍保留「关闭面板」操作。
- **用户输入气泡左侧大片留白收窄到约一个字宽** —— TextKit 历史渲染里用户消息正文左缩进原是写死的 172pt、气泡固定 82% 宽，窄窗口下输入内容左边空出一大块。现在正文左缩进降到 16pt（约一个汉字），气泡几乎撑满内容列（左缘仅留 4pt、右缘保持 30pt trailing margin），窄到极限时退回 260pt 最小宽度右对齐。

### Changed
- 版本号从 **1.130.0-rc3** 提升为 **1.130.0-rc4**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness 位点。

## 1.130.0-rc3 - 2026-07-06

### Fixed
- **右侧面板（预览等）在小窗口下启动即占掉半个窗口** —— 面板宽度此前只按持久化值（默认 320pt）夹在 240–760 之间，完全不看窗口实际宽度；在 ~650pt 的窗口里 320+ 的面板直接吃掉一半以上，中间 chat 列被裁得没法用。现在面板有效宽度按「窗口宽 − 会话侧栏 − chat 舒适宽」动态封顶：小窗口下自动收窄（最窄 240pt），窗口拉大后自动恢复用户拖出来的偏好宽度；拖拽上限同样吃这个封顶，不允许把 chat 列挤没。
- **拖动右侧面板分隔条时闪动感明显** —— 此前每个鼠标事件都改真实布局宽度，chat 列与面板内容（markdown 逐帧重折行、WebView/终端逐帧重排）整体重排版，肉眼即闪。现在拖拽期间两侧内容都按拖拽起点宽度冻结排版，只有 frame 跟手移动（chat 内容钉左缘、面板内容钉右缘，多余部分裁掉），松手后一次性按新宽度重排；分隔条在拖拽中还锁定左右缩放光标与高亮，消除快速拖动时 hover 高频翻转带来的光标/高亮闪烁。窗口 `contentMinSize` 也不再跟随持久化面板宽度，只保证最窄面板放得下。

### Changed
- 版本号从 **1.130.0-rc2** 提升为 **1.130.0-rc3**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness 位点。

## 1.130.0-rc2 - 2026-07-06

### Fixed
- **窗口收窄时左侧会话栏被挤出左缘 / 中间聊天区外溢右缘** —— 中间 chat 列的 frame 只写了 `maxWidth: .infinity`,按 SwiftUI frame 语义其最小宽度会回退为子内容本征最小宽,统计卡片 / composer 等压不动的内容把中间列下限顶得比可用空间还宽,整条 HStack 溢出后被父级默认居中:左栏被推出窗体左缘、chat 内容溢出右缘。现在中间列显式 `minWidth: 0` 成为真正的唯一可压缩列(压不下的内容靠左、在右缘被 `.clipped()` 裁掉),外层 frame 改 `.leading` 对齐,即便平铺工具 / 编程式 resize 把窗口压到固定列宽之和以下,左栏也钉在左缘不再被遮挡。

### Changed
- 版本号从 **1.130.0-rc1** 提升为 **1.130.0-rc2**,并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness 位点。

## 1.130.0-rc1 - 2026-07-06

### Added
- **截图工具与工具结果图片直通视觉模型** —— 新增 `capture_screenshot` 工具，可截取本机 Mac 屏幕（`screencapture`）、连接的 Android 设备/模拟器（`adb exec-out screencap`）或已启动的 iOS 模拟器（`xcrun simctl io screenshot`）。`AgentToolResult` 新增 `images` 字段，`.tool` 消息随之携带图片：Anthropic 等视觉模型以 `tool_result` image block 形式直接“看到”像素并可多轮重发；DeepSeek / OpenAI Chat / Gemini 等非视觉或不支持工具图片的 provider 自动降级为纯文本 payload（含本地 OCR + 保存的完整分辨率路径，可再调 `visual_qa_screenshot` 做 VL 描述）。图片在捕获时即缩放到 ≤1568 长边再入会话，避免上下文与内存膨胀。工具卡片内联渲染缩略图（ImageIO 下采样解码，规避历史上的图片/布局内存失控），点击在“预览”中打开完整截图。

### Fixed
- **手机网关设置页默认不再铺开高级参数** —— “显示高级信息”改为本次设置视图内的临时状态，不再记住历史展开值；旧用户曾经打开过高级信息，也不会每次进来都看到 IP、端口、协议、可执行路径等一大屏参数。
- **Settings 里的图像理解配置立即作用到当前聊天** —— Settings 窗口不再新建独立 `AppState`，而是复用 `EditorAppStateRegistry` 当前 AppState；切换 Image Understanding 到 some.im 后，正在聊天的 Agent 会直接拿到新的 provider/baseURL/model/API key，不再继续用旧的 DashScope 配置。
- **获取视觉模型列表成功后同步提交当前图像理解配置** —— 避免用户看到 `Fetched ... image models` 后误以为已生效，但下一次发图仍按旧配置请求。

### Changed
- **公共中继配置再收进自定义区域** —— `j.niuwoai.com` 默认中继地址和 relay room 字段仍保留给自建兼容 WebSocket 中继服务的用户，但默认藏在“自定义中继服务”折叠组里；普通用户只看连接方式、状态和配对二维码即可。
- 版本号从 **1.130.0** 调整为 **1.130.0-rc1**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness 位点。

## 1.130.0 - 2026-07-06

### Fixed
- **Android 发图终于进入 Mac Agent 图片链路** —— `message.send` 和 `queue.update` 现在会解析 Android 上传的 `payload.images` data URL，转成 Mac 原生 `AgentImageAttachment` 后进入现有 composer / queued message / Image Understanding 流程；纯图片消息也允许发送，不再因为缺少 `payload.text` 被拒绝。

### Changed
- 本次记录对齐当前产品版本 **1.130.0**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness 位点。

## 1.129.0-rc47 - 2026-07-06

### Fixed
- **纯「思考中」切换不再自动开合右侧任务监控面板** —— `AgentTaskMonitorSnapshot` 的 `isAgentResponding` 虽然被设计为不参与自动展开判定，却仍是 `Equatable` 的比较字段，导致 agent 每次「思考↔空闲」翻转都会触发 `handleTaskMonitorSnapshotChange`；当用户手动打开、当前无后台内容的面板遇到一次 thinking 切换时，会被「无可见监控内容 → 收起」分支自动关掉。现在当两次快照除 `isAgentResponding` 外其余字段全等时判定为纯思考态切换，直接跳过、不改动面板开合状态。

### Changed
- 版本号从 **1.129.0-rc46** 提升为 **1.129.0-rc47**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness 位点。

## 1.129.0-rc46 - 2026-07-06

### Added
- **Mobile Gateway 下发真实运行能力给 Android** —— Swift desktop peer 新增 `capabilities.get` / `capabilities.updated` 协议路径，向手机同步当前 provider、模型、技能、专家和插件列表；Android 发送 `message.send` 时可带回 `provider_id`、`model`、`skills`、`experts` 和 `plugins`，Mac 端在发起这一轮 Agent 前应用这些运行上下文。

### Changed
- 版本号从 **1.129.0-rc45** 提升为 **1.129.0-rc46**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness 位点。

## 1.129.0-rc45 - 2026-07-06

### Fixed
- **Agent composer「更多设置」弹层不再抢输入焦点** —— workspace / model / mode / 审批 / 执行器 / 插件 / 专家这些 composer pill 统一声明 `focusable(false)`；「更多设置」popover、专家开关、插件行和 MCP 只读行也补齐焦点禁用，避免打开弹层后把键盘焦点从输入框拿走。

### Changed
- 版本号从 **1.129.0-rc44** 提升为 **1.129.0-rc45**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness 位点。

## 1.129.0-rc44 - 2026-07-06

### Fixed
- **Agent 左侧 workspace 列表更安静也更顺手** —— workspace 行尾的新建会话 `+` 不再常驻显示，只有鼠标移到该 workspace 行或其会话列表区域时才出现；点击 workspace 名称本身现在也会展开 / 收起会话列表，不再必须精确点文件夹图标。

### Changed
- 版本号从 **1.129.0-rc43** 提升为 **1.129.0-rc44**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness 位点。

## 1.129.0-rc43 - 2026-07-06

### Fixed
- **智能审批终于会真正调用 AI 裁判了** —— 排查发现「智能审批」的 LLM 裁判此前几乎从不生效（本机审计日志 2000+ 条里 `llmJudge` 命中 0 次），根因有二并一并修复：
  - **工具覆盖缺口**：裁判此前只覆盖 `run_command` 和 `call_mcp_tool`，而占人工审批大头的 `terminal_send_command`（侧边栏终端命令）直接绕过裁判弹人工。现在 `terminal_send_command` 走与 `run_command` 相同的「静态安全白名单 → LLM 裁判」链路，`terminal_send_control`（ctrl_c/enter/escape）也通过伪命令送裁判。
  - **裁判请求必然失败且静默**：`max_tokens` 仅 16，被 reasoning 模型（如 deepseek-v4-flash）的思考过程烧光，正文永远为空；且 OpenAI-兼容响应体 `content` 为非可选字段，`content=null` 时整体解码失败 → 静默 `return false`。现在输出预算提到 512（Responses 1024）、`content` 改可选、超时从 12s 放宽到 20s。
- **裁判失败不再无声无息** —— 每次裁判结果（allow / deny / unavailable + 失败原因）落盘到 `~/Library/Application Support/WillDeep/AgentAudit/judge.jsonl`，「为什么还在问我」从此可查。

### Added
- **把人工审批历史喂给 AI 裁判做参照** —— 从审计日志提取操作者过去手动「批准 / 拒绝」的命令样本，作为软性 few-shot 附到裁判 system prompt（明确不覆盖安全规则，危险命令仍判 NO）。历史块经过去重、单行截断、注入标记中和，且**体量受控**（批准≤14 条、拒绝≤6 条）。
- **裁判请求针对 prompt 缓存优化** —— 历史块**不是每次调用都重取**：在内存里缓存、最多每 30 分钟重建一次，使「安全规则 + 历史」的 system 前缀在多次裁判间保持字节一致，命中 provider 的 prompt 缓存；Anthropic 路径额外给 system 块打 `cache_control: ephemeral`；每次调用只有末尾 `<command>` 变化。

### Changed
- 版本号从 **1.129.0-rc42** 提升为 **1.129.0-rc43**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness 位点。

## 1.129.0-rc42 - 2026-07-06

### Fixed
- **聊天历史里的终端工具摘要不再刷屏** —— `terminal_send_command`、`terminal_snapshot`、`terminal_send_control` 统一聚合为「终端操作」，最新 assistant 输出保留终端操作摘要，历史 assistant 输出会隐藏终端相关摘要；历史里的读取文件、搜索代码等非终端工具摘要仍照常显示，保留必要上下文。
- 新增回归测试覆盖终端工具聚合、最新 assistant 终端摘要展示，以及历史 assistant 仅隐藏终端摘要的行为。

### Changed
- 版本号从 **1.129.0-rc41** 提升为 **1.129.0-rc42**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness 位点。

## 1.129.0-rc41 - 2026-07-06

### Changed
- **version_consistency 回归通用版本一致性检查** —— `scripts/version_consistency.rb` 不再扫描短剧/剧本相关 cutoff、tryout、manual queue，也不再承载短剧 delivery gate；报告只检查产品版本号位点是否一致。
- **短剧验收脚本解除对 version_consistency delivery gate 的依赖** —— `short_drama_mvp_acceptance_report.rb` 仍要求版本报告通过，但不再要求版本报告内包含短剧专属 gate 名称；短剧守门继续留在短剧自己的 contract / acceptance / handoff 脚本里。
- 版本号从 **1.129.0-rc40** 提升为 **1.129.0-rc41**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness 位点。

## 1.129.0-rc40 - 2026-07-06

### Fixed
- **全屏 Agent composer 上方不再重复显示单文件编辑提示** —— 已有贴近 composer 的「N 个文件已更改 +X -Y / 审查」汇总条时，transcript 底部不再额外显示「正在编辑/已编辑 某个文件」活动行，避免同一组工作树变更出现两次提示；停靠侧边栏模式仍保留该行，因为它没有同样的 composer 汇总条。
- **侧边栏终端 heredoc / apply patch 改为兜底可用而非绝对禁止** —— system prompt、`terminal_send_command` 描述、远程 runtime 附加提示和默认全局规则同步改为：优先使用 App 编辑/写入、`apply_patch`、明确文件传输或 `rz/sz`；当远程无法安装 `lrzsz` 或传输路径不可用时，可以使用小而清晰、可审查、可验证的 heredoc、patch、sed/perl 等远程编辑兜底。

### Changed
- 版本号从 **1.129.0-rc39** 提升为 **1.129.0-rc40**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.129.0-rc39 - 2026-07-06

### Added
- **WillDeep 侧边栏终端支持 rz/sz ZMODEM 桥接** —— 侧边栏终端现在会拦截远端 `rz` / `sz` 的 lrzsz 握手：远端 `rz` 时弹本机文件选择并用本机 `sz` 上传，远端 `sz` 时弹保存目录并用本机 `rz` 下载。桥接过程把本机 lrzsz 子进程与当前 PTY 对接，不再把 ZMODEM 控制流直接刷成乱码。
- **lrzsz 缺失时给安装提示** —— 本机缺 `rz`/`sz` 时终端会取消本次 ZMODEM 并提示 `brew install lrzsz`；system prompt / `terminal_send_command` 工具说明也改为明确 WillDeep 前端支持 ZMODEM，模型在远端使用前应先跑 `command -v rz sz`，缺失时按服务端系统提示安装 `lrzsz`。
- 新增 ZMODEM 握手检测回归断言，覆盖远端 `rz` 提示归类为上传、远端 `sz` 握手归类为下载。

### Fixed
- **`terminal_snapshot` 取侧边栏终端内容不再卡死** —— 读取加了 3 秒超时护栏：主线程被占用（典型是 agent 流式渲染富 markdown 时 SwiftUI 布局吃满主线程）时，工具不再无限等待 `MainActor` 调度而挂住整个工具调用；超时会返回一句「主线程繁忙、什么都没改、稍后重试」的明确错误，让模型自己重试而不是干等。
- **脱敏与截断移出主线程** —— 主线程上只做一次廉价的原始视口抓取（`rawViewportText`），secret 脱敏正则和长度截断改到主线程外执行，避免超长行触发正则灾难性回溯时冻结 UI；超时护栏同时覆盖脱敏阶段。
- **无终端/终端已退出时给出可操作的错误而非静默空快照** —— 没有活跃终端标签时抛出清晰错误（提示先打开侧边栏终端，或用 `terminal_send_command` 自动起 shell），不再返回一个 agent 无法与「真的没输出」区分的空「disconnected」快照；终端进程已退出时明确标注「process has exited（展示最后可见屏幕）」。

### Changed
- 版本号从 **1.129.0-rc38** 提升为 **1.129.0-rc39**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.129.0-rc38 - 2026-07-06

### Fixed
- **侧边栏终端提示词避免 heredoc 文件写入** —— Stable system prompt、`terminal_send_command` 工具描述和远程 runtime 附加提示同步收紧：操作可见侧边栏终端时，不再用 heredoc / here-string / `cat > file` / `echo > file` 等粘贴式多行 shell 技术生成或覆写文件，优先走 `create_file` / `edit_file`、普通 `run_command` 或明确的文件传输路径。
- **rz/sz 作为检测后启用的增强路径** —— system prompt 明确 `rz/sz` 只在终端前端支持 ZMODEM、远端安装 `rz`/`sz`，并经用户同意或小文件测试证明可用后才尝试；支持不明或测试失败时回退到 scp/rsync、workspace 文件、附件或 App 编辑/写入流程。
- 新增回归断言覆盖侧边栏终端上下文提示中的 heredoc 禁用与 `rz/sz` ZMODEM 条件说明。

### Changed
- 版本号从 **1.129.0-rc37** 提升为 **1.129.0-rc38**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.129.0-rc37 - 2026-07-06

### Fixed
- **Composer 粘贴同一张图片不再重复入队** —— 剪贴板图片读取新增内容 fingerprint 去重，避免 macOS 同一张图以多个 pasteboard item/flavor 暴露时，`Command+V` 后预览区出现重复缩略图。
- **文本模型带图发送不再静默丢图** —— 当当前模型不支持图片输入（如 DeepSeek 非 VL 模型）时，会先用 Image Understanding 生成图片描述并并入用户消息；若图片描述失败，本轮会停在错误卡而不是继续发出一个“图片已省略”的请求。OpenAI-compatible text-only payload 在已有生成描述时也不再追加误导性的 omitted 提示。
- **shell 包装的 `echo DOCKER_DONE` 哨兵不再误弹审批** —— `SafeCommand` 现在能识别 `sh` / `bash` / `zsh` 的 `-c` / `-lc` 包装命令：内层是 `echo` / `printf` 等无副作用哨兵时直接按只读放行，避免远端/容器脚本收尾的一句 `echo DOCKER_DONE` 交给用户确认；内层藏有 `rm`、敏感路径或显式系统路径时仍会降级为审批/确认。
- 新增回归测试覆盖剪贴板图片去重，以及 text-only provider 收到生成图片描述时的请求编码。
- 新增回归测试覆盖 `/bin/sh -lc "echo DOCKER_DONE"` 的静态安全分类与沙箱决策，确认 shell 包装哨兵不再进入用户审批。

### Changed
- 版本号从 **1.129.0-rc36** 提升为 **1.129.0-rc37**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.129.0-rc36 - 2026-07-06

### Fixed
- **工作树 diff 预览遇到大量前端构建产物时自动降级** —— `showAgentWorktreeDiff` 现在在超过文件数/变更行数阈值，或命中 `dist` / `*-web-dist` / `assets/*.js` 等疑似预构建前端产物时，不再渲染完整 hunk，而是展示原因、文件摘要和受限预览，避免 160+ 个压缩 JS/CSS diff 拖慢界面。
- 新增回归测试覆盖 `railway-prebuilt-web-dist/assets/*.js` 大量删除场景，确保预览不再输出完整 `diff --git` 内容。

### Changed
- 版本号从 **1.129.0-rc35** 提升为 **1.129.0-rc36**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.129.0-rc35 - 2026-07-06

### Fixed
- **队列引导接管等待确认/询问时会收起旧卡片** —— 用户在当前 turn 卡在 `confirm` / 普通授权 / `ask_user` 时发送新消息或点击排队消息的“立即发送”，现在会把当前阻塞工具调用标记为已拒绝/已跳过，并恢复队列消费；旧的 confirm / ask_user 交互卡不再继续挂在聊天区等用户输入。
- 新增回归测试覆盖 Stop、立即发送排队消息和新消息接管等待态时的 `awaitingConfirm` / `awaitingUserAnswer` 收尾行为。

### Changed
- 版本号从 **1.129.0-rc34** 提升为 **1.129.0-rc35**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.129.0-rc34 - 2026-07-05

### Fixed
- **apply_patch 现在支持 CRLF 文件** —— `AgentPatchApplier.apply` 此前把文件内容按 `"\n"` 切分,CRLF 文件每行残留尾部 `\r`,而解析出的 diff 行不带 `\r`(parse 用 `.newlines` 切),导致上下文永远匹配不上、每个 hunk 都 "hunk did not match"。现在匹配时先剥掉每行尾部 `\r`,输出时若原文件是 CRLF 再整体还原 `\r\n`——LF 文件零影响(仅当真有 `\r` 时才 dropLast)。
- **补丁模糊匹配歧义时拒绝而非改错位置** —— hunk 在 ±6 行锚点窗口匹配不上时会退回全文件搜索;此前取**第一个**匹配,在重复代码里可能把补丁打到错误的函数上。现在全文件回退要求**唯一**匹配,出现多处相同 context+removed 块时拒绝(→ "hunk did not match"),交回用户判断。±6 锚点窗口内仍保留就近优先(高置信,行为不变)。
- **越界 hunk 行号不再崩溃** —— hunk 头 `oldStart` 指向文件末尾之后(文件被外部截断/头部损坏)时,`(preferredIndex-6)...(preferredIndex+6)` 会出现 `lower > upper` 触发 ClosedRange 运行时陷阱直接崩溃;现在先把锚点夹到合法区间,安全失败为 "hunk did not match"。
- 新增回归测试 `AgentPatchApplierRobustnessTests`(CRLF 应用/LF 不受影响/歧义拒绝/唯一漂移块仍应用/越界锚点安全失败),既有 32 个补丁与 edit_file 用例全绿。

### Changed
- 版本号从 **1.129.0-rc33** 提升为 **1.129.0-rc34**,并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.129.0-rc33 - 2026-07-05

### Fixed
- **图片蒙版编辑面板文案国际化收尾** —— 继 rc29 首批（蒙版工具/画笔模式选择器、发送到聊天、空状态、枚举标签）之后，把 `AgentImageEditPanel` 剩余约 40 处硬编码中文全部迁入 `L10n.AgentImageEditor`：面板标题与工具栏 tooltip（撤销/清空/导出）、反选蒙版 Toggle 及说明、提交区（标题、模式/服务选择器、提示词与 model/version/endpoint 占位符、提交按钮、Replicate 配置提示、provider 说明）、导出/提交状态消息（含 %@ 插值模板）、选区摘要、聊天接力 lead 行和制作锚点行标签。聊天 handoff 结构化块中被合约测试钉住的 `active_task_follow_up` 行保持原文（属 agent prompt 合约，非 UI 文案）；`short_drama_media_contract_test` / `image_edit_contract_test` 中逐字断言中文源串的检查同步改为断言 L10n 调用形式，两个合约测试与 i18n 覆盖率守卫（100%）全部通过。
- 版本号从 **1.129.0-rc32** 提升为 **1.129.0-rc33**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.129.0-rc32 - 2026-07-05

### Changed
- **持久化模型图 Swift 6 就绪：整体标注 `nonisolated`** —— 项目开着 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，`AgentSession` 及其全部 Codable 子类型（29 个顶层声明，含 AgentMessage / AgentPlan / AgentGoal / WorkflowReport / AgentWidget / 自学习与回忆模型等）的 synthesized Codable conformance 之前都是 main-actor 隔离的，rc30 的后台写队列 encode 会触发「isolated conformance in nonisolated context」警告（Swift 6 模式下是 error）。这些类型全是无 main-actor 状态的纯值类型，现已显式 `nonisolated`。
- **连带清理**：`L10n`（纯 `String(localized:)`）、`AgentSessionStore.defaultTitle`、`AgentWorkspaceAvailability(+Resolver)`、`RemotePathValidator`、`AgentWidgetRecommendedAction/HandoffAction`、`AgentLocalModelFileMatch`、`AgentSessionTodoSummary`、`AgentMarkdownTableFormatter.StyledSpan` 一并标注，顺手消掉同族的既有隔离警告（含测试宏展开处）。本次为纯注解变更，无行为变化；相关隔离警告从约 20 条降到 0。
- 版本号从 **1.129.0-rc31** 提升为 **1.129.0-rc32**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.129.0-rc31 - 2026-07-05

### Fixed
- **编辑器终端面板 i18n 补全** —— `EditorTerminalView.swift` 约 20 处硬编码英文 UI 文案（终端头部标题/工作目录占位符/Run 菜单/「未找到项目命令」/四个按钮 tooltip，以及终端设置页的 Shell/字体/自定义字体/大小/光标/光标闪烁/配色方案/环境各标签、「跟随应用皮肤」选项、字号 pt 显示和三段说明文案）全部提取到 `L10n.EditorTerminal`（key 前缀 `editor-terminal.`，共 23 个），`Localizable.xcstrings` 按字母序补齐 en + zh-Hans 双语条目；中文系统下终端面板与终端设置不再回落英文。i18n 覆盖率守卫保持 100%。
- 版本号从 **1.129.0-rc30** 提升为 **1.129.0-rc31**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.129.0-rc30 - 2026-07-05

### Changed
- **会话持久化移出主线程** —— 此前每次 persist 都在 @MainActor 上同步 JSON 编码 + 原子写盘（一个回合触发多次，长对话/含 base64 图片的会话单次可达几十毫秒），流式输出期间反复卡 UI。现在所有会话写盘走 `AgentSessionStore` 的串行后台写队列：
  - `persist()` 异步入队并**按会话合并**（一回合连发 N 次只编码最新快照一次）；写序用票据（seq）门控，`saveAsync → delete → saveAsync` 交错时后发的保存不会被先排队的 drain 抢走、也不会被 delete 误伤。
  - 同步 `save()` / `delete()` 也路由到同一队列，与异步路径保持每会话写序一致；`delete` 先取消待写快照，防「删除后被 pending 写复活」。
  - `load(id:)` 优先返回还没落盘的最新快照；**`loadAll()` 叠加 pending 快照**——否则 Settings 窗口（第二个 AppState 实例）在写窗口期调用 loadAll 会把刚持久化的会话误标回「metadata-only 且无用户消息」，下一次空会话清理会**删掉有真实历史的会话**（对抗性审查发现的数据丢失竞态）。
  - 写失败时快照**放回内存兜底**（load 仍能读到最新态）并经 `saveDidFailNotification` 广播，各 AppState 实例认领自己 runtime 的失败挂到错误卡；App 退出前 `flushPendingWrites()` 排空队列，⌘Q 不丢最后一条消息。
  - 置顶/归档/改名/标题摘要这几处同步 save 改为异步（调用方本就丢弃返回值），不再排队等大会话写完。

### Fixed
- **置顶/归档不再被回合结束的 persist 冲掉** —— `toggleAgentSessionPinned/Archived` 此前只改 `agentSessions` 行、不回写常驻 runtime 的 session 副本（rename 早就回写了），runtime 下一次 persist 会用旧副本覆盖,静默取消置顶/归档；现在两处都镜像回写。附回归测试。
- 新增回归测试：异步写合并+flush、pending 快照可读、delete 取消待写、delete 后再 save 不被吞、loadAll 叠加 pending 快照且不误标空会话、pin/归档扛住 runtime persist。
- 版本号从 **1.129.0-rc29** 提升为 **1.129.0-rc30**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.129.0-rc29 - 2026-07-05

### Fixed
- **移动网关非法 host 配置不再闪崩** —— `desktopBaseURL` / `pairingBaseURL` 此前把用户可编辑的 host/port 拼进 `URL(string:)!` 强制解包，host 含空格或非法字符时直接崩溃；现在统一走 `httpBaseURL(host:port:)`，先 trim 再解析，解析失败回退 `127.0.0.1`。
- **关标签页对话框期间 tabs 变化不再越界** —— `closeTab` 在「未保存更改」弹窗（含背后的存储面板）模态循环期间，主队列任务可能改动 `tabs` 数组，之前继续用弹窗前捕获的 index 删除，有错删/越界风险；现在弹窗返回后按 id 重查 index。
- **LSP 跳转失败不再无声无息** —— 定义/声明/类型定义/实现四条查询路径的 catch 此前完全吞掉错误，语言服务器持续故障时只能靠猜；现在补 `NSLog("[EditorLSP] …")` 日志（回退/蜂鸣行为不变），排查有迹可循。

### Changed
- **窗口 chrome 轮询不再多链叠加** —— `MainWindowChrome.Coordinator.attach` 被 SwiftUI 每次 `updateNSView` 调用，之前每次都新启一条 30-tick 的递归 poll 链、多条链并行做同样的事；现在加 `isPolling` 防重入，只维持一条链（刷新重试预算的语义保留）。
- **项目文件缓存淘汰排序不再重复查磁盘** —— `ProjectFileListCache.evictOldProjectsIfNeeded` 的排序比较器里每次比较都查两次 mtime（O(n log n) 次元数据查询）；现在先一次性解析成 `(URL, Date)` 再排序。
- **一批硬编码文案走 L10n（en/zh-Hans 齐全）** —— ① 关标签页「未保存更改 / 保存失败」两个 NSAlert（原硬编码英文）；② composer 手动压缩按钮 Compress / Compressing… 及 tooltip（原硬编码英文）；③ composer 工作树摘要条「N 个文件已更改 / 审查」与侧栏任务监控「还有 N 个后台任务 / 还有 N 个文件」（原硬编码中文）。i18n 覆盖率守卫保持 100%。
- 版本号从 **1.129.0-rc28** 提升为 **1.129.0-rc29**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.129.0-rc28 - 2026-07-05

### Fixed
- **LSP 进程不再无限累积** —— language server 会话按「服务器×工作区」缓存但从不关闭（`closeAll` 无调用者），跨项目游走一圈就挂一排 sourcekit-lsp/gopls 常驻到退出。现在加 LRU 上限（6 组），超出即停掉最久未用的会话；被淘汰的项目再次打开文件时自动重建（文档状态经 `didOpen` 重同步）。`transport.stop()` 同时关闭 stdin 写端（体面退出 + 立刻回收文件描述符），`send()` 改用可 throw 的 `write(contentsOf:)`，杜绝向已停进程写入时的 ObjC 异常崩溃。新增 LRU 淘汰回归测试。
- **删除会话加确认框** —— 右键菜单误触不再直接抹掉整段对话；弹窗含会话名，删除按钮标记为 destructive（en/zh-Hans 文案齐全）。
- **会话落盘失败浮出错误卡** —— `AgentSessionStore.save` 失败（磁盘满/权限丢失）此前只 print 到控制台，用户重启后才发现历史丢失；现在 persist 失败会在会话错误卡上提示（不覆盖已显示的 provider 错误）。

### Changed
- **聊天渲染：路径识别正则提为 static 缓存** —— 此前每渲染一个文本块都重新编译一次 `NSRegularExpression`，流式输出期间是纯浪费；pattern 恒定，编译一次终生复用。
- **会话列表：persist 不再全量排序** —— `persistAgentSession` 每回合触发多次、每次对整个 @Published 会话数组全量 `sort`（顺带放大侧栏重绘）；现改为单次 move-to-front（persist 刚盖了 `updatedAt`，该会话必是最新）。加载与其余插入点原本就维持降序，语义不变。
- 版本号从 **1.129.0-rc27** 提升为 **1.129.0-rc28**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.129.0-rc27 - 2026-07-04

### Fixed
- **后台任务失败后聊天会话不再"装死"** —— 侧栏任务监控里后台任务（`run_in_background` shell job）已显示失败，但聊天窗口不发起任何新动作、agent 承诺的"完成后我会告诉你结果"永远不来。修复了完成通知唤起链路上的四个死角：
  - **上下文压缩窗口**：回合结束的 defer 先跑自动压缩再尝试唤起，`isCompressingContext` 把唤起 guard 挡掉后无人补触发；现在压缩结束时会重新 kick（`runContextCompression` defer）。
  - **Provider 槽位竞争**：唤起尝试抢不到并发槽就静默放弃，之后槽位释放只排空用户消息队列；现在 `releaseProviderSlot` 会额外扫描所有持有滞留完成事件的会话并逐个唤起。
  - **媒体任务与后台 subagent 完全没有唤起钩子**：此前只能等下一个用户消息才在回合顶部拉取；现在 `AgentMediaTaskRegistry.onTaskFinished` / `AgentSubagentRegistry.onRunFinished` 与 shell job 走同一条 auto-resume 链路，唤起判定也改为三通道合并计数（`hasPendingBackgroundWakeups`）。
  - **闲置 runtime 淘汰竞态**：带着运行中后台任务/subagent 的会话可能被 idle-runtime 淘汰，任务完成时查不到 runtime、通知丢失（淘汰还会误杀在跑的 subagent）；现在这类会话不参与淘汰，且完成钩子改用 `runtime(for:)` 兜底重新物化。
  - 新增回归测试：subagent 完成钩子/计数、媒体任务终态钩子/计数、重复终态不重复入队。
- 版本号从 **1.129.0-rc26** 提升为 **1.129.0-rc27**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.129.0-rc26 - 2026-07-04

### Fixed
- **Patch 批量操作条移到待审卡片组底部** —— 当多张 Apply 卡片同时待审时，`全部拒绝 / 全部应用` 不再显示在列表顶部，而是放在这一组待审卡片最下面；用户可以先逐项扫完变更，再决定是否批量处理。
- 版本号从 **1.129.0-rc25** 提升为 **1.129.0-rc26**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.129.0-rc25 - 2026-07-04

### Fixed
- **VL 图片说明失败时不再把供应商错误贴进用户消息** —— 文本模型带图时，Image Understanding / VL 请求失败后不再把 `Image description failed...`、HTTP 状态码或 provider 错误正文拼进用户气泡；保留原用户文本继续发送，避免 401、模型名、relay 信息等诊断文本污染对话内容。
- **外部执行器与视觉 QA 的 VL 失败输出改为安静降级** —— Composer 委托 Claude Code / Codex 时，VL 失败不再把错误详情写入委托 prompt；视觉 QA 工具也改为返回通用不可用提示，不暴露底层 provider 错误。
- 版本号从 **1.129.0-rc24** 提升为 **1.129.0-rc25**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness 文档位点。

## 1.129.0-rc24 - 2026-07-03

### Changed
- **移动网关默认改为互联网中继，Go 本地网关降级为可选备选** —— 新增连接方式设置（Settings → 移动网关 → 连接方式），两档：
  - **互联网中继（默认）**：不再启动本地 Go 网关进程。Swift 桌面 peer 直接连中继房间（`wss://j.niuwoai.com/ws/broadcast/{room}`），并由 App 自己用中继设置生成配对二维码（`relay_base_url`/`relay_room`/`relay_token`）；手机凭共享 `relay_token` 加入同一房间，脱离局域网也能用，无需安装/运行任何本地进程。存活状态取桌面 peer 自己的 WebSocket 连接（无 `/mobile/health`）。注销设备为全体轮换：轮换房间 + 令牌后所有已配对设备需重新扫码。
  - **局域网网关（备选，默认关闭）**：仍可一键切回，启动 Go `serve-mobile` 进程走同网 HTTP 配对 + 按设备令牌 + 按设备注销（rc24 前的行为，现改为 opt-in）。
  - 关键事实：Go 网关从不自己连中继，rc24 前它只是在配对负载里「广告」中继坐标；中继总线一直是 Swift peer 直连——所以中继模式可完全不跑 Go 进程。
  - 向后兼容：配对二维码里的 `relay_*` 字段与现有安卓端读取的完全一致；旧安装缺 `transportMode` 字段的一律迁移为中继。
- **会话内容加密说明**：中继模式下内容经中继服务器转发，目前仅传输层加密（WSS），尚未端到端加密。端到端加密设计（需与 `willdeep-android` 仓库协同）见新增文档 [MOBILE_GATEWAY_E2E_ENCRYPTION_DESIGN.md](docs/MOBILE_GATEWAY_E2E_ENCRYPTION_DESIGN.md)。
- 版本号从 **1.129.0-rc23** 提升为 **1.129.0-rc24**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.129.0-rc23 - 2026-07-03

### Fixed
- **移动网关快照不再在主线程反复物化/淘汰/落盘 runtime** —— `mobileGatewayQueuedMessages` / `mobileGatewayRecentMessages` / `mobileGatewayWorktreeChanges` 此前经由 `runtime(for:)` 读状态：每次周期快照都会把所有持久化会话物化成 runtime（磁盘读 + JSON 解码），随即触发 idle runtime 淘汰、对每个被淘汰会话同步 JSONEncoder 编码 + 原子写盘，全部发生在 @MainActor，下一次快照又重来 —— materialize→evict→persist 死循环把 CPU 常驻拖到 20–60%（rc21 采样 `/tmp/WillDeep-29480.sample.txt` 定位）。快照访问器现在只读已存活的 `agentRuntimes`（新增只读 `mobileGatewayLiveRuntimes`），零副作用；手机端打开会话仍走命令路径按需物化单个会话。新增防回归测试断言快照访问器不改变 `agentRuntimes`。

### Changed
- 版本号从 **1.129.0-rc22** 提升为 **1.129.0-rc23**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.129.0-rc22 - 2026-07-03

### Added
- **workspace 级记忆可视与隔离补强** —— Global/Project 记忆隔离链路原本就在（project 记忆按 workspace 指纹只在对应项目注入），本次补齐可用性短板：
  - 记忆记录新增可读 `projectPath`；设置 → 记忆列表为 project 记忆显示项目名 tag 与完整路径行，当前 workspace 的记忆带「当前项目」标识；
  - 记忆列表新增「全部 / 仅全局 / 当前项目」scope 过滤器；
  - 只有指纹的老记录在对应 workspace 打开时自动回填可读路径（retrieve 和设置页 onAppear 两处触发）；检索匹配增加路径兜底，指纹方案变化不再导致 project 记忆失联；编辑重存为 Project 可把搬家后的孤儿记忆一键重绑到当前 workspace；
  - `add_memory` 不传 scope 时不再一律默认 global，改为按内容启发式推断（提到仓库/项目/版本/changelog/测试等且有 workspace → project），工具描述同步引导模型显式传 scope。

### Changed
- 版本号从 **1.129.0-rc21** 提升为 **1.129.0-rc22**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.129.0-rc21 - 2026-07-03

### Added
- **edit_file 精确替换编辑工具（对齐 Claude Code）** —— Agent 编辑既有文件的首选原语不再是模型手写 unified diff，改为 `edit_file(path, old_string, new_string, replace_all)` 精确字符串替换：宿主在当前内容中定位唯一匹配、自行合成上下文行与文件逐字节一致的 diff，再走既有 patch 卡片 / Goal & workspace 自动应用 / undo / worktree 跟踪管线，合成后先做 parse→apply 往返自检。old_string 找不到、不唯一、与 new_string 相同时以可自纠的工具错误回传模型（附出现次数与修正建议）。这从根源上消除「patch 的某段与当前文件内容不匹配」的高频 Apply 失败。

### Changed
- **apply_patch 降级为 legacy fallback** —— 工具描述与 system prompt（stable prefix bump 到 v6）全面改为引导 edit_file；仅当 edit_file 无法表达变更时才允许手写 diff。create_file 指引同步更新。
- **edit_file 读取与应用同源** —— 新增 `editableContentProvider`：edit_file 匹配 old_string 时优先取编辑器 tab 的未保存缓冲（与 patch 应用侧 `editableContent` 同一来源），tab 与磁盘不一致不再导致必然失配。

### Fixed
- **聊天代码块超宽自动换行** —— 聊天里 ``` 代码块的长行（docker 命令、URL 等）此前按 `.byClipping` 直接在卡片边缘裁掉，内容不可读；现在改为按字符自动换行。原「裁剪 + 代码块内横向滚动」机制（scroll-wheel 平移 glyph）随之整体移除；表格仍保持不换行以保住等宽列对齐，宽表格继续走表格详情窗口。
- **patch 解析器 hunk 内伪文件头误判** —— hunk 内以 `-`/`+` 开头、内容恰为 `-- …`/`++ …` 的行（如删除 SQL/Lua 注释行）会序列化成 `--- …`/`+++ …`，此前被误当成文件头导致解析错乱；现在仅在无打开 hunk 或目标形如 `a/`、`b/`、`/dev/null` 时才按头处理。
- 版本号从 **1.129.0-rc20** 提升为 **1.129.0-rc21**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.129.0-rc20 - 2026-07-03

### Fixed
- **Apply 卡片点击后立即收起** —— Agent patch proposal 列表现在只渲染仍待处理的 `.pending` 卡片；用户点击 Apply 或 Reject 后，卡片会从聊天区收起，避免失败态卡片继续露出灰色按钮、让用户误以为还能重复点击。失败原因仍保留在 proposal 状态里供诊断、持久化和移动端状态使用。
- **Agent 不再把本地命令误发到已 SSH 的侧边栏终端** —— system prompt 现在要求把右侧可见终端当作独立的会话级机器上下文：使用 `terminal_send_command` 前要确认 active tab 是本地 macOS shell 还是 SSH 到某台服务器，并记录 host/user/directory；当终端已经在远端服务器里而命令本应本地执行时，必须改用 `run_command` 或先确认。

### Changed
- **终端工具说明补强主机边界** —— `terminal_snapshot` 明确用于识别当前终端是否本地/SSH，`terminal_send_command` 明确禁止把 local-intended command 发进 SSH server tab。
- 版本号从 **1.129.0-rc19** 提升为 **1.129.0-rc20**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.129.0-rc19 - 2026-07-03

### Added
- **Goal 卡片吸附到 composer 上方并可编辑** —— Goal 模式已有目标时，composer 上方显示紧凑目标卡片，展示目标摘要、运行耗时和清单进度；点击卡片或铅笔按钮可直接打开 Goal 编辑器。

### Fixed
- **修改 Goal 后后续执行立即按新目标走** —— 用户在 Agent 正在响应时保存新 Goal，会自动排入一条 follow-up，让当前 turn 结束后的下一轮带着新 Goal 继续；同时用运行期修订时间戳避免旧回复里的 `goal-check` 误勾新清单。

### Changed
- 版本号从 **1.129.0-rc18** 提升为 **1.129.0-rc19**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness 文档位点。

## 1.129.0-rc18 - 2026-07-03

### Fixed
- **终端录制密码询问回到聊天区** —— `terminal_create_shortcut` 创建带 `protected_placeholder` 的录制后，不再自动把用户带到右侧 Terminal 侧栏填写密码；聊天区工具卡直接显示本地 SecureField 密码询问卡，保存后写入本机终端加密 vault，并折叠为“用户输了密码”。右侧 Terminal 侧栏不再显示密码输入卡，避免同一件事在两个地方问。

### Changed
- 版本号从 **1.129.0-rc17** 提升为 **1.129.0-rc18**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.129.0-rc17 - 2026-07-03

### Fixed
- **Agent 侧栏切换不再卸载 Terminal** —— 右侧侧栏第一次打开 Terminal 后会记住并常驻终端面板；切换到 Diff / Files / Widget / 媒体任务等其它侧栏时，Terminal 只隐藏并关闭命中测试，不再触发 SwiftUI 分支销毁，已有 PTY 进程、滚屏和输入状态继续保留。

### Changed
- 版本号从 **1.129.0-rc16** 提升为 **1.129.0-rc17**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.129.0-rc16 - 2026-07-03

### Fixed
- **终端录制密码输入统一放到右侧 Terminal 侧栏** —— `terminal_create_shortcut` 成功后仍自动打开终端侧栏；聊天区工具卡不再显示 SecureField 密码输入，只保留“打开终端侧栏”的本地提示，真实密码统一在侧栏顶部卡片填写并写入本机终端加密 vault，避免用户误以为需要把密码发进聊天。

### Changed
- 版本号从 **1.129.0-rc15** 提升为 **1.129.0-rc16**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.129.0-rc15 - 2026-07-03

### Fixed
- **Agent 统计面板恢复历史模型用量数据** —— 会话启动轻量索引仍不常驻完整 `messages`，但新增统计专用 usage snapshot，从持久化 session JSON 解码角色、时间、token、模型、图片数量和工具参数长度等轻量字段；概览、热力图、模型用量和时间范围过滤改读该快照，避免“会话数还在但消息、令牌、活跃天数全归零”。

### Changed
- 版本号从 **1.129.0-rc14** 提升为 **1.129.0-rc15**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.129.0-rc14 - 2026-07-03

### Fixed
- **终端录制带密码占位时不再“灰着不能播还不知道去哪填”** —— `terminal_create_shortcut` 创建录制后会自动打开右侧 Terminal 侧栏；带 `protected_placeholder` 的录制会在终端上方显示本地 SecureField 密码卡片，保存后写入本机终端加密 vault，回放按钮随即恢复可用。聊天区工具卡只提示打开终端侧栏，不再提供密码输入框；该侧栏卡片不会卸载当前 SwiftTerm/PTY 终端，填写密码时已有终端进程、滚屏和输入状态继续保留。
- **终端录制 JSON 可见事件改成人可读文本** —— 可见输入保存为 `text` 字段，不再在编辑器里展示 `115, 115, 104...` 数字串；`text` 支持 `\n`、`\t`、`\r`、`\e`、`\b`、`\xHH` 等转义，旧 `bytes` 数组格式仍可读取。

### Changed
- 版本号从 **1.129.0-rc13** 提升为 **1.129.0-rc14**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness 文档位点。

## 1.129.0-rc13 - 2026-07-03

### Changed
- **本地图片理解默认模型明确为 VL** —— 本地辅助模型设置里的“图片理解模型”默认值从旧的 `qwen3.5-4b-q4_k_m` 自动迁移为 `qwen3.5-4b-vl-q4_k_m`，Summary 模型继续默认使用 `qwen3.5-4b-q4_k_m`；Provider 列表里的 `Ollama / Local OpenAI` 默认模型也改为 VL 名称，避免设置页看起来像在拿纯文本模型做图片识别。
- **模型下载区新增本地必要文件查找** —— 设置页“模型下载”新增“查找本地文件”，通过 `/usr/bin/find` 按 `Qwen3.5-4B.Q4_K_M.gguf` 与 `mmproj-BF16.gguf` 文件名搜索常见本地目录，并根据文件大小与推荐包预估大小给出“大小匹配 / 大小接近 / 大小不像”的候选判断。
- 版本号从 **1.129.0-rc12** 提升为 **1.129.0-rc13**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.129.0-rc12 - 2026-07-03

### Changed
- **本地 provider system prompt 增加语言偏好** —— 当请求走内置 `Ollama / Local OpenAI`，或自定义 OpenAI-compatible endpoint 指向 `localhost` / `127.0.0.1` / `::1` 时，system prompt 会追加“请优先使用当前系统首选语言回答；若用户最近明确使用其他语言则跟随用户语言”，并保留代码、命令、路径、API 名称和模型名原文。普通远端 OpenAI / Claude / some.im provider 不追加该提示，避免改变远端请求行为。
- 版本号从 **1.129.0-rc11** 提升为 **1.129.0-rc12**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.129.0-rc11 - 2026-07-03

### Added
- **本地模型辅助加速（Ollama / LM Studio / llama.cpp server）** —— Agent provider 清单新增 `Ollama / Local OpenAI`，支持无 API Key 的本机 OpenAI-compatible endpoint。Settings → AI Providers 新增「本地模型加速」区，可配置本地 endpoint、图片理解模型、summary 模型，并分别控制“图片识别先用本地”和“标题 / 上下文压缩先用本地”。图片理解、会话标题和上下文压缩会按“本地候选 → 远端 provider”顺序尝试，本地服务不可用或返回空结果时自动 fallback，不影响用户继续用 OpenAI / Claude / some.im 做主生产对话。
- **本地 VL 模型后台下载入口** —— 设置页新增推荐模型包下载状态，当前只下载 `Qwen3.5-4B.Q4_K_M.gguf` 和 `mmproj-BF16.gguf` 两个必要文件，跳过同仓库其他量化版本；下载在后台执行，可查看当前文件、总体进度、速度、保存目录并随时取消。下载完成后仍由 Ollama、LM Studio 或 llama.cpp server 加载模型并暴露 OpenAI-compatible endpoint，WillDeep 暂不直接在进程内加载 GGUF。

### Changed
- 版本号从 **1.129.0-rc10** 提升为 **1.129.0-rc11**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness 文档位点。

## 1.129.0-rc10 - 2026-07-03

### Fixed
- **Agent 左侧历史会话列表恢复显示** —— 1.129.0-rc3 为降低启动内存，把会话启动加载改成只读取轻量索引，`messages` 不再常驻；但侧边栏“隐藏空 New Chat”逻辑仍用 `session.messages` 判断是否有用户消息，导致历史会话索引被误判为空会话并全部隐藏，只剩当前新对话。现在轻量索引会额外用只解 `role` 的消息索引记录“是否存在用户消息”，侧边栏显示和空会话清理都使用该标记，恢复旧会话列表，同时不回退到完整 transcript 常驻内存。

### Changed
- 版本号从 **1.129.0-rc9** 提升为 **1.129.0-rc10**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.129.0-rc9 - 2026-07-03

### Fixed
- **纯文本模型不再收到历史图片的 `image_url`（HTTP 400）** —— some.im 这类多模型中转的 provider 级 `supportsImageInput` 为 true，但用户实际选的可能是纯文本模型（如 `deepseek-v4-flash`）；长会话历史里只要有一张图（早前贴图、工具截图），编码请求时就会生成 `image_url` content part，被 API 以 `unknown variant image_url, expected text` 400 掉整个请求。现在 `AgentConfiguration.supportsImageInput` 在 provider 开关之上叠加模型级判断（`modelAcceptsImageInput`）：DeepSeek 文本/代码系（非 `-vl`）与 `someim-auto*` 判为不支持图片，历史图片自动替换为「[N image attachment(s) omitted ...]」文字占位，最新消息图片继续走视觉子模型转文字描述；未知模型保持支持图片，不误伤多模态自定义模型。
- **错误详情卡片复制按钮命中区过小、无反馈** —— Request/Input Messages/Request Body/Response 各区右上角的复制按钮此前是 10pt 裸 SF Symbol，可点区域只有十几个点，点上去经常"没反应"；且复制成功也无任何提示。现在按钮补了 padding + contentShape 撑大命中区，点击后 icon 变绿色 ✓ 并显示「已复制」1.5 秒，复制内容仍为该区完整文本（不受界面截断影响）。

### Changed
- 版本号从 **1.129.0-rc8** 提升为 **1.129.0-rc9**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.129.0-rc8 - 2026-07-03

### Fixed
- **patch 卡片「已应用」识别，不再把已落地的改动误报为失败（1.129.0-rc8）** —— 当一个 patch 卡片对应的改动其实已经落地（Goal / workspace-access 前置自动应用、另一个会话改了同一 working tree、或同一改动裂成的重复卡片其孪生卡已应用），点「应用」时旧逻辑会因 hunk 的 context 对不上而抛出「patch 的某段与当前文件内容不匹配」并标为失败，让用户面对一张无法处理的孤儿卡。现在 `applyAgentPatch` 失配（`hunkDidNotMatch`）后会调用 `AgentPatchApplier.isAlreadyApplied` 判断文件是否已是该 patch 的目标状态：若每个 hunk 的目标内容（context + 新增行）都已存在，则把卡片标为 `.applied` 并显示「改动已存在，无需重复应用」，卡片随即从待处理列表隐藏；只有 context 与目标结果都对不上的真失败才继续报错。手动 Apply、批量自动应用、enqueue 直接落盘三条路径统一走新的 `resolveAgentPatchApplication`，行为一致。判断保持保守：纯删除 hunk（目标内容为空）无法凭存在性确认，仍按真失败处理。

### Changed
- 版本号从 **1.129.0-rc7** 提升为 **1.129.0-rc8**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.129.0-rc7 - 2026-07-03

### Fixed
- **Xcode 全量测试不再被文件加载错误弹窗卡住（1.129.0-rc7）** —— `AppState.applyFileLoadResult` 在 XCTest 环境下跳过 `NSAlert.runModal()`，仍执行失败回退逻辑，避免测试宿主因为用户本机会话中的大文件或不可读文件弹出模态窗口后无限等待。
- **性能修复验证链路继续收口（1.129.0-rc7）** —— 保留 rc6 的 provider library Keychain 懒加载、测试 Keychain 隔离和 Voice smoke opt-in，并补齐文件加载错误路径的非交互测试保护，减少开发机状态对全量 `XeditTests` 的干扰。

### Changed
- 版本号从 **1.129.0-rc6** 提升为 **1.129.0-rc7**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.129.0-rc6 - 2026-07-03

### Fixed
- **Provider library 启动不再批量解密 Keychain（1.129.0-rc6）** —— `AgentSettingsStore.loadProviderLibrary()` 只 materialize active provider 的 API key，非 active entry 保留为未加载状态；切换 active 或在 Settings 选中条目时再按需读取对应 Keychain row，避免启动时逐条 `SecItemCopyMatching` 阻塞主线程。
- **未加载 provider key 不会被保存流程误删（1.129.0-rc6）** —— `AgentProviderEntry` 增加运行时 `apiKeyLoaded` 标记，`saveProviderLibrary` 只同步已加载的 secret；新增单测覆盖“半加载 library 保存后 inactive key 仍可懒加载回来”的回归场景。
- **XCTest 启动不再访问开发机真实 Keychain（1.129.0-rc6）** —— `AgentSettingsStore` 在 XCTest 环境下使用进程内 Keychain storage，与已有 sandbox 测试隔离对齐，修复完整 Xcode 测试宿主在建立 XCTest connection 前卡在 Keychain 解密的问题。
- **Voice smoke 测试改为显式 opt-in（1.129.0-rc6）** —— `VoiceSmokeTests` 不再默认扫描 `~/Downloads` 里的本地音频文件，避免完整单测在开发机文件系统元数据读取或长音频 preflight 上卡住；需要手动转录 smoke 时设置 `WILLDEEP_VOICE_SMOKE=1`。

### Changed
- 版本号从 **1.129.0-rc5** 提升为 **1.129.0-rc6**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.129.0-rc5 - 2026-07-03

### Fixed
- **Git / 文件状态轮询 timer 不再在 body 内重建（1.129.0-rc5）** —— editor 主视图的 10s 状态刷新 timer publisher 提升为稳定静态实例，避免 SwiftUI body 重算时反复构造新的 autoconnect timer；配合前序 git 状态同值保护，空闲刷新不再因为 publisher 重建和相同结果发布放大全局 UI 更新。

### Changed
- 版本号从 **1.129.0-rc4** 提升为 **1.129.0-rc5**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.129.0-rc4 - 2026-07-03

### Fixed
- **编辑器行号尺大文件首行定位改为缓存二分（1.129.0-rc4）** —— gutter 计算首个可见行号时不再每次从文件头逐字符扫描到可见区，而是按文本长度缓存行起点表并二分定位；大文件底部滚动和重绘时避免每帧重复扫完整前缀。
- **Mobile Gateway / Dock badge 降低全局通知放大（1.129.0-rc4）** —— Mobile Gateway 快照调度改为 400ms 窗口节流，持续流式期间不会无限推迟也不会每个 `objectWillChange` 重建任务；Dock badge 不再订阅整个 `AppState.objectWillChange`，改为会话列表变更 + runtime 局部订阅驱动。
- **远端 daemon 前台命令轮询降频（1.129.0-rc4）** —— daemon runtime 的前台命令状态轮询从 250ms 调整为 1s，避免长命令期间每个任务持续 4 req/s 压远端服务和本地 async 调度。

### Changed
- 版本号从 **1.129.0-rc3** 提升为 **1.129.0-rc4**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.129.0-rc3 - 2026-07-03

### Fixed
- **MCP stdio 工具不再每次调用冷启动（1.129.0-rc3）** —— stdio MCP server 现在按配置复用已初始化连接，后续 `listTools` / `callTool` 走同一进程和 JSON-RPC id 序列，避免 `npx/node` 类 server 每次工具调用都启动、initialize、退出；阻塞式 stdio 等待移到每个连接的专用串行队列，减少挤占 Swift cooperative pool 的风险。
- **Agent 会话启动内存不再常驻完整历史（1.129.0-rc3）** —— `AgentSessionStore.loadAll()` 改为加载轻量会话索引，跳过 `messages` 和 `contextSummary`，打开具体会话时再从磁盘物化完整 transcript；置顶、归档、重命名和空会话清理都加物化保护，避免把轻量索引误当空消息写回。
- **编辑器括号匹配限制扫描窗口（1.129.0-rc3）** —— 光标停在未配对括号附近时，匹配高亮最多扫描 120000 个 UTF-16 code unit，不再从当前位置一路扫到大文件开头或结尾。

### Changed
- 版本号从 **1.129.0-rc2** 提升为 **1.129.0-rc3**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.129.0-rc2 - 2026-07-02

### Fixed
- **Agent 与 Editor 高 CPU / 高内存热路径收敛（1.129.0-rc2）** —— Agent 工具参数流式更新改用滚动指纹和节流发布，避免碎片化 JSON 参数在流式过程中反复拼接比较并触发高频 UI invalidation；Editor 的 LSP 文档同步新增输入防抖，选区与 git 状态等 `@Published` 状态增加同值保护，降低每键输入和空闲轮询造成的全局刷新。
- **大文件编辑与媒体预览内存占用下降（1.129.0-rc2）** —— Scope guide 与 changed-line cache 避免大文件 O(n²) / 全文 hash 热路径；Agent 图片、媒体缩略图改为后台降采样并缓存，侧栏 diff / preview 避免在 SwiftUI body 中重复重算，远端媒体 artifact 下载改为文件流落盘而不是整包读入内存。
- **异步进程等待不再阻塞协程线程池（1.129.0-rc2）** —— Shell 前台命令与视频 workflow 中的 ffmpeg / ffprobe 等进程等待改为 termination handler + continuation，减少长时间外部命令挤占 Swift concurrency worker 的风险；非活跃 Agent runtime 会按最近使用保留并持久化驱逐，降低多会话常驻对象压力。

### Changed
- 版本号从 **1.129.0-rc1** 提升为 **1.129.0-rc2**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.129.0-rc1 - 2026-07-02

### Added
- **Agent Composer 空输入提示（1.129.0-rc1）** —— composer 在用户尚未输入时显示多语言 placeholder，提示 `/` 唤起命令、`@` 引用文件/工作区、`$` 挂载技能与插件；开始输入、粘贴文本、选择历史消息或插入触发 token 后提示会自动消失。
- **内置 SwiftUI 卡死诊断技能（1.129.0-rc1）** —— `BundledSkills` 新增 `swiftui-hang-diagnose`，WillDeep 的技能目录、设置页与 `$` skill picker 可直接发现并读取该技能；技能内置 `sample` / `spindump` 主线程采样流程和 SwiftUI/AppKit/UIKit 卡死模式库，用于诊断原生 Mac/iOS App 转圈、Beachball、CPU 跑满和主线程死锁。

### Changed
- 版本号从 **1.128.0-rc6** 提升为 **1.129.0-rc1**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.128.0-rc6 - 2026-07-02

### Fixed
- **CI artifact 上传配额不再拖红整个 run** —— GitHub Actions artifact 存储被约 300 个历史测试报告（13.3GB，主要是每次约 100MB 的 xcresult）占满后，`Upload test artifacts` 步骤失败会把测试全绿的 run 标成 failure。已清理旧 artifact（保留最近 10 个），上传步骤加 `continue-on-error: true`（测试结论以前置步骤为准，报告仍写入 job summary），retention 从 14 天缩短到 7 天减缓积累。

### Changed
- 版本号从 **1.128.0-rc5** 提升为 **1.128.0-rc6**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.128.0-rc5 - 2026-07-02

### Fixed
- **修复 CI 上 some.im provider 同步测试断言过期** —— `syncSomeIMProvider` 自 1.127.0-rc1 起默认文本模型改为 `someim-auto-flash`，但 `syncingSomeIMProviderCreatesActiveChatProvider` 测试仍断言旧的 `deepseek-v4-flash/pro`，导致 main 上 GitHub Actions 失败。测试改为断言 `SomeIMIntegrationSettings.defaultTextModel`，与实现保持单一事实来源。

### Changed
- 版本号从 **1.128.0-rc4** 提升为 **1.128.0-rc5**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.128.0-rc4 - 2026-07-02

### Fixed
- **终端录制受保护输入按“回车”成条计数** —— 手动录制终端会话时，echo-off 隐藏输入（密码）此前按字符逐个生成受保护事件：一条 19 字符的密码会被记成 19 次“受保护输入”。现在连续按键合并到一个待定缓冲区，直到用户按回车（CR/LF）或 echo 恢复才落成一个受保护事件，做到“一条密码 = 一次受保护输入”。回车键本身作为普通提交事件保留，回放仍能正常提交密码行；录制中途结束时未提交的密码行也会在 `finish` 时补齐，不再丢失。

### Changed
- 版本号从 **1.128.0-rc3** 提升为 **1.128.0-rc4**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.128.0-rc3 - 2026-07-02

### Added
- **口述录制密码占位本地填写（1.128.0-rc3）** —— `terminal_create_shortcut` 支持 `protected_placeholder` 事件，Agent 只生成“密码 1 / 密码 2”这类占位；工具成功后聊天区工具卡片会像 `ask_user` 一样显示本地 SecureField，让用户填写真实密码并直接写入终端录制 vault。
- 未填写密码占位的终端录制禁止回放，侧边栏 tooltip 会提示待填写数量，避免用户误以为录制已完整可用。

### Security
- 真实密码不作为 tool 参数、不进入聊天消息、不回传模型、不写入录制 JSON；本地提交只调用 App 内部方法把值写入 AES-GCM vault。
- `terminal_create_shortcut` 继续拒绝 `password` / `secret` / `protected_text` 等明文字段，只允许无密文的 `protected_placeholder` 标签。

### Changed
- 版本号从 **1.128.0-rc2** 提升为 **1.128.0-rc3**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.128.0-rc2 - 2026-07-02

### Fixed
- **终端录制受保护输入不再反复触发 Keychain 解锁（1.128.0-rc2）** —— 新录制的隐藏输入改为写入本地 AES-GCM 加密 vault，回放时优先从 vault 读取，避免一个录制里多个密码片段逐条弹系统密码。
- 旧版终端录制的 Keychain 引用仍保留兼容 fallback：首次成功读取后会迁移写入本地 vault，后续回放不再依赖 Keychain 读取。

### Security
- 终端录制受保护输入 vault 文件和密钥文件落在本机 Application Support 录制目录，并收紧为当前用户可读写；录制 JSON 仍不保存明文密码。

### Changed
- 版本号从 **1.128.0-rc1** 提升为 **1.128.0-rc2**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.128.0-rc1 - 2026-07-02

### Added
- **口述生成终端录制（1.128.0-rc1）** —— 新增 `terminal_create_shortcut` Agent 工具，可把用户口述的终端操作转换为可回放的终端录制捷径；事件支持命令、可见文本、控制键和等待时间，生成前仍需用户审批。

### Security
- `terminal_create_shortcut` 拒绝生成 password / protected / echo-off 隐藏输入事件，避免把口述中的敏感内容写入可回放录制；密码类步骤仍建议由用户手动录制受保护输入。

### Changed
- 版本号从 **1.127.0-rc1** 提升为 **1.128.0-rc1**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.127.0-rc1 - 2026-07-02

### Added
- **终端录制回放状态可视化（1.127.0-rc1）** —— 终端录制捷径现在会在列表中展示录制总耗时；回放执行时高亮当前捷径，显示剩余时间、当前事件进度和预计结束时间，结束或中断后保留状态提示。
- **some.im 邮箱验证码自动接入（1.127.0-rc1）** —— Onboarding 与 Settings 支持填写邮箱、收验证码、自动注册/登录 some.im 并保存 app 专用令牌；默认文本模型切到 `someim-auto-flash`，侧边栏左下角显示按 `1 USD = 100000 credits` 换算后的剩余 credits，并可一键打开自动登录后的 some.im 后台。

### Changed
- 版本号从 **1.126.0-rc1** 提升为 **1.127.0-rc1**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.126.0-rc1 - 2026-07-02

### Added
- **AI 辅助终端录制编辑（1.126.0-rc1）** —— 新增 `terminal_list_shortcuts` 与 `terminal_edit_shortcut` Agent 工具，AI 可列出终端录制事件结构，并在用户批准后修改标题、等待时间、删除事件、替换或重写可见输入文本。

### Fixed
- 终端录制保存时会把同一录制中重复的 echo-off 隐藏输入合并到同一个本地凭据引用，回放时同一密码只需读取一次；`AgentCredentialStore.save` 不再为了比较旧值而先读取 Keychain，减少保存或回放录制时反复要求解锁钥匙串的情况。
- 终端录制编辑工具不会向模型暴露隐藏输入明文，也拒绝对受保护事件执行可见文本替换或重写。
- 版本号从 **1.125.0-rc1** 提升为 **1.126.0-rc1**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness 文档位点。

## 1.125.0-rc1 - 2026-07-02

### Added
- **Agent Composer 触发符语义统一（1.125.0-rc1）** —— Agent composer 新增 `$` Skill picker，技能 chip 也改为 `$skill` 展示；`@` picker 只保留 workspace 与项目文件引用，`/` 继续负责命令和 workflow，和通用软件里的“命令 / 引用 / 能力包”心智保持一致。

### Changed
- `@` picker 的搜索提示和空状态不再提及 skills，新增 `$` 技能搜索提示与空状态本地化文案。
- 版本号从 **1.124.0-rc1** 提升为 **1.125.0-rc1**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness 文档位点。

## 1.124.0-rc1 - 2026-07-01

### Changed
- **Mobile Gateway 默认公网中继（1.124.0-rc1）** —— Mac 端 Mobile Gateway 默认使用 `https://j.niuwoai.com` 作为 relay base URL，用户不再需要手动填写中继站点域名。
- **安装级自动 room** —— relay room 从固定 `willdeep-mobile` 改为首次安装后自动生成并持久化的 `willdeep-<uuid>`；已保存旧默认 room 的配置会自动迁移到安装级 room，避免不同 Mac 共用默认房间名。
- 版本号从 **1.123.0-rc1** 提升为 **1.124.0-rc1**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness 文档位点。

## 1.123.0-rc1 - 2026-07-01

### Added
- **Mobile Gateway Public Relay（1.123.0-rc1）** —— Mobile Gateway 配对二维码现在可携带公网 relay 信息，Mac desktop peer 可连接 `cdnproxy` 的 `/ws/broadcast/*` 房间，Android 扫码后可直接通过公网 WebSocket 发送 `message.send`、`session.list`、审批/补丁决策等既有 Mobile Gateway 命令，不再必须与 Mac 处于同一局域网。
- `willdeep-agent serve-mobile` 新增 `--relay-base-url`、`--relay-room`、`--relay-token-file`，relay token 通过 0600 文件传入，避免出现在进程命令行；Swift coordinator 会把 relay 信息写入二维码 payload，并用同一 relay 房间连接桌面端业务桥。
- 版本号从 **1.122.0-rc1** 提升为 **1.123.0-rc1**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness 文档位点。

## 1.122.0-rc1 - 2026-07-01

### Added
- **Editor LSP Authoritative Workspace Symbol Misses（1.122.0-rc1）** —— Go / TypeScript / JavaScript / Swift 的符号跳转查询现在会把 LSP `workspace/symbol` 成功返回的空结果视为权威未命中，不再继续过滤当前文件 outline 来补一个本地猜测结果。
- `SymbolJump` 现在区分 workspace symbol 的 `loading` / `available` / `failed` 状态；LSP 正常响应时显示 workspace symbol 结果（即使为空），只有 LSP 未就绪或失败时才回退当前文件大纲过滤。
- 新增 `EditorLanguageServiceTests` 覆盖空 workspace symbol 结果从 LSP manager 原样返回，并新增 `EditorWorkflowTests` 覆盖第一批语言 workspace symbol available 空结果权威、failed 才 fallback 的策略。版本号从 **1.121.0-rc1** 提升为 **1.122.0-rc1**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.121.0-rc1 - 2026-07-01

### Added
- **Editor LSP Authoritative Definition Misses（1.121.0-rc1）** —— Go / TypeScript / JavaScript / Swift 的 Go to Definition 现在会把 LSP 成功返回的空 definition 结果视为权威“未找到定义”，不再继续用正则 resolver 补跳到一个看似匹配但可能错误的位置。
- 语言服务器缺失、启动失败或请求异常时仍保留旧正则 fallback，保证未安装 LSP 的环境还能基础跳转；但只要 LSP 正常响应，就由 LSP 决定是否存在定义。
- 新增 `EditorLanguageServiceTests` 覆盖空 definition 结果从 LSP manager 原样返回，以及第一批语言定义 fallback policy 的空结果权威语义。版本号从 **1.120.0-rc1** 提升为 **1.121.0-rc1**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.120.0-rc1 - 2026-07-01

### Added
- **Editor LSP Authoritative Folding（1.120.0-rc1）** —— Go / TypeScript / JavaScript / Swift 的折叠/作用域引导线现在会区分 LSP folding range 的 `loading` / `available` / `failed` 状态；当语言服务器已返回 `textDocument/foldingRange` 时会完全信任 LSP 结果，即使为空也不再用本地括号/缩进启发式补折叠线。
- AppKit editor 的 folding cache 现在把“LSP folding 是否权威”纳入缓存 key，避免从 fallback 切到 LSP 空结果后继续显示旧的本地 scope guides；语言服务器失败或未就绪时仍保留旧本地 fallback。
- 新增 `EditorWorkflowTests` 覆盖第一批语言 LSP folding available 时不执行本地 fallback、failed 时才 fallback 的策略。版本号从 **1.119.0-rc1** 提升为 **1.120.0-rc1**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.119.0-rc1 - 2026-07-01

### Added
- **Editor LSP Authoritative Outline（1.119.0-rc1）** —— Go / TypeScript / JavaScript / Swift 的结构面板与符号跳转现在会区分 LSP 大纲的 `loading` / `available` / `failed` 状态；当语言服务器已返回结果时会完全信任 `textDocument/documentSymbol`，即使结果为空也不再用正则 outline 补一个看似合理但可能错误的结构。
- 结构面板在 LSP 大纲已可用时不再启动后台正则提取，只有语言服务器未就绪或失败时才使用旧正则 fallback，减少第一批 IDE 语言继续被正则驱动的情况。
- 新增 `EditorWorkflowTests` 覆盖第一批语言 LSP 大纲 available 时不执行 fallback、failed 时才 fallback 的策略。版本号从 **1.118.0-rc1** 提升为 **1.119.0-rc1**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.118.0-rc1 - 2026-07-01

### Added
- **Editor LSP Workspace Resource Operations（1.118.0-rc1）** —— Go / TypeScript / JavaScript / Swift 的 LSP `WorkspaceEdit.documentChanges` 现在会保留并应用 `create` / `rename` / `delete` 文件资源操作，不再把 server 返回的资源变更吞掉。
- 资源操作应用沿用当前 workspace 安全边界：所有目标路径必须位于 root 内，未保存 tab 会阻止覆盖、移动或删除；成功创建、重命名或删除后会发送对应 `workspace/didChangeWatchedFiles` `created` / `deleted` 事件，帮助语言服务器刷新项目结构索引。
- 新增 `EditorLanguageServiceTests` 覆盖 resource operation 解码与 applier 映射。版本号从 **1.117.0-rc1** 提升为 **1.118.0-rc1**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.117.0-rc1 - 2026-07-01

### Added
- **Editor LSP Workspace Edit Refresh（1.117.0-rc1）** —— Go / TypeScript / JavaScript / Swift 的 rename、quick fix 和 server `workspace/applyEdit` 在成功改写当前文件、已打开 tab 或磁盘文件后，会把实际变更文件逐个发送 `workspace/didChangeWatchedFiles` `changed` 事件，帮助语言服务器刷新跨文件索引和诊断。
- **Editor LSP Semantic Token Polish（1.117.0-rc1）** —— 语义高亮现在识别 LSP 常见的 `variable`、`parameter` 和 `label` token；`variable` 可覆盖正则误判的类型名颜色并保留 declaration/definition 加粗，`parameter` 使用独立颜色，Go / Swift / TypeScript / JavaScript 的语义 token 呈现更接近 IDE。
- 新增 `EditorLanguageServiceTests` 覆盖变量、参数语义 token 覆盖正则高亮的行为。版本号从 **1.116.0-rc1** 提升为 **1.117.0-rc1**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.116.0-rc1 - 2026-07-01

### Added
- **Editor LSP Watched Files（1.116.0-rc1）** —— Go / TypeScript / JavaScript / Swift 的 editor 会在保存、新建文件、新建文件夹和创建缺失外部文件成功后发送 `workspace/didChangeWatchedFiles`，帮助 gopls / typescript-language-server / sourcekit-lsp 刷新项目索引。
- `LanguageServerClient` 现在声明 workspace `didChangeWatchedFiles` client capability，并支持 `created` / `changed` / `deleted` file event payload；`EditorLanguageServiceManager` 会把第一批语言文件精确投递给对应 session，把配置文件或文件夹变更投递给当前 root 覆盖路径的已有 session，不无端启动无关 server。
- 新增 `EditorLanguageServiceTests` 覆盖 client 级 watched-files notification payload，以及 manager 对 `package.json` 这类非源文件变更通知已有 workspace session 的路由。版本号从 **1.115.0-rc1** 提升为 **1.116.0-rc1**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.115.0-rc1 - 2026-07-01

### Added
- **Voice 转录语言设置（1.115.0-rc1）** —— Settings → Voice 新增“转录语言”选择，默认跟随系统语言，也可强制使用自动检测、中文、英文、粤语、日语或韩语，方便日本市场和多语言语音输入测试。
- Fn push-to-talk 与 composer 麦克风按钮现在会读取该偏好后再调用 SenseVoice ONNX 推理；日语系统会默认映射到 SenseVoice `ja`，手动选择“日语”时也会固定走日语识别。
- 新增语音语言偏好解析测试，覆盖日语、中文、英文、韩语和未知系统语言回退。版本号从 **1.114.0-rc17** 提升为 **1.115.0-rc1**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness 文档位点。

## 1.114.0-rc17 - 2026-07-01

### Added
- **Editor LSP Will Save Wait Until（1.114.0-rc17）** —— Go / TypeScript / JavaScript / Swift 保存前会在 server 声明 `textDocumentSync.willSaveWaitUntil` 时请求 `textDocument/willSaveWaitUntil`，把语言服务器返回的保存前 edits 应用到即将写盘的内容，再继续原有 `textDocument/didSave` 通知。
- 保存流程会先执行本地 `contentForSave` 归一化，再用短超时等待 LSP 保存前 edits，最后再次按本地保存规则归一化；LSP 失败或超时时回退原内容，不阻断保存。
- 新增 `EditorLanguageServiceTests` 覆盖 client 级 `willSaveWaitUntil` 请求参数、manager 保存前同步顺序和 fake server edits。版本号从 **1.114.0-rc16** 提升为 **1.114.0-rc17**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.114.0-rc16 - 2026-07-01

### Added
- **Editor LSP Range Formatting（1.114.0-rc16）** —— Go / TypeScript / JavaScript / Swift 的 editor 右键菜单在有选区时新增 Format Selection，通过 `textDocument/rangeFormatting` 只格式化当前选区，不再只能对整篇文档发 `textDocument/formatting`。
- `LanguageServerClient` 现在声明 `textDocument.rangeFormatting` capability、读取 `documentRangeFormattingProvider`，并在 server 支持时发送 `LSPDocumentRangeFormattingParams`；AppState 复用现有 `EditorTextEditApplier` 安全应用 edits，并在异步返回前校验当前文件、语言和文本未变化。
- 新增 `EditorLanguageServiceTests` 覆盖 manager 级 `textDocument/rangeFormatting` 主流程、range 参数和 formatting options。版本号从 **1.114.0-rc15** 提升为 **1.114.0-rc16**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.114.0-rc15 - 2026-07-01

### Added
- **Editor LSP Inlay Hint Resolve（1.114.0-rc15）** —— Go / TypeScript / JavaScript / Swift 的 inlay hint 现在会保留 server 返回的 `data`，并在 server 声明 `inlayHintProvider.resolveProvider` 时请求 `inlayHint/resolve`，拿到懒加载 tooltip / text edits / padding 等信息后再映射到 editor hint span。
- `LSPInlayHint`、`LSPInlayHintLabel` 和 label parts 升级为 `Codable`，支持把 hint 原样发回 server；`EditorInlayHintSpan` 新增 tooltip 承载位，resolve 失败时回退原 hint，不让单个懒加载失败清空整页提示。
- 新增 `EditorLanguageServiceInlayHintTests` 覆盖 manager 级 `inlayHint/resolve` 主流程、resolve 请求 `data` 回传和 resolved tooltip 映射。版本号从 **1.114.0-rc14** 提升为 **1.114.0-rc15**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.114.0-rc14 - 2026-07-01

### Added
- **Editor LSP Document Link Resolve（1.114.0-rc14）** —— Go / TypeScript / JavaScript / Swift 的 document link 现在会保留 server 返回的原始 `DocumentLink.data`，当链接没有初始 `target` 且 server 声明 `documentLinkProvider.resolveProvider` 时，Command-click 会先请求 `documentLink/resolve` 再打开安全 target。
- `EditorDocumentLinkSpan` 现在可以承载 unresolved link range，不再因为初始 `target` 为空就丢弃 import/module 链接；AppState 会在当前文件、语言和文本仍匹配时打开 resolve 后的 `file` / `http` / `https` URL，继续过滤不可信 scheme。
- 新增 `EditorLanguageServiceDocumentLinkTests` 覆盖 manager 级 `documentLink/resolve` 主流程、resolve 请求 `data` 回传和 resolved target 解码。版本号从 **1.114.0-rc13** 提升为 **1.114.0-rc14**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.114.0-rc13 - 2026-07-01

### Added
- **Editor LSP Code Action Resolve（1.114.0-rc13）** —— Go / TypeScript / JavaScript / Swift 应用 quick fix 前会在 server 声明 `codeActionProvider.resolveProvider` 时请求 `codeAction/resolve`，拿到懒加载的 `WorkspaceEdit` / command / `data` 后再执行。
- `LSPCodeAction` 现在保留并回传 `data`，`LSPWorkspaceEdit` 支持编码；AppState 在当前文件、语言和文本仍匹配时使用 resolve 后的 action，并复用现有 workspace edit 安全应用路径。resolve 失败会回退原 action。
- 新增 `EditorLanguageServiceTests` 覆盖 manager 级 `codeAction/resolve` 主流程、resolve 前同步文档顺序、server `data` 回传和 resolved edit 应用数据。版本号从 **1.114.0-rc12** 提升为 **1.114.0-rc13**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.114.0-rc12 - 2026-07-01

### Added
- **Editor LSP Workspace Requests（1.114.0-rc12）** —— Go / TypeScript / JavaScript / Swift 的语言服务器主动请求 `workspace/configuration` 时，client 现在会按请求项数量返回空配置对象数组，避免 server 等不到 JSON-RPC response；后续有真实语言设置 UI 时可在同一路径填入 per-language 配置。
- `LanguageServerClient` 现在声明 workspace `configuration` capability，并响应 `workspace/workspaceFolders`，返回 initialize root 的 URI 和名称，帮助 gopls / typescript-language-server / sourcekit-lsp 识别当前工作区。
- 新增 `EditorLanguageServiceTests` 覆盖 server-initiated `workspace/configuration` 与 `workspace/workspaceFolders` 请求响应。版本号从 **1.114.0-rc11** 提升为 **1.114.0-rc12**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.114.0-rc11 - 2026-07-01

### Added
- **Editor LSP Completion Resolve（1.114.0-rc11）** —— Go / TypeScript / JavaScript / Swift 应用补全前会在 server 声明 `completionProvider.resolveProvider` 时请求 `completionItem/resolve`，拿到懒加载的 detail、documentation、`additionalTextEdits` 和 server `data` 后再应用补全。
- `LSPCompletionItem` 现在保留 `data` 字段并随 resolve 请求原样回传；AppState 会在当前文件、语言和文本仍匹配时使用 resolve 后的 item，resolve 失败则回退原 item，避免补全动作因为懒加载失败而中断。
- 新增 `EditorLanguageServiceTests` 覆盖 manager 级 `completionItem/resolve` 主流程、保存原始 completion `data`、以及 resolve 前同步文档顺序。版本号从 **1.114.0-rc10** 提升为 **1.114.0-rc11**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.114.0-rc10 - 2026-07-01

### Added
- **Editor LSP DidSave（1.114.0-rc10）** —— Go / TypeScript / JavaScript / Swift 保存成功后会按语言服务器声明的 `textDocumentSync.save` 能力发送 `textDocument/didSave`，让 gopls / typescript-language-server / sourcekit-lsp 能在真实保存生命周期后刷新诊断、索引和项目状态。
- `LanguageServerClient` 现在解析 `textDocumentSync` 的数字与 options 两种形态，只有 server 声明 save 支持时才发保存通知，并尊重 `save.includeText` 决定是否携带最终写盘文本；`EditorLanguageServiceManager` 会先同步最新 buffer，再发送 didSave。
- 新增 `EditorLanguageServiceTests` 覆盖 client 级 didSave capability 协商、includeText payload，以及 manager 级保存前同步顺序。版本号从 **1.114.0-rc9** 提升为 **1.114.0-rc10**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.114.0-rc9 - 2026-07-01

### Added
- **Editor LSP Code Action Commands（1.114.0-rc9）** —— Go / TypeScript / JavaScript / Swift 的 code action 现在支持执行语言服务器返回的 command-only quick fix：读取 `executeCommandProvider.commands` 后发送 `workspace/executeCommand`，并兼容裸 `Command` action 的 `arguments`。
- `LanguageServerClient` 现在处理语言服务器发起的 `workspace/applyEdit` 请求，AppState 复用现有 workspace edit 安全应用路径，限制在当前 workspace 内并保护未保存 tab；执行后刷新当前 LSP 文档状态和 outline。
- 新增 `EditorLanguageServiceCodeActionCommandTests`，覆盖裸 Command 解码、manager 级 `workspace/executeCommand` 主流程、null result 响应和未声明 capability 时不请求。版本号从 **1.114.0-rc8** 提升为 **1.114.0-rc9**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.114.0-rc8 - 2026-07-01

### Added
- **Editor LSP Document Links（1.114.0-rc8）** —— Go / TypeScript / JavaScript / Swift 打开或编辑时会在 server 声明 `documentLinkProvider` 后请求 LSP `textDocument/documentLink`，把语言服务器识别出的 import 路径、URL 或文件引用映射为 editor link spans。
- Editor 会用临时 underline / link color 绘制 document links，Command-click 命中语义链接时通过系统默认应用打开安全的 `file` / `http` / `https` target；切换文件、切换语言或语言服务器不可用时清空 stale links。
- 新增 `EditorLanguageServiceDocumentLinkTests`，覆盖 document link 解码、target scheme 过滤、manager 级 `textDocument/documentLink` 主流程和未声明 capability 时不请求。版本号从 **1.114.0-rc7** 提升为 **1.114.0-rc8**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.114.0-rc7 - 2026-07-01

### Added
- **Editor LSP Document Symbols 兼容增强（1.114.0-rc7）** —— Go / TypeScript / JavaScript / Swift 的 outline 现在完整兼容 LSP `textDocument/documentSymbol` 的层级 `DocumentSymbol[]`、扁平 `SymbolInformation[]` 和 `null` 返回形态，扁平符号会映射为现有 editor outline items。
- `LanguageServerClient` 现在会读取 `documentSymbolProvider` capability，server 未声明能力时不再直接请求；声明能力后再走 LSP 符号树，减少第一批 IDE 语言退回本地正则 outline 的概率。
- 新增 `EditorLanguageServiceDocumentSymbolTests`，覆盖 document symbol 三种返回形态解码和 manager 级 `SymbolInformation[]` 主流程。版本号从 **1.114.0-rc6** 提升为 **1.114.0-rc7**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.114.0-rc6 - 2026-07-01

### Added
- **Editor LSP Inlay Hints（1.114.0-rc6）** —— Go / TypeScript / JavaScript / Swift 打开或编辑时会请求 LSP `textDocument/inlayHint`，把参数名、类型等语义提示转换为 editor hint spans，并在 TextKit 中作为轻量虚拟提示绘制，不写入正文。
- `LanguageServerClient` 现在声明并解析 `inlayHintProvider`，支持 string label 与 label parts 两种返回形态；AppState 会按当前文件 URI 管理 hint 生命周期，切换文件、切换语言或语言服务器不可用时清空 stale hints。
- 新增 `EditorLanguageServiceInlayHintTests`，覆盖 inlay hint 解码和 manager 级 `textDocument/inlayHint` 主流程。版本号从 **1.114.0-rc5** 提升为 **1.114.0-rc6**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.114.0-rc5 - 2026-07-01

### Added
- **Editor LSP Completion TextEdit / Additional Edits（1.114.0-rc5）** —— Go / TypeScript / JavaScript / Swift 的 completion 应用现在优先使用 LSP `CompletionItem.textEdit` / `InsertReplaceEdit` 指定的替换范围，不再只靠本地前缀范围猜测补全边界。
- Completion item 会声明并处理 `snippetSupport`、`additionalTextEditsSupport`、`insertTextFormat`、`additionalTextEdits`；应用补全时会把 snippet placeholder 清成可插入文本，并将 server 返回的额外 edits 与主 edit 原子应用，支持补全同时插入 import 等语义改动。
- 新增 `EditorLanguageServiceCompletionTests`，覆盖 completion item 解码、server text edit + additional edits 应用、snippet placeholder 清理和旧式本地 replacement range fallback。版本号从 **1.114.0-rc4** 提升为 **1.114.0-rc5**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.114.0-rc4 - 2026-07-01

### Added
- **Editor LSP Declaration / Go to Declaration 导航（1.114.0-rc4）** —— Go / TypeScript / JavaScript / Swift 的 editor 右键菜单新增 Go to Declaration，通过 LSP `textDocument/declaration` 跳转到符号声明位置，继续减少正则 resolver 在第一批 IDE 语言中的职责。
- `LanguageServerClient` 现在声明 declaration client capability，解析 `declarationProvider`，并复用现有 `LSPDefinitionResult` 兼容单个 location、location 数组和空结果；Declaration 失败时只给可控失败反馈，不做本地正则伪回退。
- 新增 `EditorLanguageServiceNavigationTests`，覆盖 manager 级 `textDocument/declaration` 主流程，并将导航专项测试从接近 2000 行的主语言服务测试文件拆出。版本号从 **1.114.0-rc3** 提升为 **1.114.0-rc4**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.114.0-rc3 - 2026-07-01

### Added
- **Editor LSP prepareRename / Rename Symbol 预校验（1.114.0-rc3）** —— Go / TypeScript / JavaScript / Swift 的 Rename Symbol 在弹出输入框前会优先调用 LSP `textDocument/prepareRename`，由语言服务器确认当前位置是否可重命名，并读取返回的 range / placeholder 作为默认名称。
- `LanguageServerClient` 现在声明 rename `prepareSupport`，解析 `renameProvider.prepareProvider`，并支持 `prepareRename` 的 `null`、裸 `Range`、`{ range, placeholder }` 三种返回形态；未声明 prepare 能力的 server 会继续走原有 LSP rename 流程，已声明但返回不可重命名时显示明确提示。
- 新增 `EditorLanguageServiceRenameTests` 2 条，覆盖 first-stage capability 暴露和 manager 级 `textDocument/prepareRename` 主流程。版本号从 **1.114.0-rc2** 提升为 **1.114.0-rc3**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.114.0-rc2 - 2026-07-01

### Added
- **Editor LSP Call Hierarchy / Show Call Hierarchy（1.114.0-rc2）** —— Go / TypeScript / JavaScript / Swift 的 editor 右键菜单新增 Show Call Hierarchy，会通过 LSP `textDocument/prepareCallHierarchy`、`callHierarchy/incomingCalls` 和 `callHierarchy/outgoingCalls` 查询当前符号调用关系。
- 右上角新增 Call Hierarchy 浮层，分 Incoming / Outgoing 展示调用方与被调用方的符号名、文件、行列、detail 和预览行；点击条目会跳转到对应文件位置，语言服务器不可用或无结果时只显示可控空态，不做本地正则伪回退。
- `EditorLanguageServiceTests` 扩展到 43 条，新增 manager 级 call hierarchy 主流程测试，并覆盖 first-stage capability 暴露。版本号从 **1.114.0-rc1** 提升为 **1.114.0-rc2**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.114.0-rc1 - 2026-07-01

### Added
- **Agent 联网调研来源胶囊（1.114.0-rc1）** —— `web_search` / `web_fetch` 工具结果新增结构化来源列表，当前轮 assistant 输出后会显示紧凑 favicon 来源胶囊，点击可展开来源清单并打开对应网页。
- `AgentTurnReport` 会从本轮全部工具结果中去重收集来源，不受工具明细前 8 条展示限制；工具结果脱敏链路同步处理来源标题和 URL，避免 token / key 类 query 值进入 UI。
- `AgentWebToolsTests` 和 `AgentTurnReportTests` 覆盖搜索来源提取、host 解析和回合来源去重。版本号从 **1.113.0-rc20** 提升为 **1.114.0-rc1**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.113.0-rc20 - 2026-07-01

### Added
- **Editor LSP Selection Range / Expand Selection（1.113.0-rc20）** —— Go / TypeScript / JavaScript / Swift 的 editor 右键菜单新增 Expand Selection，会通过 LSP `textDocument/selectionRange` 请求语言服务器的语法树选区链，并把当前光标或选区扩到下一层更大的语义范围。
- 新增 `EditorSelectionRangeResolver`、selection range LSP 协议模型、client capability、manager 请求和 AppState 选区应用路径；没有可靠 LSP 范围时只提示不可用或无更大范围，不做本地正则伪回退。
- `EditorLanguageServiceTests` 扩展到 42 条，新增 manager 级 `textDocument/selectionRange` 主流程和 selection range 扩选 resolver 测试。版本号从 **1.113.0-rc19** 提升为 **1.113.0-rc20**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.113.0-rc19 - 2026-07-01

### Added
- **Editor LSP Workspace Symbols / Symbol Jump 项目搜索（1.113.0-rc19）** —— Go / TypeScript / JavaScript / Swift 的 Symbol Jump 在输入非空查询时会优先通过 LSP `workspace/symbol` 做项目级语义符号搜索，结果展示文件名、行号和容器名，并可跨文件跳转到语言服务器返回的位置。
- Symbol Jump 仍保留当前文件 outline fallback：空查询继续显示当前文件结构；语言服务器不可用、未声明 workspace symbol 能力或项目级查询无结果时，继续用当前文件 outline 过滤，避免项目符号搜索失败时把面板变成死路。
- `EditorLanguageServiceTests` 扩展到 40 条，新增 manager 级 `workspace/symbol` 主流程测试，并覆盖 first-stage capability 暴露。版本号从 **1.113.0-rc18** 提升为 **1.113.0-rc19**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.113.0-rc18 - 2026-07-01

### Added
- **Editor LSP Type Definition / Implementation 导航（1.113.0-rc18）** —— Go / TypeScript / JavaScript / Swift 的 editor 右键菜单新增 Go to Type Definition 和 Go to Implementation，分别通过 LSP `textDocument/typeDefinition` 与 `textDocument/implementation` 跳转到类型定义或实现位置。
- LSP initialize 现在声明并协商 type definition / implementation client capability；`LanguageServerClient`、`EditorLanguageServiceManager` 和 AppState 导航路径复用现有 location 跳转能力。普通 Definition 仍保留正则 fallback；Type Definition / Implementation 没有可靠正则语义时只提示失败，避免跳到看似相关但实际错误的位置。
- `EditorLanguageServiceTests` 扩展到 39 条，新增 manager 级 `textDocument/typeDefinition` 和 `textDocument/implementation` 主流程测试，并覆盖 first-stage capability 暴露。版本号从 **1.113.0-rc17** 提升为 **1.113.0-rc18**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.113.0-rc17 - 2026-07-01

### Changed
- **Agent 侧边栏快捷入口优化（1.113.0-rc17）** —— Agent 标题栏右侧新增 Diff、Terminal、Preview、Files 四个高频侧边栏小图标，点击即可直接打开或关闭对应右侧面板；完整面板列表收进 `...` 菜单，保留原有所有侧栏 tab 选择能力。
- Editor 窗口入口继续保留，但改为独立强调色胶囊按钮，并与侧栏工具组之间加入分隔线，避免和普通 side panel 入口混在一起。

### Fixed
- 右侧侧边栏拖拽改宽时不再每像素写入 `@AppStorage`，窗口最小宽度约束也延后到拖拽结束后提交；拖动过程只更新临时宽度并关闭隐式动画，减少面板内容和边界的抖动、闪动。版本号从 **1.113.0-rc16** 提升为 **1.113.0-rc17**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness 文档位点。

## 1.113.0-rc16 - 2026-07-01

### Added
- **Editor LSP Document Highlights 接入（1.113.0-rc16）** —— Go / TypeScript / JavaScript / Swift 的 editor 光标移动到符号上时，会通过 LSP `textDocument/documentHighlight` 请求当前文档内的语义关联位置，并以轻量背景高亮读/写引用。
- Document highlight 请求接入 `LanguageServerClient`、`EditorLanguageServiceManager`、`AppState` 和 `EditorView`：光标移动带 UTF-16 字符偏移，AppState 做 120ms 防抖和过期响应丢弃，EditorView 将符号高亮与诊断临时属性统一刷新，诊断显示优先级更高。
- `EditorLanguageServiceTests` 扩展到 37 条，新增 document highlight 结果解码、manager 级 `textDocument/documentHighlight` 主流程和 first-stage capability 覆盖测试。版本号从 **1.113.0-rc15** 提升为 **1.113.0-rc16**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.113.0-rc15 - 2026-07-01

### Added
- **Editor LSP Code Actions 接入（1.113.0-rc15）** —— Go / TypeScript / JavaScript / Swift 的 editor 右键菜单新增 Show Code Actions，会通过 LSP `textDocument/codeAction` 获取 quick fix / source action 候选，并在右上角浮层展示。
- Code Action 会携带当前选区或光标命中的诊断上下文；带 `WorkspaceEdit` 的 action 会复用 rename 的 workspace 安全应用路径，限制在当前 workspace 内，保护已打开且未保存的其他 tab，当前文件保持 dirty，其他安全文件写回磁盘。
- `EditorLanguageServiceTests` 扩展到 35 条，新增 code action 联合结果解码、manager 级 `textDocument/codeAction` 主流程和面板 item 映射测试。版本号从 **1.113.0-rc14** 提升为 **1.113.0-rc15**，并同步 Xcode / Go agent / Help / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.113.0-rc14 - 2026-07-01

### Added
- **Editor LSP Signature Help 接入（1.113.0-rc14）** —— Go / TypeScript / JavaScript / Swift 的 editor 右键菜单新增 Show Signature Help，会通过 LSP `textDocument/signatureHelp` 展示当前调用签名、文档和 active parameter。
- 新增 `LSPSignatureHelp`、`LSPSignatureInformation`、`LSPParameterInformation` 和 `EditorSignatureHelpPanelState`，支持参数 label 的字符串与 `[start, end]` 两种 LSP 形态；面板会高亮当前参数，语言服务器不可用时给出可控空态。
- `EditorLanguageServiceTests` 扩展到 32 条，新增 signature help 解码、manager 级 `textDocument/signatureHelp` 主流程和 active parameter 面板映射测试。版本号从 **1.113.0-rc13** 提升为 **1.113.0-rc14**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.113.0-rc13 - 2026-07-01

### Added
- **Editor LSP Folding Ranges 接入（1.113.0-rc13）** —— Go / TypeScript / JavaScript / Swift 的 editor 折叠 gutter 现在会优先使用 LSP `textDocument/foldingRange` 返回的语法树折叠范围，不再只依赖本地 brace/indent/regex 规则。
- 新增 `LSPFoldingRangeParams`、`LSPFoldingRange`、client folding range capability 和 `EditorFoldingRangeMapper`，把 LSP 0-based range 转为 editor 1-based `ScopeGuide`；语言服务器不可用或未声明 folding range 支持时继续使用 `ScopeGuideCalculator` fallback。
- `EditorLanguageServiceTests` 扩展到 29 条，新增 folding range 到 scope guide 的映射测试和 manager 级 `textDocument/foldingRange` 主流程测试。版本号从 **1.113.0-rc12** 提升为 **1.113.0-rc13**，并同步 Xcode / Go agent / Help / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.113.0-rc12 - 2026-07-01

### Added
- **Editor LSP Rename Symbol 接入（1.113.0-rc12）** —— Go / TypeScript / JavaScript / Swift 的 editor 右键菜单新增 Rename Symbol，会通过 LSP `textDocument/rename` 获取语义级 `WorkspaceEdit`，而不是按正则直接替换当前单词。
- 新增 `LSPRenameParams`、`LSPWorkspaceEdit`、`LSPTextDocumentEdit` 和 `EditorWorkspaceEditApplier`，支持 LSP `changes` 与常见 `documentChanges` text edits；rename 应用会限制在当前 workspace 内，保护已打开且未保存的其他 tab，当前文件改动保持为 dirty，其他安全文件写回磁盘。
- `EditorLanguageServiceTests` 扩展到 27 条，新增 WorkspaceEdit 解码、manager 级 `textDocument/rename` 主流程和 workspace edit 应用测试。版本号从 **1.113.0-rc11** 提升为 **1.113.0-rc12**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.113.0-rc11 - 2026-07-01

### Added
- **Editor LSP Document Formatting 接入（1.113.0-rc11）** —— Go / TypeScript / JavaScript / Swift 的 editor 右键菜单新增 Format Document，当前文件会通过 LSP `textDocument/formatting` 获取语言服务器返回的 `TextEdit` 并应用到正文。
- 新增 `LSPFormattingOptions`、`LSPTextEdit`、`LSPTextEditResult` 和 `EditorTextEditApplier`，格式化 edits 会按文档位置倒序应用，避免多段 replacement 因前序编辑导致 range 漂移；格式化成功后会标记 dirty、同步 LSP 文档并刷新语义 tokens。
- `EditorLanguageServiceTests` 扩展到 24 条，新增 manager 级 `textDocument/formatting` 主流程和 TextEdit 应用顺序测试。版本号从 **1.113.0-rc10** 提升为 **1.113.0-rc11**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.113.0-rc10 - 2026-07-01

### Fixed
- **Agent workspace 移动/删除懒诊断（1.113.0-rc10）** —— Agent session 持久化本地 workspace 的 security-scoped bookmark 与文件身份线索，正常工具调用继续乐观使用记录路径，不做周期性目录轮询。
- 工具、delegated agent、移动端读文件、patch 应用和 worktree 刷新现在会尊重 runtime 的 workspace availability；只有在工具/文件操作失败或 runtime 已知 missing/moved 时才诊断旧路径和 bookmark，检测到 rename/move 后不会静默改会话路径，而是要求用户重新选择确认。新增 `WorkspaceSessionTests` 覆盖 rename 后不静默 rebind 的行为。版本号从 **1.113.0-rc9** 提升为 **1.113.0-rc10**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.113.0-rc9 - 2026-07-01

### Added
- **Editor LSP References 接入（1.113.0-rc9）** —— Go / TypeScript / JavaScript / Swift 的 editor 右键菜单新增 Find References，会通过 LSP `textDocument/references` 查询当前符号引用，并在 editor 右上角显示可点击引用列表。
- References 面板支持 loading、空结果和不可用状态，结果行展示文件名、行列和预览行；点击结果会复用现有 LSP location 导航能力跳转到对应文件和位置。
- `EditorLanguageServiceTests` 扩展到 22 条，新增 manager 级 `textDocument/references` 主流程和 `EditorReferenceItem` 显示元数据映射测试。版本号从 **1.113.0-rc8** 提升为 **1.113.0-rc9**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.113.0-rc8 - 2026-07-01

### Added
- **Editor LSP Semantic Tokens 接入（1.113.0-rc8）** —— Go / TypeScript / JavaScript / Swift 的 editor 高亮现在会在 regex fallback 之后优先应用 LSP `textDocument/semanticTokens/full` 返回的语义 token，让函数、类型、关键字、字符串、数字、注释等颜色来自语言服务器的语法树/AST 语义。
- LSP initialize 现在声明 semantic tokens client capability，并读取 server 返回的 legend；editor 会把相对 delta token 数据解码成 UTF-16 range，切文件/切语言/语言服务器不可用时清空语义 token 并继续保留原有 regex 高亮 fallback。
- `EditorLanguageServiceTests` 扩展到 20 条，新增 semantic token delta 解码、manager 级 `textDocument/semanticTokens/full` 主流程和 semantic token 覆盖 regex 高亮颜色测试。版本号从 **1.113.0-rc7** 提升为 **1.113.0-rc8**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.113.0-rc7 - 2026-07-01

### Added
- **Editor LSP Completion 接入（1.113.0-rc7）** —— Go / TypeScript / JavaScript / Swift 的 editor 右键菜单新增 LSP 补全入口，会通过 `textDocument/completion` 获取语言服务器候选，并在 editor 右上角显示可点击候选面板。
- 补全面板支持 loading、空结果和不可用状态；选择候选后会按当前符号前缀或选区替换文本，优先使用 LSP `insertText`，没有时回退到 `label`，并把光标移动到插入文本末尾。
- `EditorLanguageServiceTests` 扩展到 17 条，新增 completion array/list/null 解码、manager 级 `textDocument/completion` 主流程和 `EditorCompletionItem` 插入文本 fallback 测试。版本号从 **1.113.0-rc6** 提升为 **1.113.0-rc7**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.113.0-rc6 - 2026-07-01

### Added
- **Editor LSP Hover 接入（1.113.0-rc6）** —— Go / TypeScript / JavaScript / Swift 的右键菜单新增 LSP Hover 信息入口，当前符号会通过 `textDocument/hover` 查询语言服务器，并在 editor 右上角显示可复制的轻量信息面板。
- LSP hover 解码支持 markdown、普通字符串和 marked-string 数组，避免不同语言服务器返回形态不一致时丢失文档或类型签名；语言服务器不可用、无内容或切换文件时会显示可控空态并清理过期 hover。
- `EditorLanguageServiceTests` 扩展到 14 条，新增 hover 内容解码、manager 级 `textDocument/hover` 主流程和 `EditorHoverInfo` 映射测试。版本号从 **1.113.0-rc5** 提升为 **1.113.0-rc6**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.113.0-rc5 - 2026-07-01

### Fixed
- **Workspace 菜单 URL 比较卡死（1.113.0-rc5）** —— 采样显示 WillDeep 主线程 3715/3715 个样本卡在 SwiftUI `Menu` / `GraphHost.flushTransactions` 布局刷新链路，热点集中于 `URL.==`、`URL.path`、`NSURL.relativeString` 和 Swift 字符串桥接。
- `WorkspacePickerPill` 的已知工作区缓存从 `[URL]` 改为稳定的 `id/path/displayName` 轻量快照，菜单 `ForEach` 不再用 `URL` 自身当 identity，active check 改为字符串 path 比较，避免 SwiftUI 在菜单布局和 diff 期间反复标准化、桥接和比较 URL。版本号从 **1.113.0-rc4** 提升为 **1.113.0-rc5**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness / 短剧指针文档位点。

## 1.113.0-rc4 - 2026-07-01

### Added
- **Editor LSP 诊断接入（1.113.0-rc4）** —— Go / TypeScript / JavaScript / Swift 的 LSP `textDocument/publishDiagnostics` 现在会进入 AppState，并按当前文件 URI 转换为 editor 可绘制的错误、警告、信息和提示区间。
- Editor 正文新增 LSP 诊断下划线与轻量背景提示，状态栏显示错误/警告数量，并可一键跳转到首个诊断位置；切换到非第一批 IDE 语言或关闭文件时会清理过期诊断。
- `EditorLanguageServiceTests` 扩展到 11 条，新增 diagnostics notification 分发、UTF-16 range 反向转换和 editor diagnostic issue 映射测试。版本号从 **1.113.0-rc3** 提升为 **1.113.0-rc4**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness 文档位点。

## 1.113.0-rc3 - 2026-07-01

### Added
- **Editor LSP 结构大纲接入（1.113.0-rc3）** —— Go / TypeScript / JavaScript / Swift 的 Structure 侧栏和符号跳转现在优先使用 LSP `textDocument/documentSymbol` 返回的真实语义结构；语言服务器不可用、返回为空或刷新尚未完成时继续使用原有正则 outline 作为 fallback。
- `EditorLanguageServiceManager` 新增 document symbols 请求，AppState 增加当前文件 IDE outline 缓存与刷新桥接，Structure 面板打开和 Symbol Jump 打开/编辑时会触发 LSP outline 刷新，并在结果仍匹配当前文件内容时替换本地 outline。
- `EditorLanguageServiceTests` 扩展到 9 条，新增 LSP document symbol 嵌套结构到 outline 的映射测试，以及 manager 级 `textDocument/documentSymbol` 主流程测试。版本号从 **1.113.0-rc2** 提升为 **1.113.0-rc3**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness 文档位点。

## 1.113.0-rc2 - 2026-07-01

### Added
- **Editor LSP 定义跳转接入（1.113.0-rc2）** —— Go / TypeScript / JavaScript / Swift 文件打开和编辑时会同步到 `EditorLanguageServiceManager` 管理的 LSP session；Command-click / 右键 Go to Definition 现在优先走 LSP `textDocument/definition`，找不到服务器、请求失败或无结果时自动回退到原有正则 resolver。
- 新增 editor UTF-16 offset 到 LSP line/character 的位置转换，补齐 `EditorDefinitionRequest` 光标 offset 传递、LSP location 到现有 editor navigation 的桥接，以及 manager 级 session 复用、didOpen/didChange 版本递增逻辑。
- `EditorLanguageServiceTests` 扩展到 7 条，新增 LSP position 转换和 manager definition 主流程测试，锁住 initialize → initialized → didOpen → definition 的第一批 IDE 通路。版本号从 **1.113.0-rc1** 提升为 **1.113.0-rc2**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness 文档位点。

## 1.113.0-rc1 - 2026-07-01

### Added
- **第一批 IDE 语言服务底座（1.113.0-rc1）** —— 新增 `EditorLanguageServiceRegistry`，把 Go、TypeScript、JavaScript、Swift 标记为第一批 IDE 级语言，分别映射到 `gopls`、`typescript-language-server --stdio` 和 `sourcekit-lsp`，并记录 workspace marker、安装提示和 diagnostics / hover / definition / document symbols / completion 等本期能力。
- 新增最小 LSP 协议模型、`Content-Length` JSON-RPC framing、进程 transport、可执行文件解析和 `LanguageServerClient`，支持 initialize、didOpen、didChange、didClose、hover、definition、document symbols 与 diagnostics 通知缓存；现有正则高亮/outline/definition 保持 fallback，后续 UI 接入走 LSP 优先。
- 新增 `EditorLanguageServiceTests`，覆盖第一批语言 registry、workspace root 探测、LSP 帧解析、文档生命周期通知和 request/response 解码。版本号从 **1.112.0-rc5** 提升为 **1.113.0-rc1**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway / Agent Harness 文档位点。

## 1.112.0-rc5 - 2026-07-01

### Fixed
- **Editor 光标点击定位闪动收敛（1.112.0-rc5）** —— 编辑器插入点竖线现在按字体实际 ascender/descender 高度居中绘制，不再跟随整行 line fragment 撑得偏高；点击不同位置移动光标时，selection change 只重绘旧/新当前行附近，避免把整个 text view 标记为需要刷新导致轻微闪动。
- 版本号从 **1.112.0-rc4** 提升为 **1.112.0-rc5**，并同步 Xcode / Go agent / Help / README badge / product overview / Mobile Gateway 文档位点。

## 1.112.0-rc4 - 2026-07-01

### Fixed
- **智能审批改为 AI 判断正常运维命令（1.112.0-rc4）** —— `run_command` 的非 typed-confirmation 网络/远端命令不再因为 `ssh`、`curl -X POST`、Docker/nginx 运维动作等直接退回人工审批；智能审批会把这类命令送到 safety judge，由 AI 判断是否属于正常开发/部署/运维工作。
- Safety judge 提示词从“只有只读才 YES”改为“正常工作且非恶意可 YES”：启动 Docker、重启/重载 nginx、添加 nginx 站点等正常运维可以通过；清盘、广泛删除、读私钥/泄露密钥、隐藏持久化、关闭安全控制、无边界 root/远端交互 shell 等仍为 NO。`rm -rf /`、读 `~/.ssh/id_rsa` 等 typed-confirmation 命令继续硬性要求人工确认。
- UI 文案同步为“AI 批准正常命令”，并增加回归测试锁住 `ssh ... docker run` 可进入 AI judge、破坏性/偷密钥命令不可进入 judge。版本号从 **1.112.0-rc3** 提升为 **1.112.0-rc4**。

## 1.112.0-rc3 - 2026-07-01

### Fixed
- **Agent 验证中不再自动切到任务监控侧栏（1.112.0-rc3）** —— 前台 `run_command` 的「验证中」状态继续显示在 composer / 状态行，但不再把右侧侧边栏自动切到「任务监控」；真正需要右栏承载的后台 job、媒体任务、待办、工作文件、学习事件和上下文压缩仍保留自动展开能力。
- `AgentTaskMonitorSnapshot` 增加独立的自动展开摘要，自动展开逻辑只比较这份摘要，避免已有待办时因为前台验证状态变化顺手抢右栏；`AgentBackgroundJobsTests` 增加回归覆盖。版本号从 **1.112.0-rc2** 提升为 **1.112.0-rc3**。

## 1.112.0-rc2 - 2026-07-01

### Fixed
- **Agent 浅色皮肤在系统 dark mode 下保持可读（1.112.0-rc2）** —— `mist-forest` 和 `rice-paper` 两个浅色自定义皮肤现在显式使用 light color scheme，不再在 macOS dark mode 下继承白色 `.primary/.secondary` 文字，修复 `/goal` / Agent 窗口浅底白字几乎不可读的问题。
- `EditorCoreBehaviorTests` 增加皮肤 color scheme 回归测试，锁住 system 皮肤继续跟随系统、浅色皮肤固定 light、暗色皮肤固定 dark 的对比度约束；版本号从 **1.112.0-rc1** 提升为 **1.112.0-rc2**。

## 1.112.0-rc1 - 2026-06-30

### Added
- **受保护机密批量插入（1.112.0-rc1）** —— Agent Composer 的“插入受保护机密”弹窗现在一次最多支持 3 个密码/Token；每行独立填写标签和机密内容，插入后会把多个 `${secret:...}` 占位符按顺序追加到输入框。
- 弹窗新增用法提示，明确“每行一个密码或 Token，插入后把占位符放到命令、请求头或表单字段需要的位置”；真实值仍只保存在本机 Keychain，本地工具执行前才解析。
- `AgentToolsCoreTests` 增加批量机密插入回归测试，锁住空行跳过、最多 3 个和第四个不会保存/解析的边界；版本号从 **1.111.0-rc1** 提升为 **1.112.0-rc1**。

## 1.111.0-rc1 - 2026-06-30

### Added
- **Browser Ops HAR / API / 性能诊断（1.111.0-rc1）** —— 内嵌浏览器新增 `embedded_browser_requests`、`embedded_browser_export_har`、`embedded_browser_storage`、`embedded_browser_performance` 和 `embedded_browser_failed_resources`，覆盖 fetch/XHR AJAX API、脱敏请求/响应头、HAR 文件导出、同源 cookie/storage/IndexedDB 概况、页面导航/绘制/资源性能，以及失败资源聚合。
- WKWebView 诊断脚本现在会在页面启动时包装 `fetch` 与 `XMLHttpRequest`，捕获 method、URL、status、耗时、MIME、响应大小、请求头和响应头；`authorization`、`cookie`、`set-cookie`、token、secret、API key 等敏感头会在采集层脱敏。
- Browser Ops 专家提示和门禁测试同步扩展，确保新诊断工具仍只在激活 Browser Ops 后暴露；版本号从 **1.110.0-rc1** 提升为 **1.111.0-rc1**。

## 1.110.0-rc1 - 2026-06-30

### Added
- **Browser Ops 诊断工具（1.110.0-rc1）** —— 内嵌浏览器新增 `embedded_browser_snapshot`、`embedded_browser_wait_for`、`embedded_browser_eval`、`embedded_browser_console` 和 `embedded_browser_network`，补齐 DOM 元素探测、等待页面变化、受控 JS 检查、console/error/rejection 读取，以及 Performance Resource Timing 网络资源耗时、大小和估算速度。
- Browser 面板 WKWebView 会在页面启动时注入轻量诊断脚本，捕获 `console.debug/log/info/warn/error`、`window.error` 和 `unhandledrejection` 到本地环形缓冲；网络读取基于浏览器原生 performance entries，不额外代理或下载资源。
- `XeditTests` 扩展 Browser Ops 专家门禁断言，确认 console、network、snapshot 等新工具仍只在激活 Browser Ops 后暴露；这是 Browser Ops 的新增诊断能力，版本号从 **1.109.0-rc498** 提升为 **1.110.0-rc1**。

## 1.109.0-rc498 - 2026-06-30

### Added
- **侧边栏内嵌浏览器与浏览器专家包（1.109.0-rc498）** —— Composer 专家入口新增 Browser Ops，可像短剧专家一样按会话激活；激活后才显示右侧“Browser”面板，并暴露 `embedded_browser_*` 与 `chrome_*` 浏览器操作工具。
- 右侧 Browser 面板内置 WKWebView、地址栏、前进/后退/刷新和截图按钮；Agent 可对可见内嵌浏览器执行导航、读取页面、CSS selector 点击、填写文本和截图保存。Chrome bridge 工具保留给用户真实 Chrome 会话、登录态和已有标签页。
- `XeditTests` 增加专家门禁回归测试，锁住默认不暴露浏览器/Chrome 操作工具、激活 Browser Ops 后才开放的边界；版本号从 **1.109.0-rc497** 提升为 **1.109.0-rc498**。

## 1.109.0-rc497 - 2026-06-30

### Fixed
- **编译告警清理：AVFoundation 弃用 + run-script 每次重跑（1.109.0-rc497）** —— 接续 rc 系列的告警清理。① 7 个 workflow（MeetingNotes / Transcribe / VideoClip / VideoExtract / VideoGif / VideoSummary / VideoThumbnail）里的 `AVURLAsset.duration`（macOS 13 起弃用）改为异步 `try? await asset.load(.duration)`，行为不变；TranscribeWorkflow 的同步 IIFE 顺手重写成 async 取值。② `Re-sign ONNX dylib (Release only)` 这条 run-script build phase 之前没声明 `inputPaths/outputPaths`，被 Xcode 判为「无输出 → 每次 build 都跑」；补上源 dylib 输入与产物 dylib 输出后可做依赖分析、Release 下能跳过。编译告警 25 → 17（累计 43 → 17，剩余为 onnxruntime C 互操作 16 + AppIntents 元数据提示 1，风险高/无害，暂留）。
- 版本号从 **1.109.0-rc496** 提升为 **1.109.0-rc497**。pbxproj / Go agent / Help Info.plist / README badge×2 / product-overview / Mobile Gateway 同步。

## 1.109.0-rc496 - 2026-06-30

### Fixed
- **侧边栏终端 SSH 主机来源透明化（1.109.0-rc496）** —— 新建终端菜单不再让本机保存过的 SSH runtime 像 App 内置环境一样混在本地终端下面；菜单显式标注“已配置的 SSH 主机”，空配置时显示无主机状态，并提供“管理 SSH 主机...”入口直达 Settings → Runtimes。
- `AgentRuntimeStore` 增加隔离 defaults 的回归测试，确认空配置不会自动种下 `q3` 这类个人主机；保存团队主机后也只读取已保存的配置。
- 版本号从 **1.109.0-rc495** 提升为 **1.109.0-rc496**。pbxproj / Go agent / Help Info.plist / README badge×2 / product-overview / Mobile Gateway / Agent Harness 同步。

## 1.109.0-rc495 - 2026-06-30

### Fixed
- **终端捷径改名不再反复触发 Keychain 授权（1.109.0-rc495）** —— 已经落盘的受保护输入片段在改名、排序、pretty JSON 保存时只保留 Keychain 引用，不再逐段读取再写回，避免改一个标题弹多次“允许访问机密信息”。
- 回放同一个终端捷径时会按 Keychain account 缓存受保护片段，同一次回放里同一引用最多读取一次；`WillDeepTests` 增加“改名不碰 Keychain”和“回放缓存读取”回归测试。
- 版本号从 **1.109.0-rc494** 提升为 **1.109.0-rc495**。pbxproj / Go agent / Help Info.plist / README badge×2 / product-overview / Mobile Gateway / Agent Harness 同步。

## 1.109.0-rc494 - 2026-06-30

### Added
- **终端录制捷径可编辑（1.109.0-rc494）** —— 终端捷径菜单新增“编辑”，会用 WillDeep 现有编辑器打开 `Application Support/WillDeep/terminal-shortcuts/shortcuts.json` 并定位到当前捷径，用户可直接修改录制内容。
- 捷径 JSON 改为 pretty printed，保存该文件后终端捷径列表会自动从磁盘重载；如果 JSON 格式错误，列表继续使用保存前的可用版本并提示用户修正。
- `WillDeepTests` 增加终端捷径编辑文件格式与重载回归测试；版本号从 **1.109.0-rc493** 提升为 **1.109.0-rc494**。

## 1.109.0-rc493 - 2026-06-30

### Fixed
- **请求详情面板长文本截断（1.109.0-rc493）** —— Agent 错误卡片展开详情时不再直接渲染完整超长 request summary / request body；展示层会对超长单行和超长段落做中间省略，保留头尾关键信息，避免 SwiftUI 文本布局卡顿。
- 每个详情 section 新增复制完整内容按钮，排查时仍可取到未截断原文；`AgentToolsCoreTests` 增加截断预览回归测试。
- 版本号从 **1.109.0-rc492** 提升为 **1.109.0-rc493**。pbxproj / Go agent / Help Info.plist / README badge×2 / product-overview / Mobile Gateway / Agent Harness 同步。

## 1.109.0-rc492 - 2026-06-30

### Fixed
- **侧边栏终端快照只读最新一屏（1.109.0-rc492）** —— `terminal_snapshot` 不再把最近 400 行 scrollback/history 一起塞进模型上下文，默认只读取 active tab live 底部可见屏幕，避免旧命令输出干扰当前判断。
- 快照 payload 标题改为 `latest visible screen`，默认 `max_characters` 从 16000 降到 6000、上限从 40000 降到 12000；工具描述同步说明默认不包含历史滚动内容。
- 版本号从 **1.109.0-rc491** 提升为 **1.109.0-rc492**。pbxproj / Go agent / Help Info.plist / README badge×2 / product-overview / Mobile Gateway / Agent Harness 同步。

## 1.109.0-rc491 - 2026-06-30

### Fixed
- **SSH 远端只读命令识别（1.109.0-rc491）** —— `run_command` 现在会跳过 `ssh` 外壳、按远端真实命令判断风险；`ssh host cat /var/log/...`、`ssh host ping ...` 这类只读远端命令不再被本地 workspace 路径检查误判为写操作。
- 远端危险命令和敏感路径仍保持拦截：交互式 `ssh host` 继续需要用户批准，`ssh host "rm -rf ..."` 需要危险确认，`ssh host "cat ~/.ssh/id_rsa"` 仍按敏感路径升级。
- `AgentToolsCoreTests` 新增 SSH 远端命令风险和授权签名回归测试，锁住 `ssh git status` 的窄签名与远端路径判断边界。
- 版本号从 **1.109.0-rc490** 提升为 **1.109.0-rc491**。pbxproj / Go agent / Help Info.plist / README badge×2 / product-overview / Mobile Gateway / Agent Harness 同步。

## 1.109.0-rc490 - 2026-06-30

### Security
- **Agent secret 占位符加固（1.109.0-rc490）** —— `${secret:...}` ID 改为纯随机 32 位 hex，不再把用户填写的 label slug 暴露给模型；Agent 专用 secret 以 base64 envelope 存入 Keychain，解析时还原原文，避免通用凭据保存链路 trim 掉首尾空格这类可能属于密码本体的字符。
- URL encode transform 改为 query value 级严格 percent-encoding，并在结果脱敏时同时覆盖严格编码、旧 queryAllowed 编码、base64 和原文；`AgentToolsCoreTests` 新增本地执行工具解析 / 委托型 AI 执行器不解析的边界测试。
- 版本号从 **1.109.0-rc489** 提升为 **1.109.0-rc490**。pbxproj / Go agent / Help Info.plist / README badge×2 / product-overview / Mobile Gateway / Agent Harness 同步。

## 1.109.0-rc489 - 2026-06-30

### Added
- **终端工具支持总是允许（1.109.0-rc489）** —— `terminal_send_command` 和 `terminal_send_control` 现在会生成 always-allow 签名，审批卡片可显示“总是允许”。终端命令按完整命令行记忆，终端控制键按具体控制键记忆，例如 `ctrl_c` 不会顺带允许 `enter`。
- `AgentToolsCoreTests` 新增终端工具签名回归测试，锁住终端命令和不同控制键的授权边界。
- 版本号从 **1.109.0-rc488** 提升为 **1.109.0-rc489**。pbxproj / Go agent / Help Info.plist / README badge×2 / product-overview / Mobile Gateway / Agent Harness 同步。

## 1.109.0-rc488 - 2026-06-30

### Added
- **Agent 受保护机密占位符（1.109.0-rc488）** —— Composer 新增“插入受保护机密”入口，把用户输入的密码/Token 原样封装后保存到本机 Keychain，只把带随机 ID 的 `${secret:...}` 占位符放进对话；`run_command`、终端发送、MCP 调用、Lark CLI 和 Chrome 输入等本地执行工具会在执行前解析占位符，委托给外部 AI 执行器的工具不会解析明文。

### Security
- 工具结果、后台任务命令/输出、终端工具摘要和 tool error 都会对真实机密、URL 编码值、base64 值和占位符做统一脱敏；XCTest 环境下 `AgentCredentialStore` 默认使用内存凭据仓库，避免测试宿主触发真实 `com.willdeep.credentials` 钥匙串授权弹窗。
- 版本号从 **1.109.0-rc487** 提升为 **1.109.0-rc488**。pbxproj / Go agent / Help Info.plist / README badge×2 / product-overview / Mobile Gateway / Agent Harness 同步。

## 1.109.0-rc487 - 2026-06-30

### Fixed
- **本轮 Agent 变更归因（1.109.0-rc487）** —— Agent 每轮开始不再把整个 git worktree 的历史脏文件写入会话；工具执行后改用前后快照签名归因本轮实际变化路径，右侧“产物”和底部“xx 个文件已更改”只展示当前会话/本轮 Agent 引发的文件。
- 审查 diff 预览也改为按已归因文件路径执行 `git diff`，不再把未归因的用户本地改动一起带进 diff 窗口。
- `GitWorktreeCoreTests` 新增归因过滤、基线变化路径和 diff 预览限域回归测试。
- 版本号从 **1.109.0-rc486** 提升为 **1.109.0-rc487**。pbxproj / Go agent / Help Info.plist / README badge×2 / product-overview / Mobile Gateway / Agent Harness 同步。

## 1.109.0-rc486 - 2026-06-30

### Changed
- **变更文件列表默认收起（1.109.0-rc486）** —— Agent composer 上方不再默认显示“前 3 个已变更文件”卡片；吸附的“xx 个文件已更改 +x -y 审查”栏在“审查”后新增展开/收起图标，用户点展开后才显示文件列表，点收起后隐藏。
- 展开状态改为按 Agent session/runtime 保存，切换会话不会互相串状态；“审查”仍打开完整 diff 预览。
- 版本号从 **1.109.0-rc485** 提升为 **1.109.0-rc486**。pbxproj / Go agent / Help Info.plist / README badge×2 / product-overview / Mobile Gateway / Agent Harness 同步。

## 1.109.0-rc485 - 2026-06-30

### Fixed
- **审查 diff 窗口不抢焦点（1.109.0-rc485）** —— Agent composer 的“审查”入口和弹出的 worktree diff 预览窗口中，标题、复制/关闭按钮、分隔线、滚动 diff 文本和外层容器均显式 `.focusable(false)`，避免窗口打开后把焦点环落到任一组件上。
- 版本号从 **1.109.0-rc484** 提升为 **1.109.0-rc485**。pbxproj / Go agent / Help Info.plist / README badge×2 / product-overview / Mobile Gateway / Agent Harness 同步。

## 1.109.0-rc484 - 2026-06-30

### Fixed
- **等待审批不自动打开右侧栏（1.109.0-rc484）** —— tool call 进入 `pendingApproval` / `awaitingConfirm` / `awaitingUserAnswer` 时，审批卡片已经以内联形式显示在 chat 区；任务监控不再因为“仅等待用户审批”自动展开右侧栏。
- 右侧任务监控仍可在用户手动打开时展示等待审批状态；后台任务、上下文压缩、媒体任务、待办、工作文件和学习事件等仍会按原逻辑自动展开。
- `AgentBackgroundJobsTests` 新增 snapshot 回归测试，锁住“等待审批是可见监控内容，但不是自动开栏内容”的区别。
- 版本号从 **1.109.0-rc483** 提升为 **1.109.0-rc484**。pbxproj / Go agent / Help Info.plist / README badge×2 / product-overview / Mobile Gateway / Agent Harness 同步。

## 1.109.0-rc483 - 2026-06-30

### Fixed
- **终端录制捷径落盘持久化（1.109.0-rc483）** —— 终端录制生成的捷径从 UserDefaults 迁到 `Application Support/WillDeep/terminal-shortcuts/shortcuts.json` 文件存储；首次读取会自动迁移旧版 `com.willdeep.terminalShortcuts.v1` 数据，退出 App 后重新进入仍能恢复录制内容。
- 终端捷径改名会立即写回同一份 JSON 文件，重新启动后继续显示改名后的标题；受保护输入仍只保存 Keychain 引用，捷径 JSON 不写入密码/Token 明文。
- `WillDeepTests` 增加终端捷径文件落盘和改名持久化回归测试。
- 版本号从 **1.109.0-rc482** 提升为 **1.109.0-rc483**。pbxproj / Go agent / Help Info.plist / README badge×2 / product-overview / Mobile Gateway 同步。

## 1.109.0-rc482 - 2026-06-30

### Fixed
- **Composer 打字回显卡顿 / 启动 CPU 跑满（1.109.0-rc482）** —— `sample` 采样定位到 debug 版主线程约 90% 时间在重建 composer 底部 picker pill（Workspace/Model/Mode/Approval/Execution/Overflow）的 SwiftUI view-list。根因：每次击键写入 `activeRuntime.input`（`@Published`），其 `objectWillChange` 经 `subscribeToActiveRuntime` 转发成 `AppState.objectWillChange`，重渲染所有 `appState` 观察者——包括整排 pill，且被 `ComposerAdaptiveControlStrip` 的 `ViewThatFits` 放大 3×。修复：打字路径用 `suppressActiveRuntimeForward` 抑制这条转发（输入缓冲 `runtime.input` 仍实时更新，发送/外部读取无感知；仅在输入空↔非空翻转时放行一次，让 `SendStopButton.canSend` 更新）。配套：slash 命令面板改由 `ComposerTextEditor` 协调器经 `onSlashQueryChange` 推送查询过滤（只在缓冲以 `/` 开头时更新，避免普通打字churn `@State` 又触发重渲染）；Plan banner 的「继续打字即留在 Plan 模式」从 `onChange(of: appState.agentInput)` 改走 `ComposerCard` 的 `onUserEdit` 回调。打字时若 slash 面板未开则几乎零重渲染（采样验证：pill 重建降 5～13×，`_makeViewList` 11000→1637）。
- **窗口切换 / 焦点变化时 composer 卡顿（1.109.0-rc482）** —— 窗口重新显示时 SwiftUI 必然重建 composer view 树，而 `ComposerAdaptiveControlStrip` 原先用 `ViewThatFits` 在三套布局变体间按窗口宽度挑一套，代价是**每次重建都要把每个变体整建一遍来测量**（采样：窗口切换时 `_makeViewList` 7854 次、占主线程一半多）。改为**固定单套布局**：Workspace / Model / Mode 固定展示，审批 / 执行器 / 插件 / 专家固定收进「更多 …」弹层（`ComposerOverflowControl` 新增 `.approval`，复用既有 `composer.overflow.approval` 文案），彻底去掉 `ViewThatFits` 与宽度自适应。采样验证：窗口切换时 composer 重建 `_makeViewList` 7854→0，主线程回到空闲。
- 版本号从 **1.109.0-rc481** 提升为 **1.109.0-rc482**。pbxproj / Go agent / Help Info.plist / README badge×2 / product-overview / Mobile Gateway 同步。

## 1.109.0-rc481 - 2026-06-29

### Fixed
- **Agent 窗口打开迟疑与标题串名（1.109.0-rc481）** —— Agent singleton 窗口现在会标记自己的 `NSWindow.identifier` 并持续恢复标题为 `WillDeep Agent`，编辑器文件名更新不会再误写到 Agent 窗口标题。
- Composer 的 workspace/runtime/model picker 改为维护菜单快照缓存；SwiftUI 布局 Agent 窗口时不再反复读取远端 runtime descriptor、排序 workspace 列表或重算 ad-hoc 模型分组，减少点击 Agent 模式后的主线程布局抖动。
- **终端输入与侧栏切换卡顿（1.109.0-rc481）** —— 左侧会话列表和右侧面板显隐不再对整棵 Agent 布局做隐式动画；终端 session/controller 改由终端面板局部观察，不再经 `AppState` 把每次字符/标题/tab 状态变化广播给全局；终端字体/Nerd Font 枚举改为进程级缓存，终端 tab 状态通知合并到下一轮 runloop，降低终端字符显示和侧栏切换时的 SwiftUI 重排压力。
- **启动内存占用（1.109.0-rc481）** —— 语音 ONNX 模型启动预热改为默认关闭；用过语音后仍可在 Settings → Voice 手动打开预热，以更高 idle memory 换取 push-to-talk 即刻响应。
- 版本号从 **1.109.0-rc480** 提升为 **1.109.0-rc481**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / Mobile Gateway / Agent Harness 同步。

## 1.109.0-rc480 - 2026-06-29

### Fixed
- **右侧侧栏打开延迟（1.109.0-rc480）** —— Agent 右侧侧栏打开时不再同步 `setFrame(display: true)` 强制窗口立即重绘；终端侧栏首次挂载时延后启动默认本地 shell，让侧栏壳子先显示，减少点击后约 1 秒才出现的体感延迟。
- 版本号从 **1.109.0-rc479** 提升为 **1.109.0-rc480**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / Mobile Gateway / Agent Harness 与短剧验收指针同步。

## 1.109.0-rc479 - 2026-06-29

### Fixed
- **终端录制 echo 查询缓存（1.109.0-rc479）** —— 终端录制期间连续普通键入复用 echo 状态缓存，不再每个按键都查询 PTY；收到非预期回显输出、缓存过期或重新启动终端时才重新读取 echo 状态，继续保证 `Password:` 等不回显输入按受保护片段记录。
- 版本号从 **1.109.0-rc478** 提升为 **1.109.0-rc479**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / Mobile Gateway / Agent Harness 与短剧验收指针同步。

## 1.109.0-rc478 - 2026-06-29

### Fixed
- **终端非录制输入延迟（1.109.0-rc478）** —— Agent 右侧终端在普通打字时不再执行录制用的 echo 状态检查和输入字节复制，只有真正开始录制后才检测 echo 并记录受保护输入，降低侧边栏终端键入时的 CPU 与延迟。
- 版本号从 **1.109.0-rc477** 提升为 **1.109.0-rc478**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / Mobile Gateway / Agent Harness 与短剧验收指针同步。

## 1.109.0-rc477 - 2026-06-29

### Changed
- **Composer 更多设置专家入口（1.109.0-rc477）** —— “专家”不再固定占用 composer 底部空间，改为进入“更多设置”；专家列表使用开关组件表达单向激活，未激活可打开，已激活保持开启并禁用，避免误关。
- Composer 底部控制行新增自适应布局：宽度充足时会逐步把执行器、插件、专家从“更多设置”里直接放出来显示，窄屏时仍收进“更多设置”，减少侧栏/输入区挤压。
- 版本号从 **1.109.0-rc476** 提升为 **1.109.0-rc477**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / Mobile Gateway / Agent Harness 与短剧验收指针同步。

## 1.109.0-rc476 - 2026-06-29

### Added
- **终端捷径录制（1.109.0-rc476）** —— Agent 右侧终端面板新增录制按钮，可把当前终端输入字节和输入间隔记录为可回放捷径，停止后显示在终端标签上方。
- 终端捷径支持在当前活动终端回放，并可通过捷径菜单改名或删除；回放期间不会被再次录进新捷径。

### Security
- 录制入口在写入 PTY 前检查终端 echo 状态；登录/密码等不回显输入保存为受保护片段，持久化时只在捷径 JSON 中留下 Keychain 引用。
- 回放受保护片段前会再次检查当前终端是否仍处于 echo-off；如果已经回到普通可回显输入，WillDeep 不会把该片段打出来。
- `WillDeepTests` 新增终端录制回归测试，验证 echo-off 输入不会落入捷径 JSON，且仍可通过受保护事件恢复。

### Changed
- 版本号从 **1.109.0-rc475** 提升为 **1.109.0-rc476**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / Mobile Gateway / Agent Harness 与短剧验收指针同步。

## 1.109.0-rc475 - 2026-06-29

### Changed
- **专家单向激活与侧栏门禁（1.109.0-rc475）** —— composer 专家入口从可反复开关改为会话内只允许“未激活 → 已激活”；已激活专家在菜单中保持勾选并禁用，避免误关后让模型工具面突然收窄。
- 短剧右侧面板现在复用专家可用性判断：未激活短剧专家时，侧栏菜单不再显示“短剧”，外部短剧打开请求也会被消费并拒绝。

### Fixed
- `WillDeepTests` 扩展专家回归测试，覆盖短剧工具过滤、短剧侧栏门禁和重复激活不回退。
- 版本号从 **1.109.0-rc474** 提升为 **1.109.0-rc475**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / Mobile Gateway / Agent Harness 与短剧验收指针同步。

## 1.109.0-rc474 - 2026-06-29

### Added
- **Composer 专家激活（1.109.0-rc474）** —— composer 底部新增“专家”入口，按会话激活可选专家包；短剧制作专家默认关闭，开启后才向模型暴露 `short_drama_*` 工具和短剧专家提示。
- Agent 会话新增 `activeExperts` 持久化字段，切换历史会话后专家激活状态保持不丢。

### Fixed
- **No workspace 会话迁移（1.109.0-rc474）** —— 没有 workspace 时已经聊过的会话，选择 workspace 后会原地绑定到该 workspace，不再把旧内容留在 “No workspace” 分组并另开一条会话。
- `WillDeepTests` 新增 no-workspace 历史会话迁移和短剧专家工具过滤回归测试。
- 版本号从 **1.109.0-rc473** 提升为 **1.109.0-rc474**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / Mobile Gateway / Agent Harness 与短剧验收指针同步。

## 1.109.0-rc473 - 2026-06-29

### Fixed
- **编辑器软换行行号与当前行高亮（1.109.0-rc473）** —— 行号尺现在只在逻辑行起始 fragment 绘制行号，长行软换行出来的延续视觉行不再重复显示同一个行号。
- 当前行高亮改为按光标所在 TextKit glyph fragment 对齐正文，不再因为逻辑行号相同而把软换行延续行、下一行行号区或行号与文本之间的小缝一起染上高亮色。
- `EditorCoreBehaviorTests` 新增 TextKit 软换行布局回归测试，守住“软换行延续 fragment 不产生新行号”的行为。
- 版本号从 **1.109.0-rc472** 提升为 **1.109.0-rc473**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / Mobile Gateway / Agent Harness 与短剧验收指针同步。

## 1.109.0-rc472 - 2026-06-29

### Fixed
- **编辑器 Paper 当前行高亮色（1.109.0-rc472）** —— Paper 主题当前行高亮从不透明米灰改为低透明品牌绿洗色，正文区和行号栏继续复用同一主题色，避免当前行在浅色编辑器里呈现灰脏条带感。
- `EditorCoreBehaviorTests` 新增回归测试，守住 Paper 当前行高亮为低透明、偏品牌绿的轻量提示色。
- 短剧 MVP 指针文档同步到当前 rc；本版本不新增短剧制作能力，rc471 的 handoff todo summary 验收口径继续保留。
- 版本号从 **1.109.0-rc471** 提升为 **1.109.0-rc472**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / Mobile Gateway / Agent Harness 与短剧验收指针同步。

## 1.109.0-rc471 - 2026-06-29

### Changed
- **短剧 handoff todo summary（1.109.0-rc471）** —— `scripts/short_drama_mvp_handoff_bundle.rb` 现在输出 `handoff_todo_summary`，汇总交接待办总数、阶段分布、manual/provider/verify/release 数量、证据路径数、复验命令数、缺证据待办数、是否需要机器重放和是否存在 release 待办。
- Markdown `Handoff Todos` 小节顶部会直接显示 todo 摘要，接手人不用先读完整 JSON 才知道当前包是“补人工证据/补 provider 证据/重跑机器验收/可 release”哪种状态。
- `scripts/short_drama_mvp_handoff_bundle_contract_test.rb` 新增 trial 和 ready release 的 todo summary 检查，确保摘要与 `handoff_todos` 数量、阶段、证据路径和复验命令一致。
- `scripts/version_consistency.rb` 新增守门，确保 handoff bundle 持续保留 `handoff_todo_summary`、`build_handoff_todo_summary`、`machine_replay_required`、`release_ready_todo_present` 和 contract 中的 summary 检查。
- `SHORT_DRAMA_AI_MVP_CUTOFF.md`、`SHORT_DRAMA_AI_MVP_TRYOUT.md` 和 `MANUAL_TEST_QUEUE.md` 同步把当前人工验收入口更新为 `1.109.0-rc471 — 短剧 handoff todo summary`。
- 版本号从 **1.109.0-rc470** 提升为 **1.109.0-rc471**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / Mobile Gateway / Agent Harness 与短剧验收指针同步。

## 1.109.0-rc470 - 2026-06-29

### Changed
- **短剧 handoff todo evidence（1.109.0-rc470）** —— `scripts/short_drama_mvp_handoff_bundle.rb` 的 `handoff_todos` 现在为每条待办输出 `evidence_paths` 和 `verification_command`，Markdown `Handoff Todos` 小节会直接列出 Evidence 与 Verify。
- manual/provider smoke 待办会指向对应的 manual/provider JSON、脱敏指南或 smoke evidence 报告；ready release 待办会保留 release 阶段证据路径和 handoff bundle contract 复验命令。
- `scripts/short_drama_mvp_handoff_bundle_contract_test.rb` 新增 `handoff todos point at evidence files` 检查，并加强 release todo 的 evidence/verification 断言。
- `scripts/version_consistency.rb` 新增守门，确保 handoff bundle 持续保留 `todo_evidence_paths`、`verification_command`、`evidence_paths` 和 contract 中的 todo evidence 检查。
- `SHORT_DRAMA_AI_MVP_CUTOFF.md`、`SHORT_DRAMA_AI_MVP_TRYOUT.md` 和 `MANUAL_TEST_QUEUE.md` 同步把当前人工验收入口更新为 `1.109.0-rc470 — 短剧 handoff todo evidence`。
- 版本号从 **1.109.0-rc469** 提升为 **1.109.0-rc470**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / Mobile Gateway / Agent Harness 与短剧验收指针同步。

## 1.109.0-rc469 - 2026-06-29

### Changed
- **短剧 handoff todos（1.109.0-rc469）** —— `scripts/short_drama_mvp_handoff_bundle.rb` 现在会把 readiness、pending reasons 和 smoke evidence next actions 收敛成 `handoff_todos`，每条待办包含 `order`、`phase`、`kind`、`title`、`detail`、`command` 和 `items`。
- 默认 trial handoff 会产出 `manual_smoke`、`provider_smoke` 和 `verify` 阶段，ready release 会产出 `release_candidate_handoff` 待办，交接人不用在多个报告小节中手动拼行动顺序。
- `scripts/short_drama_mvp_handoff_bundle_contract_test.rb` 新增 handoff todo 合约检查，守住 default trial 的 manual/provider/verify 阶段和 ready release 的 release 待办。
- `scripts/version_consistency.rb` 新增守门，确保 handoff bundle 持续保留 `handoff_todos`、`build_handoff_todos`、`## Handoff Todos`、`regenerate_acceptance_and_handoff` 和 contract 中的 todo 检查。
- `SHORT_DRAMA_AI_MVP_CUTOFF.md`、`SHORT_DRAMA_AI_MVP_TRYOUT.md` 和 `MANUAL_TEST_QUEUE.md` 同步把当前人工验收入口更新为 `1.109.0-rc469 — 短剧 handoff todos`。
- 版本号从 **1.109.0-rc468** 提升为 **1.109.0-rc469**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / Mobile Gateway / Agent Harness 与短剧验收指针同步。

## 1.109.0-rc468 - 2026-06-29

### Changed
- **短剧 handoff file fingerprints（1.109.0-rc468）** —— `scripts/short_drama_mvp_handoff_bundle.rb` 的 `handoff_files` 现在会为普通文件输出 `size_bytes` 与 SHA-256，为目录输出 `file_count`。
- `scripts/short_drama_mvp_handoff_bundle_contract_test.rb` 的 default_trial 场景新增 `handoff files include fingerprints` 检查，守住文件指纹和目录计数。
- `scripts/version_consistency.rb` 新增守门，确保 handoff bundle 持续保留 `Digest::SHA256`、`size_bytes`、`sha256`、`file_count` 和 contract 中的 fingerprint 检查。
- `SHORT_DRAMA_AI_MVP_CUTOFF.md`、`SHORT_DRAMA_AI_MVP_TRYOUT.md` 和 `MANUAL_TEST_QUEUE.md` 同步把当前人工验收入口更新为 `1.109.0-rc468 — 短剧 handoff file fingerprints`。
- 版本号从 **1.109.0-rc467** 提升为 **1.109.0-rc468**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / Mobile Gateway / Agent Harness 与短剧验收指针同步。

## 1.109.0-rc467 - 2026-06-29

### Changed
- **短剧 handoff bundle contract（1.109.0-rc467）** —— 新增 `scripts/short_drama_mvp_handoff_bundle_contract_test.rb`，用本地 acceptance JSON 构造默认 trial、ready release、manual_failed、machine_failed 和 missing evidence 五种交接包状态。
- 新合约会验证 `handoff_mode`、`ready_for_release`、blocking items、next actions 和命令退出码，防止后续把机器失败、人工失败、缺交付证据和 ready 状态混成同一种结论。
- `scripts/run_tests.sh` 和 GitHub Actions `Tests` workflow 接入该合约，并把 `short_drama_mvp_handoff_bundle_contract_report.md/json` 与场景目录上传为 artifacts。
- `scripts/version_consistency.rb` 新增守门，确保本地/远端 acceptance 持续运行 handoff bundle 状态矩阵。
- `SHORT_DRAMA_AI_MVP_CUTOFF.md`、`SHORT_DRAMA_AI_MVP_TRYOUT.md` 和 `MANUAL_TEST_QUEUE.md` 同步把当前人工验收入口更新为 `1.109.0-rc467 — 短剧 handoff bundle contract`。
- 版本号从 **1.109.0-rc466** 提升为 **1.109.0-rc467**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / Mobile Gateway / Agent Harness 与短剧验收指针同步。

## 1.109.0-rc466 - 2026-06-29

### Changed
- **短剧 handoff bundle（1.109.0-rc466）** —— 新增 `scripts/short_drama_mvp_handoff_bundle.rb`，读取 acceptance report 后生成最终交接包 Markdown/JSON。
- handoff bundle 会输出 `handoff_mode`、`ready_for_release`、readiness、blocking items、next actions、handoff files 和 remaining risks；默认未补完 manual/provider smoke 的试用包会明确显示为 `trial_package_with_explicit_pending_reasons`，不会误称 ready。
- `scripts/run_tests.sh` 和 GitHub Actions `Tests` workflow 接入 handoff bundle，并把 `short_drama_mvp_handoff_bundle.md/json` 写入 job summary 与 artifacts。
- 试用包 `acceptance-runbook.md/json` 与 `handoff-index.md/json` 增加 handoff bundle 命令和 required report 指针，接手人可从包内直接跑完整交付索引。
- `scripts/version_consistency.rb` 新增守门，确保本地/远端 acceptance 持续生成 handoff bundle，且脚本保留交付模式、证据文件、下一步动作和剩余风险。
- `SHORT_DRAMA_AI_MVP_CUTOFF.md`、`SHORT_DRAMA_AI_MVP_TRYOUT.md` 和 `MANUAL_TEST_QUEUE.md` 同步把当前人工验收入口更新为 `1.109.0-rc466 — 短剧 handoff bundle`。
- 版本号从 **1.109.0-rc465** 提升为 **1.109.0-rc466**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / Mobile Gateway / Agent Harness 与短剧验收指针同步。

## 1.109.0-rc465 - 2026-06-29

### Changed
- **短剧 smoke evidence readiness matrix（1.109.0-rc465）** —— 新增 `scripts/short_drama_mvp_smoke_evidence_contract_test.rb`，用本地试用包构造默认未测、ready、缺 evidence、manual_failed 和 sensitive blocked 五种 smoke evidence 场景。
- 新合约会验证 readiness、`next_actions` 和 sensitive evidence 脱敏输出，确保 raw fake bearer value 不进入 Markdown/JSON 报告。
- `scripts/run_tests.sh` 和 GitHub Actions `Tests` workflow 接入该合约，并把 `short_drama_mvp_smoke_evidence_contract_report.md/json` 与场景目录上传为 artifacts。
- `scripts/short_drama_mvp_acceptance_report.rb` 新增 `Smoke Evidence Readiness Matrix` 小节和 JSON `smoke_evidence_contract_report` 证据，总验收报告会显示矩阵场景结果。
- `scripts/version_consistency.rb` 新增守门，确保本地/远端 acceptance 持续运行 smoke evidence readiness matrix，并确保 acceptance report 持续展示该矩阵。
- `SHORT_DRAMA_AI_MVP_CUTOFF.md`、`SHORT_DRAMA_AI_MVP_TRYOUT.md` 和 `MANUAL_TEST_QUEUE.md` 同步把当前人工验收入口更新为 `1.109.0-rc465 — 短剧 smoke evidence readiness matrix`。
- 版本号从 **1.109.0-rc464** 提升为 **1.109.0-rc465**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / Mobile Gateway / Agent Harness 与短剧验收指针同步。

## 1.109.0-rc464 - 2026-06-29

### Changed
- **短剧 acceptance runbook（1.109.0-rc464）** —— `scripts/short_drama_mvp_tryout_package.rb` 现在会在试用包内生成 `acceptance-runbook.md/json`，列出重新生成试用包、smoke evidence report、MVP acceptance report 和完整本地 gate 的命令。
- `handoff-index.md/json` 增加 acceptance report 与 `scripts/run_tests.sh` 入口；接手人不用从多份文档里手动拼验收顺序。
- `scripts/short_drama_mvp_acceptance_report.rb` 新增 `Acceptance Runbook` 小节和 JSON `acceptance_runbook` 证据，验收报告会检查 runbook schema、关键命令和 `manual_pending` 判定口径。
- `scripts/version_consistency.rb` 新增守门，确保试用包持续保留 acceptance runbook，且 acceptance report 持续展示该交付入口。
- `SHORT_DRAMA_AI_MVP_CUTOFF.md`、`SHORT_DRAMA_AI_MVP_TRYOUT.md` 和 `MANUAL_TEST_QUEUE.md` 同步把当前人工验收入口更新为 `1.109.0-rc464 — 短剧 acceptance runbook`。
- 版本号从 **1.109.0-rc463** 提升为 **1.109.0-rc464**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / Mobile Gateway / Agent Harness 与短剧验收指针同步。

## 1.109.0-rc463 - 2026-06-29

### Changed
- **短剧 handoff pending reasons（1.109.0-rc463）** —— `scripts/short_drama_mvp_acceptance_report.rb` 现在输出 `handoff_pending_reasons` 和 Markdown 的 `Handoff Pending Reasons` 小节，明确列出机器检查失败、手测队列 pending、包内 manual smoke 未测、provider smoke 未测、证据缺失或 sensitive guard 阻断等原因。
- 交付报告不再只给 `manual_pending` 结论；接手人可以直接看到下一步要填哪几个包内手测步骤、是否只是保留真实 provider 外网风险。
- `scripts/version_consistency.rb` 新增守门，确保 handoff pending reasons 和 provider smoke untested 原因持续保留。
- `SHORT_DRAMA_AI_MVP_CUTOFF.md`、`SHORT_DRAMA_AI_MVP_TRYOUT.md` 和 `MANUAL_TEST_QUEUE.md` 同步把当前人工验收入口更新为 `1.109.0-rc463 — 短剧 handoff pending reasons`。
- 版本号从 **1.109.0-rc462** 提升为 **1.109.0-rc463**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / Mobile Gateway / Agent Harness 与短剧验收指针同步。

## 1.109.0-rc462 - 2026-06-29

### Changed
- **短剧 smoke 证据脱敏指南（1.109.0-rc462）** —— `scripts/short_drama_mvp_tryout_package.rb` 现在会在试用包内生成 `smoke-evidence-redaction-guide.md`，明确 allowed evidence、Never Paste 和被 sensitive guard 阻断后的修复步骤。
- Widget 预览、manual smoke checklist、provider API smoke 模板、handoff index、tryout package report 和 acceptance report 都会暴露该指南路径，交接人不用靠口头记忆判断哪些 evidence 能写。
- `scripts/version_consistency.rb` 新增守门，确保试用包和 acceptance report 持续保留 smoke evidence redaction guide。
- `SHORT_DRAMA_AI_MVP_CUTOFF.md`、`SHORT_DRAMA_AI_MVP_TRYOUT.md` 和 `MANUAL_TEST_QUEUE.md` 同步把当前人工验收入口更新为 `1.109.0-rc462 — 短剧 smoke 证据脱敏指南`。
- 版本号从 **1.109.0-rc461** 提升为 **1.109.0-rc462**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / Mobile Gateway / Agent Harness 与短剧验收指针同步。

## 1.109.0-rc461 - 2026-06-29

### Security
- **短剧 smoke 证据敏感信息守门（1.109.0-rc461）** —— `scripts/short_drama_mvp_smoke_evidence_report.rb` 现在会扫描手测/provider smoke JSON 中的 API key、Bearer token、webhook secret、`sk-` 风格密钥、带签名或 token 的 URL，并在报告中只输出脱敏定位信息。
- `scripts/short_drama_mvp_acceptance_report.rb` 会把 sensitive findings 纳入 `handoff_readiness`；一旦 evidence 中出现疑似密钥或私有回调 URL，交付状态直接变为 `blocked`。
- `scripts/version_consistency.rb` 新增守门，确保 standalone smoke evidence report 与 acceptance report 持续保留敏感信息扫描、脱敏输出和 `Smoke Evidence Sensitive Guard` 小节。
- `SHORT_DRAMA_AI_MVP_CUTOFF.md`、`SHORT_DRAMA_AI_MVP_TRYOUT.md` 和 `MANUAL_TEST_QUEUE.md` 同步把当前人工验收入口更新为 `1.109.0-rc461 — 短剧 smoke 证据敏感信息守门`。
- 版本号从 **1.109.0-rc460** 提升为 **1.109.0-rc461**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / Mobile Gateway / Agent Harness 与短剧验收指针同步。

## 1.109.0-rc460 - 2026-06-28

### Fixed
- **长消息预览保留头尾（1.109.0-rc460）** —— Agent 正在流式输出的超长消息不再只显示前 3000 字符，而是在同一预算内保留消息开头和结尾，并在中间插入省略提示，避免结论、报错或用户最后要求被截掉。
- 截断提示文案改为明确显示“保留前后片段 / 省略字符数”，中英文 i18n 同步更新；新增单测覆盖头尾保留预览行为。
- **编辑器选区内存稳定化（1.109.0-rc460）** —— Editor 模式选中文本时不再把完整选区文本作为 `@Published` 状态广播，避免拖选过程中反复刷新 Agent/sidebar 视图树并放大内存分配。
- 选区行号、选中行数计算改为直接在 `NSString` 上扫描，不再为每次选区变化创建 prefix/selected 子串数组；实时发布给 Agent 上下文的选区文本按 6000 字符预算截断，完整右键附件流程保持原逻辑。
- 版本号从 **1.109.0-rc458** 提升为 **1.109.0-rc460**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / Mobile Gateway / Agent Harness 与短剧验收指针同步。

## 1.109.0-rc458 - 2026-06-28

### Changed
- **短剧试用包交付索引（1.109.0-rc458）** —— `scripts/short_drama_mvp_tryout_package.rb` 现在会在样例包内生成 `handoff-index.md/json`，集中列出 start-here 执行顺序、关键文件、dry-run/import/review queue/smoke evidence 命令和剩余风险。
- `scripts/short_drama_mvp_acceptance_report.rb` 新增 `Handoff Index` 小节，并把 `handoff_index` 纳入 JSON 验收报告；`scripts/version_consistency.rb` 新增守门，确保试用包持续暴露该交付入口。
- `SHORT_DRAMA_AI_MVP_CUTOFF.md`、`SHORT_DRAMA_AI_MVP_TRYOUT.md` 和 `MANUAL_TEST_QUEUE.md` 同步把当前人工验收入口更新为 `1.109.0-rc458 — 短剧试用包交付索引`。
- 版本号从 **1.109.0-rc457** 提升为 **1.109.0-rc458**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / 短剧 cutoff/tryout 文档同步。

## 1.109.0-rc457 - 2026-06-28

### Changed
- **短剧 smoke 证据下一步建议（1.109.0-rc457）** —— `scripts/short_drama_mvp_smoke_evidence_report.rb` 现在会输出 `next_actions`，按 JSON 解析错误、schema 漂移、失败 smoke、缺 evidence、本地手测待完成和 provider smoke 待记录分别给出下一步。
- `scripts/short_drama_mvp_acceptance_report.rb` 新增 `Smoke Evidence Next Actions` 小节，并把 standalone smoke evidence report 的 `next_actions` 纳入 JSON 报告，交付时不再只看到 `manual_pending` 这个结论。
- `scripts/version_consistency.rb` 新增守门，确保 standalone smoke evidence report 和 acceptance report 持续保留下一步建议。
- `SHORT_DRAMA_AI_MVP_CUTOFF.md`、`SHORT_DRAMA_AI_MVP_TRYOUT.md` 和 `MANUAL_TEST_QUEUE.md` 同步把当前人工验收入口更新为 `1.109.0-rc457 — 短剧 smoke 证据下一步建议`。
- 版本号从 **1.109.0-rc456** 提升为 **1.109.0-rc457**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / 短剧 cutoff/tryout 文档同步。

## 1.109.0-rc456 - 2026-06-28

### Changed
- **短剧 smoke 证据自检报告（1.109.0-rc456）** —— 新增 `scripts/short_drama_mvp_smoke_evidence_report.rb`，可读取试用包内 `manual-smoke-results-template.json` 与 `provider-api-smoke-template.json`，输出独立 Markdown/JSON 报告，明确 `ready`、`manual_pending`、`manual_failed` 或 `blocked`。
- 本地 `scripts/run_tests.sh` 和 GitHub Actions `Tests` workflow 现在都会在生成试用包后生成 `short_drama_mvp_smoke_evidence_report.md/json`，并把报告加入 job summary 与 artifacts。
- `scripts/short_drama_mvp_acceptance_report.rb` 现在会汇总 standalone smoke evidence report，并在交付验收报告中展示 `Smoke Evidence Report` 小节；`scripts/version_consistency.rb` 新增守门，防止该自检入口从本地/远端验收链路中脱落。
- `SHORT_DRAMA_AI_MVP_CUTOFF.md`、`SHORT_DRAMA_AI_MVP_TRYOUT.md` 和 `MANUAL_TEST_QUEUE.md` 同步把当前人工验收入口更新为 `1.109.0-rc456 — 短剧 smoke 证据自检报告`。
- 版本号从 **1.109.0-rc455** 提升为 **1.109.0-rc456**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / 短剧 cutoff/tryout 文档同步。

## 1.109.0-rc455 - 2026-06-28

### Changed
- **短剧 provider smoke 证据守门（1.109.0-rc455）** —— `scripts/short_drama_mvp_acceptance_report.rb` 现在会统计 provider smoke 中 pass/fail 行的 evidence 填写情况，并输出 `evidence_required_count`、`evidence_present_count`、`evidence_missing_count` 与缺失项。
- `handoff_readiness` 现在会把真实 provider smoke 的 failed 行计入 `manual_failed`；pass/fail 行缺少 evidence 时保持 `manual_pending`。默认 `untested` provider smoke 仍作为剩余风险暴露，不阻断本地 MVP 验收。
- `scripts/version_consistency.rb` 新增守门，确保 provider smoke 摘要持续包含 evidence 质量判断。
- `SHORT_DRAMA_AI_MVP_CUTOFF.md`、`SHORT_DRAMA_AI_MVP_TRYOUT.md` 和 `MANUAL_TEST_QUEUE.md` 同步把当前人工验收入口更新为 `1.109.0-rc455 — 短剧 provider smoke 证据守门`。
- 版本号从 **1.109.0-rc454** 提升为 **1.109.0-rc455**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / 短剧 cutoff/tryout 文档同步。

## 1.109.0-rc454 - 2026-06-28

### Changed
- **短剧 provider smoke 模板（1.109.0-rc454）** —— `scripts/short_drama_mvp_tryout_package.rb` 现在会生成 `provider-api-smoke-template.md/json`，覆盖 some.im 图片/视频异步任务与 Replicate 放大/蒙版编辑的真实 provider smoke 证据格式。
- `scripts/short_drama_mvp_acceptance_report.rb` 新增 `provider_api_smoke_summary` 和 Markdown 的 `Provider API Smoke Templates` 小节，让交付报告能看到真实 provider smoke 模板、provider 覆盖和 capability 覆盖；CI 仍不调用外网 API。
- `scripts/version_consistency.rb` 新增守门，确保试用包持续包含 provider API smoke 模板，并确保验收报告持续汇总这些模板。
- `SHORT_DRAMA_AI_MVP_CUTOFF.md`、`SHORT_DRAMA_AI_MVP_TRYOUT.md` 和 `MANUAL_TEST_QUEUE.md` 同步把当前人工验收入口更新为 `1.109.0-rc454 — 短剧 provider smoke 模板`。
- 版本号从 **1.109.0-rc453** 提升为 **1.109.0-rc454**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / 短剧 cutoff/tryout 文档同步。

## 1.109.0-rc453 - 2026-06-28

### Changed
- **短剧验收报告补手测证据摘要（1.109.0-rc453）** —— `scripts/short_drama_mvp_acceptance_report.rb` 现在会统计包内 `manual-smoke-results-template.json` 中 pass/fail 步骤的 evidence 填写情况，输出 `manual_evidence_summary` 和 Markdown 的 `Manual Evidence` 小节。
- `handoff_readiness` 在手测步骤标为 pass/fail 但 evidence 为空时会保持 `manual_pending`，避免“状态已填”被误读成“交付证据已齐”。
- `scripts/version_consistency.rb` 新增守门，确保验收报告持续保留手测证据摘要能力。
- `SHORT_DRAMA_AI_MVP_CUTOFF.md`、`SHORT_DRAMA_AI_MVP_TRYOUT.md` 和 `MANUAL_TEST_QUEUE.md` 同步把当前人工验收入口更新为 `1.109.0-rc453 — 短剧手测证据摘要`。
- 版本号从 **1.109.0-rc452** 提升为 **1.109.0-rc453**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / 短剧 cutoff/tryout 文档同步。

## 1.109.0-rc452 - 2026-06-28

### Changed
- **短剧验收报告读取包内手测结果文件（1.109.0-rc452）** —— `scripts/short_drama_mvp_acceptance_report.rb` 现在会解析试用包 `manual-smoke-results-template.json`，输出 `manual_results_summary` 和 Markdown 的 `Manual Results File` 小节。
- `handoff_readiness` 会同时考虑 manual queue 与包内手测结果文件；若结果文件出现 failed 步骤，整体交付状态会显示 `manual_failed`。
- `scripts/version_consistency.rb` 新增守门，确保验收报告持续保留手测结果文件摘要能力。
- `scripts/version_consistency.rb` 的短剧 pending 指针检查允许当前无待办指针，避免 `MANUAL_TEST_QUEUE.md` 最新短剧小节全 ✅ 后被误判为缺失版本。
- `SHORT_DRAMA_AI_MVP_CUTOFF.md`、`SHORT_DRAMA_AI_MVP_TRYOUT.md` 和 `MANUAL_TEST_QUEUE.md` 同步把当前人工验收入口更新为 `1.109.0-rc452 — 短剧手测结果文件摘要`。
- 版本号从 **1.109.0-rc451** 提升为 **1.109.0-rc452**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / 短剧 cutoff/tryout 文档同步。

## 1.109.0-rc451 - 2026-06-28

### Changed
- **短剧显式剩余风险纳入交付守门（1.109.0-rc451）** —— `scripts/short_drama_mvp_acceptance_report.rb` 现在会检查 cutoff 中至少保留一条真实剩余风险，避免交付摘要在风险被误删时兜底成“无剩余风险”。
- `scripts/version_consistency.rb` 新增 `Short drama cutoff preserves explicit remaining risks` delivery gate，并要求验收报告保留 `cutoff keeps explicit remaining risks` 检查。
- `AgentBackgroundJobsTests` 的运行任务计数用例改用 Debug/test-only job snapshot 注入，避免完整 Swift Testing 并发套件里真实 `Process` 退出时序导致偶发红灯。
- `SHORT_DRAMA_AI_MVP_CUTOFF.md`、`SHORT_DRAMA_AI_MVP_TRYOUT.md` 和 `MANUAL_TEST_QUEUE.md` 同步把当前人工验收入口更新为 `1.109.0-rc451 — 短剧显式剩余风险守门`。
- 版本号从 **1.109.0-rc450** 提升为 **1.109.0-rc451**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / 短剧 cutoff/tryout 文档同步。

## 1.109.0-rc450 - 2026-06-28

### Changed
- **短剧交付就绪摘要纳入版本一致性守门（1.109.0-rc450）** —— `scripts/version_consistency.rb` 现在会检查短剧验收报告持续输出 `handoff_readiness`、`remaining_risks`、`Handoff Readiness` 和 `Remaining Risks`，防止交付就绪/剩余风险摘要在后续改动中被删漏。
- `scripts/short_drama_mvp_acceptance_report.rb` 会反向确认版本报告中存在该 delivery gate，确保本地验收摘要和版本一致性守门互相接住。
- 稳定 `AgentBackgroundJobsTests` 的后台任务计数 drain 用例，改用短暂后台任务自然完成，避免 shell/沙箱子进程信号时序导致完整 Xcode 套件偶发红灯。
- `SHORT_DRAMA_AI_MVP_CUTOFF.md`、`SHORT_DRAMA_AI_MVP_TRYOUT.md` 和 `MANUAL_TEST_QUEUE.md` 同步把当前人工验收入口更新为 `1.109.0-rc450 — 短剧交付就绪摘要守门`。
- 版本号从 **1.109.0-rc449** 提升为 **1.109.0-rc450**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / 短剧 cutoff/tryout 文档同步。

## 1.109.0-rc449 - 2026-06-28

### Changed
- **短剧验收摘要补交付就绪状态（1.109.0-rc449）** —— `scripts/short_drama_mvp_acceptance_report.rb` 现在输出 `handoff_readiness` 和 `remaining_risks`，Markdown 报告新增 `Handoff Readiness` / `Remaining Risks`，明确区分机器守门通过、人工 smoke 待测和当前剩余风险。
- `SHORT_DRAMA_AI_MVP_CUTOFF.md`、`SHORT_DRAMA_AI_MVP_TRYOUT.md` 和 `MANUAL_TEST_QUEUE.md` 同步把当前人工验收入口更新为 `1.109.0-rc449 — 短剧交付就绪与剩余风险摘要`。
- 版本号从 **1.109.0-rc448** 提升为 **1.109.0-rc449**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / 短剧 cutoff/tryout 文档同步。

## 1.109.0-rc448 - 2026-06-28

### Changed
- **短剧验收摘要补手动 smoke 状态（1.109.0-rc448）** —— `scripts/short_drama_mvp_acceptance_report.rb` 现在会解析 `MANUAL_TEST_QUEUE.md` 当前短剧小节，输出 `manual_smoke_summary`，在 Markdown/JSON 中展示 ✅/⏳/❌ 计数和待办项标题，交付时能同时看到机器证据和人工剩余项。
- `SHORT_DRAMA_AI_MVP_CUTOFF.md`、`SHORT_DRAMA_AI_MVP_TRYOUT.md` 和 `MANUAL_TEST_QUEUE.md` 同步把当前人工验收入口更新为 `1.109.0-rc448 — 短剧验收摘要手动状态`。
- 版本号从 **1.109.0-rc447** 提升为 **1.109.0-rc448**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / 短剧 cutoff/tryout 文档同步。

## 1.109.0-rc447 - 2026-06-28

### Added
- **短剧交付验收摘要报告（1.109.0-rc447）** —— 新增 `scripts/short_drama_mvp_acceptance_report.rb`，汇总 `version_report`、本地试用包报告、手动 smoke 结果模板、cutoff/tryout/manual queue 指针，生成 `short_drama_mvp_acceptance_report.md/json`，方便交付时一眼确认短剧 MVP 可用版证据。
- 本地 `scripts/run_tests.sh` 与 GitHub Actions `Tests` workflow 接入短剧验收摘要报告，并上传/追加到 CI summary；`scripts/version_consistency.rb` 新增 Delivery Gate，防止本地和远端验收漏跑该报告。
- `SHORT_DRAMA_AI_MVP_CUTOFF.md`、`SHORT_DRAMA_AI_MVP_TRYOUT.md` 和 `MANUAL_TEST_QUEUE.md` 同步把当前人工验收入口更新为 `1.109.0-rc447 — 短剧交付验收摘要`。
- 版本号从 **1.109.0-rc446** 提升为 **1.109.0-rc447**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / 短剧 cutoff/tryout 文档同步。

## 1.109.0-rc446 - 2026-06-28

### Added
- **短剧人工 smoke 结果模板（1.109.0-rc446）** —— `scripts/short_drama_mvp_tryout_package.rb` 生成的本地试用包新增 `manual-smoke-results-template.md` 和 `manual-smoke-results-template.json`，用于记录 dry-run 导入、正式导入、`latest-media-import`、Widget 结构化动作和 review queue dry-run 的人工验收 evidence。
- 试用包 JSON/Markdown 报告新增结果模板路径，并自检结果模板覆盖关键步骤且初始状态为 `untested`；`scripts/version_consistency.rb` 新增交付守门，防止试用包以后漏掉人工 smoke 结果模板。
- `SHORT_DRAMA_AI_MVP_CUTOFF.md`、`SHORT_DRAMA_AI_MVP_TRYOUT.md` 和 `MANUAL_TEST_QUEUE.md` 同步把当前人工验收入口更新为 `1.109.0-rc446 — 短剧人工 smoke 结果模板`。
- 版本号从 **1.109.0-rc445** 提升为 **1.109.0-rc446**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / 短剧 cutoff/tryout 文档同步。

## 1.109.0-rc445 - 2026-06-28

### Fixed
- **短剧交付验收入口纳入版本一致性守门（1.109.0-rc445）** —— `scripts/version_consistency.rb` 现在会检查 cutoff 是否明确写出本地一键 `scripts/run_tests.sh`、远端 `go test ./...` 和 GitHub Actions `Run XeditTests` 门槛，防止交付说明漏跑关键路径。
- `SHORT_DRAMA_AI_MVP_CUTOFF.md` 的可用版验收清单补充本地一键入口和远端 CI Go/Xedit 验收入口；试用文档与人工 smoke 队列同步指向 `1.109.0-rc445 — 短剧交付验收入口守门`。
- 前台 `run_command` 改为同步 drain stdout/stderr pipe，避免短命令在进程退出时偶发丢掉最后一段 stdout，稳定本轮交付验收。
- 版本号从 **1.109.0-rc444** 提升为 **1.109.0-rc445**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / 短剧 cutoff/tryout 文档同步。

## 1.109.0-rc444 - 2026-06-28

### Fixed
- **短剧过期指针 smoke 纳入版本一致性守门（1.109.0-rc444）** —— `scripts/version_consistency.rb` 现在会检查仍处于 `⏳` 状态的短剧文档指针 smoke，防止人工队列继续要求当前试用文档指向旧版本。
- 将已被新版覆盖的 rc442/rc443 短剧文档指针检查标为机器守门已覆盖，并新增 `1.109.0-rc444 — 短剧过期指针 smoke 守门` 作为当前人工验收入口。
- 版本号从 **1.109.0-rc443** 提升为 **1.109.0-rc444**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / 短剧试用文档同步。

## 1.109.0-rc443 - 2026-06-28

### Fixed
- **短剧人工 smoke 队列顺序纳入版本一致性守门（1.109.0-rc443）** —— `scripts/version_consistency.rb` 现在同时检查语义最新版短剧 smoke 小节和文档中最后一个短剧 smoke 小节，防止试用文档指向的新验收入口夹在旧小节中间。
- 短剧试用文档的人工 smoke 记录入口更新为 `1.109.0-rc443 — 短剧人工 smoke 队列顺序守门`，方便交付前直接定位最新人工验收项。
- 版本号从 **1.109.0-rc442** 提升为 **1.109.0-rc443**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / 短剧试用文档同步。

## 1.109.0-rc442 - 2026-06-28

### Fixed
- **短剧收口文档纳入版本一致性守门（1.109.0-rc442）** —— `scripts/version_consistency.rb` 现在会同时检查 `SHORT_DRAMA_AI_MVP_CUTOFF.md`、`SHORT_DRAMA_AI_MVP_TRYOUT.md` 和 `MANUAL_TEST_QUEUE.md` 的短剧基线/验收小节版本，防止短剧可用版文档指向旧 smoke 小节。
- 修正短剧试用文档的人工 smoke 记录入口，当前基线、验收记录和手动队列最新短剧小节统一指向 `1.109.0-rc442`。
- 版本号从 **1.109.0-rc441** 提升为 **1.109.0-rc442**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / 短剧试用文档同步。

## 1.109.0-rc441 - 2026-06-28

### Fixed
- **run_command stdout 收尾读取稳定化（1.109.0-rc441）** —— 前台 `run_command` 在进程结束后改为同步 drain stdout/stderr pipe 剩余数据，避免 GitHub macOS runner 偶发出现命令 `exit=0` 但最后一段 stdout 未进入 payload，导致 `runCommandClosesStandardInputForHeadlessCLIs` 间歇失败。
- 版本号从 **1.109.0-rc440** 提升为 **1.109.0-rc441**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / 短剧试用文档同步。

## 1.109.0-rc440 - 2026-06-28

### Added
- **短剧 MVP 试用包内置手动 smoke 清单（1.109.0-rc440）** —— `scripts/short_drama_mvp_tryout_package.rb` 现在会生成 `manual-smoke-checklist.md`，把 dry-run 导入、正式导入、媒体任务侧栏、`latest-media-import` 和 Widget 结构化动作验收步骤放进试用包本身。
- 试用包 JSON/Markdown 报告新增 `manual_smoke_checklist_path`，并自检清单必须覆盖 `<widget-handoff-action>` 与 `short_drama_import_review_csv`，避免交付包只适合机器跑、不适合人验收。
- 版本号从 **1.109.0-rc439** 提升为 **1.109.0-rc440**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / 短剧试用文档同步。

## 1.109.0-rc439 - 2026-06-28

### Changed
- **短剧 MVP 试用包 Widget 改为结构化动作（1.109.0-rc439）** —— `widget-preview.html` 现在生成 `sendToolAction` 按钮，直接携带 `import_media_manifest` dry-run / 正式导入和 `short_drama_import_review_csv` review queue dry-run 参数，保留 `sendPrompt` 作为兜底。
- `scripts/short_drama_mvp_tryout_package.rb` 新增结构化 Widget 动作检查，确保本地试用包覆盖网页 Widget 到聊天窗口的工具动作回传路径。
- 版本号从 **1.109.0-rc438** 提升为 **1.109.0-rc439**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / 短剧试用文档同步。

## 1.109.0-rc438 - 2026-06-28

### Added
- **短剧 MVP 本地试用包生成器（1.109.0-rc438）** —— 新增 `scripts/short_drama_mvp_tryout_package.rb`，可在 `build/ci/short_drama_mvp_tryout_package` 生成不调用外网 API 的制作包样例，覆盖 completed 本地产物、pending 远端视频任务、失败修复项、review queue、gap report 和 Widget handoff。
- 本地 `scripts/run_tests.sh` 与 GitHub Actions 新增试用包生成步骤，并产出 `short_drama_mvp_tryout_package_report.md/json` 与可下载样例包，避免“可试用包”只停留在文档里。
- 版本号从 **1.109.0-rc437** 提升为 **1.109.0-rc438**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / 短剧试用文档 / CI 配置同步。

## 1.109.0-rc437 - 2026-06-28

### Fixed
- **短剧/媒体工具扩容后不再误触发上下文压缩（1.109.0-rc437）** —— 自动压缩判断改为只按可被压缩的会话历史 token 触发，固定工具 schema 开销不再让短聊天在小窗口模型下提前进入压缩。
- `agent token estimate includes tool schemas without exploding short chats` 测试上限同步到当前 94 个工具的规模，仍保留工具 schema 估算不能失控的守门。
- 版本号从 **1.109.0-rc436** 提升为 **1.109.0-rc437**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc436 - 2026-06-28

### Changed
- **manifest 导回写入聊天运行时上下文（1.109.0-rc436）** —— `import_media_manifest` 正式导入本地产物、登记 pending 远端任务或记录失败任务后，会写入 `<latest-media-import>`，下一轮聊天可直接看到 package、manifest、pending/completed/failed 任务和继续动作。
- 新增 `AgentMediaImportContext.swift` 与 `scripts/media_import_context_contract_test.rb`，并接入本地测试和 GitHub Actions，守住 Ruby/Skill/第三方 API 制作包导回后的聊天接力。
- 新增 `docs/SHORT_DRAMA_AI_MVP_CUTOFF.md`，冻结本轮短剧 AI 能力为可用 MVP，记录验收命令、暂缓范围、手动 smoke 场景和剩余风险。
- 版本号从 **1.109.0-rc435** 提升为 **1.109.0-rc436**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc435 - 2026-06-28

### Changed
- **短剧制作缺口精确接力（1.109.0-rc435）** —— 项目和分集的“补主图 / 补视频 / 审片”按钮会分别写入 `<short-drama-production-gap-action>`，直接携带 dry-run、正式提交、打开/刷新媒体任务和检查项处理参数。
- 新增 `scripts/production_gap_actions_contract_test.rb` 并接入本地测试与 GitHub Actions，守住制作缺口动作条到聊天窗口的结构化接力。
- 版本号从 **1.109.0-rc434** 提升为 **1.109.0-rc435**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc434 - 2026-06-28

### Changed
- **媒体任务刷新写入聊天运行时上下文（1.109.0-rc434）** —— “媒体任务”侧栏手动刷新运行中/卡住任务后，会记录 `latest-media-task-refresh`，下一轮聊天可读取刷新原因、范围、任务句柄和刷新后的运行/失败/完成统计。
- 新增 `AgentMediaTaskRefreshContext.swift` 与 `scripts/media_task_refresh_contract_test.rb`，并接入本地测试和 GitHub Actions，守住手动刷新与聊天协作的接力契约。
- 版本号从 **1.109.0-rc433** 提升为 **1.109.0-rc434**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc433 - 2026-06-28

### Changed
- **短剧侧栏制作缺口动作条（1.109.0-rc433）** —— 项目卡里的“制作缺口”从单个文本入口升级为动作条，缺主图、缺视频、未解决检查项和缺人物/场景参考图会分别给出可点击动作。
- 新增 `AgentShortDramaProductionGapActions.swift` 承载制作缺口 UI；主短剧侧栏文件减少到 2588 行，继续向拆分热点文件推进。
- 短剧媒体合约更新为检查新的缺口动作条和参考图直提闭包；版本号从 **1.109.0-rc432** 提升为 **1.109.0-rc433**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc432 - 2026-06-28

### Changed
- **图片蒙版上下文携带真实 mask_path（1.109.0-rc432）** —— 图片蒙版侧栏的“发送到聊天”对通用图片也可见；当用户已经画选区但尚未手动导出时，会先导出当前蒙版并把真实 `current_mask_path` 写入聊天上下文。
- `edit_image_with_mask` 的 `submit_with_existing_mask_arguments` / `submit_inpaint_arguments` / `submit_erase_arguments` 会优先使用真实 `mask_path`，方便聊天、Skill 或 Ruby 脚本直接继续提交 Replicate / some.im 编辑任务。
- 新增 `scripts/image_edit_contract_test.rb` 并接入本地测试与 GitHub Actions，发布 `image_edit_report.md/json`，守住图片蒙版编辑到聊天接力的关键契约。
- 版本号从 **1.109.0-rc431** 提升为 **1.109.0-rc432**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc431 - 2026-06-28

### Changed
- **Widget 侧栏协作合约测试（1.109.0-rc431）** —— 新增 `scripts/widget_side_panel_contract_test.rb`，用独立 Ruby 合约守住右侧网页组件面板的推荐动作/可用动作必须写入 `latest-widget-tool-action`。
- 本地 `scripts/run_tests.sh` 与 GitHub Actions 会运行并发布 `widget_side_panel_report.md/json`，避免 Skill/Ruby 生成网页工作台与聊天窗口的结构化接力后续回退。
- 版本号从 **1.109.0-rc430** 提升为 **1.109.0-rc431**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc430 - 2026-06-28

### Changed
- **侧边栏 Widget 动作写入聊天上下文（1.109.0-rc430）** —— 右侧网页组件面板里的推荐动作和可用动作点击后，会同步记录 `latest-widget-tool-action`，聊天窗口下一轮可读取明确工具名、参数、来源和侧边栏动作标签。
- 侧边栏仍保留原有安全直达预览：打开媒体任务、刷新远端任务、打开蒙版、候选图、短剧分镜板或 Skill/Ruby 生成的本地 HTML 时，不会直接提交付费生成或修改检查项。
- 版本号从 **1.109.0-rc429** 提升为 **1.109.0-rc430**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc429 - 2026-06-28

### Changed
- **远端媒体任务动作本地定位（1.109.0-rc429）** —— `sendToolAction` 的本地预览支持 `replicate_poll_prediction` / `some_im_poll_media_task` / `replicate_cancel_prediction` / `some_im_cancel_media_task`。
- 远端 poll 动作会按 `task_id`、远端 id、status URL 或 cancel URL 匹配本地媒体任务，打开对应任务范围并立即刷新；远端 cancel 动作只打开匹配任务范围供核对，避免本地暗中取消。
- 版本号从 **1.109.0-rc428** 提升为 **1.109.0-rc429**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc428 - 2026-06-28

### Changed
- **结构化网页动作本地预览（1.109.0-rc428）** —— 新增 `AgentWidgetLocalActionPreview`，`sendToolAction` 会先对安全本地动作做预处理，再把结构化动作发送到聊天。
- 本地预处理覆盖打开/刷新媒体任务侧栏、打开图片蒙版编辑器、生成短剧分镜/候选图 Widget、生成通用候选图 Widget、加载本地 `show_widget` HTML；不会直接提交生成、放大、删除或关闭检查项等有成本/改状态动作。
- 版本号从 **1.109.0-rc427** 提升为 **1.109.0-rc428**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc427 - 2026-06-28

### Changed
- **候选图按钮结构化接力（1.109.0-rc427）** —— 媒体任务候选图和通用候选图 Widget 的选图、打开蒙版、擦除、放大、图生视频按钮接入 `sendToolAction`。
- `sendToolAction` 携带 `<image-choice>` / `<media-task-image-choice>` 时也会记录 `latest-image-choice`，带短剧分镜或人物/场景资产锚点的选择动作仍能在下一轮聊天里直接回填主图、参考图或继续编辑。
- 版本号从 **1.109.0-rc426** 提升为 **1.109.0-rc427**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc426 - 2026-06-28

### Changed
- **短剧分镜板按钮结构化接力（1.109.0-rc426）** —— 短剧分镜板里的全剧/单集批量图片视频、查看/刷新任务、导出制作包、候选图选择、蒙版重绘/擦除和主图放大按钮改用 `sendToolAction`。
- 新增 `toolActionButton` 统一把工具名、参数、备注和 action key 编码为 Widget 结构化动作，避免 HTML 按钮继续依赖自然语言 prompt 反推工具调用。
- 版本号从 **1.109.0-rc425** 提升为 **1.109.0-rc426**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc425 - 2026-06-28

### Changed
- **网页组件结构化工具动作回传（1.109.0-rc425）** —— 新增 `AgentWidgetToolAction`，Widget 可通过 `sendToolAction({tool, arguments, note, action_key})` 把明确工具动作交回聊天，而不是只能发送自然语言提示。
- Widget WebView 桥会校验工具名、参数和备注长度，记录 `latest-widget-tool-action`，并把 `<widget-tool-action>` 注入聊天；下一轮模型请求也会携带 `latest-widget-tool-action`，方便 Skill/Ruby 短剧网页、审片页和候选图页稳定接力到工具调用。
- `show_widget` 工具描述补充 `sendToolAction` 用法；版本号从 **1.109.0-rc424** 提升为 **1.109.0-rc425**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc424 - 2026-06-28

### Changed
- **媒体任务完成写入聊天运行时上下文（1.109.0-rc424）** —— 新增 `AgentMediaTaskCompletionContext`，在异步媒体任务完成队列 drain 时记录最近完成任务的 provider、状态、产物路径、短剧锚点和后续动作。
- 下一轮模型请求会携带 `latest-media-task-completion`，可直接继续候选图选择、设为分镜主图、图生视频、蒙版编辑、擦除、放大、打开分镜板或关闭检查项；图片编辑任务完成时也会刷新 `latest-image-edit-submission`。
- 版本号从 **1.109.0-rc423** 提升为 **1.109.0-rc424**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc423 - 2026-06-28

### Changed
- **蒙版编辑提交写入聊天运行时上下文（1.109.0-rc423）** —— 新增 `AgentImageEditSubmission`，记录最近一次 Replicate / some.im 蒙版重绘或擦除任务的 source image、mask、任务句柄、provider、状态、远端轮询地址和短剧锚点。
- 图片蒙版面板和 `edit_image_with_mask` 工具提交任务后都会更新当前 runtime 的 `latest-image-edit-submission`；下一轮模型请求会直接携带该结构化块，便于继续刷新任务、重开带旧蒙版的编辑器、选择完成产物、图生视频或关闭短剧检查项。
- 版本号从 **1.109.0-rc422** 提升为 **1.109.0-rc423**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc422 - 2026-06-28

### Changed
- **候选图选择写入聊天运行时上下文（1.109.0-rc422）** —— Widget 内的图片候选按钮发送聊天提示前，会先解析 `<image-choice>` / `<media-task-image-choice>` / `<short-drama-image-choice>` 并记录为当前会话的 `latest-image-choice`。
- 下一轮模型请求会携带结构化 `latest-image-choice`，包含 `image_path`、短剧分镜/资产锚点、推荐工具和 post-select 动作键，后续图生视频、蒙版编辑、擦除、放大或短剧主图选择不必从长聊天里反查用户点了哪张图。
- 带短剧分镜锚点的“选择”动作会同步调用本地短剧 store 更新分镜主图；带人物/场景资产锚点的选择会把图片加入资产参考图，侧栏与聊天协作更贴近真实制作流。
- 版本号从 **1.109.0-rc421** 提升为 **1.109.0-rc422**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc421 - 2026-06-28

### Changed
- **网页组件支持重载源 HTML（1.109.0-rc421）** —— Widget 来源区在 `source_path` / `html_path` 指向 `.html`、`.htm` 或 `.svg` 文件时显示刷新按钮。
- 刷新会重新读取最新源 HTML，创建新的 `AgentWidget` 并放回当前 runtime 的 Widget 历史，同时保留原 `contextLines`，追加 `reloaded_from_widget_id`、`reloaded_at` 和最新 `html_path`，方便 Skill/Ruby 脚本重跑后直接在侧栏查看新预览。
- 版本号从 **1.109.0-rc420** 提升为 **1.109.0-rc421**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc420 - 2026-06-28

### Changed
- **网页组件路径边界共享（1.109.0-rc420）** —— 新增 `AgentWidgetPathResolver.swift`，统一 Widget HTML、源文件和制作包目录的本地安全路径解析。
- `show_widget` 工具、右侧网页组件面板和 Widget 来源区现在共用 workspace / 系统临时目录 / WillDeep 短剧导出目录边界，减少 Skill/Ruby 网页嵌入、制作包预览和 Finder 定位规则漂移。
- 版本号从 **1.109.0-rc419** 提升为 **1.109.0-rc420**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc419 - 2026-06-28

### Changed
- **网页组件来源区拆分（1.109.0-rc419）** —— 将 Widget 来源摘要、源 HTML/制作包路径展示和 Finder 定位动作从 `AgentSidePanel.swift` 拆到独立 `AgentWidgetSourceRows.swift`。
- `AgentSidePanel.swift` 从 1952 行降到 1854 行，继续低于 2000 行软线；后续拆整个 `AgentSidePanelWidgetView` 或继续扩展 Skill/Ruby 网页接力时边界更清楚。
- 版本号从 **1.109.0-rc418** 提升为 **1.109.0-rc419**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc418 - 2026-06-28

### Changed
- **网页组件来源可定位（1.109.0-rc418）** —— 右侧网页组件详情里的源 HTML 路径和制作包目录现在提供 Finder 定位按钮。
- 定位动作复用 Widget 面板已有路径安全边界，仅允许 workspace、系统临时目录或 WillDeep 短剧导出目录内的源文件/制作包，方便从 Skill/Ruby 嵌入网页回到脚本产物继续排查或导回。
- 版本号从 **1.109.0-rc417** 提升为 **1.109.0-rc418**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc417 - 2026-06-28

### Changed
- **网页组件显示 Skill/Ruby 来源（1.109.0-rc417）** —— `AgentWidget` 现在会从 `source_label`、`source_path`、`package_directory` 和 `widget_context` 提取来源摘要。
- 右侧网页组件面板的最近列表和详情头部会显示来源、HTML 路径、制作包目录和上下文说明，方便用户识别 Skill/Ruby 脚本生成的短剧预览、候选图网页或制作包仪表盘，并继续把动作接力到聊天。
- 版本号从 **1.109.0-rc416** 提升为 **1.109.0-rc417**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc416 - 2026-06-28

### Changed
- **媒体产物缩略图交互拆分（1.109.0-rc416）** —— 将 `AgentMediaArtifactThumbnail` 从 `AgentMediaArtifactViews.swift` 拆到独立 `AgentMediaArtifactThumbnail.swift`。
- 候选图网页组件继续留在 `AgentMediaArtifactViews.swift`；本地缩略图的设分镜主图、设人物/场景参考图、加入聊天附件、Replicate 放大和打开蒙版编辑入口独立维护，后续接图片编辑工具时边界更清楚。
- 版本号从 **1.109.0-rc415** 提升为 **1.109.0-rc416**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc415 - 2026-06-28

### Changed
- **任务监控快照拆分（1.109.0-rc415）** —— 将 `AgentTaskMonitorSnapshot` 从 `AgentTaskMonitorRail.swift` 拆到独立 `AgentTaskMonitorSnapshot.swift`。
- 任务监控 rail 主文件继续回落，侧栏自动展开、媒体任务摘要和聊天窗口协作状态的快照契约可以独立维护，后续扩展异步短剧任务状态不会继续挤在 UI 文件里。
- 版本号从 **1.109.0-rc414** 提升为 **1.109.0-rc415**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc414 - 2026-06-28

### Changed
- **媒体任务行拆分（1.109.0-rc414）** —— 将 `AgentMediaTaskRow` 从 `AgentMediaTasks.swift` 拆到独立 `AgentMediaTaskRow.swift`。
- 单条任务的刷新/取消、短剧锚点、候选图、完成图片转视频和检查项关闭等行级逻辑独立维护；任务中心主文件继续回落，避免后续扩展异步媒体制作时逼近 2000 行软阈值。
- 版本号从 **1.109.0-rc413** 提升为 **1.109.0-rc414**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc413 - 2026-06-28

### Changed
- **媒体任务侧栏支撑组件拆分（1.109.0-rc413）** —— 将媒体任务状态筛选和侧栏通用 UI 行拆到 `AgentMediaTaskPanelSupport.swift`。
- `AgentMediaTasks.swift` 从 1907 行降到安全线内，后续继续扩展 some.im / Replicate / Skill/Ruby 异步任务、候选图、蒙版和短剧制作侧栏时，不必继续把主任务注册/轮询文件越堆越高。
- 版本号从 **1.109.0-rc412** 提升为 **1.109.0-rc413**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc412 - 2026-06-28

### Changed
- **媒体任务侧栏支持只刷新卡住任务（1.109.0-rc412）** —— “媒体任务”侧栏在当前范围存在可刷新且超过 30 分钟未更新的运行中任务时，会显示“刷新卡住”按钮。
- “刷新卡住”只轮询这批长时间未更新的 some.im、Replicate 或带 HTTPS status URL 的 Skill/Ruby 任务，不再必须刷新全部运行中任务，适合整剧批量生成时先处理最可疑的远端任务。
- 版本号从 **1.109.0-rc411** 提升为 **1.109.0-rc412**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc411 - 2026-06-28

### Changed
- **媒体任务卡住状态外层可见（1.109.0-rc411）** —— 聊天头部侧栏按钮和任务监控 rail 会优先显示超过 30 分钟未更新的运行中媒体任务。
- 任务监控 rail 会把卡住任务作为失败之后的第二优先级聚焦对象，行内显示“未更新 Nm”；从 rail 发送状态到聊天时也会带出 `stale_active_count` / `stale_active_tasks` 和刷新参数。
- 版本号从 **1.109.0-rc410** 提升为 **1.109.0-rc411**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc410 - 2026-06-28

### Changed
- **媒体任务识别长时间未更新（1.109.0-rc410）** —— “媒体任务”侧栏会统计并筛选超过 30 分钟未更新的运行中任务，任务行显示“超过 N 分钟未更新”的提示。
- “发送状态到聊天”会额外写入 `stale_active_count` 和 `stale_active_tasks`，并携带刷新/轮询参数，让 Agent 先刷新 some.im、Replicate 或 Skill/Ruby 异步任务，再决定等待、取消或重试。
- 版本号从 **1.109.0-rc409** 提升为 **1.109.0-rc410**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc409 - 2026-06-28

### Changed
- **媒体任务聊天接力携带时间线（1.109.0-rc409）** —— 媒体任务自动完成通知、单任务上下文和侧栏范围状态接力都会写入创建时间、更新时间和完成时间。
- 聊天窗口接手 some.im、Replicate 或 Skill/Ruby 异步任务时，能根据 `created_at` / `updated_at` / `finished_at` 判断是继续等待、立即刷新、重试失败任务，还是从完成产物进入候选图、蒙版、放大或图生视频。
- 版本号从 **1.109.0-rc408** 提升为 **1.109.0-rc409**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc408 - 2026-06-28

### Changed
- **媒体任务行显示创建/更新/完成时间（1.109.0-rc408）** —— “媒体任务”侧栏每条任务现在会显示创建时间和更新时间；已完成任务会额外显示完成时间。
- 用户查看 some.im、Replicate 或 Skill/Ruby 异步图片/视频任务时，可以直接判断任务多久没更新、是否刚完成，不必只靠状态文案猜远端是否还在推进。
- 版本号从 **1.109.0-rc407** 提升为 **1.109.0-rc408**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc407 - 2026-06-28

### Changed
- **媒体任务筛选空态区分无任务和无匹配（1.109.0-rc407）** —— “媒体任务”侧栏在当前范围有任务、但状态筛选结果为空时，会显示“当前筛选暂无任务”，并提供“查看全部任务”入口。
- 真正没有任何媒体任务时仍保留原空态说明；用户切到运行中、需处理或已完成筛选后，不会再误以为 some.im、Replicate 或 Skill/Ruby 任务都消失了。
- 版本号从 **1.109.0-rc406** 提升为 **1.109.0-rc407**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc406 - 2026-06-28

### Changed
- **媒体任务摘要支持快捷筛选（1.109.0-rc406）** —— “媒体任务”侧栏摘要区新增运行中、需处理、已完成和全部快捷按钮。
- 用户看到异步任务统计后，可以直接从摘要区切换到对应状态列表，不必再回到上方分段控件查找，适合整集/全剧批量生成后快速聚焦运行中任务、失败任务或已完成产物。
- 版本号从 **1.109.0-rc405** 提升为 **1.109.0-rc406**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc405 - 2026-06-28

### Changed
- **媒体任务侧栏摘要补完成态统计（1.109.0-rc405）** —— “媒体任务”侧栏摘要区除了运行中和需要处理外，现在会展示已完成任务数、完成图片任务数和完成视频任务数。
- some.im、Replicate、Skill/Ruby 异步任务批量跑完后，用户不必切到“已完成”筛选才能先判断本轮图片/视频产物是否已经回到 App；聊天的状态接力仍保留完整完成图片/视频后续动作。
- 版本号从 **1.109.0-rc404** 提升为 **1.109.0-rc405**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc404 - 2026-06-28

### Changed
- **推荐-only Widget 也可发送动作清单（1.109.0-rc404）** —— 当网页组件只有 `recommended_tool`、没有额外 handoff actions 时，组件标题行会显示“动作清单”按钮。
- 推荐型 Skill/Ruby widget 现在也能把推荐工具、参数、直达语义和 widget 上下文写回聊天，不再依赖“可用动作”区域出现后才有完整动作清单出口。
- 版本号从 **1.109.0-rc403** 提升为 **1.109.0-rc404**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc403 - 2026-06-28

### Changed
- **Widget 动作清单补直达语义（1.109.0-rc403）** —— “发送清单”写入聊天的 `<widget-action-list>` 现在会为推荐动作和每个 handoff 动作附带用户可读标题、`local_direct` 标记和 help 说明。
- 聊天窗口接手 Skill/Ruby 制作包、审片页或候选图页面时，能区分“先本地打开侧栏/网页/蒙版”的动作和“需要 dry-run 或确认后调用工具”的动作，减少下一步执行时的歧义。
- 版本号从 **1.109.0-rc402** 提升为 **1.109.0-rc403**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc402 - 2026-06-28

### Changed
- **Widget 动作清单可一键发送到聊天（1.109.0-rc402）** —— 右侧“网页组件”侧栏的“可用动作”标题行新增“发送清单”，会把推荐工具、全部 handoff 动作、工具参数和 widget 上下文写入聊天输入框。
- Skill/Ruby 制作包、审片页、候选图或媒体任务状态页动作很多时，聊天窗口可以一次性看到完整可接力工具清单，再决定先 dry-run、刷新异步任务、打开候选图、蒙版编辑、放大、导入 manifest 或回写审片 CSV。
- 版本号从 **1.109.0-rc401** 提升为 **1.109.0-rc402**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc401 - 2026-06-28

### Changed
- **Widget 可用动作列表支持展开全部（1.109.0-rc401）** —— 右侧“网页组件”侧栏的“可用动作”默认仍显示前 6 个，但当 Skill/Ruby 制作包、审片页或候选图页面提供更多 handoff 时，会显示动作总数和“展开全部/收起”切换。
- 展开状态只保存在当前侧栏视图本地，不写入 AppState 或项目数据；长制作包页面的导入、审片、任务刷新、候选图、蒙版、放大等动作不再因为数量超过 6 个而被藏起来。
- 版本号从 **1.109.0-rc400** 提升为 **1.109.0-rc401**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc400 - 2026-06-28

### Changed
- **Widget 远端取消动作先定位媒体任务（1.109.0-rc400）** —— 右侧“网页组件”侧栏点击 `replicate_cancel_prediction` 或 `some_im_cancel_media_task` 推荐/可用动作时，会先按本地任务句柄、远端 ID、状态 URL 或取消 URL 匹配媒体任务并打开对应侧栏范围。
- 本地侧栏只做核对和定位，不直接调用取消；完整取消动作仍写回聊天，由 Agent 在上下文里确认后再执行，避免网页组件按钮产生隐藏的远端取消副作用。
- 版本号从 **1.109.0-rc399** 提升为 **1.109.0-rc400**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc399 - 2026-06-28

### Changed
- **Widget 远端任务刷新动作本地直达（1.109.0-rc399）** —— 右侧“网页组件”侧栏点击 `replicate_poll_prediction` 或 `some_im_poll_media_task` 推荐/可用动作时，会先按 `task_id`、`prediction_id`、`remote_task_id`、`status_url` 或 `cancel_url` 匹配本地媒体任务。
- 找到任务后会打开对应媒体任务侧栏范围并立即调用现有 poller 刷新状态；找不到本地任务时仍会打开全量媒体任务侧栏，并把完整远端刷新动作写回聊天继续执行。取消动作仍只交给聊天确认，不做本地暗取消。
- 版本号从 **1.109.0-rc398** 提升为 **1.109.0-rc399**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc398 - 2026-06-28

### Changed
- **Widget 制作包导入/审片动作增加本地辅助入口（1.109.0-rc398）** —— 右侧“网页组件”侧栏点击 `import_media_manifest` 推荐或 handoff 动作时，会先尝试从 `widget_preview_path`、`package_directory` 或 `manifest_path` 同目录打开 `widget-preview.html` 制作包预览。
- `short_drama_import_review_csv` 推荐或 handoff 动作会先打开短剧侧栏查看审片上下文；两类动作仍会把完整参数写回聊天，由 Agent 按 dry-run 或确认再执行真正导入/回写，避免侧栏点击产生隐藏写入。
- 版本号从 **1.109.0-rc397** 提升为 **1.109.0-rc398**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc397 - 2026-06-28

### Changed
- **Widget 推荐动作复用本地直达（1.109.0-rc397）** —— 右侧“网页组件”侧栏顶部的 `recommended_tool` 现在会转换为内部 handoff，并复用同一套本地直达处理。
- 推荐动作如果是 `show_widget`、`show_image_choice_widget`、`list_media_tasks`、`open_image_editor` 或短剧分镜/候选图入口，会先打开对应侧栏或组件，再把完整 `<widget-recommended-action>` 写回聊天，避免推荐入口和“可用动作”入口行为不一致。
- 版本号从 **1.109.0-rc396** 提升为 **1.109.0-rc397**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc396 - 2026-06-28

### Changed
- **Widget 媒体任务查看动作本地直达（1.109.0-rc396）** —— 右侧“网页组件”侧栏点击 `list_media_tasks` handoff 动作时，会直接打开媒体任务侧栏。
- `list_media_tasks` 参数带 project / episode / shot / asset / review_item / scope 锚点时会复用对应筛选范围；没有锚点时打开全量媒体任务。点击后仍会把完整 handoff 写回聊天，方便模型继续刷新、处理失败或导回产物。
- 版本号从 **1.109.0-rc395** 提升为 **1.109.0-rc396**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc395 - 2026-06-28

### Fixed
- **Widget handoff 嵌套参数保真（1.109.0-rc395）** —— 右侧“网页组件”侧栏解析 handoff 参数时，会把 `recommended_arguments`、`widget_arguments` 等 `*_arguments` 中的嵌套逗号参数完整保留。
- Skill/Ruby 制作包常见的 `recommended_arguments=package_directory=..., dry_run=true, import_pending_tasks=true` 不再被截成只有 `package_directory`；本地打开网页组件或候选图后，Widget context 仍能把完整后续导入参数交给聊天窗口。
- 版本号从 **1.109.0-rc394** 提升为 **1.109.0-rc395**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc394 - 2026-06-28

### Changed
- **Widget show_widget 网页动作本地直达（1.109.0-rc394）** —— 右侧“网页组件”侧栏点击 `show_widget` handoff 动作时，如果参数携带 `html_path`，会直接本地读取并打开对应 Skill/Ruby 生成的 HTML/SVG 网页组件。
- 本地直达沿用工具层的安全边界：仅允许当前工作区、系统临时目录和 WillDeep 短剧导出目录内的 `.html` / `.htm` / `.svg`，文件需为非空 UTF-8 且不超过 1MB；完整 handoff 仍会写回聊天，便于继续导入 manifest、回写审片 CSV 或刷新媒体任务。
- `show_widget` handoff 在“可用动作”中显示为“打开网页组件”并带“直达”标记，让 Ruby 制作包预览、短剧 Skill 看板和外部 API 结果页能从侧栏直接打开。
- 版本号从 **1.109.0-rc393** 提升为 **1.109.0-rc394**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc393 - 2026-06-28

### Changed
- **Widget 通用候选图动作本地直达（1.109.0-rc393）** —— 右侧“网页组件”侧栏点击 `show_image_choice_widget` handoff 动作时，如果参数携带 `image_paths` / `candidate_image_paths` / `image_path`，会本地生成通用候选图选择器并打开 Widget 侧栏。
- 通用候选图直达复用现有 `AgentImageChoiceWidgetBuilder`，保留 project/episode/shot/asset/review 锚点和源动作上下文；点击后仍会把完整 handoff 写回聊天，方便模型继续选主图、蒙版编辑、擦除、放大或图生视频。
- Widget “可用动作”补充更多用户可读标题，包括“关闭检查项”“批量生成”“生成分镜媒体”“生成资产参考”“图生视频”“放大图片”“导入制作包”“回写审片 CSV”“刷新/取消远端任务”等。
- 版本号从 **1.109.0-rc392** 提升为 **1.109.0-rc393**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc392 - 2026-06-28

### Changed
- **Widget 可用动作展示直达语义（1.109.0-rc392）** —— 右侧“网页组件”侧栏会把常见 handoff 工具显示为更清晰的标题和图标，例如“打开媒体任务”“刷新媒体任务”“打开蒙版”“打开分镜看板”“打开候选图”。
- 对可本地直达的动作增加“直达”标记；底层工具名和参数仍保留显示，点击后继续写回聊天，兼顾用户可读性和模型接力上下文。
- 版本号从 **1.109.0-rc391** 提升为 **1.109.0-rc392**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc391 - 2026-06-28

### Changed
- **Widget 短剧网页组件动作本地直达（1.109.0-rc391）** —— 右侧“网页组件”侧栏点击 `short_drama_show_storyboard_widget` 或 `short_drama_show_image_choice_widget` handoff 动作时，会本地生成对应短剧分镜看板或候选图选择器并打开 Widget 侧栏。
- 直达逻辑复用现有 `AgentShortDramaStoryboardWidgetBuilder` 和当前媒体任务摘要，不调用外部 API、不修改短剧数据；聊天 handoff 仍完整保留，方便模型继续排产、审片或发起 some.im / Replicate 任务。
- 短剧媒体合约测试同步覆盖 Widget 查看类动作本地直达；版本号从 **1.109.0-rc390** 提升为 **1.109.0-rc391**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc390 - 2026-06-28

### Changed
- **Widget 图片编辑动作直达蒙版面板（1.109.0-rc390）** —— 右侧“网页组件”侧栏点击 `open_image_editor` 或 `short_drama_open_image_editor` handoff 动作时，会先本地打开图片蒙版编辑面板。
- 本地直达会保留 `image_path` / `artifact_path`、可选 `mask_path`、`operation=erase|inpaint` 以及 project/episode/shot/asset/review 锚点；聊天接力仍保留完整 handoff，方便提交 some.im / Replicate 编辑任务后继续回填短剧分镜或检查项。
- 短剧媒体合约测试同步覆盖 Widget 图片编辑动作本地直达；版本号从 **1.109.0-rc389** 提升为 **1.109.0-rc390**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc389 - 2026-06-28

### Changed
- **Widget 刷新任务动作触发本地轮询（1.109.0-rc389）** —— 右侧“网页组件”侧栏点击 `short_drama_refresh_media_tasks` handoff 动作时，会在打开对应媒体任务筛选范围后，立即刷新该范围内运行中的 some.im、Replicate 和可 HTTPS 轮询的通用媒体任务。
- `short_drama_open_media_tasks` 仍只做本地打开；刷新动作仍会把完整 handoff 写回聊天，方便模型继续处理失败任务、补齐缺失分镜或关闭检查项。
- 短剧媒体合约测试同步覆盖 Widget 刷新动作本地轮询；版本号从 **1.109.0-rc388** 提升为 **1.109.0-rc389**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc388 - 2026-06-28

### Changed
- **Widget 动作直达媒体任务侧栏（1.109.0-rc388）** —— 右侧“网页组件”侧栏点击 `short_drama_open_media_tasks` / `short_drama_refresh_media_tasks` handoff 动作时，会先解析 `project_id`、`episode_id`、`shot_id`、`asset_kind`、`asset_id`、`review_item_id` 和 `scope`，本地打开对应媒体任务侧栏过滤范围。
- 动作仍会写回聊天，保留模型继续刷新、处理失败、生成补图/补视频或关闭检查项的能力；用户不必等模型执行工具才看到当前异步任务状态。
- 短剧媒体合约测试同步覆盖 Widget 任务动作本地直达；版本号从 **1.109.0-rc387** 提升为 **1.109.0-rc388**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc387 - 2026-06-28

### Changed
- **候选图 Widget 补 post-select 动作摘要（1.109.0-rc387）** —— `show_image_choice_widget` 的网页组件 contextLines 现在会写入 `post_select_action_keys`，提前说明选中候选图后可用的视频、编辑、擦除、放大、任务状态和检查项动作。
- 工具返回说明同步提示模型优先读取 `post_select_action_keys` 与结构化 `post_select_*` 字段，减少选图后继续调用 some.im、Replicate 或短剧任务工具时的参数猜测。
- 短剧媒体合约测试同步覆盖通用候选图 Widget 的 post-select 摘要；版本号从 **1.109.0-rc386** 提升为 **1.109.0-rc387**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc386 - 2026-06-28

### Changed
- **网页组件动作解析兼容紧凑 handoff（1.109.0-rc386）** —— `AgentWidget.handoffActions` 现在兼容冒号、等号两种键值行，并能识别单行 `action=..., tool=..., arguments=...`。
- Skill/Ruby、短剧制作包或媒体任务上下文把工具动作压成一行时，右侧“网页组件”侧栏也能显示为可点击动作，并把完整参数尾部送回聊天，避免逗号参数被截断。
- 短剧媒体合约测试同步覆盖 Widget 紧凑 handoff 解析；版本号从 **1.109.0-rc385** 提升为 **1.109.0-rc386**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc385 - 2026-06-28

### Changed
- **网页组件侧栏显式展示多动作接力（1.109.0-rc385）** —— `AgentWidget` 现在会从 contextLines 中解析 `*_tool` / `*_arguments` 动作，保留原有 `recommended_tool` 的同时，把 Widget 派生动作作为独立 handoff actions。
- 右侧“网页组件”侧栏新增“可用动作”按钮组，可把 `open_widget_tasks_tool`、`refresh_widget_tasks_tool`、`resolve_widget_review_tool` 等动作连同完整 Widget 上下文写回聊天，方便 Skill/Ruby 看板直接接续短剧异步任务状态。
- 短剧媒体合约测试同步覆盖 Widget 多动作解析和侧栏聊天接力；版本号从 **1.109.0-rc384** 提升为 **1.109.0-rc385**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc384 - 2026-06-28

### Changed
- **show_widget 补项目/分集任务范围接力（1.109.0-rc384）** —— `show_widget` 只携带 `project_id` 或 `project_id + episode_id` 时，也会自动派生 `short_drama_open_media_tasks` / `short_drama_refresh_media_tasks` 参数。
- 整剧网页组件会生成 `scope=project`，单集网页组件会生成 `scope=episode`；Skill/Ruby 生成的整剧或分集看板回到聊天后，可直接打开对应异步媒体任务状态。
- 短剧媒体合约测试同步覆盖 `show_widget` 的项目/分集范围派生 handoff；版本号从 **1.109.0-rc383** 提升为 **1.109.0-rc384**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc383 - 2026-06-28

### Changed
- **show_widget 自动派生短剧任务范围接力（1.109.0-rc383）** —— `show_widget` 携带短剧分镜、检查项或资产锚点时，会自动在 Widget contextLines 中补 `short_drama_open_media_tasks` / `short_drama_refresh_media_tasks` 参数。
- 当网页组件带 `review_item_id` 时，contextLines 还会补 `short_drama_resolve_review_item` 参数；Skill/Ruby 审片网页回到聊天后，可以直接打开检查项任务范围、刷新异步任务或关闭检查项。
- 短剧媒体合约测试同步覆盖 `show_widget` 的短剧任务范围派生 handoff；版本号从 **1.109.0-rc382** 提升为 **1.109.0-rc383**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc382 - 2026-06-28

### Changed
- **show_widget 补审片检查项锚点（1.109.0-rc382）** —— `show_widget` 现在支持可选 `review_item_id` 参数，并会把它写入 Widget contextLines。
- Skill/Ruby 生成的审片、修复队列或蒙版返工网页可以直接锚定到短剧检查项，聊天窗口从网页组件接手后能继续打开检查项任务范围、刷新相关异步任务或关闭检查项。
- 短剧媒体合约测试同步覆盖 `show_widget` 的 `review_item_id` 参数与上下文保留；版本号从 **1.109.0-rc381** 提升为 **1.109.0-rc382**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc381 - 2026-06-28

### Changed
- **show_widget 自动保留 html_path 上下文（1.109.0-rc381）** —— Skill/Ruby 脚本调用 `show_widget(html_path=...)` 嵌入本地 HTML/SVG 网页时，Widget contextLines 现在会自动写入 `html_path`。
- 聊天窗口从网页组件接手时无需调用方额外重复传 `source_path`，也能定位原始网页文件，继续读取、复查或重新生成 Skill/Ruby 产物。
- 短剧媒体合约测试同步覆盖 `show_widget` 的 `html_path` 上下文保留；版本号从 **1.109.0-rc380** 提升为 **1.109.0-rc381**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc380 - 2026-06-28

### Changed
- **图片蒙版编辑提交补通用任务状态交接（1.109.0-rc380）** —— 图片蒙版编辑面板提交 Replicate / some.im 任务后，`<image-edit-task-submitted>` 现在会携带 `list_media_tasks` 的 active/all 查询参数和 `target_task_id`。
- 非短剧锚定的通用图片编辑任务也能从聊天窗口继续跟踪异步状态；短剧分镜、检查项和资产范围的打开/刷新参数继续保留。
- 短剧媒体合约测试同步覆盖图片编辑提交后的通用媒体任务状态交接；版本号从 **1.109.0-rc379** 提升为 **1.109.0-rc380**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc379 - 2026-06-28

### Changed
- **通用候选图 Widget 补候选动作上下文（1.109.0-rc379）** —— `show_image_choice_widget` 和短剧候选图选择器现在会在调用方传入的 contextLines 之外追加 `<image-choice-widget>`，列出锚点、候选图路径和前 12 张候选图的选择/蒙版编辑/擦除/放大/图生视频参数。
- 由 Skill、聊天工具或短剧流程生成的候选图网页组件，不再只依赖按钮点击返回 `<image-choice>`，聊天窗口可直接读取 Widget 上下文继续接手图片编辑与短剧制作。
- 短剧媒体合约测试同步覆盖通用候选图 Widget 的候选动作上下文；版本号从 **1.109.0-rc378** 提升为 **1.109.0-rc379**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc378 - 2026-06-28

### Changed
- **媒体任务候选图 Widget 补聊天上下文（1.109.0-rc378）** —— 从媒体任务侧栏打开的“候选图”网页组件现在会携带 `<media-task-image-choice-widget>` contextLines，列出任务锚点、候选图路径和前 12 张候选图的选择/编辑/擦除/放大/图生视频参数。
- 这样聊天窗口在接手侧栏候选图 Widget 时，不必只依赖 HTML 按钮发送的 `<media-task-image-choice>`，也能直接理解每张候选图可执行的推荐工具参数。
- 短剧媒体合约测试同步覆盖候选图 Widget contextLines；版本号从 **1.109.0-rc377** 提升为 **1.109.0-rc378**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc377 - 2026-06-28

### Changed
- **manifest 导回工具结果补项目任务刷新交接（1.109.0-rc377）** —— `import_media_manifest` 返回的 `<media-import-follow-up>` 现在会在本批任务归并到同一个短剧项目 UUID 时，直接写入项目级 `short_drama_open_media_tasks` 和 `short_drama_refresh_media_tasks` 参数。
- Widget context 里的项目级任务交接也同步补上刷新入口；聊天窗口即使只拿到工具结果、不打开网页组件，也能打开或刷新当前短剧项目的异步媒体任务侧栏。
- 短剧媒体合约测试同步覆盖 manifest follow-up 的项目级打开/刷新任务交接；版本号从 **1.109.0-rc376** 提升为 **1.109.0-rc377**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc376 - 2026-06-28

### Changed
- **manifest Widget 补项目媒体任务打开交接（1.109.0-rc376）** —— `import_media_manifest` 自动排入制作包 Widget 时，如果本批任务能归并到同一个短剧项目 UUID，会在 `<media-import-widget-handoff>` 中写入 `short_drama_open_media_tasks` 工具和 `project_id=..., scope=project` 参数。
- 这让网页组件回到聊天窗口后，可以直接打开对应项目的媒体任务侧栏，而不是只依赖任务 ID 和 `list_media_tasks` 状态查询；非 UUID 项目路径不会输出该调用参数，避免误把路径当 `project_id`。
- 短剧媒体合约测试同步覆盖 manifest Widget 的项目级媒体任务打开交接；版本号从 **1.109.0-rc375** 提升为 **1.109.0-rc376**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc375 - 2026-06-28

### Changed
- **manifest 导回媒体任务侧栏按同项目自动过滤（1.109.0-rc375）** —— `import_media_manifest` 导回 pending/failed 任务并优先打开“媒体任务”侧栏时，如果本次导回任务都锚定到同一个短剧项目，会自动使用项目级 `AgentMediaTaskScope` 过滤。
- 跨项目或无短剧锚点导回仍打开全局媒体任务侧栏，避免误筛；同项目制作包导回则直接看到该短剧项目的异步任务状态。
- 短剧媒体合约测试同步覆盖 manifest 导回后的项目级媒体任务过滤；版本号从 **1.109.0-rc374** 提升为 **1.109.0-rc375**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc374 - 2026-06-28

### Changed
- **manifest 导回 pending/failed 时优先打开媒体任务侧栏（1.109.0-rc374）** —— `import_media_manifest` 仍会把制作包 `widget-preview.html` 排入网页组件，但当本次导回存在 pending 或 failed 任务时，右侧侧栏会优先打开“媒体任务”。
- 无待处理任务时仍直接打开网页组件；这样 Ruby/第三方 API 导回异步任务后，用户第一眼看到的是任务状态，完成态导回则继续优先看制作包预览。
- 短剧媒体合约测试同步覆盖 pending/failed 导回的媒体任务侧栏优先级；版本号从 **1.109.0-rc373** 提升为 **1.109.0-rc374**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc373 - 2026-06-28

### Changed
- **manifest 自动网页组件补媒体任务计数摘要（1.109.0-rc373）** —— `import_media_manifest` 自动排入的制作包 Widget handoff 现在会写入 `task_count`、`pending_task_count`、`failed_task_count` 和 `completed_task_count`。
- 聊天窗口从网页组件接手时，可以先按计数判断是刷新 pending、处理失败，还是继续候选图选择、视频生成和审片回写流程。
- 短剧媒体合约测试同步覆盖自动 Widget 的任务计数摘要；版本号从 **1.109.0-rc372** 提升为 **1.109.0-rc373**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc372 - 2026-06-28

### Changed
- **manifest 自动网页组件补媒体任务状态索引（1.109.0-rc372）** —— `import_media_manifest` 自动排入的制作包 Widget 现在会把本次导回创建或更新的 `task_ids`、`pending_task_ids` 和 `failed_task_ids` 写入 `<media-import-widget-handoff>`。
- Widget handoff 同步附带 `list_media_tasks` 的 active/all 状态查询参数；用户从网页组件回到聊天时，模型能直接定位异步任务侧栏状态，而不是只知道制作包文件路径。
- 短剧媒体合约测试同步覆盖自动 Widget 的任务索引和状态查询字段；版本号从 **1.109.0-rc371** 提升为 **1.109.0-rc372**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc371 - 2026-06-28

### Changed
- **manifest 自动网页组件补完整制作包上下文（1.109.0-rc371）** —— `import_media_manifest` 自动排入的制作包 Widget 现在会携带 `widget_preview_path`、`timeline_path`、`gap_report_path`、`shot_list_path`、`review_template_path` 和 `review_queue_path`。
- Widget handoff 同步包含 dry-run/正式 `import_media_manifest` 参数，以及 `short_drama_import_review_csv` 修复队列回写参数；Ruby/第三方 API 产物导回后，右侧网页组件和聊天窗口可直接继续排产、审片和回写检查项。
- 短剧媒体合约测试同步覆盖 manifest 自动 Widget 的完整制作包上下文；版本号从 **1.109.0-rc370** 提升为 **1.109.0-rc371**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc370 - 2026-06-28

### Changed
- **manifest 导回后自动打开制作包网页组件（1.109.0-rc370）** —— `import_media_manifest` 正式导回制作包产物或 pending 远端任务后，如果同目录存在 `widget-preview.html`，会自动排入右侧“网页组件”并打开侧栏。
- 自动排入的 Widget 会携带 `<media-import-widget-handoff>`，包括 package、manifest、source、`recommended_tool=import_media_manifest` 和 `dry_run=true, import_pending_tasks=true` 参数；导回后的网页组件可继续预检、登记异步任务和复查制作包。
- 短剧媒体合约测试同步覆盖 manifest 导回自动排队 Widget；版本号从 **1.109.0-rc369** 提升为 **1.109.0-rc370**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc369 - 2026-06-28

### Changed
- **manifest 导回后的网页预览提示携带 Widget 上下文（1.109.0-rc369）** —— `import_media_manifest` 导回制作包后，返回的 `show_widget` 示例现在包含 `source_label`、`source_path`、`package_directory`、`recommended_tool` 和 `recommended_arguments`。
- Ruby/第三方 API 脚本把产物导回后，聊天窗口打开 `widget-preview.html` 时可继续保留 dry-run 预检、pending 远端任务登记和正式导入参数，不再只是打开一个孤立 HTML。
- 短剧媒体合约测试同步覆盖 manifest 导回后的 Widget 上下文字段；版本号从 **1.109.0-rc368** 提升为 **1.109.0-rc369**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc368 - 2026-06-28

### Changed
- **制作包预览时间线/缺口/CSV 按钮补完整 handoff（1.109.0-rc368）** —— 初始制作包预览和 Ruby 脚本重写后的 `widget-preview.html` 中，时间线、缺口报告和 CSV 审片按钮都会把对应 `<production-package-handoff>` 或 `<ruby-media-script-handoff>` 一并送回聊天。
- 这些按钮现在保留 timeline、gap report、CSV、`import_media_manifest` dry-run/正式导入和 `short_drama_import_review_csv` 回写参数，聊天窗口接手时不再只拿到自然语言计划。
- 短剧媒体合约测试同步覆盖 timeline/gap/CSV 按钮 handoff；版本号从 **1.109.0-rc367** 提升为 **1.109.0-rc368**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc367 - 2026-06-28

### Changed
- **Ruby 预览失败处理按钮带完整 handoff（1.109.0-rc367）** —— Ruby 媒体脚本生成的 `widget-preview.html` 中，“分析失败”和“重跑失败”按钮现在通过 `JSON.dump` 写入完整 prompt，并把 `<ruby-media-script-handoff>` 一并带回聊天。
- 失败分析和失败重跑提示现在可直接复用 `dry_run_import_arguments` / `submit_import_arguments`，聊天窗口不再需要猜制作包、manifest、pending 远端任务和回写路径。
- 短剧媒体合约测试同步覆盖失败按钮 handoff；版本号从 **1.109.0-rc366** 提升为 **1.109.0-rc367**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc366 - 2026-06-28

### Changed
- **Ruby 媒体脚本运行接力补结构化参数（1.109.0-rc366）** —— 短剧侧栏“运行脚本”写入聊天的提示现在包含 `<ruby-media-script-run-handoff>`，列出 package、Ruby 脚本、私有 env 示例、timeline、gap report、CSV、manifest、outputs 和 widget 路径。
- 结构块还带出建议命令、`import_media_manifest` dry-run/正式导入、pending 远端任务登记、修复队列回写、网页预览参数和安全提示，方便聊天窗口直接接手 Ruby/Skill 调第三方 API 后的回流。
- 短剧媒体合约测试同步覆盖 Ruby 脚本运行 handoff；版本号从 **1.109.0-rc365** 提升为 **1.109.0-rc366**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc365 - 2026-06-28

### Changed
- **侧栏导出制作包后自动打开网页组件（1.109.0-rc365）** —— 从短剧侧栏导出整剧或单集制作包后，会自动读取 `widget-preview.html` 排入右侧“网页组件”，并在状态消息里标注打开结果。
- 手动“预览网页”也复用同一套 `<production-package-handoff>` contextLines，包含 manifest、timeline、gap report、CSV、导入、审片回写和修复队列回写参数；侧栏导出和聊天工具导出的网页组件上下文保持一致。
- 短剧媒体合约测试同步覆盖侧栏导出自动预览和完整 handoff；版本号从 **1.109.0-rc364** 提升为 **1.109.0-rc365**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc364 - 2026-06-28

### Changed
- **自动制作包预览上下文包入 production-package-handoff（1.109.0-rc364）** —— `short_drama_export_production_package` 自动排入右侧网页组件的 `AgentWidget.contextLines` 现在用 `<production-package-handoff>` 包住完整制作包上下文，并标注 `action: short_drama_export_production_package_widget`。
- 网页组件按钮或侧栏推荐动作回到聊天时，模型能按同一结构块识别制作包路径、manifest、timeline、gap report、CSV、导入、审片回写和修复队列回写参数。
- 短剧媒体合约测试同步覆盖自动预览 widget 的 handoff 边界；版本号从 **1.109.0-rc363** 提升为 **1.109.0-rc364**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc363 - 2026-06-28

### Changed
- **自动制作包预览携带完整 handoff 上下文（1.109.0-rc363）** —— `short_drama_export_production_package` 自动排入右侧网页组件的 `AgentWidget` 现在携带完整制作包上下文，包括 manifest、widget、timeline、gap report、shot list、审片模板、修复队列路径。
- 该 widget 的 contextLines 同步携带 `import_media_manifest` dry-run/正式导入、审片 CSV 回写、修复队列回写和 `show_widget` 参数；用户从网页组件按钮回到聊天时，聊天窗口能继续拿到全套制作包 handoff。
- 短剧媒体合约测试同步覆盖自动预览 widget 的 contextLines；版本号从 **1.109.0-rc362** 提升为 **1.109.0-rc363**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc362 - 2026-06-28

### Changed
- **制作包导出后自动打开网页预览（1.109.0-rc362）** —— 在对话 runtime 中调用 `short_drama_export_production_package` 后，工具会读取刚生成的 `widget-preview.html`，排入 `AgentWidgetRegistry`，并请求打开右侧“网页组件”面板。
- 工具返回新增 `Widget panel` 状态；如果不是对话 runtime 或预览文件不可读，会明确说明未排队，但不会影响制作包导出。
- 短剧媒体合约测试同步覆盖导出工具自动排队制作包预览组件；版本号从 **1.109.0-rc361** 提升为 **1.109.0-rc362**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc361 - 2026-06-28

### Changed
- **制作包导出工具返回结构化接力参数（1.109.0-rc361）** —— `short_drama_export_production_package` 的工具返回现在直接包含 `<production-package-handoff>`，列出制作包目录、manifest、widget、timeline、gap report、CSV 路径，以及 `import_media_manifest` dry-run/正式导入、审片 CSV、修复队列和 `show_widget` 参数。
- 聊天窗口从短剧制作包导出结果接手时，可以直接按结构化参数预检导入、正式导入、回写审片、回写修复队列或打开网页组件，不必再从路径列表里猜下一步。
- 短剧媒体合约测试同步覆盖工具返回的 handoff 字段；版本号从 **1.109.0-rc360** 提升为 **1.109.0-rc361**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc360 - 2026-06-28

### Changed
- **制作包修复队列推荐动作可一键交回聊天（1.109.0-rc360）** —— 初始导出的 `widget-preview.html` 和 Ruby 重写版都会在“修复队列推荐动作”里为每条未解决检查项提供“交给聊天处理”按钮。
- 按钮会发送 `<short-drama-review-queue-action>`，包含 `fix_production_review_queue_item`、`recommended_tool`、`recommended_arguments`、同检查项任务流水入口和关闭检查项参数；聊天窗口可直接接手执行重绘、擦除、放大、补拍、查看任务或关闭检查项。
- 短剧媒体合约测试同步覆盖初始预览与 Ruby 预览的一键聊天接力；版本号从 **1.109.0-rc359** 提升为 **1.109.0-rc360**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc359 - 2026-06-28

### Changed
- **初始制作包预览展示修复队列推荐动作（1.109.0-rc359）** —— 初始导出的 `widget-preview.html` 现在和 Ruby 重写版一样，会展示前 20 条未解决检查项的 `recommended_tool`、`recommended_arguments`、任务流水参数和关闭检查项参数。
- 用户刚导出制作包、不运行 Ruby 媒体脚本时，也能从网页组件直接接力处理 `production-review-queue.csv` 的修复动作，不必再打开 CSV 手动查每行参数。
- 短剧媒体合约测试同步覆盖初始预览的修复队列推荐动作区；版本号从 **1.109.0-rc358** 提升为 **1.109.0-rc359**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc358 - 2026-06-28

### Changed
- **Ruby 制作预览展示修复队列推荐动作（1.109.0-rc358）** —— Ruby 媒体脚本重写的 `widget-preview.html` 现在会读取 `production-review-queue.csv`，展示前 20 条未解决检查项的 `recommended_tool`、`recommended_arguments`、任务流水参数和关闭检查项参数。
- 外部脚本跑完后，用户从网页组件回到聊天窗口时，可以直接看到修复队列每行推荐的执行动作，不必再打开 CSV 手动查工具参数。
- 短剧媒体合约测试同步覆盖 Ruby 预览的修复队列推荐动作区；版本号从 **1.109.0-rc357** 提升为 **1.109.0-rc358**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc357 - 2026-06-28

### Changed
- **检查项修复队列 CSV 补可执行接力字段（1.109.0-rc357）** —— `production-review-queue.csv` 现在新增 `recommended_tool`、`recommended_arguments`、`secondary_tool`、`secondary_arguments`、`open_review_tasks_arguments`、`refresh_review_tasks_arguments` 和 `resolve_review_arguments`。
- Ruby Skill、第三方修复脚本或聊天窗口读取修复队列后，可直接按检查项类型执行蒙版重绘、擦除、放大、补拍、查看同一检查项任务流水或关闭检查项，不必重新推断工具参数。
- 拆出 `AgentShortDramaProductionReviewQueue.swift` 承载修复队列导出逻辑，保持导出器主文件低于 3000 行；版本号从 **1.109.0-rc356** 提升为 **1.109.0-rc357**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc356 - 2026-06-28

### Changed
- **制作包资产关联分镜补可执行批量参数（1.109.0-rc356）** —— `production-gap-report.json` 的 `assets[]` 现在新增 `linked_shot_image_dry_run_arguments` / `linked_shot_image_submit_arguments` / `linked_shot_video_dry_run_arguments` / `linked_shot_video_submit_arguments`。
- Ruby Skill 或第三方排产脚本补完人物/场景参考图后，可直接调用这些 `short_drama_generate_batch_media(shot_ids=...)` 参数推进关联分镜的补主图或补视频，不必自行拼接 `shot_ids`。
- 制作包 Markdown、网页预览提示和短剧媒体合约测试同步覆盖关联分镜可执行参数；版本号从 **1.109.0-rc355** 提升为 **1.109.0-rc356**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc355 - 2026-06-28

### Changed
- **制作包资产缺口报告补关联分镜索引（1.109.0-rc355）** —— `production-gap-report.json` 的 `assets[]` 现在新增 `linked_shot_count` 和 `linked_shot_ids`，按分集/分镜顺序列出人物或场景资产关联到的分镜。
- Ruby Skill 或第三方排产脚本补完人物/场景参考图后，可直接用这些分镜 ID 优先推进相关镜头的补主图、补视频或检查项修复，避免资产制作和分镜排产脱节。
- 制作包 Markdown、网页预览提示和短剧媒体合约测试同步覆盖关联分镜索引；版本号从 **1.109.0-rc354** 提升为 **1.109.0-rc355**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc354 - 2026-06-28

### Fixed
- **单集制作包只导出本集引用资产（1.109.0-rc354）** —— 当 `short_drama_export_production_package` 传入 `episode_id` 时，导出器现在会按该集分镜引用过滤人物和场景。
- 单集制作包的 `production-package.json`、`media-import-manifest-template.json`、`production-gap-report.json` 和网页预览不再携带无关集的人物/场景参考图缺口，避免 Ruby Skill 或第三方脚本误给整部剧资产排产。
- 短剧媒体合约测试同步覆盖单集导出的角色/场景裁剪；版本号从 **1.109.0-rc353** 提升为 **1.109.0-rc354**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc353 - 2026-06-28

### Fixed
- **单集制作包缺口批量动作保留 episode 范围（1.109.0-rc353）** —— 当 `short_drama_export_production_package` 只导出某一集时，`production-gap-report.json` 的 `batch_actions` 现在会带上 `episode_id`。
- Ruby Skill 或第三方排产脚本读取单集制作包后，批量补主图/补视频会限制在当前集内，不会因为只有 `project_id` 而误排整部短剧的缺口。
- 短剧媒体合约测试同步覆盖 episode scope 的 batch action 前缀和制作包说明；版本号从 **1.109.0-rc352** 提升为 **1.109.0-rc353**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc352 - 2026-06-28

### Changed
- **制作包缺口报告补单镜正式提交参数（1.109.0-rc352）** —— `production-gap-report.json` 的缺主图/缺视频分镜现在除了 `image_dry_run_arguments` / `video_dry_run_arguments`，还会输出 `image_submit_arguments` / `video_submit_arguments`。
- Ruby Skill 或第三方排产脚本读取缺口报告后，可先调用单镜 dry-run 预检，再直接使用同一分镜的 submit 参数正式提交 `short_drama_generate_shot_media`，不必自行拼接 `dry_run=false`。
- 短剧媒体合约测试同步覆盖单镜 submit 字段和制作包说明；版本号从 **1.109.0-rc351** 提升为 **1.109.0-rc352**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc351 - 2026-06-28

### Changed
- **单分镜媒体生成支持 dry-run 预检（1.109.0-rc351）** —— `short_drama_generate_shot_media` 新增 `dry_run` 参数，可先校验分镜、prompt、model、endpoint、图片尺寸和视频参考图，不提交 some.im 任务。
- 制作包预览和 Ruby 模板重写版的单镜“补主图 / 补视频”按钮改为先 `dry_run=true`，确认后再 `dry_run=false`；短剧侧栏分镜上下文也输出单镜图片/视频 dry-run 与正式提交两套参数。
- 短剧媒体合约测试同步覆盖单分镜 dry-run schema、工具返回、侧栏上下文和制作包按钮；版本号从 **1.109.0-rc350** 提升为 **1.109.0-rc351**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc350 - 2026-06-28

### Changed
- **资产参考图生成支持 dry-run 预检（1.109.0-rc350）** —— `short_drama_generate_asset_media` 新增 `dry_run` 参数，可先校验人物/场景资产、prompt、model、size 和 endpoint，而不提交 some.im 任务。
- 制作包缺口报告、短剧聊天上下文和网页预览的资产参考图动作同步输出 `generate_reference_dry_run_arguments` / `generate_asset_reference_dry_run_arguments`，正式提交参数显式带 `dry_run=false`，方便 Skill/Ruby 自动排产先预检再花额度。
- 短剧媒体合约测试同步覆盖资产参考图 dry-run schema、工具返回和制作包接力；版本号从 **1.109.0-rc349** 提升为 **1.109.0-rc350**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc349 - 2026-06-28

### Changed
- **制作包缺口报告纳入人物/场景参考图（1.109.0-rc349）** —— `production-gap-report.json` 现在新增 `missing_asset_reference_count` 和 `assets[]`，逐个人物/场景列出参考图数量、是否缺参考图、打开/刷新资产任务参数，以及缺图时的 `short_drama_generate_asset_media` 参数。
- 制作包 Markdown 和网页预览的“按缺口报告排产”提示同步要求优先读取资产参考图缺口，再安排补主图、补视频和检查项处理；短剧 Skill 或 Ruby 脚本可用同一 gap report 先补齐角色定妆与场景板。
- 短剧媒体合约测试同步覆盖资产参考图 gap 字段；版本号从 **1.109.0-rc348** 提升为 **1.109.0-rc349**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc348 - 2026-06-28

### Changed
- **制作包网页任务入口补刷新接力（1.109.0-rc348）** —— 制作包预览和 Ruby 模板重写后的网页预览中，分镜、分集、检查项和人物/场景资产的任务入口现在会同时提示 `short_drama_open_media_tasks` 与 `short_drama_refresh_media_tasks`。
- 人物/场景资产网页动作新增 `short_drama_generate_asset_media` 再生成参考图参数；用户从 Skill/Ruby 生成的网页组件回到聊天时，可直接刷新异步任务状态、继续补参考图或处理检查项。
- 短剧媒体合约测试同步覆盖网页预览刷新与资产再生成接力；版本号从 **1.109.0-rc347** 提升为 **1.109.0-rc348**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc347 - 2026-06-28

### Changed
- **资产完成图聊天接力补任务刷新与再生成入口（1.109.0-rc347）** —— 带人物/场景资产锚点的图片任务完成后，自动通知、完整任务上下文和范围摘要都会输出资产任务打开/刷新参数，以及 `short_drama_generate_asset_media` 再生成参考图参数。
- 用户从侧栏或聊天看到资产参考图后，可直接刷新同一人物/场景的任务流水、继续生成更多参考图，或沿用已有绑定、蒙版编辑、擦除和放大动作继续短剧资产制作。
- 短剧媒体合约测试同步覆盖资产任务刷新与再生成接力；版本号从 **1.109.0-rc346** 提升为 **1.109.0-rc347**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc346 - 2026-06-28

### Changed
- **show_widget 支持 Skill 临时网页文件（1.109.0-rc346）** —— `show_widget(html_path:)` 现在允许读取系统临时目录中的 `.html` / `.htm` / `.svg` 文件，方便 Ruby Skill 或第三方脚本先写临时网页，再嵌入右侧「网页组件」侧栏。
- 安全边界仍保留：只允许 workspace、系统临时目录或 WillDeep 短剧导出目录，继续校验扩展名、1MB 上限，并由 WKWebView CSP 禁网络和禁导航。
- 短剧媒体合约测试同步覆盖临时目录白名单；版本号从 **1.109.0-rc345** 提升为 **1.109.0-rc346**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc345 - 2026-06-28

### Changed
- **媒体任务缩略图可一键绑定人物/场景参考图（1.109.0-rc345）** —— 带 `project_id + asset_kind + asset_id` 锚点的图片产物，现在可在媒体任务侧栏缩略图上直接设为短剧人物/场景参考图。
- 点击后会更新短剧 store、打开短剧侧栏，并向聊天输入 `<short-drama-asset-reference-attached>`，携带查看资产任务、继续生成资产参考图、蒙版编辑、擦除和放大参数。
- 短剧媒体合约测试同步覆盖缩略图资产参考图入口；版本号从 **1.109.0-rc344** 提升为 **1.109.0-rc345**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc344 - 2026-06-28

### Changed
- **通用第三方异步任务识别更多产物字段（1.109.0-rc344）** —— `AgentGenericMediaStatusClient` 的 provider-neutral 轮询现在会把 `media_url`、`download_url`、`artifact_url`、`file_url` 等常见字段纳入完成判断和产物下载。
- 轮询响应里的 `media` / `images` / `videos` / `artifacts` / `files` 数组也会被收集，短剧 Skill、Ruby 制作包或第三方 API 返回常规媒体 URL 后，侧栏任务可自动下载产物并继续回流聊天。
- 短剧媒体合约测试同步覆盖这些输出键；版本号从 **1.109.0-rc343** 提升为 **1.109.0-rc344**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc343 - 2026-06-28

### Changed
- **制作包 Ruby 模板补 Replicate Predictions 请求体（1.109.0-rc343）** —— Ruby 模板新增 `WILLDEEP_MEDIA_REQUEST_PRESET=replicate_predictions`，会把通用媒体任务 JSON 转为 Replicate `/v1/predictions` 需要的 `{version,input}`。
- `source_image_data_url` / `mask_data_url` 会映射到 Replicate `input.image` / `input.mask`，并支持 `WILLDEEP_REPLICATE_EXTRA_INPUT_JSON` 注入模型参数，方便短剧制作包调用 Replicate 放大、擦除和蒙版重绘类工作流。
- `.env` 示例、制作包 Markdown 说明和短剧媒体合约测试同步覆盖该 preset；版本号从 **1.109.0-rc342** 提升为 **1.109.0-rc343**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc342 - 2026-06-28

### Changed
- **任务监控范围摘要补完成视频接力（1.109.0-rc342）** —— 完整媒体任务侧栏和右侧任务监控 rail 发送范围状态到聊天时，现在会统计并输出 `completed_video_tasks`。
- 完成视频摘要包含 `video_path`、打开/刷新分镜任务、回到分镜板、审片和关联检查项处理参数；用户从侧边栏中间看到异步视频完成后，可直接让聊天继续短剧审片或修复。
- 版本号从 **1.109.0-rc341** 提升为 **1.109.0-rc342**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc341 - 2026-06-28

### Changed
- **制作包预览支持视频审片接力（1.109.0-rc341）** —— 初始导出的 `widget-preview.html` 和 Ruby 模板运行后重写的制作包预览，在分镜已有视频产物时都会显示「审片视频」按钮。
- 按钮输出 `<short-drama-production-video-action>`，携带 `video_path`、项目/分集/分镜锚点、打开/刷新分镜任务和回到分镜板参数，让交给 Skill/Ruby/第三方 API 的制作包也能直接回到聊天审片和问题回写流程。
- 版本号从 **1.109.0-rc340** 提升为 **1.109.0-rc341**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc340 - 2026-06-28

### Changed
- **网页分镜板支持视频审片接力（1.109.0-rc340）** —— 短剧网页分镜板的分镜卡片在已有视频产物时会显示「审片视频」按钮。
- 按钮会输出 `<short-drama-widget-video-action>`，携带 `video_path`、项目/分集/分镜锚点、打开/刷新分镜任务和回到分镜板参数，让嵌入网页组件也能直接进入视频审片、连续性检查和问题回写流程。
- 版本号从 **1.109.0-rc339** 提升为 **1.109.0-rc340**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。
