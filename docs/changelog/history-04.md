# 历史变更记录 4

[返回当前变更记录](../../CHANGELOG.md)

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
