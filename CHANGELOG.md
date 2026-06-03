# Changelog

## 1.49.0-rc4 - 2026-06-03

- **并发 Agent Runtime 重构，第 4/4 步：UI 跟上 + 用户可调。** rc3 的并发能跑但视觉上看不见——active 之外的 runtime 在背后流式输出，sidebar 那一行仍是静默的灰点。rc4 把这一刀补完：
  - **Sidebar 状态点活了**。每条 session 行左侧的 5pt 圆点现在按 runtime 状态变色 + 脉动：① runtime 正在跑 → **绿色脉冲**（1.6× scale 反复 0.85s easeInOut）；② runtime 卡在 tool 审批（`toolDecisionWaiter != nil`）→ **橙色脉冲**；③ active 会话且空闲 → accent color 静态；④ 没 runtime 或 runtime 闲着 → 老灰色。脉动用 `@State pulse + .animation(.repeatForever, value: pulse)` 实现，在 `onAppear` / `onChange(of: shouldPulse)` 切换，没在跑的时候**不参与 animation**避免主线程白白渲染。新文件 `AgentSessionRowStatusDot.swift`（独立出去，AgentModeView 早已超 3000 行，不再恶化）。
  - **AppState 改成订阅所有 runtime 的 objectWillChange**，不是只订阅 active。rc2/rc3 的 `activeRuntimeSubscription: AnyCancellable?` 升级为 `runtimeSubscriptions: [SessionID: AnyCancellable]`，每次 `subscribeToRuntime(_:)` 一次（创建 runtime 时一定调），`unsubscribeFromRuntime(id:)` 在 delete / prune 时调；订阅幂等。这让 sidebar 的状态点能在背景 runtime `isResponding` 翻转的瞬间重画——不再卡到下次 active 切换。代价：active 不变时背景 runtime 任一状态变化都会触发 AppState.objectWillChange，整棵 SwiftUI 子树重算一次；SwiftUI diff 是浅的，实测无感知，但如果未来 sidebar 性能有问题可以改成"只发给 sidebar 的 publisher"。
  - **切 session 不再杀 outgoing turn**。pre-rc4 `selectAgentSession` / `startNewAgentSession` 会 `outgoing.requestTask?.cancel()` + 复位 isResponding——那是单 runtime 时代"我要换思路了"的等价物。现在每个 runtime 有自己的 task，切走只是 UI 焦点换了，**outgoing 该跑还是跑**，sidebar 上看得见。要真停只能在那个 runtime 的 chat pane 上点 Stop。这是并发体验的核心——切到 session B 写代码时，session A 的长 turn 仍在背后流式推进，回到 A 立刻看到中间状态。
  - **Settings 加 "Per-provider concurrency" slider（1–8，默认 3）**。`perProviderConcurrencyLimit` 从 `static let` 升级为 `@Published var` + `AgentSettingsStore.{load,save}PerProviderConcurrencyLimit()` 持久化。`didSet` 钳 1–8、写盘、**立刻 `drainPendingDispatchQueue()`**——把 cap 从 3 调到 5 的瞬间，队列里前两个本来要等的 dispatch 立刻起步；从 5 调到 1 不会粗暴中断已经在跑的 turn，只是后续 cap 满了就排队。Settings → Agent → Concurrency section 新增。

## 1.49.0-rc3 - 2026-06-03

- **并发 Agent Runtime 重构，第 3/4 步：真并发。** `dispatchAgentMessage` / `runAgentLoop` / `prepareImagesForTextOnlyProvider` / `configurationForCurrentTurn` / `consumeNextQueuedMessageIfNeeded` / `captureAgentPlanFromLatestMessage` / `captureAgentGoalEvaluationFromLatestMessage` / `captureAgentPatchProposals` / `awaitToolDecision` / `appendToolMessage` / `setAgentError` / `maybeAutoCompressContext` / `shouldAutoCompressNow` / `compressAgentContext` / `runContextCompression` 全部改成 `(for runtime: AgentRuntime, …)` 签名。函数体内 `self.agent*` 一律改成 `runtime.*` 对应字段——这样多个 runtime 各自跑 `Task` 时谁也不会写错对方的 messages / toolCalls。原 API 保留薄壳转发到 `activeRuntime`（如 `persistActiveAgentSession()` / `clearAgentConversation()` / UI 直接调的 `stopAgentResponse()`），UI 侧零改动。`runAgentLoop` 现在用 `runtime.workspaceRootPath` 而不是 `AppState.rootDirectory` 解析 workspace——并发跑两个不同 workspace 的 session 时，背景 runtime 的 tool 不再被前台窗口切项目污染。
- **Per-provider 并发上限。** `AppState` 新增 `inFlightCountByProvider: [String: Int]` + `pendingDispatchQueue: [PendingDispatch]`。`dispatchAgentMessage` 入口先 `acquireProviderSlotIfPossible(providerID:)`：当前 provider 在跑的 turn < 3（`perProviderConcurrencyLimit`）就 +1 通过；满了就入队 `PendingDispatch(runtimeID, text, images, providerID, enqueuedAt)` FIFO 排队。`runAgentLoop` 的 defer 末尾 `releaseProviderSlot(providerID:)` → -1 + `drainPendingDispatchQueue()` 扫一遍队列 promote 可以放行的（每 provider 一次只 promote 一个，保持公平）。**关键**：上限按 `providerID` 分桶（不是 baseURL 也不是 model），DashScope key 限 3 个 ↔ OpenAI key 同时再开 3 个互不挤；用户用多个 provider 时实际并发是 3 × provider 数。Settings slider 留给 rc4。
- **Routine 改后台启动。** `fireRoutine` 不再 `appMode = .agent`，不再 `startNewAgentSession(inWorkspaceAt:)`（那俩会切 `activeAgentSessionID` + 切窗口当前文件夹），改成直接 `agentSessions.insert(session, at: 0)` + `AgentRuntime(session:)` + `agentRuntimes[id] = runtime`，然后 `dispatchAgentMessage(for: runtime, …)`——一切走并发 gate。Routine 跑起来时 sidebar 上会出现那条 session，但用户正在看的 chat pane 不受打扰；新建的那个 routine session 后台静默跑，rc4 会给 sidebar 加状态点让"哪些在跑"一眼可见。旧的"isAgentResponding 时退避，下个 tick 再试"逻辑废弃——并发 gate 接管这事，多条 routine 同时 fire 也都进队不会丢。
- **runtime 删除清场。** `deleteAgentSession` 现在 cancel 该 runtime 的 `requestTask`、resume 它的 `toolDecisionWaiter`、从 `pendingDispatchQueue` 移除该 runtime 的所有排队条目——避免"session 删了但它的网络请求还在跑"或"队列里还有它的待 dispatch"的悬挂状态。
- **关于 UI：rc3 不动一行 UI 代码。** chat pane / composer / sidebar / status bar 全部继续读 `appState.agent*` 委托属性——指向 active runtime。UI 上看起来还是"只有一个对话框"，但底下 active 之外的 runtime 已经真在并发跑了。rc4 会改 UI 直接绑 runtime 并加 sidebar 状态点，那时多 session 并发的"看得见"也跟上。**rc3 行为目标**：多 session / routine 真同时跑且互不阻塞，但视觉上跟 rc2 一致——active 切到正在跑的 routine session 上可以看到它的 messages 实时流入。
- **空状态欢迎页顶部留白收一收，header 复制按钮不再被 focus ring 描蓝。** ① `AgentEmptyState` 在 transcript 里被 `.padding(.top, 80)` 推得太低，"What's up next, rocky?" 上方一大片空白，视觉上像把欢迎语生硬地按到了页面中段——改 `40`，整体往上提一截，但仍跟 header 留出可呼吸的间距，不会贴脸。② `AgentChatHeader` 顶部"复制 title"那个 `square.on.square` 小按钮，因为是 `.buttonStyle(.plain)` 但仍可被 macOS keyboard focus 系统抓住，键盘 tab 一过或者鼠标点完之后就挂一圈蓝色 focus ring，跟正文标题挤在一起非常脏。加 `.focusable(false)` 后这个按钮不再吃 focus，描边消失；顺手给同 header 里"新会话 / 切到 Editor 模式"两个 icon button 也补上同样的 `.focusable(false)`，避免哪天用户 tab 一下整个 header 又被框起来。视觉行为：只去掉 focus ring，按钮本身的点击/hover/help tooltip 全部保留，accessibility 仍可通过 VoiceOver rotor 访问。

## 1.49.0-rc2 - 2026-06-03

- **并发 Agent Runtime 重构，第 2/4 步：状态真搬。** `AgentRuntime` 扩成持有完整 per-session 运行状态：22 个 @Published 字段（messages / patchProposals / toolCalls / input / pendingImages,Skills,Files / pendingIncludeWorkspaceOverview / isResponding / turnStartedAt / errorMessage,Details / interactionMode / currentPlan,Goal / queuedMessages / sessionModelOverride / didEditFiles / worktreeChanges / isCompressingContext）+ 2 个非 Published 字段（requestTask / toolDecisionWaiter）。`AppState` 上的同名字段从 stored `@Published` 改成 get/set **委托属性**——读写自动路由到 `activeRuntime`，nil 时回安全默认（空数组 / nil / false）。这意味着 313 处 AppState 内部代码 + 75 处 UI 代码**一行不改**就完成数据迁移，靠的是相同符号名的语义重定向。
- **关键防御：UI 刷新通知通过 objectWillChange 转发。** AppState 在 init 末尾 `subscribeToActiveRuntime()`，订阅 active runtime 的 `objectWillChange`，每次 runtime 内部 @Published 字段变化时调用 `appState.objectWillChange.send()`。`activeAgentSessionID` 切换时重订（startNew / select / delete 三处都加了 `subscribeToActiveRuntime()` 调用）。这让 SwiftUI 视图通过 `appState.agentMessages` 等绑定的现有路径继续收到刷新通知，不需要任何 @ObservedObject runtime 改动——UI 完全不动。
- **三个 session 生命周期函数语义重写。** `startNewAgentSession` / `selectAgentSession` / `deleteAgentSession` / `pruneEmptyAgentSessions` 全部针对委托语义重写：① 不再"清 AppState 上唯一一份 agent\* 字段"（那个动作在委托下会**真把上一任 runtime 的状态清掉**——和原意"清出新槽"完全不等价）；② 改为"取消 outgoing runtime 的 in-flight 任务和 waiter"，per-session 状态保留在 runtime 上不变；③ runtime 在 activeAgentSessionID 切到它之前装好，避免委托 setter 写到 nil 黑洞；④ delete 时如果命中正在跑的 session 还会取消它的 requestTask 和 waiter，避免 URL session 泄漏；⑤ `persistActiveAgentSession` 改为通过 `runtime.persist()` 落盘，再把更新过的 session 镜像回 `agentSessions[index]` 让 sidebar 跟上 title/updatedAt。
- **rc2 不动 UI。** 75 处 `appState.agent*` 读写继续工作。UI 直接绑 runtime 留给 rc3——那时真并发上线，sidebar 需要给每个 runtime 各画"正在跑"指示器，那是 UI 不得不动的最自然时机。**rc2 行为目标：和 v1.48 一致**——只跑一个 active turn，切 session 时 outgoing 被取消、incoming 显示自己的 messages。如果发现行为差异，那是 bug，不是 feature。

## 1.49.0-rc1 - 2026-06-03

- **并发 Agent Runtime 重构，第 1/4 步：脚手架。** 新增 `AgentRuntime` 类（`@MainActor`、`ObservableObject`、`Identifiable`），目前只持有 session 引用和 `workspaceRootPath`——真状态字段下个 rc 才搬。`AppState` 新增 `agentRuntimes: [AgentSession.ID: AgentRuntime]` 字典、`activeRuntime` 计算属性、`runtime(for:)` 懒加载。`startNewAgentSession` / `selectAgentSession` / `deleteAgentSession` 钩进生命周期：开 session 创建 runtime，删 session 销毁 runtime。**rc1 行为零变化**——UI 完全没动，所有 `@Published agent*` 字段还在 `AppState` 上原样工作，runtime 只是个空容器先就位。这一步的价值是：rc2 把状态搬进 runtime 并改 UI 绑定时，session 生命周期代码已经备好钩子，不会变成"两件事在一个 PR 里搅在一起"。`workspaceRootPath` 在 runtime 上是 `let`（构造时冻结）——为 rc3 真并发铺路：那时多个 runtime 各跑各 turn，谁也不能回头读 `AppState.rootDirectory`（窗口当前文件夹会因用户切项目而变化）。

## 1.48.0-rc1 - 2026-06-03

- **新增 Routines：到点自动开新 Agent session 跑预设 Prompt。** 数据模型 `AgentRoutine`（id / name / prompt / workspaceRootPath / modelID / schedule / isEnabled / lastRunAt / lastSessionID）落盘到 `~/Library/Application Support/VeilWriter/agent-routines/<uuid>.json`，一文件一 routine，复刻 `AgentSessionStore` 的容错读写——单条 JSON 坏掉只影响它自己。`AgentRoutineSchedule` 是 tagged enum，四种节奏：① `.interval(minutes)` 间隔；② `.dailyAt(h,m)` 每天定点；③ `.weekdaysAt(h,m)` 工作日定点（截图里 "Runs weekdays at 20:30" 的形态）；④ `.weeklyAt(weekday,h,m)`；`nextFireDate(after:calendar:)` 用 `Calendar.nextDate(after:matching:matchingPolicy:.nextTime)` 计算下次触发，避免自己造 DST/夏令时 bug。`AgentRoutineScheduler` 是 `@MainActor` 单例式持有：30s 间隔 `Timer.scheduledTimer` 挂到 `.common` runloop mode（菜单/拖动时也照走），每 tick 遍历快照判断哪些 routine `nextFireDate <= now`；启动时先做一次 `evaluate(catchUp: true)` 把睡眠/未启动期间错过的补跑一次；`UserNotifications` 懒申请权限——用户拒绝也不影响 routine 跑，只是少了系统通知。关键防御：trigger 返回 `Bool`——`AppState.fireRoutine` 在 `isAgentResponding == true` 时返回 false，scheduler 不更新 `lastDispatchedAt`，下个 tick 再试，**绝不打断你正在写代码时的当前对话**；同一 tick 重入用 `lastDispatchedAt[id]` < tickInterval 拦截，避免一个 minute 边界双发。`AppState` 新增 `agentRoutines: [AgentRoutine]`（@Published）+ `saveAgentRoutine` / `deleteAgentRoutine` / `toggleAgentRoutineEnabled` / `runAgentRoutineNow` / 内部 `fireRoutine(force:)`；fire 时先 `appMode = .agent` 再 `startNewAgentSession(inWorkspaceAt:)`（自动切到对的 workspace），按需要叠加 `agentSessionModelOverride`，最后复用现成的 `dispatchAgentMessage(text:images:)`——一行接进核心 turn loop。
- **Sidebar 新增 "Routines" 区段（独立文件 `AgentRoutinesSidebarSection.swift`，避免恶化已超 3000 行的 `AgentModeView`）。** 区段插在 primary actions 和 Workspaces 之间。每行：左侧 `clock.fill`（启用）/ `clock`（停用）+ 名称 + 下面小字调度摘要（`schedule.summary` 输出 "每天 09:00" / "工作日 20:30" / "周一 09:00" / "每 30 分钟"）；hover 出 ▶ 立即运行 + ⏸ 启停按钮，右键菜单提供 启用/停用、立即运行、编辑、删除（destructive）；右上角 + 直接弹空白编辑器 sheet（默认绑当前 `rootDirectory`，省一步选 workspace）。空状态文案"还没有 Routine。点击 + 创建一条到点自动运行的提示词。"
- **Routine 编辑器 sheet（`AgentRoutineEditorView`）。** 字段：名称（TextField）、Prompt（多行 TextEditor + 边框 overlay）、Workspace（Menu 列出 sessions 已用过的根 ∪ 最近文件夹 ∪ 当前 root，dedup + 按 lastPathComponent 字母序；带"不绑定 Workspace"选项）、模型（Menu 列出 `agentKnownModelIDs` ∪ provider library 每个 entry 的 `flashPrimary` / `proPrimary` / `flashAlternates` / `proAlternates`；带"跟随当前 Flash / Pro 路由"占位）、调度（segmented picker 四选一，下方 Stepper/Picker 联动配出小时分钟/星期）、启用开关。底部：左下"立即运行一次"（不影响调度时间表，且禁用态也能手动跑），右下取消 / 保存（保存按钮在 name 或 prompt 任一空时 disabled）。`assembledSchedule()` 从 local @State 重组回 enum，保存时 `appState.saveAgentRoutine(_:)` 一并刷新 scheduler 快照。

## 1.47.0-rc22 - 2026-06-03

- **会话置顶 + 归档（Cursor 风格的行内 icon 操作）。** `AgentSession` 新增 `pinnedAt: Date?` / `archivedAt: Date?` 两个字段（用时间戳而不是 bool：钉住的多条按 `pinnedAt` desc 排序，再钉一次自动浮到最顶；老 JSON 走 `decodeIfPresent` 兼容）；`AppState` 加 `toggleAgentSessionPinned(id:)` / `toggleAgentSessionArchived(id:)`，每次写回 `AgentSessionStore`。`AgentSessionsSidebar` 的 sessionRow 新增 `.onHover` + `hoveredSessionID` 状态，hover 时右侧浮出 pin（`pin` ↔ `pin.slash`）和 archive（`archivebox` ↔ `tray.and.arrow.up`）两个小按钮；未 hover 但已置顶的行常驻显示一个 45° 旋转的 `pin.fill` badge，让置顶状态一眼可见。右键菜单加「置顶 / 取消置顶」「归档 / 取消归档」「删除会话」。归档项不再混在主列表里：`workspaceGroup` 拆 `activeSessions` / `archivedSessions`，archived 走 workspace 末尾一个 `已归档 (N) ▸` 折叠条（`expandedArchivedGroups: Set<String>`），点开才展开，看完再点收起。组内排序新增 `sessionOrder(_:_:)`：① 已置顶在前，按 `pinnedAt` desc；② 其余按 `updatedAt` desc——workspace 之间的稳定顺序不变，只是组内多了一个"置顶块"。

## 1.47.0-rc21 - 2026-06-03

- **Agent 输入框：Cmd+V 真的能粘贴图片了（不再只对极少数 app 工作）。** 旧实现的 `hasImage` 只检查 pasteboard items 里有没有 `.png` / `.tiff`，但很多来源（Notes、Sketch、Figma、Safari/Chrome 网页图片、Cmd+Shift+Ctrl+4 截屏到剪贴板）放进 pasteboard 的是 `public.image`、`com.apple.icns` 或 NSImage 归档，这些类型一律不命中 → 用户感觉"粘贴对图片不生效"，只能点加号选文件。`AgentImagePasteboardHelper` 新增 `pasteboardHasImage(_:)`，先用 AppKit 官方推荐的 `NSImage.canInit(with:)` 做存在性判断，再退回到具体类型探测；`readImages(from:)` 也加了 `NSImage(pasteboard:)` 兜底分支——前面三条具体类型都没匹中就让 AppKit 自己解码，再 flatten 成 PNG。`ComposerNSTextView.paste(_:)` 切到新 helper，于是不管图片是从哪个 app 复制来的，Cmd+V 都能直接挂到 `agentPendingImages` 里。

## 1.47.0-rc20 - 2026-06-03

- **Keychain"想要使用机密信息"弹窗不再频繁出现。** 旧版 `saveAPIKey` 每次都 `SecItemDelete + SecItemAdd`，而 `AppState.agentProviderLibrary.didSet` 在 Settings 任何字段（base URL、model、entry 名）改动时都会触发，结果每动一下设置都对所有 entry 做一遍"删了再加"，每次 add 都被 macOS 视作新写入秘密 → 反复弹"VeilWriter 想使用钥匙串里的 'im.some.veilwriter.agent'"。三件套修复：① **no-op 快路径** —— 先读现有值，和要写的一样就直接 return，砍掉 99% 的重复写入；② **优先 `SecItemUpdate` 而不是 delete+add**，保住 Keychain ACL 列表（之前 delete 会清掉用户"始终允许"的授权，下次读就再问一次）；③ 写入时显式设 `kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock`，避免默认策略在某些 macOS 版本上被解读为"每次访问都问"。空字符串路径还原成只 delete 不重建。

## 1.47.0-rc19 - 2026-06-03

- **粘贴一律按纯文本来，外部字体/段落样式不再污染编辑器。** 默认 `NSTextView.paste(_:)` 会优先挑选 pasteboard 里的 RTF/HTML，把源应用（Notes、Safari、终端、富文本编辑器）的字体、字号、行距、背景色整段灌进来，于是出现截图里粘贴命令突然字号变大 / 配色错乱的情况。`VeilWriterTextView.paste(_:)` 重写：自己读 `pasteboard.string(forType: .string)`，走 `insertText:replacementRange:` 注入——和敲键盘走同一条路径，undo / textDidChange / 语法高亮全部正常触发；只有真没字符串表示时才回落 `pasteAsPlainText:`。`ComposerNSTextView` 同步：原本图片分支 `super.paste` 也会带格式，改成同样的"读 string + insertText"；非图片分支也一并修。这样代码编辑器和 Agent 对话框两边粘贴体验都干净，外部样式一律剥离，渲染交由我们自己的高亮 / 主题来。

## 1.47.0-rc18 - 2026-06-03

- **新增 Developer ID 打包 + 公证 + DMG 一键脚本（`scripts/release.sh`）和发布手册（`docs/RELEASE.md`）。** 脚本流程：`xcodebuild archive`（Release + Manual + Developer ID 身份）→ `xcodebuild -exportArchive`（method=developer-id, 临时 ExportOptions.plist 内联生成）→ 优先 `create-dmg`、回落 `hdiutil` 打包 → `codesign --timestamp` 给 dmg 自身签名 → `xcrun notarytool submit --keychain-profile veilwriter-notary --wait` 同步公证 → `xcrun stapler staple` 钉公证票 → `spctl --assess` 自检；支持 `--skip-notarize` 跳过公证用于本地验证。证书身份从钥匙串里 `Developer ID Application: Beijing Alibaba ... (ZH2S7D6PL6)` 取，TEAM_ID 写死 `ZH2S7D6PL6`，版本号从 pbxproj 的 `MARKETING_VERSION` 抓。`docs/RELEASE.md` 详细写了 App-Specific Password 的申请路径（appleid.apple.com → 登录与安全 → 专用密码）、`xcrun notarytool store-credentials` 怎么把密码安全存进 Keychain、create-dmg 可选安装、常见公证失败排查、撤销/重发流程。

## 1.47.0-rc17 - 2026-06-03

- **窗口尺寸真正"记住上次退出时的状态"，且首次启动就开到屏幕 80%。** SwiftUI `WindowGroup` 既没设 `defaultSize` 也没设 frame autosave，于是每次启动都用一个小默认 frame，看着就像"我上次明明拖大了，它怎么又变小了"。新增 `applyFrameAutosaveAndDefaultSize(_:)`：① 第一次见到 `NSWindow` 时检查 `UserDefaults` 下 `"NSWindow Frame VeilWriterMainWindow"` 是否已有记录；没有就主动 `setFrame` 到 `screen.visibleFrame` 的 80% 并居中。② 之后调用 `setFrameAutosaveName("VeilWriterMainWindow")`，让 AppKit 自动把后续 resize 写回 UserDefaults，下次启动直接复原。③ 用 `NSHashTable.weakObjects()` + `didBindFrameAutosaveName` 守门：`WindowChromeConfigurator.poll()` 每个 runloop 都重入 `configure`，但 resize 和 setFrameAutosaveName 只在每个 window 首见时各跑一次；同时 AppKit 不允许两个 window 共用同一 autosave name，多窗口场景下只让第一个窗口持有 binding，后续窗口仍能拿到首次启动的 80% 居中行为但不污染 UserDefaults。

## 1.47.0-rc16 - 2026-06-03

- **点击 Workspace 前的文件夹图标可整组收起/展开。** 新增 `collapsedWorkspaces: Set<String>` 状态，独立于既有的"超过 5 条 → See more"展开标志。文件夹图标外面包了个 `Button`：点一下整组所有 session 立刻隐藏（带 150ms `easeInOut` 动画），只剩 workspace 标题；再点一下还原。视觉提示用 SF Symbol `folder` ↔ `folder.fill` 切换——填充态暗示"里面藏着东西"，空心态是"已打开"；`help` 文案也对应"展开 / 收起会话列表"。点击命中区域只盖住 14×14 的图标本身，标题行其余部分维持原 contextMenu（"New Chat in this Workspace"）不变，不会因为收起改动撞到右键菜单。

## 1.47.0-rc15 - 2026-06-03

- **Workspaces 顺序进一步固化，连"当前项目置顶"都去掉。** rc14 把当前 `rootDirectory` 置顶 + 其余字母序，但用户希望完全固定，不要因为切项目而动。新规则：所有命名 workspace 按 `workspaceDisplayName`（也就是 folder 的 `lastPathComponent`，更像 Finder 体验）做 `localizedCaseInsensitiveCompare`；"No workspace" 仍钉在最末。顺序只跟"有哪些 workspace"有关，跟"现在打开的是哪个"无关，跨启动跨切换 100% 稳定。

## 1.47.0-rc14 - 2026-06-03

- **Workspaces 分组顺序冻结，不再每发一条消息就上下乱跳。** 旧版 `groupedSessions` 按"组内 first session 的 updatedAt"排 workspace group，发条消息组就被顶到第一位，导致 Teamify / No workspace 反复换位置。新规则：① 当前 `rootDirectory` 对应的 workspace 永远置顶（眼睛最容易看到正在用的项目）；② 其余 workspace 按路径 `localizedCaseInsensitiveCompare` 字母序——跨启动跨操作全程稳定；③ "No workspace" 兜底组钉在最末。组**内**的 session 仍按 `updatedAt` 倒序，所以单组内"刚聊过的在上面"的直觉没丢，只是文件夹层不再乱动。

## 1.47.0-rc13 - 2026-06-03

- **qwen-vl 图片描述默认折叠成小胶囊，不再霸屏。** 文本-only 模型走 qwen-vl 兜底时，`contentByAppendingImageDescription` 把整段 AI 描述拼进了 user 消息的 content 里，于是用户的气泡里"图片说的啥"只占一行、底下却跟着一整版 markdown bullets（见截图）。新增 `AgentUserContentSplitter`：用正则匹配 `[Image description generated by … for N attached image(s)]` 头部行，把它和后面所有内容剥离成独立的 `description` 段；`userBubble` 渲染时只把用户本人那句话保留为正文，剥出来的描述塞进 `AgentImageDescriptionDisclosure` —— 一个白底 18% 透明胶囊，默认收起显示"图片 AI 描述 ⌄"，点击展开后才用半透明卡片显示完整内容。底层存储不变（依然是完整 content，下一轮模型仍能看到描述、上下文连贯性不受影响），只是看图省心了。

## 1.47.0-rc12 - 2026-06-03

- **侧栏不再堆"New Chat"垃圾。** 每按一次 ⌘N 都会建一条空 session 并落盘，时间一久 Workspaces 列表就密密麻麻全是同名"New Chat"，根本分不清哪个是哪个。本次：① `groupedSessions` 渲染前过滤掉"无 user 消息且非当前激活"的 session，UI 立刻干净；② 新增 `pruneEmptyAgentSessions()`，把这种空 session 从内存和磁盘（`AgentSessionStore.delete(id:)`）一并清掉；③ 在 `init` 加载 sessions 之后调用一次（启动时清存量），在 `startNewAgentSession()` insert 新 session 之前再调用一次（避免连按 ⌘N 累积）。规则上当前激活的会话即使空也保留——用户正打算往里写呢，藏起来高亮就没了。

## 1.47.0-rc11 - 2026-06-03

- **API 超时三件套：调大超时 + 友好中文报错 + 错误卡上的「重试」按钮。** 旧版 `AgentClient.requestTimeout = 45` 用在 `URLSessionConfiguration.timeoutIntervalForRequest`，这个语义是"两次字节之间最多等多久"，对带 reasoning 的 Qwen3/QwQ/DeepSeek-R1 来说首字节经常超 45s，于是好端端的请求被 NSURLErrorTimedOut 干掉，UI 只甩出一行英文 *"The request timed out."* 就没了。本次：① `requestTimeout: 45 → 120`；② 新增 `friendlyMessage(for:)`，把 `URLError`（timed out / 无网 / DNS / TLS / 连接重置 / 被取消…）和 `AgentClientError.serverStatus(401/403/404/429/5xx/504…)` 全部翻译成中文一行话 + 建议下一步操作；③ `AgentErrorCard` 右侧加「重试」「关闭」按钮，新增 `AppState.retryLastAgentTurn()` 直接复用 `runAgentLoop`（user 消息本来就还在历史里，错只是把空 assistant 占位删了），新增 `dismissAgentError()` 给关闭按钮用。`canRetryLastAgentTurn` 计算属性把"非响应中且历史里有 user 消息"作为重试可用条件，避免在压缩上下文或新会话上误触发。

## 1.47.0-rc10 - 2026-06-03

- **"正在思考"分隔条现在带实时秒表。** 之前思考中的横线只显示静态的"正在思考"和一个转圈圈，模型卡几十秒甚至几分钟也分不清是慢还是挂了。`dispatchAgentMessage` 时新写入 `agentTurnStartedAt`，`AgentThinkingDivider` 用 `TimelineView(.periodic(from:by:1))` 每秒读一次，渲染 `正在思考 · 12s`（>60s 自动切 `1m 5s`，>1h 切 `1h 03m`）；turn 结束、会话切换、清空对话、进入 Agent 模式时一并清空时间戳，避免残留。等于给用户一个"还活着"的脉搏，怀疑挂了直接看秒数有没有走就行。

## 1.47.0-rc9 - 2026-06-03

- **Auto-approval safety judge always runs on Flash now.** The LLM judge that classifies "is this `run_command` shell command safe enough to auto-run" used to use the currently-active model — which for users on Pro routing meant every `find -name "*.swift"` decision burned Pro tokens *and* waited Pro latency, often timing out the 12s budget and falling back to the user gate. New `configurationForSafetyJudge()` always resolves to the active library entry's Flash model regardless of the turn's routing (with a graceful fallback to the per-turn config if Flash isn't set). Same YES/NO contract on the wire, an order of magnitude faster and cheaper in practice. Settings → Tool approval text updated to reflect the new behaviour.

## 1.47.0-rc8 - 2026-06-03

- **Toned down the Stop button.** The streaming-active state was a fully-saturated solid red disc with a white `stop.fill` glyph — a visual alarm bell for what is, in practice, "click to interrupt the model". Now it's a soft red-tinted disc (12% fill) with a thin red stroke (55%) and a red-foreground `square.fill` glyph. Same target size, same affordance, much calmer.

## 1.47.0-rc7 - 2026-06-03

- **Model picker no longer drops submenus on hover.** The chat-mode model picker used to be a two-level Menu (provider → its models). SwiftUI's macOS Menu dismisses nested Menus on the slightest hover drift, so clicking a provider row would only flash the submenu before it disappeared. Flattened to a single-level layout: each library entry becomes a `Section("ProviderName")` (active entry prefixed with ★) and its Flash/Pro models live directly under that header as one-click rows. Same activation behaviour (`selectAgentEntryAndModel` does provider + model in one go), just one click instead of fighting the submenu.

## 1.47.0-rc6 - 2026-06-03

- **Workspace picker in the composer toolbar.** New `WorkspacePickerPill` sits between the `+` attach button and the model picker. Shows a folder icon plus either the current workspace name or "Pick folder" when nothing is open. Click → menu with three sections: (1) for the current folder — Show in Finder / Copy path / Copy branch name (last one only when on a git branch); (2) "Switch workspace" listing every known root (union of every agent session's `workspaceRootPath` and the global `recentFolders`, deduped by canonical path, sorted by name, ✓ on the active one); (3) a "Choose folder…" sentinel at the bottom that opens the system folder picker. Picking from (2) or (3) calls `openFolderURL`, which registers as recent + flips `rootDirectory` + refreshes git — so the next new chat in this window auto-groups under that workspace in the sidebar.

## 1.47.0-rc5 - 2026-06-02

- **Per-message footer with copy / timing / tokens.** Chat bubbles in both the full-screen Agent mode and the right-side Agent panel now sport a small caption row right under the bubble. User rows show just a copy-to-clipboard button (square→checkmark for ~1.4s on success). Assistant rows additionally show the wall-clock elapsed seconds for that turn (e.g. `1.8s`, `42s`, `1m 12s`) and the prompt/completion token split when the provider returned a usage block (`in 1.2k · out 340`). Three new fields on `AgentMessage` — `elapsedSeconds`, `promptTokens`, `completionTokens` — all decoded with `decodeIfPresent` so older session JSON loads cleanly. `AppState` stamps `turnStartedAt` right before handing the request to `AgentClient`, then writes the elapsed delta back on the message once the stream resolves; the existing `.usageReported` event handler now also splits prompt vs completion into the new fields.
- **Composer shrunk a touch.** Bottom-of-chat text editor minHeight 40→26, maxHeight 130→116. Same multiline behaviour, just less vertical real-estate burned when the buffer is empty.

## 1.47.0-rc4 - 2026-06-02

- **Resizable Settings window.** Settings used to come up as a fixed 560-wide panel — the Agent provider editor in particular ran out of room and you couldn't drag the corners to fix it. Replaced the hard `frame(width: 560)` lock with `minWidth: 560 / idealWidth: 760 / maxWidth: .infinity` (height analogous, ideal 680), and added a `SettingsWindowResizableEnforcer` NSViewRepresentable that reaches into the host `NSWindow` and ORs `.resizable / .miniaturizable / .closable / .titled` into its styleMask, drops the contentMaxSize cap, and enables the zoom/minimize buttons. End result: behaves like a normal mac document window — drag any corner, minimize, zoom, all of it.

## 1.47.0-rc3 - 2026-06-02

- Added an Apache License 2.0 `LICENSE` file at the repo root. README license badges now point to the actual file (blue "Apache 2.0" instead of grey "see LICENSE"), and both English and Chinese license sections were rewritten to state the terms explicitly (commercial use OK, retain notices, patent grant included) instead of the previous "source-available pending an explicit license" placeholder.

## 1.47.0-rc2 - 2026-06-02

- Added an **Agent Mode** button to the "No Folder Open" empty-state hero. Same row as Open File / Open Folder, but tinted in the accent color to read as the primary alternative for users who don't need to open a project before chatting. One click calls `setAppMode(.agent)` and lands directly in a workspace-free chat session. Subhead reworded to mention the new option. `EmptyWorkspaceButtonStyle` gained an optional `tint:` parameter so the accent treatment is reusable.

## 1.47.0-rc1 - 2026-06-02

Four quality/polish phases shipped together — Markdown polish, per-entry routing, sidebar provider status, and parity tests for the chat picker primitive.

- **Markdown polish.** Inline `` `code` `` spans now render as monospace-with-light-tinted-pill via a new centralised `MarkdownInline.attributedString(from:)` helper (used by every block kind + table cells, so headings / paragraphs / quotes / list items all stay consistent). Nested lists are now actually nested: parser counts leading whitespace (2 spaces or a tab = 1 level), `MarkdownPreviewBlock` carries a new `indent: Int`, renderer pads 18pt per level (capped at 4) and cycles bullet glyphs by level (• → ◦ → ▪). Added `MarkdownListNestingTests` (5 cases).
- **Per-entry routing mode.** Routing (Auto / Flash / Pro) used to be a single global Settings control. Now lives on each `AgentProviderEntry` — Settings → Agent → provider editor has its own segmented picker, and activating an entry adopts that entry's routing mode automatically. So you can keep OpenAI on Auto, force DeepSeek to Pro, and Claude to Flash without flipping a global control every time you switch providers. Older library JSON (pre-this field) decodes to `.auto` via `decodeIfPresent`. `makeConfiguration(routingMode:)` now accepts an optional override; nil means "use the entry's own mode" — compression still overrides to Flash explicitly.
- **Sidebar provider status bar.** Agent-mode sidebar now shows a one-line pill right under the "CHATS" header listing the active library entry name. Click → menu lists every library entry, click any to set active. Hidden when only one entry exists (no point picking from one).
- **`selectAgentEntryAndModel` regression tests.** New `AgentEntryModelSelectionTests` (4 cases) covering: switching to a different entry flips both `activeID` and the live `agentConfiguration`; picking a model that matches the route default clears the session override; empty model string clears the override; the entry's own routing mode propagates to the live configuration on activate.

## 1.46.0-rc7 - 2026-06-02

- Markdown renderer enhancements (Phase 1 of the post-multi-provider cleanup):
  - **Inline code chips.** Spans Apple's parser tags as `.code` now render with a monospaced font + light grey pill background instead of the plain monospace they were getting from `AttributedString(markdown:)`. Centralised in a new `MarkdownInline.attributedString(from:)` helper so headings, paragraphs, quotes, list items, and table cells stay visually consistent.
  - **Nested lists.** Parser counts leading whitespace (2 spaces or tabs = 4 spaces, normalised to one indent level) and stamps a new `indent: Int` on each `.unorderedList` / `.orderedList` block. Renderer pads 18pt per level (capped at 4) and cycles the bullet glyph by level (• → ◦ → ▪) so nested children read as nested at a glance. Top-level lists look identical to before.
  - Added `MarkdownListNestingTests` (5 cases) covering top-level, 2-space, 4-space, tab-indented, and ordered-list nesting. All pass.

## 1.46.0-rc6 - 2026-06-02

- Markdown renderer now handles GFM-style pipe tables in Agent assistant messages. Previously a model reply containing `| Path | Note | / |---|---| / | x | y |` got flattened into one long paragraph because the parser had no table support. `MarkdownPreviewBlock.Kind` gains `.table` (with `tableHeaders` + `tableRows`); the parser commits to table parsing only when a pipe row is immediately followed by an alignment row like `|---|---|` (so a stray `|` in prose can't hijack the parser), accepts colon alignment markers (`:---`, `:---:`, `---:`), tolerates the loose form without outer pipes, and closes the table cleanly at EOF.
- New `MarkdownTableBlockView` renders the parsed table — bold tinted header row, alternating-zebra body rows, inline-Markdown-rendered cells via `AttributedString(markdown:)`, the whole thing wrapped in a horizontal scroll view so wide tables don't push the chat column. 5 parser tests cover plain GFM, alignment colons, EOF-trailing tables, pipe prose left as paragraph, and the loose-form variant.

## 1.46.0-rc5 - 2026-06-02

- Fixed `cd /path && git status | grep ... | head ...` (and similar read-only chains starting with `cd`) prompting for Allow/Deny instead of running silently. `cd`, `pushd`, and `popd` are now in `SafeCommand.alwaysSafeFirstTokens` — they change shell state only, no FS writes. Command-substitution forms like `cd $(...)` continue to be blocked upstream by the `$(` needle gate, so the loosening only affects the literal-arg case. Added `testSafeCommandCdAllowed` covering the typical agent emission, plus the substitution-still-dangerous regression.

## 1.46.0-rc4 - 2026-06-02

- **Chat-mode model picker rewritten as a two-level Provider → Model menu** (Phase D, completes the multi-provider effort). Top of the menu still offers "Use route default" to drop any session override. Below it, every library entry collapses into a submenu whose children are its Flash primary + Flash alternates, then Pro primary + Pro alternates (separated by a divider). Picking any leaf flips the active library entry to that provider (rebuilds the live configuration via `selectAgentEntryAndModel`) and sets the session override in one click — no need to first activate the entry in Settings.
- The active entry shows a yellow ★ in its submenu label; checked rows mark whichever model is *effectively* in play right now (override → that model; no override → the route's natural Flash/Pro pick).
- When more than one library entry exists, the pill label prefixes the provider's display name (`OpenAI · gpt-4.1-mini`) so the user always sees which provider this chat is talking to.
- Previously-fetched ad-hoc model IDs that don't appear in any library entry now collect under a "Recently fetched" submenu instead of getting mixed into the main list — keeps the picker scannable when the catalog is large.
- New `AppState.selectAgentEntryAndModel(entryID:model:)` collapses "switch active entry" + "set session override" into a single transactional call so the menu can't end up in a half-switched state.

## 1.46.0-rc3 - 2026-06-02

- **Settings → Agent rewritten as a multi-provider library** (Phase C). The old single-form layout is replaced by a left-pane provider list (with active star, add `+` / remove `−` controls) and a right-pane editor for the selected entry. The editor lets you set display name / preset / base URL / API key, plus separate primary + alternate model lists for Flash and Pro tiers (one model id per line). Edits commit immediately to `agentProviderLibrary` — no Save button needed for per-provider fields; the existing Save button still covers Image Understanding + routing mode.
- Clicking the star on any row activates that entry: `setActiveProviderLibraryEntry(id:)` rebuilds the live `agentConfiguration` from the entry's preset id, base URL, key, and primary flash/pro models — so the chat picks it up on the next turn without restarting.
- `AppState` exposes `agentProviderLibrary` as a `@Published` source of truth alongside the legacy `agentConfiguration`. Both are kept in sync: edits in the new UI rebuild the configuration; older code paths that write directly to the configuration are mirrored back into the active entry. A reentrancy guard breaks the obvious loop.
- Per-entry "Fetch Models" pulls /models against that entry's own base URL + API key (not the active configuration), so each provider's catalog can be inspected independently of which one is currently active in chat. Picker icons next to the primary fields drop fetched ids straight in.
- Switching the preset of an entry snaps the base URL to the preset's default and replaces flash/pro primaries if they don't look like they belong to the new preset (reusing the `recognizesModelID` heuristic added in rc2).
- Chat-side picker still uses the single-config flat list — Phase D (two-level Provider → Model picker that walks the library) comes next.

## 1.46.0-rc2 - 2026-06-02

- Fixed the chat-mode model picker showing a stale "Use route default: gpt-3.5-16k" after the user switched the agent provider (e.g. from OpenAI to DeepSeek) in Settings without explicitly resetting the flash/pro model fields. `AgentProviderPreset` now carries a `modelHints` substring list and a `recognizesModelID(_:)` helper; `AgentConfiguration.normalized` uses them to detect when the saved flash/pro/model still looks like it belongs to a previous provider and rewrites it to the current preset's documented default. Custom-provider entries (where we have no opinion about model naming) are left alone.
- Added the **multi-provider library** data layer (Phase B of the bigger Settings rewrite). New `AgentProviderEntry` carries a preset id, base URL, API key, and primary + alternate model lists for both Flash and Pro tiers. `AgentProviderLibrary` is a container with an `activeID` and upsert/remove/setActive helpers. `AgentSettingsStore.loadProviderLibrary` / `saveProviderLibrary` persist the library to UserDefaults (entries minus the API keys) plus Keychain (per-entry keys keyed by entry UUID), and the first load auto-migrates the existing legacy `AgentConfiguration` into a single-entry library so existing users don't lose their setup. UI surfaces (Settings rewrite + chat-mode two-level picker) come in the next two rc bumps.
- Added `AgentProviderLibraryTests` (8 cases) covering entry alternate-list cleaning, library upsert / active reassignment after delete / legacy migration, plus three regression tests for the picker bug (foreign model dropped after provider switch, recognised custom model preserved, custom provider left alone). All pass.

## 1.46.0-rc1 - 2026-06-02

- **Goal mode self-evaluation.** The agent is now asked to emit a fenced ```goal-check``` block at the end of every reply that should flip checklist items, listing 1-based indexes and `done` / `undone`. `AgentGoalChecklistParser.applyEvaluation(to:from:)` parses it (tolerates alias tokens — `complete`/`yes`/`✓` → done, `incomplete`/`pending`/`no` → undone — and silently drops unknown tokens / out-of-range indexes / no-op blocks). Wired through `captureAgentGoalEvaluationFromLatestMessage` in the agent-loop defer. The user retains override authority via the existing manual checkbox toggle; later `goal-check` blocks from the model can re-flip user overrides, so the loop is fully reversible in both directions. 6 parser tests.
- **`@` picker upgraded to a unified attachment menu.** Same shortcut now lists skills, project files (from the cached `quickOpenFiles` list), and a `@workspace` shortcut all in one popover with fuzzy filtering. Files attach as removable purple chips above the composer, file body re-read at send time so the model always sees the latest on-disk state. `@workspace` attaches a compact "root + first 120 file paths" overview. `AppState.composeAttachedPrompt` replaces the old skill-only composer and stitches all three context kinds in front of the user prose under labelled headers.
- **Sidebar session badges.** Each Agent-mode session row now shows tiny right-aligned indicators for active plan progress (`list.number 2/5`, colored by plan status — orange = awaiting approval, accent = executing, green = done) and goal progress (`target 1/3`). Hidden for sessions in Normal mode or with no plan/goal so ordinary chats stay clean. Hover tooltips spell out plan status / goal statement.
- **Plan step right-click menu.** Per-step context menu adds Edit / Insert above / Insert below / Restart from this step (Plan mode only) / Remove. Edit lets you fix the agent's wording without losing status; insert lands a fresh pending step in place; restart resets the chosen step and every step after it back to `pending`, then auto-sends a "resume from step N" message (with an optional note for why) so the agent picks up where you rewound. Each action uses a single-field sheet to keep the modal weight low. `AppState` gained `editAgentPlanStepText` / `insertAgentPlanStep` / `removeAgentPlanStep` / `restartAgentPlanFromStep`; all persist eagerly.

## 1.45.0-rc5 - 2026-06-02

- Added a **Replan** affordance at the bottom of every plan card. Click expands an inline note field — leave it empty to ask the agent for a fresh plan cold, or type guidance like "use sed instead of patches" / "skip step 3" / "the file is read-only" and hit Enter. Mechanics: `AppState.requestPlanRevision(note:)` drops the existing plan (so the system prompt flips back to "you must emit a ```plan``` block"), then auto-sends a user message wrapping the note, queueing if the agent is still mid-turn. The next assistant reply's ```plan``` block flows through the existing `captureAgentPlanFromLatestMessage` path and the card auto-refreshes with the new steps.
- The same row is shown for plans in every state (proposed / approved / executing / done), so mid-execution course corrections — the more common case — work without first clicking Reject.

## 1.45.0-rc4 - 2026-06-02

- Plan steps now have a lifecycle. `AgentPlan.steps` upgraded from `[String]` to `[Step]` (id + text + status: `pending` / `in_progress` / `done` / `skipped` / `failed`). The model is asked to self-report progress in a fenced ```progress block at the end of every reply it touches a step — `1: done`, `2: in_progress`, etc. The parser tolerates `1: done`, `- 1. complete`, `step 2: failed`, `4 skipped`, and the usual status-word aliases (`running`/`wip`/`doing` → in_progress, `done`/`complete`/`✓` → done, `blocked` → failed). Unknown tokens and out-of-range indexes are dropped silently rather than corrupting the whole plan.
- Plan card UI gained per-step status glyphs. Each row now starts with a clickable status icon: ○ pending, ↻ in progress (orange), ✓ done (green, struck-through), − skipped (struck-through), ✗ failed (red). Clicking cycles pending → in_progress → done → skipped → pending, so the user can override whatever the agent reported. Cycling is disabled while the plan is still .proposed (awaiting approval). Plan auto-flips to `.executing` on the first touched step and `.done` once every step is in a terminal state.
- System prompt in approved Plan mode now lists the **current** statuses inline (`1. [done] Inspect AppState`) and requires the ```progress block format, so the model has the full context to update accurately.
- Added `AgentPlanProgressTests` (7 cases) covering: initial extract → pending, progress block flips, all-terminal auto-completion, unknown-token tolerance, out-of-range indexes, no-block returns nil, and alternate formatting tolerance. Updated `AgentSessionPersistenceTests.planAndGoalSurviveJSONRoundTrip` to assert per-step status survives the JSON round-trip. All 11 tests pass.

## 1.45.0-rc3 - 2026-06-02

- Persisted Plan + Goal state to session JSON. `AgentSession` gained `interactionMode`, `currentPlan`, and `currentGoal` fields, all decoded with `decodeIfPresent` so older session files keep loading. `persistActiveAgentSession` writes them; `selectAgentSession` restores them (previously hard-reset to `.normal`/nil, dropping any plan/goal the moment you switched tabs). Every plan/goal mutator (`setAgentInteractionMode`, `approveAgentPlan`, `rejectAgentPlan`, `completeAgentPlan`, `setAgentGoal`, `toggleAgentGoalItem`) now triggers `persistActiveAgentSession()` so quitting between turns doesn't lose state.
- `setAgentGoal` preserves checklist `done` state when an item's text is unchanged across an edit, so the user can tweak the goal statement or add new items without losing what's already ticked.
- Added `AgentSessionPersistenceTests` covering legacy JSON loading, plan+goal round-trip, goal-mode-with-nil-goal, and the loud-throw contract for unknown interactionMode strings. All 4 tests pass.

## 1.45.0-rc2 - 2026-06-02

- Added a floating **Agent** pill at the upper-right of the editor window. Visible only when a workspace is open (`rootDirectory != nil`), the app is in editor mode, and focus/maximize aren't on — Agent mode needs project context to be meaningful. One click flips the window into Agent mode via `setAppMode(.agent)`. Rendered as an overlay on top of the tab bar (with a 72pt trailing reserve so the rightmost tab's close button never slips under it) and on top of the empty-project view (when a folder is open but no tab is active). Tooltip mentions the existing ⌘⇧A shortcut.

## 1.45.0-rc1 - 2026-06-02

- Added `@skill` quick attach in the Agent composer. Typing `@` opens a popover listing installed Codex skills discovered under `~/.codex/skills` and `~/.codex/plugins/cache` (same roots `list_skills` already scans). `↑`/`↓` filter and move, `Enter`/`Tab` attach. Attached skills appear as removable chips above the text editor; at send time their full `SKILL.md` bodies get spliced into the user prompt under a labelled header so the model treats them as task guidance, not verbatim user text. New `AgentSkillDirectory` / `AgentSkillEntry` surfaces the catalog publicly without going through the LLM tool round-trip.
- Added **Plan mode** (Codex-style, list → approve → execute). A new mode picker pill next to the model selector toggles Normal / Plan / Goal. In Plan mode, the system prompt requires the agent to emit a numbered ```plan fenced block and then stop. A new `AgentPlanCard` renders at the top of the transcript with Approve / Reject buttons. Until the user clicks Approve, **every write/exec tool call is hard-blocked at the AppState level** — the tool result that goes back to the model says "Blocked: Plan mode is active and no plan has been approved yet"; read-only tools still run so the agent can investigate before drafting. After approval the system prompt flips to "approved — execute step by step" and the gate opens. The plan parser handles streaming (renders the card while the block is still being typed) and walks numbered lines tolerantly (`1.` / `1)` / multi-line continuations).
- Added **Goal mode**. Open it from the mode picker → goal editor sheet (statement + acceptance checklist, one item per line). The active goal pins to every system prompt as "Goal + checklist" and asks the agent to report at the end of every reply which items moved. A goal card at the top of the transcript lets the user tick items off; the flipped state shows up in the next system prompt. Edit via the pencil button on the card or "Edit goal…" in the mode picker.
- Per-session plan + goal state resets on new-session / select-session / mode flip so chats don't bleed state into each other. Plan/goal aren't persisted to session JSON yet — they live for the lifetime of the active session and are recreated on demand.

## 1.44.0-rc1 - 2026-06-02

- Added Claude-Code-style history recall in the Agent composer. With the input empty, `↑` walks backwards through prior user messages in the current session (newest first), `↑` again steps further back, `↓` walks forward toward the saved draft. Once the buffer holds a recalled message you can keep cycling; the moment you edit it, the cursor detaches and `↑`/`↓` go back to normal caret motion. The coordinator tracks `historyIndex` (0 = newest), the original draft, and the exact last-pushed string so any external `text` binding update (slash action, programmatic set) cleanly invalidates the cursor.
- Added a "/" slash-command palette anchored to the top of the composer. Typing `/` opens it; further typing filters by command id or title prefix; `↑`/`↓` move the highlight; `Enter` or `Tab` runs the selected action and clears the input; `Esc` closes. Implemented as a SwiftUI overlay sitting above the NSTextView via a ZStack — so it can render shadows, accent-color row backgrounds, and SF Symbol icons without fighting the AppKit text system. Empty filter results render a "No matching commands" line instead of an empty floating card.
- Shipped six built-in commands, all pure local actions (no LLM round-trip, no network): `/new` (`startNewAgentSession`), `/clear` (`clearAgentConversation`), `/compress` (`compressAgentContext`), `/stop` (`stopAgentResponse`), `/clear-queue` (`clearAgentQueue`), and `/copy-last` (copies the most recent assistant message to the pasteboard).

## 1.43.0-rc7 - 2026-06-02

- Fenced code blocks in Agent assistant messages now render with a small header (language label + Copy button) and a syntax-highlighted body via the shared `SyntaxHighlighter`. A new `MarkdownCodeBlockView` resolves the fence's info string (`tsx`, `bash`, `py`, `c++`, etc.) to a known `Language` through an alias table — `sh`/`bash`/`zsh` → shell, `py`/`python3` → python, `tsx`/`jsx` → ts/js, and so on — and falls through to monospaced plain text for anything unknown. The block view auto-switches its background between `paper` (light) and `graphite` (dark) themes via `@Environment(\.colorScheme)`, with a faint border so it reads as one unit. Body is selectable and horizontally scrollable so long lines don't widen the chat column.
- Added a Copy button next to the language label. One click puts the code on the pasteboard and the button briefly flips to `✓ Copied` (green), resetting after ~1.4s so back-to-back copies still visibly confirm.
- Carried the fence language hint through the parser. `MarkdownPreviewBlock` gained an optional `info` field; the parser stores the trimmed text after the opening ``` (empty hint stays nil) and the code-block view reads it. PreviewPane consumers are untouched because `info` defaults to nil for every other block kind.
- Added a blinking accent-color cursor at the tail of the currently-streaming assistant message. `AgentAssistantMarkdownBody` takes a new `isStreaming` flag, derived from `isAgentResponding && message == last assistant message` in `AgentModeMessageView`. The cursor disappears the moment the model finishes the turn.

## 1.43.0-rc6 - 2026-06-02

- Agent-mode assistant messages now render as Markdown instead of one long unstyled `Text`. Headings (`#`..`####`), paragraphs, blockquotes, ordered/unordered lists, dividers (`---`), inline emphasis/code via `AttributedString(markdown:)`, and fenced ```code``` blocks all render properly — driven through the existing `MarkdownPreviewParser` + `MarkdownPreviewBlockView` pipeline that already powers the editor's Markdown side preview, so we don't carry two parsers. The block view's access modifier was lifted from `private` to internal so Agent-mode can call it from a different file.
- Wrapped the assistant body in a soft card (light `controlBackgroundColor` fill + faint border) so the boundary between one model turn and the next is obvious. User bubbles keep their right-aligned accent-color fill — the asymmetry is intentional. The `sparkles` role anchor stays on the left and now baselines with the card top.
- Streaming code blocks render mid-stream. The parser flushes any open code buffer at EOF, so a half-arrived ` ```tsx\nimport ... ` shows up as a real code block while the model is still typing it — no more "everything after an unmatched ``` is plain text". Same applies to a partially-streamed unordered list or quote — each line renders the moment it lands.

## 1.43.0-rc5 - 2026-06-02

- Fixed the Agent worktree-change card ("正在编辑 / N 个文件已更改") appearing in brand-new chats. The condition was just `!agentWorktreeChanges.isEmpty`, which surfaces any uncommitted change in the repo — so opening a New Chat inside a git workspace with unrelated dirty files showed a misleading banner (sometimes with thousands of files and SHA-like filenames). Now gated on a per-session `didEditFiles` flag that flips to true only after `applyAgentPatch` successfully writes at least one file. `AgentSession.didEditFiles` persists through session JSON (decoded with `decodeIfPresent` so older sessions keep loading), and `agentSessionDidEditFiles` on `AppState` mirrors it for the active session — reset on new-session / select-session / delete-session, restored on session restore. The card is suppressed in both Agent-mode transcript, Agent side-panel, and the editor status-bar pill.
- Added a right-click "New Chat in this Workspace" context menu on the Agent-mode sidebar workspace rows. Selecting it switches the current window's `rootDirectory` to that workspace (via the existing `openFolderURL` path, so FileTree / git / Quick Open / security scope all follow), then creates a fresh session grouped under it. The "No workspace" group keeps working too (creates a session with no root, no folder switch).

## 1.43.0-rc4 - 2026-06-02

- Added a proper GitHub-facing `README.md`. The repo was previously surfacing only `product-overview.md` (an internal capability matrix), which is dense and unfriendly to a first-time visitor. The new README leads with the "why", lists actual existing features (editor performance posture, file-tree-only-on-explicit-open, agent mode + BYOK + tools + diff proposals + auto-approval + context compression + queued sends, CLI, Quick Open cache, etc.), and includes a keyboard map, install/build instructions, philosophy, and contribution notes. Strictly documentation — no behavioral change.

## 1.43.0-rc3 - 2026-06-02

- Stopped auto-promoting an opened file's parent folder to `rootDirectory`. Previously every "open file" path (NSOpenPanel via Open File…, the system Open With… handler / `onOpenURL`, drag-onto-Dock, double-click in Finder, even Save As) called `setRootDirectory(url.deletingLastPathComponent())`, which loaded the FileTree, kicked off a recursive Quick Open scan, and ran `git status` on the parent. Opening a single file inside `~/Downloads` or some other huge directory could lock up the UI for seconds. Now the FileTree only loads when the user explicitly opens a folder (⇧⌘O Open Folder…, Open Recent Folder…, dropping a directory on the app, or restoring a session that already had one). Single-file edits are snappy and never trigger a directory scan.
- Save As (`writeCurrentFile`) no longer hijacks the workspace root either. If a folder was already open, it stays; if not, no sidebar appears just because you saved to a new location.
- Session restore is unchanged — a workspace that was opened explicitly in a previous session still comes back with its FileTree on launch.

## 1.43.0-rc2 - 2026-06-02

- Distinguished user and assistant messages visually in Agent mode. User messages now render as right-aligned bubbles with an accent fill and white text (capped at ~78% of the chat column so long pastes still wrap); assistant messages stay left-aligned without a bubble but gain a small accent `sparkles` glyph as a role anchor. Previously both roles drifted left and only differed by whether the bubble had a faint grey fill — easy to confuse when scrolling fast. Tool-call groups and queued/error rows are unchanged.

## 1.43.0-rc1 - 2026-06-02

- Added a Claude-Code-style stats dashboard to Agent mode's empty state. When there's at least one persisted session, the new-chat screen shows "What's up next, $USER?" plus an Overview / Models tab and an All / 30d / 7d range selector, with eight stat cells (Sessions / Messages / Tokens / Active days / Current streak / Longest streak / Peak hour / Favorite model), a GitHub-style 12-week × 7-day activity heatmap colored by message density, and a fun-fact line comparing token usage to War and Peace. Fresh installs without sessions keep the simple hero.
- Added `AgentUsageStats` (pure analytics over `[AgentSession]`) computing the overview snapshot and heatmap. Streaks are calendar-day runs; the current streak only counts when today is active; favorite model is the modelID with the most messages across all sessions.
- Started capturing real token usage. `AgentClient.streamChat` now sends `stream_options.include_usage: true` (OpenAI requires it, DashScope/DeepSeek ignore it harmlessly), decodes the final-chunk `usage` block, and emits a new `.usageReported(prompt:completion:total:)` event. AppState stamps the running assistant message's new `AgentMessage.usageTokens` field with the total. Older messages without it fall back to the chars/4 estimator, and the dashboard labels the cell "Tokens (est.)" until at least one real number lands.
- Codable bumped for `AgentMessage.usageTokens` with `decodeIfPresent`, so existing session JSON keeps loading cleanly.
- Added unit tests for usage-stats totals, current-streak with-and-without today, and heatmap shape.

## 1.42.0-rc1 - 2026-06-02

- Collapsed consecutive same-kind Agent tool calls into a single codex-style row in Agent mode. Three back-to-back `run_command` calls now render as "已运行 3 条命令"; four reads/searches/lists render as "已探索 4 个文件". Click the row to see the underlying calls; click an individual call for the full payload. `ask_user` tool calls and patch proposals always stay full-size because they require interaction.
- Added `AgentToolKind` (`runCommand`, `fileExploration`, `askUser`, `other`) plus `AgentToolCallGrouping.group(_:)` that walks the transcript's tool-call array and emits a flat `[AgentToolCallSegment]` — adjacent groupable calls of the same kind merge, everything else lands as a singleton segment. Headlines and SF Symbol icons are derived from the kind.
- Extended the existing `AgentToolCallGroup` view to accept an optional `headline` / `headlineIcon` so the codex-style "已运行/已探索" labels replace the generic "N tools" string. Status-derived icons (failed / running / asking) still win for visibility when the row is collapsed.
- Added unit tests for adjacency merging, splitting on kind change, ask_user staying standalone, and unknown-tool grouping.

## 1.41.0-rc3 - 2026-06-02

- Fixed Agent mode sidebar header colliding with the macOS traffic-light buttons. The window keeps `titlebarAppearsTransparent`, which floats close/minimize/zoom over the first ~28pt of sidebar content. The Agent sidebar now reserves that band as empty space and renders the "CHATS" header on the row below it.
- Removed the Automations and Customize placeholder rows from the Agent mode sidebar. They had no behavior since their introduction in v1.39.0-rc3 — pure visual filler matching the Cursor screenshot they were copied from. They'll come back when there's a real feature behind them.

## 1.41.0-rc2 - 2026-06-02

- Fixed HTTP 400 `The reasoning_content in the thinking mode must be passed back to the API` from DashScope thinking-mode models (qwen3, qwq, qwen3-coder, etc.). Streaming responses can carry both `delta.content` and `delta.reasoning_content`; the previous implementation discarded the latter, so the next turn's request body was missing it and the provider rejected the whole conversation. `AgentMessage` now carries an optional `reasoningContent`, `streamChat` emits a new `.reasoningDelta` event, `runAgentLoop` accumulates it into the active assistant message, and `encodeMessage` echoes the field back on assistant messages so multi-turn thinking-mode conversations work end to end. The reasoning trace isn't shown in the UI — it exists purely to keep DashScope happy — but it does round-trip through session JSON so reloaded chats can keep replying.

## 1.41.0-rc1 - 2026-06-02

- Added zero-friction auto-approval for safe Agent shell commands. A new `SafeCommand.classify` step runs before the per-call Allow/Deny prompt: commands whose every pipeline segment is in the built-in read-only allowlist (cat, head, tail, ls, find without -delete/-exec, git diff/log/status/show/branch/blame/etc., rg, grep, wc, file, stat, which, pwd, echo, sort, uniq, cut, awk, sed (read-only), md5, shasum, base64, …) run immediately with no prompt. Pipelines `|`, `&&`, `||`, `;` are tokenized respecting single/double quotes; any dangerous segment poisons the whole chain.
- Added an LLM-judge fallback for commands the static allowlist can't certify. When auto-approval is on and a `run_command` invocation is `.needsJudgment`, AppState issues a non-streaming single-shot completion ("YES or NO, is this command read-only/safe?") to the currently configured model with `max_tokens=4`, `temperature=0`. Only an explicit `YES` auto-approves; everything else falls back to the user gate.
- Added `Settings > Agent > Tool approval > Auto-approve safe commands` toggle (defaults to on). Turning it off restores the strict per-call Allow/Deny behavior for every write-tier command, while user-pinned "Always allow" signatures and the destructive `confirm` gate continue to work as before.
- Added approval-source badges to tool-call cards: `AUTO` (static allowlist), `AI OK` (LLM judge), `ALWAYS` (user-pinned signature). Cards approved by a Allow click stay unbadged so the audit trail distinguishes "Claude decided" from "you decided".
- Added `AgentToolApprovalSource` to `AgentToolCall` so the audit trail is part of the model, not the view.
- Added unit tests for the allowlist, pipeline composition, redirection rejection, and find -delete/-exec rejection.

## 1.40.0-rc25 - 2026-06-02

- Added a separate Agent Image Understanding provider configuration with its own provider, base URL, model, and Keychain API key so text-only main models can still accept pasted images through a vision-model description pass.
- When the active Agent provider is text-only, multiple attached images are described in one image-provider request and the generated notes are appended to the user message before the main model runs.

## 1.40.0-rc24 - 2026-06-02

- Marked DeepSeek as text-only for Agent image handling so attached images are omitted from provider requests instead of sending unsupported `image_url` parts that cause HTTP 400 responses.
- Updated the DeepSeek preset defaults to `deepseek-v4-flash` and `deepseek-v4-pro`, matching the current API model names while keeping existing saved settings compatible.

## 1.40.0-rc23 - 2026-06-02

- Added Flash/Pro/Auto Agent model routing so Settings can keep separate low-cost and stronger model slots instead of forcing a single global model.
- Routed context compression through the Flash model slot and updated Agent headers/model pickers to show the active route or per-session override.

## 1.40.0-rc22 - 2026-06-02

- Raised the Agent tool-call round guardrail from 24 to 64 rounds so longer multi-step project work can continue before pausing for loop protection.

## 1.40.0-rc21 - 2026-06-02

- Added a supplemental shell PATH for Agent `run_command`, covering common Homebrew and local binary directories so commands like `rg` work when the app is launched from the macOS GUI.
- Added regression coverage that verifies `run_command` exposes common user binary paths to its shell environment.

## 1.40.0-rc20 - 2026-06-02

- Suppressed Agent worktree change cards for modified entries that have no real diff or only `+0 -0` numstat output, preventing noisy "files changed" prompts when nothing actually changed.
- Added regression coverage for Agent worktree summary filtering while keeping real additions, deletions, renames, untracked files, and binary diffs visible.

## 1.40.0-rc19 - 2026-06-02

- Collapsed consecutive Agent tool calls into a compact expandable group in both the side panel and full Agent mode, reducing transcript height during multi-tool runs.
- Hid empty assistant "Using tools..." placeholder messages when a tool group already represents the same activity, while keeping approval and user-question tool calls automatically expanded.

## 1.40.0-rc18 - 2026-06-02

- Let Agent `run_command` risk checks resolve workspace-aware paths, so pure read-only chains such as `cd /path/to/workspace && git diff` and `git -C /path/to/workspace diff` run without approval.
- Kept read-only auto-allow conservative by rejecting `cd`, `git -C`, and file arguments that resolve outside the current workspace.

## 1.40.0-rc17 - 2026-06-02

- Reworked Agent context estimation to mirror the next provider request, including the system prompt, normalized message history, collapsed tool results, attached images, and tool schemas.
- Expanded model context-window detection for modern large-context model IDs such as `gpt-5.5` and `gpt-4.1`, with a safer 128k fallback for unknown OpenAI-compatible models.
- Added Codex skill tools (`list_skills`, `read_skill`) so Agent mode can discover installed skills and load a matching `SKILL.md` on demand.
- Added MCP tools (`list_mcp_servers`, `list_mcp_tools`, `call_mcp_tool`) backed by Codex MCP config, with sensitive environment values redacted and MCP tool calls kept behind approval.

## 1.40.0-rc16 - 2026-06-02

- Normalized Agent provider request history so orphan `tool` messages and incomplete assistant tool-call exchanges are dropped before sending, preventing OpenAI-compatible HTTP 400 errors.
- Added regression coverage for provider-ready Agent tool-call message ordering and incomplete tool exchanges.

## 1.40.0-rc15 - 2026-06-02

- Added an inline "正在思考" Agent transcript divider while the model request is waiting for the first assistant content or post-tool response.
- Hid empty assistant placeholder bubbles so thinking state appears as an intentional activity row instead of a blank message.

## 1.40.0-rc14 - 2026-06-02

- Added an inline Agent transcript divider while context compression is running, matching the centered status-line style used by coding agents.

## 1.40.0-rc13 - 2026-06-02

- Added an Agent worktree change summary that shows the currently changed file with added/deleted line counts and a clickable filename.
- Added a review action from the Agent change summary so users can ask the Agent to inspect current uncommitted changes directly.

## 1.40.0-rc12 - 2026-06-02

- Added expandable Agent provider error details showing the request method, URL, provider, model, input message summary, redacted request body, HTTP status, and response body.
- Redacted inline image data from debug request bodies so provider errors remain useful without dumping large base64 payloads.

## 1.40.0-rc11 - 2026-06-02

- Classified conservatively parsed read-only `run_command` chains as read risk, including safe `cd` prefixes followed by commands such as `git diff`, `ls`, `cat`, `rg`, or `grep`, so they can run without approval.
- Kept write-like, unsafe-directory, redirection, pipeline, command-substitution, and destructive shell commands behind approval or typed confirmation.

## 1.40.0-rc10 - 2026-06-02

- Show the full `run_command` text prominently on Agent approval and destructive-confirmation cards so users can review the exact command before allowing it.

## 1.40.0-rc9 - 2026-06-02

- Made Return submit the Agent-mode composer by default, matching chat-style input behavior.
- Kept multiline composition available with Shift-Return, Option-Return, or Control-Return, while Command-Return continues to submit.

## 1.40.0-rc8 - 2026-06-02

- Compacted Agent tool-call cards so completed and running tools render as a one-line execution row by default, reducing transcript height during multi-step work.
- Reduced expanded tool output height while keeping arguments, output, and errors available on demand.

## 1.40.0-rc7 - 2026-06-02

- Raised the Agent tool-call round guardrail from 6 to 24 rounds so normal multi-step project work does not stop after only a few tool batches.
- Reworded the tool-round guardrail message to explain that the Agent paused to avoid accidental loops and can be continued with another message.

## 1.40.0-rc6 - 2026-06-02

- Added an Agent-mode `Always Allow` action for approved `run_command` calls. Matching command families such as `git push` can now run automatically in future turns while dangerous commands still require confirmation.
- Added Tools settings management for Agent always-allowed command rules, including per-rule removal and clear-all controls.

## 1.40.0-rc5 - 2026-06-02

- Hardened Git status refresh against large repositories by draining `git` stdout while the process is running, capping captured output, disabling optional Git locks, and timing out stuck commands instead of blocking sidebar/status refresh.
- Added request and resource timeouts to the Agent HTTP client so model discovery and streaming chat fail cleanly when a provider connection stalls.

## 1.40.0-rc4 - 2026-06-02

- Fixed the Agent-mode composer "+" (Attach Image) button freezing the app again. `NSOpenPanel.begin { }` without a parent window has been racing the SwiftUI main run loop under macOS 26 + default-isolation=MainActor. Now the panel attaches as a sheet on the key window (`beginSheetModal(for:completionHandler:)`), with the bare `begin` form kept only as a fallback when no key window exists.
- Softened the Agent-mode visual hierarchy. The sidebar and status bar no longer paint a heavy `underPageBackgroundColor` grey band — both now sit on `windowBackgroundColor` and the sidebar gets a very light 2.5% label-color tint instead. Regions read as a single calm canvas separated by thin dividers, not three competing grey blocks.

## 1.40.0-rc3 - 2026-06-02

- Fixed the Agent Settings API Key (and Base URL / Model) field clearing while typing. The fields now use local `@State` buffers and only commit to `agentConfiguration` when the new Save button is pressed (⌘↩). Provider preset switches refresh the buffers automatically; external writes (like Fetch Models picking a default) only overwrite the buffer when it currently matches what was last saved, so in-flight typing is never clobbered.
- Extended the `ask_user` tool with optional `options: string[]` and `multi_select: boolean` parameters. When `options` is provided the card shows clickable choice buttons (single-select) or checkboxes + Confirm (multi-select); the free-form text input stays available as an escape hatch. Returned answer is the chosen option, comma-separated list (for multi-select), or the typed text if non-empty.
- Added `boolValue()` and `stringArrayValue()` helpers on `AgentJSONValue`, and a new `stringArray` JSON-schema parameter type that emits `{"type": "array", "items": {"type": "string"}}` to the provider.
- Fetched models from Settings now also flow into `agentKnownModelIDs`, so the Agent-mode model picker pill sees them immediately.
- Fixed a potential Agent `run_command` deadlock by draining stdout and stderr while the subprocess is still running, then enforcing timeout termination with a short SIGKILL fallback.
- Skipped common generated dependency/build directories during Agent file search and Quick Open scans so large projects do not spend time walking `node_modules`, `.git`, `DerivedData`, `dist`, and similar trees.
- Capped Quick Open cache candidate collection before sorting, preventing very large workspaces from monopolizing a background worker.
- Added regression tests for large command output draining, Quick Open dependency-directory skipping, and `ask_user` option metadata.

## 1.40.0-rc2 - 2026-06-02

- Made context compression automatic. `runAgentLoop`'s defer now calls a new `maybeAutoCompressContext()` that fires `compressAgentContext()` whenever the estimated context usage crosses 75% (and the conversation has more than 6 messages, and nothing else is in flight). The status bar continues to show only a `Compressing…` spinner — no popups, no extra prompt for the user.
- Made the queued-message pump wait for compression to finish. `consumeNextQueuedMessageIfNeeded` now also gates on `!isCompressingAgentContext`, and `runContextCompression`'s defer kicks the queue once compression resolves. This prevents a queued user message from racing an auto-compression that the same defer block just started.
- Added unit test `testShouldAutoCompressTriggersAt75Percent` covering the empty-conversation, low-usage, high-usage, in-flight-compression, and in-flight-turn branches of the new `shouldAutoCompressNow` predicate.

## 1.40.0-rc1 - 2026-06-02

- Added the `ask_user` tool so the Agent can pause mid-turn and ask the user a clarifying question instead of guessing. Surfaces a purple tool-call card with a question, an inline answer field, and Send / Skip buttons; the typed answer is fed back as the tool result and the turn resumes. Tracked through a new `.userInput` risk level and `.awaitingUserAnswer` status.
- Added context compression: a Compress button appears in the status bar once estimated usage crosses 50% (and the conversation has more than 6 messages). Clicking it streams a tight summary of the older transcript from the current model and replaces them with a single `[Earlier conversation summary]` assistant message; the most recent 4 messages stay verbatim. Tool calls whose owner message vanished are dropped from the rendered list.
- Auto-collapse old tool results: when the request payload is being built, every `tool` role message beyond the most recent 4 is replaced with a small `[tool result hidden — earlier turn, was N bytes; ask the user or re-run the tool if you need it again]` placeholder. The UI still shows the original content in the tool-call card.
- Updated the agent system prompt to instruct the model: when something is ambiguous or a required piece of information is missing, call `ask_user` with a single concrete question instead of guessing.
- Added unit tests for ask_user registration and old-tool-result collapsing.

## 1.39.0-rc3 - 2026-06-02

- Reworked the Agent mode visual language to track Cursor's layout: lighter window background using `windowBackgroundColor` / `underPageBackgroundColor` so it follows system appearance, narrower header that just shows the chat title and a copy/new-chat affordance, assistant messages rendered flush against the background (no bubble), user messages as compact left-aligned cards with capped width, and a refreshed composer card with attach icon + model picker pill on the lower-left and a circular send/stop button on the lower-right.
- Replaced the in-header context progress bar with a small bottom status bar showing git branch, workspace folder, and a circular context-usage ring with percentage and an estimate tooltip.
- Reworked the sessions sidebar with grouped workspaces, bold folder rows, and per-project "See more" expansion (5 rows by default). Active session is marked with a tinted row and accent dot; right-click still deletes.
- Added a queue badge in the composer that opens a Clear Queue action; queued messages render as a compact bordered orange row instead of a colored bubble.
- Centralized all Agent-mode spacing, font sizes, and colors in an `AgentDesign` enum to keep future visual passes one-file changes.

## 1.39.0-rc2 - 2026-06-02

- Fixed the "Attach Image" button freezing the whole app in Agent mode. `NSOpenPanel.runModal()` from a SwiftUI Button action was blocking the main run loop under the new MainActor-default isolation; switched to the async `panel.begin { ... }` form.

## 1.39.0-rc1 - 2026-06-02

- Added a dedicated Agent mode (View > Switch to Agent Mode, Cmd+Shift+A) with a project-grouped chat sidebar on the left and a wide chat pane on the right. The editor is hidden in this mode.
- Added persistent Agent chat sessions: each conversation lives as a JSON file under `~/Library/Application Support/VeilWriter/agent-sessions/`. Sessions are grouped by workspace folder in the sidebar with collapsible sections and right-click "Delete Chat".
- Added image attachments to the Agent composer: paste from clipboard, drag-and-drop, or pick via "Attach Image". Multiple images can be staged with removable thumbnails and are sent inline as OpenAI multimodal `image_url` parts.
- Added a per-session model picker (fed from previously fetched model IDs in Settings) so individual chats can use a different model than the global default.
- Added an estimated context-window indicator in the chat header (`≈ N left / window`) using a chars/4 token heuristic plus a flat per-image budget, with a model-aware fallback table covering OpenAI, Claude, DeepSeek, Qwen, and Kimi/Moonshot families.
- Added a message queue: sending while the agent is responding queues the new message as a dim "Queued" bubble that fires automatically when the current turn ends. Stop cancels just the current turn; Clear Queue drops pending messages.
- Added a Stop button that cancels the in-flight response and tool execution loop without dropping queued messages; the next queued message dispatches automatically.

## 1.38.0-rc1 - 2026-06-02

- Added a sixth Agent tool, `grep_files`, that searches the workspace using ICU/NSRegularExpression patterns and supports an optional `include` filename glob (`*.swift`, `*.{ts,tsx}`, etc.) and a `case_sensitive` flag. `search_files` keeps doing literal text matching for cases where regex is overkill.
- Fixed `testEditorSettingsChangeBumpsRenderAndHighlightRevisions` by letting the test drain the main run loop before asserting; AppState defers editor-settings side effects to the next main-loop turn (1.33.0-rc11) so the bumps were never visible in-line.
- Fixed `testFolderURLOpensInNewWindow` by moving its fixture out of the system temp directory, which `RecentItemsStore` deliberately filters out — the test was asserting that a path the store will never accept ends up in recent folders.
- Hardened the test suite against shared-state surprises: each test now wipes the AppState-owned `UserDefaults` keys on entry, and the suite is marked `@Suite(.serialized)` so the recent-folders defaults can't be raced by parallel test processes.
- Added unit tests covering `grep_files` happy path and invalid regex, run_command risk escalation for destructive shells, and workspace-escape rejection in `read_file`.

## 1.37.0-rc1 - 2026-06-02

- Added five built-in Agent tools: `search_files`, `read_file`, `list_directory`, `git_status`, and `run_command`. Filesystem access is sandboxed to the workspace root.
- Added OpenAI function-calling support to the Agent client: tool definitions are sent with each chat completion request, tool_call deltas are streamed and merged, and tool results are fed back to the model in a multi-turn loop (max 6 rounds).
- Added a tiered tool-permission model in the Agent panel: read tools auto-allow, `run_command` shows Allow/Deny buttons, and destructive shell commands (`rm -rf`, `git push --force`, `git reset --hard`, etc.) require typing `confirm` before running.
- Added a per-tool call card in the Agent panel showing the tool name, risk badge, argument summary, live status, and expandable arguments/output/error blocks.

## 1.36.0-rc1 - 2026-06-02

- Added tabbed Settings categories for typography, appearance, workspace, Agent, and tools.
- Added built-in Agent provider presets for OpenAI, DashScope, DeepSeek, Kimi, Moonshot, Claude, and custom OpenAI-compatible endpoints.
- Added Agent model discovery from provider `/models` endpoints, with fetched model IDs selectable in Settings.

## 1.35.0-rc1 - 2026-06-02

- Added Agent edit proposals: unified diff blocks in Agent replies are detected and shown as pending patch cards.
- Added accept/reject controls for Agent patch proposals, with workspace path checks before writing files.
- Added conservative unified-diff application for existing workspace files, updating open tabs and Git status after accepted patches.

## 1.34.0-rc1 - 2026-06-02

- Added a first-phase project Agent panel with OpenAI-compatible streaming chat, current-workspace context, active-file context, and selected-text context.
- Added Agent settings for base URL, model, and API key, storing the API key in Keychain.
- Added menu and command-palette actions for toggling the Agent panel.

## 1.33.0-rc13 - 2026-06-01

- Removed the manual file-tree collapse and restore icons, leaving the divider as a resize-only control.

## 1.33.0-rc12 - 2026-06-01

- Removed the collapsed file-tree rail from the main layout and replaced it with a compact floating restore button at the left edge of the editor.

## 1.33.0-rc11 - 2026-06-01

- Deferred editor settings persistence and editor refresh side effects to the next main-loop turn to avoid SwiftUI publishing changes during view updates.

## 1.33.0-rc10 - 2026-06-01

- Added editor background image fit controls for fill-and-crop, fit, stretch, center, and image size scaling.
- Limited custom background images to the editor/detail area so the file tree and collapsed file-tree rail stay on the native window background.

## 1.33.0-rc9 - 2026-06-01

- Added a leading tab-bar reserve when the editor reaches the window edge so the first tab title no longer overlaps the macOS window controls.

## 1.33.0-rc8 - 2026-06-01

- Added Settings controls for a custom window background image and image opacity.
- Added an optional glass editor background with material, glass strength, and editor surface opacity controls.

## 1.33.0-rc7 - 2026-06-01

- Added a draggable file-tree divider with collapse and expand controls.
- Added tab-title double-click editor maximization, hiding the file tree and inspector/minimap until the tab title is double-clicked again.

## 1.33.0-rc6 - 2026-06-01

- Removed the tinted icon tile from the no-folder empty workspace header so the folder icon no longer appears focused or selected.

## 1.33.0-rc5 - 2026-06-01

- Hid the full recent-files workspace when a folder tree is already open, replacing it with a focused no-file editor prompt.
- Stopped automatically restoring the previous folder and open tabs on window launch; recent files and folders remain available as explicit choices.

## 1.33.0-rc4 - 2026-06-01

- Moved recent files and folders into the centered empty workspace view and collapsed the sidebar when no folder is open.

## 1.33.0-rc3 - 2026-06-01

- Moved the no-folder empty state into the main editor area with a larger centered welcome layout and primary open actions, leaving the sidebar for recent files and folders only.

## 1.33.0-rc2 - 2026-06-01

- Restored the standard macOS close, minimize, and zoom window buttons while keeping the hidden-titlebar editor layout.

## 1.33.0-rc1 - 2026-06-01

- Added a File Tree line-height setting in Settings > Sidebar. The file tree now uses the configured row-height multiple directly, with a default of 1.25x.

## 1.32.0-rc18 - 2026-06-01

- Added left padding to the custom file tree content so root and child rows no longer sit flush against the rounded window edge.

## 1.32.0-rc17 - 2026-06-01

- Removed the vertical line tied to the line-number gutter. `LineNumberRulerView` now overrides `draw(_:)` so AppKit's default `NSRulerView` border/edge drawing is bypassed, and the gutter fills with the editor background color instead of a separate gutter color. Line numbers and fold controls remain visible without a distinct vertical gutter edge.

## 1.32.0-rc16 - 2026-06-01

- Removed the remaining sidebar edge hairline by replacing the file tree's system `.sidebar` `List` with a plain `ScrollView`/`LazyVStack`. The line was coming from the AppKit-backed sidebar list itself, not from the outer split view or titlebar chrome.

## 1.32.0-rc15 - 2026-06-01

- Replaced the main `NavigationSplitView` shell with a custom two-column `HStack` so SwiftUI no longer generates titlebar/sidebar tracking separator chrome. The right editor/detail column now ignores the top safe-area inset, letting the tab bar sit flush at the top of the window, while the left sidebar keeps its own named top padding for the traffic-light controls.

## 1.32.0-rc14 - 2026-06-01

- Fixed a crash introduced in rc13 by no longer removing `NSTrackingSeparatorToolbarItem` from the toolbar. AppKit owns KVO wiring for that private tracking separator item, and removing it can trigger an `NSInternalInconsistencyException`. The window toolbar is now hidden via SwiftUI's `.toolbar(.hidden, for: .windowToolbar)` so the sidebar toggle/tracking separator chrome is suppressed without mutating AppKit's private toolbar item list.

## 1.32.0-rc13 - 2026-06-01

- Tried to remove the remaining title-bar vertical separator by targeting SwiftUI/AppKit's sidebar tracking separator in the window toolbar/titlebar chrome. This approach was superseded in rc14 because directly removing `NSTrackingSeparatorToolbarItem` is unsafe.

## 1.32.0-rc12 - 2026-06-01

- Actually collapsed the title-bar row this time. rc11's AppKit-only approach (`titleVisibility = .hidden` + `.fullSizeContentView` poked onto the window) was being reset by SwiftUI's `WindowGroup`, so the "VeilWriter" strip stayed. Switched to the native SwiftUI modifier `.windowStyle(.hiddenTitleBar)` on both window groups, which SwiftUI honors and doesn't override.

## 1.32.0-rc11 - 2026-06-01

- Collapsed the empty title-bar row entirely (not just its text). `.fullSizeContentView` is now added to the window style mask so the content area — and the tab bar — extends up through the former title-bar height, sitting flush at the top of the window.
- Removed the vertical hairline NavigationSplitView draws between the sidebar and the editor. The underlying `NSSplitView` is reclassed to a `ClearDividerSplitView` whose `dividerColor` is `.clear`.

## 1.32.0-rc10 - 2026-06-01

- Removed the stray hairline that sat directly above line "1" across the gutter ruler. It was the default `NSScrollView` `.bezelBorder` peeking out along the editor's top edge; the scroll view's `borderType` is now set to `.noBorder`, so the gutter joins the tab bar above it cleanly.

## 1.32.0-rc9 - 2026-06-01

- Removed the standalone window title strip that showed the current file name (e.g. "AppState.swift") on its own row directly above the tab bar — it duplicated the active tab's label and wasted vertical space. The system title bar is now hidden (`titleVisibility = .hidden`) and made transparent (`titlebarAppearsTransparent = true`) via a `WindowChromeConfigurator`, so the tab bar tucks up under the traffic-light buttons.
- Removed the horizontal divider line under the tab bar (the `Divider()` overlay at the bottom of `EditorTabBar`), leaving the tab row visually cleaner and eliminating the stray separator that appeared to bleed upward.

## 1.32.0-rc8 - 2026-06-01

- Fixed line numbers from the gutter ruler bleeding into the tab bar above the editor (e.g. line "12" appearing inside the tab bar row, alongside the gutter's dark strip extending upward through the tab area). NSRulerView's drawing isn't automatically clipped to its bounds, so line-number labels whose Y position falls just above the ruler's top — which happens for the first visible row at certain scroll positions — leaked into the tab-bar area above. The ruler now explicitly clips drawing to its own bounds via `NSGraphicsContext.saveGraphicsState()` + `NSBezierPath(rect: bounds).addClip()`. Probed via on-screen geometry logs: ruler in window y=24..476, window content height=515, tab bar 39px — fix verified by side-by-side before/after screenshot.

## 1.32.0-rc7 - 2026-06-01

- Fixed a residual ~5-line scroll truncation when restoring a tab whose cursor sat near the viewport's bottom edge (e.g. cursor on line 928 with viewport's bottom being line 932 -> after switching away and back, bottom became 927, hiding the cursor). Restore previously laid out only from offset 0 to the saved top character, so AppKit clamped the new scroll origin against a content size that didn't yet include the content below — pulling the viewport up by a few lines. Restore now lays out the entire document before setting the scroll origin, so the document height is fully known and the viewport's bottom matches what was saved.

## 1.32.0-rc6 - 2026-06-01

- Fixed tab-switch scroll position drifting by ~one screenful upward on long files: scrolling to e.g. line 6600 in a tab, switching away and switching back used to land you on line ~6300. The restore path used `scrollRangeToVisible(saved top character)` which only guarantees the target is on screen — it would land at the bottom of the viewport, not the top. Now the saved top-of-viewport line is positioned at the top via `setBoundsOrigin` on the clip view, with layout ensured from offset 0 to the target character so the line fragment Y is exact (a fragment's Y depends on the heights of every fragment above it). Verified by instrumented measurement on an 8000-line file: scrolling to line 6596, switching tabs and back lands at actualLine=6596 (drift = 0 lines), vs ~-123 lines pre-fix.

## 1.32.0-rc5 - 2026-06-01

- Cut window re-activation lag on large files by ~66%, measured on a 348 KB file with structure inspector open: ~265 ms -> ~90 ms per re-activation. Found via main-thread sampling that two costs ran on every SwiftUI `updateNSView` (which re-fires on every window become-active):
  - `LineNumberRulerView.lineCount()` scanned the entire string to count newlines each call, and was invoked twice per update via `requiredThickness`. Now cached by string length, with an O(1) check that only recomputes when length changes.
  - The whole `applyAppearance` pass (font, theme, paragraph style, ruler retile) ran unconditionally, even when nothing changed. Now gated on `settingsChanged || langChanged || renderRevisionChanged`; the cheap `changedLineNumbers` update to the ruler still runs every time. The ruler also only calls `invalidateRuleThickness()` when the gutter's digit count would actually differ.

## 1.32.0-rc4 - 2026-06-01

- Fixed two regressions from the non-contiguous layout introduced in 1.32.0-rc2:
  - Clicking the Dock icon after switching to another app no longer takes several seconds to show the window. Non-contiguous (lazy) layout made AppKit re-layout on window re-activation and was the cause; it has been removed. The tab-switch speedup it was meant to provide actually came from not forcing a full-document layout pass on switch (the `preserveViewport`/`scrollRangeToVisible` changes), which remain in place.
  - Folding a scope on a file with ~1000+ lines was still slow. The layout-manager delegate calls `isFoldedGlyphRange` for every line fragment it lays out, and that recomputed every folded range from scratch each time (each an O(file) line scan) — O(folds × file) per layout pass. Folded character ranges are now cached and rebuilt only when the fold set or text changes.

## 1.32.0-rc3 - 2026-06-01

- Fixed the ~1 second delay when clicking a gutter fold control on a large file. Toggling a fold invalidated glyphs and layout for the *entire* document starting at offset 0; once non-contiguous layout was enabled (1.32.0-rc2), that forced TextKit to re-lay-out everything visible from the top. Folding only affects lines from the fold's start downward, so invalidation now begins at the earliest folded scope instead of the document start — content above the fold keeps its layout. Unfolding re-validates from the previously-folded start so reappearing content lays out correctly.

## 1.32.0-rc2 - 2026-06-01

- Further reduced tab-switch lag on large files. Instrumented measurement showed the model update was already trivial (2-7 ms) and the plain-text apply was 50-180 ms, but the editor's render commit took 300-1000 ms — dominated by TextKit laying out the whole document. Changes: (1) enabled non-contiguous (lazy) layout so only the visible glyphs are laid out instead of the entire file; (2) on a tab switch / fresh load, skip the viewport-anchor restore that forced a full-document `ensureLayout` (scroll is restored separately); (3) restore the tab's scroll position via `scrollRangeToVisible` on the saved top character (local layout only) instead of an absolute pixel offset that needed full layout; (4) count gutter lines over UTF-8 bytes instead of per-character NSString bridging. The inspector's structure-outline extraction and minimap line-split were also moved off the main thread (computed in a background task, only when shown) so the editor area appears immediately and the minimap/structure fill in just after.

## 1.32.0-rc1 - 2026-06-01

- Made switching between open tabs lighter: each tab now remembers its caret position and scroll offset, and switching back restores them instead of jumping to the top of the file. The position is captured live from the editor when switching away and restored after the incoming tab's content is in place (layout is forced first so the scroll offset isn't clamped against a not-yet-grown document height). Combined with the viewport highlighting from 1.31.0, switching to a large-file tab no longer re-highlights the whole document.

## 1.31.0-rc1 - 2026-06-01

- Added viewport-based syntax highlighting for large files. Files at or above ~100 KB now highlight only the visible range (expanded to line boundaries with an ~8 KB overscan margin) instead of running the regex over the whole document, and extend highlighting as you scroll (debounced). Highlight attributes are applied in place rather than swapping the whole text storage, so scroll position and layout are preserved. Smaller files keep the existing whole-file async highlight. Net effect: very large files open and scroll smoothly; the color pass for an off-screen region arrives a beat after it scrolls into view. Edits and Go to Symbol jumps re-highlight the visible range.

## 1.30.0-rc2 - 2026-06-01

- Fixed files taking many seconds to appear when opened (a large file could freeze the window for 10+ seconds). The editor ran a full-file syntax-highlight regex pass synchronously on the main thread *before* displaying any content — and then highlighted the same text again asynchronously, doing the heavy work twice. Now the file's plain text is shown instantly the moment it loads, and syntax highlighting is computed off the main thread and swapped in when ready. Opening a file is responsive immediately; the color pass arrives a beat later. Minimap, inspector outline, and scope-guide computations were already lazy/cached and are unaffected.

## 1.30.0-rc1 - 2026-06-01

- Added a cross-session disk cache for the Quick Open file list (Command+P). Previously the panel re-walked the entire project tree (FileManager enumerator, capped at 1500 files) synchronously on every keystroke, stalling on large projects. The file list is now scanned once into a cache under `~/Library/Caches/<bundle-id>/projects/<sha256-of-root-path>/filelist.json`, served instantly from cache when a project re-opens, and verified by a background scan that backfills any differences. Invalidation is layered and cheap (modification time + size per entry; no content hashing). The cache lives outside the project directory so it never pollutes the user's git tree, and keeps at most the 50 most-recently-used project caches. Quick Open keystrokes now filter an in-memory array instead of touching disk.

## 1.29.0-rc3 - 2026-06-01

- Improved Go to Symbol (Command+Shift+O) responsiveness on large files: the outline extraction (regex passes over the whole file) is now computed once when the panel opens and recomputed only when the file content or language actually changes, instead of on every body evaluation. Arrow-key navigation and typing in the query field no longer re-parse the entire file each interaction. Query filtering still happens live against the cached outline.

## 1.29.0-rc2 - 2026-06-01

- Fixed the Go to Symbol panel not scrolling the highlighted row into view when arrowing past the visible window: the list now anchors scrolling on the stable row index instead of the per-item UUID, which was regenerated on every body evaluation and never matched the rendered ids (so the scroll silently no-opped).

## 1.29.0-rc1 - 2026-06-01

- Added arrow-key navigation to the Go to Symbol panel (Command+Shift+O), matching the Command Palette: Up/Down move the selection, Return jumps to the highlighted symbol, the selected row is highlighted and scrolled into view, and hover selection is suppressed briefly after a keyboard move.

## 1.28.0-rc4 - 2026-06-01

- Fixed the editor viewport jumping after an edit (scrolling to the top, or drifting a few lines up) by anchoring on the character at the top of the viewport and re-pinning it after layout settles, instead of restoring a raw pixel scroll offset that gets clamped against the transiently-collapsed document height during a re-highlight.
- Fixed severe arrow-key cursor-movement lag by skipping the full-document glyph/layout invalidation on every caret move and clearing only the previously highlighted bracket ranges instead of sweeping the entire document's temporary attributes.
- Fixed scroll/edit sluggishness on large files by memoizing the fold-guide scope analysis (previously the line-number gutter re-parsed the whole document on every redraw) and computing visible line numbers incrementally instead of rescanning from the file start for each gutter row.

## 1.28.0-rc3 - 2026-05-31

- Fixed Escape closing behavior for Quick Open, Go to Line, and Go to Symbol floating panels so shortcut-opened navigation windows dismiss consistently.

## 1.28.0-rc2 - 2026-05-28

- Fixed folded editor ranges leaking across tab switches by clearing visual folds before programmatic tab text refreshes.

## 1.28.0-rc1 - 2026-05-28

- Added gutter folding controls for collapsible code scopes while disabling visible scope guide line rendering.

## 1.27.0-rc1 - 2026-05-28

- Added lightweight scope guide rendering for supported syntax-highlighted languages, including Ruby, Python, Java, brace-based languages, markup, and section-style formats.

## 1.26.0-rc1 - 2026-05-28

- Added an editor context menu for choosing automatic, plain text, or explicit syntax highlighting languages per tab.

## 1.25.0-rc2 - 2026-05-28

- Fixed New Window so Command-N prompts for a folder and opens the selected directory in the new window instead of restoring an already-open project.

## 1.25.0-rc1 - 2026-05-28

- Added a File menu New Tab command with Command-T for opening a fresh untitled editor tab.

## 1.24.0-rc4 - 2026-05-27

- Fixed folder opening from the app UI and external folder events so selected directories open in a new editor window instead of replacing the current window.

## 1.24.0-rc3 - 2026-05-27

- Fixed HTML outline extraction so unlabeled ul and ol list containers appear in the shallow structure outline.

## 1.24.0-rc2 - 2026-05-27

- Fixed a crash when HTML outline extraction reads id, class, title, or aria-label attributes with different quote styles.

## 1.24.0-rc1 - 2026-05-27

- Added HTML preview support beside the editor using the existing lightweight preview pane.
- Reworked HTML outline extraction to use shallow HTML node structure, including title, h1-h5, div, list, and semantic layout nodes.

## 1.23.0-rc6 - 2026-05-27

- Fixed Command-W in editor windows so it closes the active tab before falling back to the system window-close behavior when no tab is open.

## 1.23.0-rc5 - 2026-05-27

- Fixed Settings window keyboard handling so Option-W and Command-W close the Settings window when it is focused.

## 1.23.0-rc4 - 2026-05-27

- Added a sidebar image preview flow so double-clicking common raster image files shows them in the editor detail area instead of treating them as text.

## 1.23.0-rc3 - 2026-05-27

- Fixed sidebar folder Git markers flickering between untracked and deleted states by expanding untracked directories and aggregating child statuses deterministically.

## 1.23.0-rc2 - 2026-05-27

- Fixed command palette keyboard navigation flickering and snapping back to hovered bottom rows while scrolling the selected command into view.

## 1.23.0-rc1 - 2026-05-27

- Added SF Symbols-based file type icons with subtle colors for common source, web, config, media, archive, database, build, and project files in the sidebar tree.

## 1.22.0-rc2 - 2026-05-27

- Fixed editor appearance refreshes overwriting existing rich-text syntax highlight colors during SwiftUI updates.

## 1.22.0-rc1 - 2026-05-27

- Added Settings controls for sidebar file-tree text size, the default Inspector view, and Minimap/Structure ordering.
- Applied sidebar text-size changes immediately to file-tree rows.
- Preserved older saved editor settings while filling in new sidebar and inspector preference defaults.

## 1.21.0-rc2 - 2026-05-27

- Fixed Git status refresh running synchronously on the main thread and publishing changes during SwiftUI view updates.

## 1.21.0-rc1 - 2026-05-27

- Added lightweight Git integration with current branch display and sidebar file status markers.
- Added sidebar context actions for new files, new folders, Finder reveal, Terminal launch, and path copying.
- Added command palette fuzzy matching, keyword lookup, shortcut hints, and Terminal/path/Git refresh actions.

## 1.20.0-rc4 - 2026-05-27

- Added left and right breathing room around Recent Files and Recent Folders in the empty sidebar state.

## 1.20.0-rc3 - 2026-05-27

- Fixed editor theme and appearance changes from Settings not immediately refreshing the active editor.

## 1.20.0-rc2 - 2026-05-27

- Filtered temporary files and folders out of Recent Files and Recent Folders, including cleanup of previously saved temporary paths.

## 1.20.0-rc1 - 2026-05-27

- Disabled App Sandbox for the main VeilWriter app target to allow broader local filesystem access in non-App-Store builds.

## 1.19.0-rc2 - 2026-05-27

- Fixed command line tool installation by writing `veilwriter` to `~/.local/bin` without administrator authorization.
- Saved security-scoped access for restored project folders so the sidebar tree can reload after launching the app again.

## 1.19.0-rc1 - 2026-05-27

- Registered VeilWriter as an alternate Finder "Open With" app for text documents, source files, and folders.

## 1.18.0-rc1 - 2026-05-27

- Added keyboard selection to the command palette with Up/Down navigation, Return execution, and a highlighted selected row.

## 1.17.0-rc1 - 2026-05-27

- Added a Settings entry to install or update the `veilwriter` command line tool at `/usr/local/bin/veilwriter`.
- Added external file and folder open handling so the CLI can launch VeilWriter directly into a path.

## 1.16.0-rc5 - 2026-05-27

- Added a bundled macOS Help Book so VeilWriter Help opens from the system Help menu instead of showing the missing-help alert.

## 1.16.0-rc4 - 2026-05-27

- Kept the restored project root visually expanded in the sidebar so its file tree loads immediately on launch.

## 1.16.0-rc3 - 2026-05-27

- Fixed restored project folders not expanding and loading their file tree immediately on app launch.

## 1.16.0-rc2 - 2026-05-27

- Forced a dedicated syntax-highlight refresh after file loads and tab activation so shell and HTML files render highlighted immediately.

## 1.16.0-rc1 - 2026-05-27

- Added an editor line-height preference and applied it to the text view layout.
- Tightened sidebar file-tree rows for denser project browsing while preserving full-row click targets.
- Reworked Markdown preview into a richer block renderer for headings, paragraphs, quotes, lists, dividers, and fenced code blocks.

## 1.15.0-rc1 - 2026-05-27

- Added external file change detection with a status bar reload action.
- Added Focus Mode to hide editor chrome for a cleaner writing and reading surface.
- Added lightweight split editor support for viewing another text file beside the active editor.
- Added Markdown preview and an Open Containing Folder command.

## 1.14.0-rc1 - 2026-05-27

- Added optional save cleanup settings for trimming trailing whitespace and ensuring a final newline.
- Added status bar selection info for selected character and line counts.
- Added Duplicate Line, Move Line Up, and Move Line Down commands with keyboard shortcuts and command palette entries.

## 1.13.0-rc1 - 2026-05-27

- Added Command-Shift-O symbol jump for searching and navigating the active file outline.
- Added previous/next tab commands and Command-1 through Command-9 indexed tab activation.
- Added Command-Shift-T to reopen the most recently closed tab.

## 1.12.0-rc1 - 2026-05-27

- Added a Command-Shift-P command palette for fast editor actions.
- Added recent files and recent folders with quick access from the empty sidebar state.
- Added session restore for the last folder, open tabs, and active tab.
- Added a lightweight dirty gutter indicator for lines that differ from the saved file content.
- Added bracket pair highlighting around the cursor for parentheses, square brackets, and braces.

## 1.11.0-rc1 - 2026-05-27

- Added Quick Open with Command-P for fast file lookup inside the selected folder.
- Added Go to Line with Command-L, reusing editor line navigation.
- Added a compact status bar with modified state, cursor line/column, language, file size, and app version.
- Added lightweight indentation helpers for newline indentation, Tab indent, and Shift-Tab outdent.

## 1.10.0-rc1 - 2026-05-27

- Made the right inspector navigable: minimap rows and structure items now jump the current editor tab to the selected line.

## 1.9.0-rc5 - 2026-05-27

- Forced editor re-rendering after tab activation and closure so the remaining tab keeps syntax highlighting.

## 1.9.0-rc4 - 2026-05-27

- Changed the close-current-tab shortcut from Option-W to Option-Tab.

## 1.9.0-rc3 - 2026-05-27

- Added a narrow collapsed inspector rail so the right sidebar can be reopened after hiding it.

## 1.9.0-rc2 - 2026-05-27

- Fixed newly opened files briefly appearing unhighlighted by applying an immediate synchronous highlight before the background refresh.

## 1.9.0-rc1 - 2026-05-27

- Expanded bash/shell syntax highlighting for shebangs, variables, assignments, flags, command substitutions, functions, and common builtins.
- Added syntax highlighting and extension detection for YAML, TOML, XML, SQL, Dockerfile, Makefile, INI, env, Rust, C, C++, and C#.
- Added filename detection for common shell/config files such as `.bashrc`, `.zshrc`, `.env`, `Dockerfile`, and `Makefile`.

## 1.8.0-rc1 - 2026-05-27

- Added a right-side editor inspector with Minimap and Structure views.
- Added lightweight structure extraction for supported source and document languages.
- Added an Option-Command-I shortcut to show or hide the inspector.

## 1.7.0-rc1 - 2026-05-27

- Added find/replace scope selection for the current tab, all open tabs, or the selected folder.
- Added selected-folder tracking in the file tree for folder-scoped replace-all operations.
- Added independent per-window editor state so each window can own its own tab set.

## 1.6.0-rc1 - 2026-05-27

- Added an in-editor find and replace bar with match highlighting, next/previous navigation, replace current, and replace all.
- Added Command-F, Command-G, and Shift-Command-G commands for find workflows.
- Made editor theme/font changes discard stale highlight results so the visible editor re-renders with the latest settings.

## 1.5.0-rc1 - 2026-05-27

- Added an Option-W shortcut and File menu command for closing the current editor tab.

## 1.4.0-rc5 - 2026-05-27

- Tightened sidebar file-tree row height and made each file row a full-width button target.

## 1.4.0-rc4 - 2026-05-27

- Replaced the empty-sidebar icon buttons with a quieter custom style that avoids the default focus ring.

## 1.4.0-rc3 - 2026-05-27

- Fixed file-tree rows so the full row width responds to clicks, not just the filename text.

## 1.4.0-rc2 - 2026-05-27

- Fixed the empty editor area showing an insertion caret before any file is open.
- Added separate empty-sidebar actions for opening a file or opening a folder.

## 1.4.0-rc1 - 2026-05-27

- Added syntax highlighting support for Ruby, PHP, Java, and Go.
- Expanded extension detection for JavaScript, TypeScript, HTML, CSS, and JSON variants.
- Added regression coverage for requested language detection and keyword highlighting.

## 1.3.0-rc2 - 2026-05-27

- Fixed a launch/open-file crash risk by keeping `AppState` mutations on the main thread during background file loading.
- Made asynchronous file loading update the matching tab instead of whichever tab is active when the read completes.

## 1.3.0-rc1 - 2026-05-27

- Added multi-tab editing so multiple files can stay open at once.
- Preserved per-tab dirty state and content while switching between open files.
- Added tab close controls with unsaved-change confirmation.

## 1.2.0-rc1 - 2026-05-27

- Added File menu support for opening individual files.
- Replaced the default save menu group with working Save and Save As commands.
- Added Save As support for untitled or relocated files.

## 1.1.0-rc2 - 2026-05-27

- Renamed the app-facing product to VeilWriter.
- Imported the VeilWriter logo assets into the macOS AppIcon asset catalog.

## 1.1.0-rc1 - 2026-05-27

- Added editor appearance settings for font family, font size, color style, line numbers, and current-line focus highlighting.
- Added built-in color styles and wired syntax highlighting colors to the selected style.
- Added line numbers in the editor gutter with current-line emphasis.

## 1.0.0-rc2 - 2026-05-27

- Made the empty folder state clickable so it opens the directory picker directly.
- Reused the same folder-opening flow for the empty state and the menu command.

## 1.0.0-rc1 - 2026-05-27

- Improved file loading performance safeguards by enforcing the 1 MB default loading limit inside `AppState.loadFile`.
- Added a shared large-file confirmation helper so UI checks and core loading behavior stay aligned.
- Added c1 regression coverage for full asynchronous file loading under 500 ms and large-file rejection.
- Fixed existing compile blockers in editor highlighting and syntax range tracking.
