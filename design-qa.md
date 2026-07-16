# 命令确认卡响应式布局 Design QA

- source visual truth: `/var/folders/np/rjc0y5w52x324x21pv6g33440000gp/T/codex-clipboard-cf3ca2fa-70bb-49e6-9e6a-ef90e201dedc.png` 与用户本轮按钮密度要求
- wide implementation: `/tmp/Xedit-confirmation-design-qa/command-confirmation-wide.png`
- narrow implementation: `/tmp/Xedit-confirmation-design-qa/command-confirmation-narrow.png`
- combined comparison: `/tmp/Xedit-confirmation-design-qa/command-confirmation-button-density-comparison.png`
- viewport: 宽屏卡片 `1040 pt @2x`；窄屏卡片 `620 pt @2x`
- state: macOS 浅色外观、Rice Paper 皮肤、长 `run_command`、等待用户确认
- final result: passed

**Full-View Comparison Evidence**

原始界面、上一轮实现与本轮宽窄屏实现已放入同一张对比图检查。宽屏从 `680 pt` 可用宽度起稳定切换为左侧命令审阅、右侧授权操作；窄屏回退为上下结构。两种布局均把“拒绝 / 允许”保持在同一行，拒绝在左、允许在右，并将按钮宽高收紧、间距扩大，原有标题、风险提示、工作目录、复制和命令说明入口完整保留。

**Focused Region Comparison Evidence**

- 命令视口固定为 `56 pt`，当前长命令可见约两行，超出内容仍可纵向滚动。
- 宽屏操作栏使用稳定的 `260 pt` 宽度；按钮按栏宽自适应，单个按钮最大宽度为 `124 pt`，没有被长命令的理想宽度挤压或迫使卡片错误回退。
- 窄屏按钮共享一行、居中排列，并同样限制为最大 `124 pt`，不再横向铺满操作区。
- 两个按钮的间距统一为 `24 pt`；标签使用 `12 pt` 半粗体，名义内容高度为 `28 pt`，控件尺寸为系统常规级别。
- 主操作继续使用强调色并位于右侧，拒绝使用次级样式；按钮文案来自现有 `L10n.ToolCard` 本地化资源。

**Required Fidelity Surfaces**

- Fonts and typography: 沿用现有原生 macOS 字体，将按钮标签收紧为 `12 pt` 半粗体，没有改变信息层级。
- Spacing and layout rhythm: 审阅区与操作区继续使用既有 `18 pt` 内边距和 `12 pt` 节奏；按钮之间单独使用更舒展的 `24 pt` 间距。
- Colors and visual tokens: 背景、边框、分隔线、正文、风险色与按钮强调色全部继续读取当前皮肤 palette。
- Image quality and asset fidelity: 本界面只使用 SF Symbols 与原生形状，没有新增或缩放位图素材。
- Copy and content: 保留现有 i18n 文案；“拒绝 / 允许”均从 `L10n.ToolCard` 获取。

**Primary Interactions Checked**

- `1040 pt` 宽屏左右双栏渲染：passed。
- `620 pt` 窄屏上下结构渲染：passed。
- 两种布局按钮顺序与同行关系：passed。
- 长命令两行视口、滚动能力与复制入口：passed。
- SwiftUI 双尺寸视觉快照测试：passed。

**Findings**

没有未解决的 P0、P1 或 P2 视觉问题。宽屏与窄屏按钮均明显小于上一轮，两个操作之间的留白也更清楚；按钮顺序、可读性和点击区域未出现回归。

**Comparison History**

- Before: 宽屏仍采用上下结构，允许与拒绝纵向堆叠，命令框与操作区共同占用较高垂直空间。
- Iteration 1: 使用自定义 SwiftUI `Layout` 按真实可用宽度切换结构，避免长命令的理想宽度干扰断点判断。
- Iteration 2: 将按钮名义高度收紧至 `28 pt`、最大宽度限制为 `124 pt`，并把宽窄布局的按钮间距统一扩大到 `24 pt`。
- Final pass: 重新编译并生成 `1040 pt`、`620 pt` 两张原生 SwiftUI 快照；合成对比后未发现需要继续修复的布局差异。Final result passed.

---

# 会话摘要卡与工作区 Dev Server Design QA

- source visual truth: `/Users/rocky/.codex/generated_images/019f6afc-10b2-7dd2-9da0-6f66a655ff3f/exec-075edf4f-5ae5-4c88-8bc6-4cb5c5e02d09.png`
- floating card screenshot: `/Users/rocky/Sites/Xedit/build/visual-qa/conversation-activity/floating-artifacts.png`
- gray border + dismiss screenshot: `/Users/rocky/Sites/Xedit/build/visual-qa/conversation-activity/floating-artifacts-gray-dismiss.png`
- artifact panel screenshot: `/Users/rocky/Sites/Xedit/build/visual-qa/conversation-activity/artifact-files-panel.png`
- media panel screenshot: `/Users/rocky/Sites/Xedit/build/visual-qa/conversation-activity/media-panel.png`
- combined comparison: `/Users/rocky/Sites/Xedit/build/visual-qa/conversation-activity/reference-vs-implementation.png`
- state: macOS 浅色外观；已有会话包含 50 个文件产物；当前会话无媒体任务；旧会话持久化值为已废弃的任务监控侧栏
- final result: passed

**Full-View Comparison Evidence**

概念图与生产 Debug App 已在同一张对比图中并排检查。生产界面沿用现有聊天字体、皮肤、窗口工具栏和 Composer，没有复制概念图里的示意壳层；核心关系保持一致：聊天区右上角只出现有内容的摘要卡，主聊天宽度不被常驻侧栏占用，点击摘要后才在右侧打开对应内容。

**Primary Interactions Checked**

- 新会话没有产物、媒体或 Dev Server 时不显示任何摘要卡：passed。
- 含 23 个文件产物的旧会话只显示一张紧凑产物卡，标题、数量和两个代表文件完整可读：passed。
- 点击产物卡打开“文件”侧栏，旧“任务监控”侧栏即使存在于历史持久化状态也不会复活：passed。
- 点击顶栏媒体入口打开整合后的“会话媒体”侧栏，筛选、批量菜单、编辑/蒙版/放大提示和空状态层级清晰：passed。
- 媒体完成逻辑不再自动抢开侧栏；当前会话卡只读取相同 runtime 的媒体任务：passed（单元测试与 Ruby 契约共同验证）。
- Dev Server URL 解析支持任务输出 URL 与命令端口回退；任务集合按 workspace root 聚合跨会话任务：passed（单元测试验证）。
- 产物、媒体与 Dev Server 卡片均使用系统自适应淡灰描边；选中态只增强灰色线宽与不透明度，不再使用强调色：passed。
- 关闭按钮视觉为 9pt `xmark`，实际命中区保持 `22×42 pt`，辅助功能名称为“关闭摘要”：passed。
- 点击关闭后产物卡立即隐藏，文件仍保留、会话仍继续运行；同一轮轮询不会让卡片反复出现，实质内容变化后可重新显示：passed（原生交互与单元测试共同验证）。

**Findings**

首轮原生截图发现从旧会话切换时，历史 `.backgroundTasks` 值仍可能短暂恢复旧任务监控侧栏。最终实现同时在状态变化、侧栏请求、渲染目的地和 Binding 四层归一化该 legacy case；重新编译并重启 Debug App 后复验通过。后续灰色描边与关闭按钮迭代在同一生产会话中复验，关闭按钮未挤压标题或副标题，命中区也未显得笨重。没有未解决的 P0、P1 或 P2 视觉问题。

---

# 实时工具组二次计数 Design QA

- source visual truth: `/var/folders/np/rjc0y5w52x324x21pv6g33440000gp/T/codex-clipboard-35b9803f-6287-4f3a-8d0d-f33ec08ddc2a.png`
- requested difference: 移除红框中的第二层“已运行 5 条命令”及图标，保留右侧具体命令摘要、执行状态和展开能力
- implementation screenshot: blocked（当前工作区已有的非本次 UI 改动仍阻止 App 完成构建）
- final result: blocked

**Implemented Fidelity Surfaces**

- 实时工具组标题不再渲染聚合命令数量和命令类型图标。
- 折叠与展开状态都直接展示最多三条具体工具摘要，更多内容继续显示 `+N more`。
- 待处理、运行中、失败、已拒绝、完成状态以及右侧折叠箭头保持原行为。

**Blocking Evidence**

- 生产 App 仍被工作区现有的 `ReleaseNotesWorkflow.swift:27` 等异步 preflight 调用缺少 `await` 的非本次编译错误中止，因此无法捕获修改后的同视口原生截图完成最终像素对照。

---

# 命令确认卡片 Design QA

- source visual truth: `/Users/rocky/.codex/generated_images/019f6a2b-64f1-7fb1-abbe-ed82f69a39a6/exec-11c783fa-f354-40c7-b3d6-8339173024c8.png`
- implementation screenshot: blocked（当前工作区已有的非本次 UI 改动导致 App 无法完成链接与启动）
- intended viewport: macOS 聊天内容区，宽屏为命令审阅 / 授权操作双栏，窄屏自动改为上下堆叠
- final result: blocked

**Implemented Fidelity Surfaces**

- 命令确认状态绕开工具组汇总标题与外层边框，只保留一层卡片边框。
- 左侧命令视口固定约 3 行高度，长命令纵向滚动；复制、工作目录、文件修改提示和命令说明仍可用。
- 右侧保留“允许执行 / 拒绝”两项真实操作，不展示未实现的 `⌘↩` 快捷键提示。
- 背景、正文、次级文字、分隔线、状态点及按钮强调色均读取当前 `interfaceSkin.palette`。

**Blocking Evidence**

- `AgentToolCallViews.swift` 已进入并通过本轮 Swift 编译步骤，随后完整构建被工作区现有的 `DBExploreWorkflow.swift:31` 缺少 `await` 等非本次文件错误中止。
- 因生产 App 无法完成构建，本轮不能捕获同一状态的原生实现截图，也不能按相同视口与参考图完成最终像素对照；解除现有编译错误后需补跑原生截图 QA。

---

# Composer 语义图标 Design QA

- source visual truth: `/var/folders/np/rjc0y5w52x324x21pv6g33440000gp/T/codex-clipboard-258521fc-983f-45ab-b64d-d7dff7a4b4a6.png`
- implementation screenshot: `/Users/rocky/Sites/Xedit/build/visual-qa/composer-semantic-icons-rc3/implementation.png`
- aligned implementation: `/Users/rocky/Sites/Xedit/build/visual-qa/composer-semantic-icons-rc3/implementation-aligned.png`
- combined comparison: `/Users/rocky/Sites/Xedit/build/visual-qa/composer-semantic-icons-rc3/comparison.png`
- comparison viewport: 参考图与生产图均对齐到 `631 x 174 @1x`；生产 Composer 从原生 Debug App 窗口裁切为 `631 x 147 @1x` 后仅补齐画布高度，没有拉伸界面内容
- state: macOS 浅色外观、空输入、DeepSeek 模型、普通模式、智能审批、执行器为“我们”
- final result: passed

**Full-View Comparison Evidence**

参考 Composer 与生产 `AgentModeComposerView` 已在同一张对比图中按相同宽度并排检查。本次有意差异是把模型入口原来的服务器/柜子图标替换为 `brain.head.profile`，并把顶部“我们”执行器入口的装饰图标替换为 `person.fill`；工作区、运行位置、分支、输入区、模式、审批、更多、语音和发送按钮仍保持原有层级与位置。

**Focused Region Comparison Evidence**

- 模型入口继续显示当前供应商与模型名，前置图标改为语义明确的大脑图标；没有改变按钮高度、文本截断或下拉箭头。
- 顶部“我们”继续位于上下文栏最右侧，前置 `person.fill` 清楚表达当前由本应用执行；窄窗口下文字与图标均完整可见。
- “智能审批”仍紧跟“普通”模式选择器，未被图标变更挤出或移位；更多、专家、机密、麦克风和发送入口保持可见。
- 原生辅助功能树确认“我们”菜单按钮的 SF Symbol ID 为 `person.fill`，模式按钮为 `bubble.left.and.bubble.right`，审批按钮为 `checkmark.shield`。

**Required Fidelity Surfaces**

- Fonts and typography: 沿用 Composer 现有原生 macOS 字体、字号和字重，没有新增或硬编码产品文案。
- Spacing and layout rhythm: 两处仅替换同尺寸 SF Symbols；顶部与底部控制的基线、间距和点击区域没有改变。
- Colors and visual tokens: 图标继续继承当前动态前景色与强调色，没有新增硬编码色值。
- Image quality and asset fidelity: 使用系统 `brain.head.profile` 与 `person.fill`，在 `@1x` 原生截图下边缘清晰，没有位图缩放或近似绘制。
- Copy and content: “我们”及其英文继续使用既有 i18n 资源；本次没有新增用户可见字符串。

**Primary Interactions Checked**

- 模型入口继续可点击并保留模型选择辅助功能说明：passed。
- 顶部执行器入口继续可点击并保留“我们 / Claude Code / Codex”选择语义：passed。
- 模式与审批入口顺序、可见性和辅助功能 ID：passed。
- Debug App 原生窗口在 `631 pt` Composer 宽度下截图并与参考图合成检查：passed。

**Findings**

没有未解决的 P0、P1 或 P2 视觉问题。两处新图标在原生浅色界面中清晰可辨，且没有引发布局回归。

**Comparison History**

- Iteration 1: 以 `605 pt` Composer 宽度捕获初版截图，确认图标生效，但与参考图 `631 pt` 宽度不完全一致。
- Final pass: 调整原生窗口，使生产 Composer 裁切宽度与参考图同为 `631 pt`；重新合成对比后，除用户指定的图标替换外未发现阻断级差异。Final result passed.

---

# Composer 执行器入口 Design QA

- source visual truth: `/var/folders/np/rjc0y5w52x324x21pv6g33440000gp/T/codex-clipboard-e930db3d-5745-4a5a-95c3-3684a3262afe.png`
- implementation screenshot: `/Users/rocky/Sites/Xedit/build/visual-qa/executor-picker-rc1/implementation-matched-full.png`
- focused implementation: `/Users/rocky/Sites/Xedit/build/visual-qa/executor-picker-rc1/implementation-composer.png`
- combined comparison: `/Users/rocky/Sites/Xedit/build/visual-qa/executor-picker-rc1/comparison.png`
- comparison viewport: 参考 Composer 裁切为 `606 x 156 @1x`，生产 Composer 裁切为 `605 x 148 @1x`；通过缩放原生窗口将输入区宽度匹配到约 600 pt 后再裁切
- state: macOS 浅色外观；参考图为 muchtoken / 本地处理 / detached，实现图为未选择工作区 / 本地处理 / 无分支；两者均为普通模式、空输入状态
- final result: passed

**Full-View Comparison Evidence**

参考图与生产 `AgentModeComposerView` 已按近似相同的 600 pt Composer 宽度并排合成。实现中的“我们”执行器胶囊位于工作区、运行位置和分支信息行的最右侧，正好落在参考图红框标记区域；输入区和底部常用控制保持原有层级，没有被新入口挤压或遮挡。

**Focused Region Comparison Evidence**

- 执行器胶囊与顶部上下文栏使用同一垂直基线，靠右固定且不会随左侧工作区信息横向滚动。
- 空工作区与窄窗口状态下，左侧上下文栏可压缩，执行器入口仍完整显示“我们”与图标，没有截字或越界。
- 底部“审批”紧跟普通、计划与目标模式选择器；“更多”帮助文本为“更多设置：插件、专家”，执行器不再在底部重复出现。审批菜单已实测展开“每次询问 / 智能审批 / Workspace 访问”三项。
- 原生辅助功能树确认菜单包含“我们 / Claude Code / Codex”三项，入口帮助文案说明本轮可在当前会话执行或委托给本机 CLI。

**Required Fidelity Surfaces**

- Fonts and typography: 继续使用 Composer 现有原生 macOS 胶囊字号、字重和 SF Symbols；“我们 / Us”及摘要全部走 `Localizable.xcstrings`。
- Spacing and layout rhythm: 顶部上下文栏维持原有 8 pt 控件间距，执行器胶囊通过独立尾部布局保持右对齐；输入提示和底部控制区未改变高度。
- Colors and visual tokens: 胶囊沿用当前界面皮肤的动态前景、控制填充和强调色，没有新增硬编码颜色。
- Image quality and asset fidelity: 仅使用现有 SF Symbols，没有新增位图或近似绘制素材。
- Copy and content: 中文显示“我们”，英文显示“Us”；Claude Code、Codex 名称与所有说明均由 i18n 资源提供。

**Primary Interactions Checked**

- 点击顶部执行器入口后显示“我们 / Claude Code / Codex”：passed。
- 窄窗口约 600 pt Composer 宽度下入口保持右对齐且完整可见：passed。
- 底部审批入口独立展示、菜单三项可正常展开，更多菜单只保留插件与专家：passed。
- 原生 Debug App 启动、布局和辅助功能标签检查：passed。

**Findings**

没有未解决的 P0、P1 或 P2 视觉问题。参考图中的目标位置已被稳定占用，入口不会和工作区、运行位置、分支信息或输入区发生重叠。

**Comparison History**

- Iteration 1: 全宽窗口截图确认入口已在顶部右侧，但 Composer 宽度大于参考图，不满足同视口对照。
- Iteration 2: 将原生窗口收窄，使生产 Composer 宽度从约 985 pt 调整到 602 pt，与参考裁切 606 pt 对齐；重新捕获并合成后未发现需继续修复的布局差异。Final result passed.
- Iteration 3: 审批入口从更多菜单移至模式选择器后，重新编译并在 `605 pt` Composer 视口捕获；审批、更多和顶部执行器均完整可见，审批三项菜单交互通过。Final result passed.

---

# 桌面宠物新增形象与情境动画 Design QA

- source visual truth: `/Users/rocky/Sites/Xedit/build/visual-qa/desktop-pet-rc1/source.png`、现有 `DesktopPet` / `DesktopPetLaptop` 生产素材及本次两套透明像素画原图
- implementation screenshot: `/Users/rocky/Sites/Xedit/build/visual-qa/desktop-pet-rc1/settings-implementation.png`
- animation screenshot: `/Users/rocky/Sites/Xedit/build/visual-qa/desktop-pet-rc1/animation-implementation.png`
- combined comparison: `/Users/rocky/Sites/Xedit/build/visual-qa/desktop-pet-rc1/comparison.png`
- viewport: 设置内容区 `806 x 848 pt @2x`；动画状态板 `580 x 260 pt @2x`；合并对比图将参考设置页、生产设置页、原始宠物/电脑素材与生产情境组合置于同一画布
- state: macOS 浅色外观、桌面宠物关闭、机器人小狐狸选中、24 个宠物形象全部可见；代码柴犬/月兔工程师处于输入状态，机器人小狐狸处于待机卖萌峰值
- final result: passed

**Full-View Comparison Evidence**

合并对比图把用户提供的设置页、生产 `DesktopPetSettingsPage`、原始宠物/电脑素材和生产 `DesktopPetSceneView` 放入同一张图检查。实现继续沿用六列卡片、现有圆角/描边/选中态和原生正文排版，并在第四行补齐代码柴犬与月兔工程师；24 个形象、底部说明和开关均完整可见。动画状态板显示电脑不再是两个闪烁方块，而是包含多行屏幕代码、完整键盘、转轴和机身的生产素材。

**Focused Region Comparison Evidence**

- 代码柴犬与月兔工程师的像素密度、描边粗细、青蓝/海军蓝配色、透明边缘和角色占比与现有机器人小狐狸保持一致；未发现洋红底残留、白边或透明蒙版锯齿。
- 两个新形象在卡片内采用与既有素材相同的 `.interpolation(.none)` 和适配规则，没有拉伸、裁头或越出卡片。
- 输入状态中宠物向左留出身体与手部，电脑向右前景偏移；屏幕代码和键盘保持清晰，同时宠物面部、耳朵和至少一侧肢体仍可辨认。
- 输入动画由左右敲击相位、身体前倾、横纵压缩、电脑轻晃、键盘回弹和青色辉光共同驱动；静态截图只记录其中两个确定性相位，相关数值变化另由单元测试覆盖。
- 待机卖萌峰值清楚显示歪头/上跳姿态以及系统 `heart.fill`、`sparkles` 情绪符号；普通待机时特效透明度为零，每约 11 秒出现一次，不会持续遮挡桌面。

**Required Fidelity Surfaces**

- Fonts and typography: 设置页继续使用原生 macOS 14 pt 正文与现有标题层级；动画本身没有新增硬编码产品文案，QA 标签复用现有本地化状态文案。
- Spacing and layout rhythm: 六列卡片间距、圆角和内容节奏保持不变；24 个形象正好形成四行。桌宠场景仍限制在 `140 x 148 pt`，电脑和情绪特效没有扩大窗口点击区域。
- Colors and visual tokens: 新角色沿用现有青蓝、海军蓝、暖橙像素画调色；动画辉光使用语义 cyan，爱心与闪光使用系统 palette，不改变应用主题色。
- Image quality and asset fidelity: 两套新素材为 `1254 x 1254` RGBA PNG；电脑使用生产 `DesktopPetLaptop` 位图而非代码近似绘制，屏幕代码、键盘、透明边缘和像素插值均清晰。
- Copy and content: “代码柴犬”“月兔工程师”及英文名称均进入 `Localizable.xcstrings` 与 `L10n+DesktopPet`；其余设置文案保持现有本地化资源。

**Primary Interactions Checked**

- 24 张宠物卡片枚举、资源名和选中行为：passed。
- 输入状态显示完整电脑、负向身体抬升和动态屏幕辉光：passed。
- 普通待机无情绪特效、卖萌时间窗出现爱心/闪光：passed。
- 生产设置页与三个确定性动画状态真实 SwiftUI 渲染：passed。
- 原生 macOS 组件无需浏览器；本轮不适用浏览器控制台检查。

**Findings**

没有未解决的 P0、P1 或 P2 视觉问题。新形象与既有像素画体系一致，电脑细节在桌宠实际尺寸下仍可读，宠物身体与面部没有被前景电脑完全遮住。

**Comparison History**

- Iteration 1: 首次动画渲染中电脑使用 `104 x 98 pt` 并居中，屏幕细节清晰，但遮住了大部分身体，敲击姿态不够直观。
- Fix: 电脑调整为 `96 x 90 pt` 并向右移动，输入状态下宠物向左偏移；保留完整屏幕/键盘细节的同时露出面部、身体和一侧手部。
- Final pass: 重新运行 13 个桌宠专项测试并生成设置页、动画状态板和合并对比图；后置证据未发现裁切、透明边缘、字体、间距、颜色、素材或文案层面的 P0/P1/P2 问题。

---

# 桌面宠物正文可读性 Design QA

- source visual truth: `/Users/rocky/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files/hi162cm_2fb4/temp/RWTemp/2026-07/865bf65ad8064b6e14cc2dae2e8c432d/71a02608c00235ccc704064e494bee7a.png`
- implementation screenshot: `/Users/rocky/Sites/Xedit/build/visual-qa/desktop-pet-rc13/implementation-rc13.png`
- combined comparison: `/Users/rocky/Sites/Xedit/build/visual-qa/desktop-pet-rc13/pet-settings-comparison-rc13.png`
- comparison viewport: 左右均为 `806 x 848 pt` 设置内容区；参考图从原始设置窗口裁取，实现图由生产 `DesktopPetSettingsPage` 在 `@2x` 下真实渲染
- state: macOS 浅色外观、桌面宠物关闭、机器人小狐狸选中、22 个宠物形象全部可见
- final result: passed

**Full-View Comparison Evidence**

参考页面与生产 SwiftUI 渲染结果已按相同逻辑视口并排合成。右侧实现保持原有双层“桌面宠物”标题、开关、六列卡片网格和底部说明结构；本次有意差异仅是把正文层级提升到普通正文尺度。全部 22 个形象仍在四行内完整展示，底部说明未被挤出可视区。

**Focused Region Comparison Evidence**

- “显示桌面宠物”“宠物形象”和底部说明统一使用 `14 pt` 正文尺度，分区标题使用同尺寸半粗体。
- 22 个宠物名称统一使用 `14 pt`；选中名称仅增加字重和强调色，不改变字号。
- 移除了原先会把长名称缩小到 `82%` 的 `minimumScaleFactor`，长名称稳定使用最多两行。
- 名称区域保留至少 `36 pt` 高度，“绿色林地智者风”“蓝色义体流浪者”等长名称均完整显示，没有截字、遮挡或压住卡片边框。
- 卡片仍保持六列自适应布局，形象图片未拉伸、未替换，选中勾选、边框和背景状态仍然清晰。

**Required Fidelity Surfaces**

- Fonts and typography: 所有宠物设置正文统一为原生 macOS `14 pt`；外层页面标题继续沿用现有 `title3` 层级。
- Spacing and layout rhythm: 卡片间距、圆角、图片预览高度与六列网格保持不变；增加的名称高度由现有卡片内容自然承载。
- Colors and visual tokens: 沿用系统动态主文字、次文字与强调色，没有新增硬编码主题色。
- Image quality and asset fidelity: 继续使用生产资源目录中的 22 个宠物位图，并保留像素画的 `.interpolation(.none)`。
- Copy and content: 开关、分区标题和说明继续使用现有 `L10n` 本地化资源；没有新增硬编码用户可见文案。

**Primary Interactions Checked**

- 桌面宠物开关绑定与点击行为：保留，passed。
- 22 张宠物卡片的选择行为、选中勾选和辅助功能标签：保留，passed。
- `14 pt` 字号与 `36 pt` 名称最小高度回归断言：passed。
- 生产页面同视口真实渲染测试：passed。

**Findings**

没有未解决的 P0、P1 或 P2 视觉问题。最终对比中所有宠物名称均达到普通正文可读性，长名称没有缩小或溢出，网格和交互状态完整保留。

**Comparison History**

- Iteration 1: 仅渲染表单组件时缺少设置页外层标题，且测试沿用了本机当前开关与宠物选择状态。
- Iteration 2: 视觉测试补齐生产设置页外层结构，并固定为与参考图一致的“关闭 + 机器人小狐狸选中”状态。
- Final pass: 参考图与实现图按同一 `806 x 848 pt` 视口合并检查；字体增大属于用户指定差异，其余结构、素材、状态和可见内容均无阻断级偏差。Final result passed.

---

# 自动化字号与侧边栏顶部精简 Design QA

- source visual truth: `/var/folders/np/rjc0y5w52x324x21pv6g33440000gp/T/codex-clipboard-db5d4577-4cbe-4e4d-bece-841f5db7a0ff.png`
- removal reference: `/var/folders/np/rjc0y5w52x324x21pv6g33440000gp/T/codex-clipboard-1ef60235-8602-442c-b7ba-8b13c79e177a.png`
- implementation screenshot: `/Users/rocky/Sites/Xedit/build/visual-qa/sidebar-rc12/implementation-rc12.png`
- combined comparison: `/Users/rocky/Sites/Xedit/build/visual-qa/sidebar-rc12/sidebar-comparison-rc12.png`
- comparison viewport: source `232 x 606 @1x`; implementation `228 x 606 @1x`，并使用相同的自动化任务与工作区内容
- state: macOS 浅色外观、米纸主题、三条自动化任务、展开的工作区列表
- final result: passed

**Full-View Comparison Evidence**

参考截图与生产 `AgentSessionsSidebar` 的真实 SwiftUI 渲染结果已合并到同一张对比图中检查。实现图保留原有“新聊天 → 自动化 → 工作区”信息层级，并完整删除截图 2 所示的“聊天 / some.im”顶部区域，因此首个有效导航项直接从“新聊天”开始。

**Focused Region Comparison Evidence**

- 自动化任务名、日程摘要、空状态与模板入口统一使用 `14 pt` 常规正文尺度，与工作区会话正文使用同一字号令牌。
- “自动化”分区标题继续使用现有分区标题令牌，避免把层级标题误做成正文。
- 三条任务的名称和日程摘要在窄侧边栏内保持清晰，不再出现参考图中明显偏小的 `10–12 pt` 混排。
- 顶部仅保留 macOS 交通灯安全区；“聊天”标题与 `some.im` 提供商状态条均不再进入侧边栏布局，也不会留下空白占位。
- 新聊天、添加自动化、运行状态、暂停状态、工作区入口和底部账号区域均保持原有交互能力。

**Required Fidelity Surfaces**

- Fonts and typography: 自动化正文统一为原生 macOS `14 pt` 常规字号；标题层级继续使用现有设计令牌。
- Spacing and layout rhythm: 删除顶部区域后，内容自然上移；新聊天、自动化和工作区之间的既有垂直节奏保持不变。
- Colors and visual tokens: 继续使用米纸主题的动态背景、主文字、次文字及状态色，没有引入硬编码色值。
- Image quality and asset fidelity: 图标继续使用原有 SF Symbols；没有位图替代或近似绘制。
- Copy and content: 生产文案继续来自现有本地化资源；视觉测试中的固定文案仅用于复现用户截图状态。

**Primary Interactions Checked**

- 自动化字号与会话正文令牌一致：passed。
- 顶部“聊天 / some.im”区域未参与生产布局：passed。
- 生产侧边栏同视口截图生成：passed。
- 三条自动化任务与工作区列表在窄侧边栏中正常排布：passed。

**Findings**

没有未解决的 P0、P1 或 P2 视觉问题。实现图清楚显示顶部冗余区域已删除，自动化任务名与日程摘要已提升为普通正文尺度。

**Comparison History**

- Iteration 1: 首次生产截图验证了顶部区域已删除、自动化字号已统一，但测试视口和任务数量与参考截图不完全一致。
- Iteration 2: 将生产截图调整为 `228 x 606` 同视口，并复现三条自动化任务与主要工作区内容；合并对比后未发现需继续修复的视觉问题。Final result passed.

---

# Agent 右侧栏焦点策略 Design QA

- source visual truth: `/var/folders/np/rjc0y5w52x324x21pv6g33440000gp/T/codex-clipboard-aa23578d-8caf-486b-946a-dd1e43fb58c1.png`
- implementation screenshot: `/Users/rocky/Sites/Xedit/build/visual-qa/side-panel-focus/implementation-rc11.png`
- viewport: source `330 x 159 @1x`; implementation `330 x 156 pt @2x`
- state: macOS 浅色外观、系统界面配色、本地终端“主机身份”浮层展开
- final result: passed

**Full-View Comparison Evidence**

原始截图与生产 `AgentHostVerificationPopover` 渲染结果已在同一次对照中打开检查。原图记录了“复制 hostname 命令”按钮被系统键盘焦点环包围的异常状态；修复后的生产组件保持相同标题、说明、分隔线及按钮层级，同时不再显示紫色焦点环。

**Focused Region Comparison Evidence**

- “复制 hostname 命令”仍保留中性描边、图标、文字和完整点击区域。
- 按钮及浮层根容器均退出键盘焦点链，展开浮层时不会抢走终端输入焦点。
- 右侧栏其他按钮、菜单、选择器、滑杆和开关统一应用相同策略；终端、地址栏、重命名及图片编辑输入框等真实文本输入区域继续可聚焦。
- 生产组件截图不包含 AppKit 浮层窗口的箭头和窗口阴影；本次变更只涉及内容区域的焦点环，因此以生产内容组件作为聚焦对照证据。

**Required Fidelity Surfaces**

- Fonts and typography: 沿用现有原生 macOS 字体、字号与字重，没有新增硬编码文案或字体。
- Spacing and layout rhythm: 标题、说明、分隔线与操作按钮的间距未因焦点策略调整而改变。
- Colors and visual tokens: 使用现有动态调色板与中性边框；移除的仅是系统焦点强调环。
- Image quality and asset fidelity: 继续使用原有 SF Symbols，不涉及外部图片素材或降质替换。
- Copy and content: 标题、主机校验说明及复制命令文案均保持不变。

**Primary Interactions Checked**

- 侧边栏交互控件焦点策略源码扫描：passed。
- 主机身份浮层复制操作不会自动聚焦：passed。
- 生产 SwiftUI 浮层渲染与截图生成：passed。

**Findings**

没有未解决的 P0、P1 或 P2 视觉问题。目标焦点环已移除，且没有牺牲侧边栏中的真实文本输入能力。

**Comparison History**

- Normalization pass: 首次 QA 截图误用了米纸主题，与原图的系统浅色主题不一致；这是验收环境差异，不是产品回归。最终截图已改为系统配色后重新生成。
- Final pass: 系统浅色截图中焦点环已消失，排版、边框与操作层级符合原图约束，无需追加视觉修复。

---

# Assistant Turn Grouping Design QA

- source visual truth: `/var/folders/np/rjc0y5w52x324x21pv6g33440000gp/T/codex-clipboard-0e6a3489-7f68-421f-b180-e3916752294c.png`
- implementation screenshot: `/Users/rocky/Sites/Xedit/build/visual-qa/assistant-turn-grouping/implementation-rc10.png`
- viewport: source `636 x 499 @1x`; implementation `636 x 499 pt @2x`
- state: light appearance; one completed user turn with two visible assistant outputs and one internal tool-only assistant message
- final result: passed

**Full-View Comparison Evidence**

The supplied screenshot and the production `AgentChatHistoryNSTextView` rendering were opened together in one comparison pass. The source documents the failure state: one logical user turn is fragmented by repeated processed headers, dividers, and token footers. The implementation normalizes the same interaction to a single user-turn shell while keeping both visible assistant text blocks readable in chronological order.

**Focused Region Comparison Evidence**

- The implementation contains exactly one `已处理 18s` label and one divider before the first assistant body.
- Both visible assistant outputs remain present, separated by normal prose rhythm rather than another status block.
- The footer appears exactly once after the final assistant body and reports the aggregated `49.6k/366` usage for all three provider calls.
- The internal tool-only assistant message contributes time and usage but does not leak an empty message, duplicate status, or duplicate footer into the transcript.
- The source and implementation use different fixture copy intentionally; the comparison target is the user-turn boundary and chrome frequency identified in the source, not verbatim content matching.

**Required Fidelity Surfaces**

- Fonts and typography: existing 14 pt native macOS body and medium-weight tertiary status typography are unchanged; intermediate and final output use the same readable hierarchy.
- Spacing and layout rhythm: one status/divider establishes the turn start, normal paragraph spacing connects intermediate output to the final answer, and one compact footer closes the turn. The repeated vertical chrome visible in the source is gone.
- Colors and visual tokens: existing dynamic label, tertiary label, subtle divider, user-bubble, and footer colors are preserved; no hard-coded light-only color was introduced.
- Image quality and asset fidelity: this transcript state contains no product imagery; copy, retry, and status affordances remain native SF Symbols rendered by the production component.
- Copy and content: all assistant prose remains visible and the copy action aggregates the full user-turn output. Existing localized status and duration strings are reused.

**Primary Interactions Checked**

- Completed multi-provider turn: one processed header and one aggregate footer, passed.
- Active multi-provider turn: one processing header and no premature footer, passed by renderer regression test.
- Footer copy payload: contains both visible assistant outputs in order, passed.
- Token and elapsed-time aggregation: includes the tool-loop provider call and wall-clock wait, passed.

**Findings**

No open P0, P1, or P2 visual findings. The structural density regression in the reference is removed without hiding intermediate AI prose or weakening the existing typography, color, and action hierarchy.

**Comparison History**

- Iteration 1: the first production-rendered comparison showed one completed status/divider, two assistant prose blocks, and one aggregated footer. No actionable P0/P1/P2 mismatch was found, so no additional visual fix iteration was required.

---

# Codex-Aligned Conversation Sidebar Design QA

- source visual truth: `/var/folders/np/rjc0y5w52x324x21pv6g33440000gp/T/codex-clipboard-95c83944-62b9-4d4e-b038-602861323993.png`
- implementation screenshot: `/tmp/willdeep-sidebar-rc9.png`
- normalized implementation: `/tmp/willdeep-sidebar-rc9-1x.png`
- combined comparison: `/tmp/sidebar-codex-vs-willdeep-rc9.png`
- comparison viewport: two `361 x 450 @1x` crops, source on the left and production SwiftUI rendering on the right
- state: light appearance; Codex workspace/session list versus WillDeep rice-paper skin with expanded workspace groups and one selected session
- final result: passed

**Full-View Comparison Evidence**

The supplied Codex screenshot and the actual `AgentSessionsSidebar` rendering were normalized to the same width and inspected in one side-by-side comparison. The implementation is rendered by `NSHostingView` with production workspace grouping, session rows, selection surface, SF Symbols, and rice-paper skin tokens; it is not a recreated mock.

**Focused Region Comparison Evidence**

- Reference text ink height is consistently `12–14 px`; the implementation is consistently `12–14 px` after the Retina capture is normalized to `@1x`.
- Reference row baselines repeat on a `31 px` cadence; the implementation uses a shared `31 pt` row token for workspace rows, sessions, archived disclosure, and “show more”.
- Workspace and session titles begin at `x = 40`: reference pixels were measured directly, while implementation geometry is `18 + 14 + 8 = 40 pt` for workspaces and `8 + 32 = 40 pt` for sessions.
- Selected rows use an inset rounded surface instead of a full-width accent strip. The implementation matches the reference with `8 pt` horizontal outer inset and `10 pt` continuous radius while taking its fill from the active interface skin.
- Workspace groups retain the reference's compact rhythm through a `6 pt` post-group gap; ordinary idle sessions no longer reserve a visible leading bullet or trailing timestamp.

**Required Fidelity Surfaces**

- Fonts and typography: 14 pt native macOS system font, regular weight for both workspace and conversation titles; secondary disclosure text continues through the current skin's secondary token.
- Spacing and layout rhythm: 31 pt rows, 40 pt shared title column, 6 pt group separation, 8 pt selection inset, and 10 pt selection radius are centralized in `AgentDesign`.
- Colors and visual tokens: title contrast uses each skin's `primaryText`; selected and hover surfaces use `selectionFill` and `hoverFill`, preserving all built-in light and dark skins instead of hard-coding Codex's light-gray pixels.
- Image quality and asset fidelity: workspace and status symbols use native SF Symbols at the measured size; no custom bitmap or placeholder icon was introduced.
- Copy and content: existing localized workspace, disclosure, hover, and context-menu strings are unchanged.

**Primary Interactions Checked**

- Workspace folder buttons still collapse and expand their groups: preserved by the production row implementation.
- Hover still reveals new-session, pin, and archive controls: preserved; selection and hover now share rounded semantic surfaces.
- Active, running, and approval-wait states remain observable per session: preserved by the existing isolated runtime observer, with the indicator moved to the trailing edge and hidden only for ordinary idle rows.
- Long titles still truncate with priority over badges and actions: preserved.

**Findings**

No open P0, P1, or P2 visual findings. The measured glyph height, title column, row cadence, and rounded selection geometry match the reference. Theme-dependent background hues intentionally remain skin-native; forcing the Codex gray would break the user's requirement that the layout work with WillDeep's built-in skins.

**Comparison History**

- Iteration 1: production used 12 pt session text, semibold 12 pt workspace text, 26 pt rows, permanent leading dots, trailing timestamps, and a full-width accent-tinted selection.
- Iteration 2: typography moved to 14 pt regular, row cadence to 31 pt, both title columns to 40 pt, and selection to an inset 10 pt semantic surface; status moved to the trailing edge and ordinary idle chrome disappeared.
- Iteration 3: the real SwiftUI capture was normalized and combined with the reference. Pixel-band inspection confirmed matching `12–14 px` glyph ink and `31 px` vertical cadence. Final result passed.

---

# Terminal Recording Toolbar Design QA

- selected visual direction: option 2, `/Users/rocky/.codex/generated_images/019f61dd-70dd-7610-a9f0-b0b2f8ebfde4/exec-fcaaab9a-a1ee-4a1f-a990-532a7c2842a0.png`
- implementation screenshot: `build/visual-qa/terminal-recording/implementation-rc7.png`
- viewport: source `2084 x 754`; implementation `1246 x 768`, terminal side panel approximately `480 pt` wide
- state: light app appearance, dark terminal scheme, two persisted recordings, inactive recording and playback
- final result: passed

**Full-View Comparison Evidence**

The selected option and the live Debug build were inspected together in one comparison pass. The implementation preserves the selected two-layer hierarchy: a dark recording-control strip followed by a light, flat recent-recordings list. The terminal tabs and terminal content remain visually separate below it, so the recording area no longer reads as a capsule inside another capsule.

**Focused Region Comparison Evidence**

- The record control uses a red semantic icon while its label uses a high-contrast terminal foreground color; the helper text remains readable but subordinate.
- “最近录制” is a stable section label rather than part of a recording chip.
- Each recording is one flat row with a circular play control, name, localized duration, input count, optional protected-input indicator, and trailing menu.
- Two rows fit without increasing the panel beyond the selected compact direction; additional rows use the bounded vertical scroller.
- The live `480 pt` side panel selects the wide single-line row variant. A narrower width falls back to the two-line metadata variant through `ViewThatFits`.

**Required Fidelity Surfaces**

- Fonts and typography: native macOS system typography is retained; hierarchy comes from weight and semantic foreground colors rather than red/green body text.
- Spacing and layout rhythm: the control row, section header, and two `42 pt` history rows form three distinct bands with single-pixel separators.
- Colors and visual tokens: red is limited to recording affordance; green/orange remain limited to small status icons. Terminal-scheme foreground colors prevent black-on-black labels.
- Image quality and asset fidelity: all controls use native SF Symbols and remain sharp at the captured scale; no bitmap placeholder is used in the implementation.
- Copy and content: start/stop labels, helper copy, section label, duration, input-count metadata, menus, and accessibility descriptions all use localized resources.

**Primary Interactions Checked**

- Open the terminal panel with two persisted recordings: passed in the ad-hoc-signed Debug build.
- Recording rows expose play controls and trailing action menus: passed through the live accessibility tree.
- Protected-input recording exposes its security indicator without turning the entire row into a status pill: passed.
- Narrow-width fallback is present in implementation and compiled; the live screenshot covers the standard side-panel width.

**Findings**

No open P0, P1, or P2 visual findings. The production Swift sources and string catalog compile successfully. The selected terminal tests also compile, but the local XCTest runner cannot launch because two installed Apple Development identities make the repository's signing phase ambiguous; this does not affect the live Debug visual result.

**Comparison History**

- Iteration 1: the previous production UI used dark text on a dark surface, colored whole labels red/green, and nested recording capsules.
- Iteration 2: option 2 established the two-layer structure and flat list-row language.
- Iteration 3: the live Debug build confirmed readable contrast, Chinese duration localization, two visible rows, native menus, and removal of nested cards. Final result passed.

---

# Assistant Status Divider Design QA

- source visual truth: `/var/folders/np/rjc0y5w52x324x21pv6g33440000gp/T/codex-clipboard-ae1c8da7-65a7-484e-b03b-44dc425db09b.png`
- implementation screenshot: `/tmp/willdeep-assistant-divider-rc6.png`
- combined comparison: `/tmp/willdeep-assistant-divider-comparison-rc6.png`
- viewport: source `797 x 102 @1x`; implementation `797 x 106 pt @2x`
- state: light appearance, completed assistant turn, 14 pt base font
- final result: passed

**Full-View Comparison Evidence**

The Codex reference and the actual WillDeep TextKit rendering were normalized to the same 797-point width and stacked in one comparison image. The status, divider, and first body line retain the same hierarchy and low-contrast rhythm. The implementation screenshot comes from `AgentChatHistoryNSTextView`, not a redrawn mock.

**Focused Region Comparison Evidence**

- Reference divider center: source row `43`; sampled center color `RGB(240, 240, 240)` / `#F0F0F0`.
- Implementation divider: physical rows `54-55` at `@2x`; sampled color on both rows `RGB(240, 240, 240)` / `#F0F0F0`.
- Reference status-ink bottom to divider center: `13 px`; implementation: `12.75 pt` after SF-font ink calibration.
- Reference divider center to body-ink top: `21 px`; implementation: `21.25 pt`. The remaining quarter-point is raster antialiasing, not a layout-token mismatch.
- Shared layout tokens are `9 pt` above, `18 pt` below, and `1 pt` line thickness; the same values drive SwiftUI streaming and TextKit history rendering.

**Required Fidelity Surfaces**

- Fonts and typography: existing 14 pt medium-weight SF status and 14 pt body typography are preserved; this change does not alter font, wrapping, or line height.
- Spacing and layout rhythm: measured visible-ink distances match the source within `0.25 pt`; horizontal alignment follows the existing assistant content column.
- Colors and visual tokens: the neutral overlay is calibrated to render exactly `#F0F0F0` on the white reference surface and reverses to a light neutral overlay in dark appearance.
- Image quality and asset fidelity: no image asset is part of this component; the source screenshot and actual native rendering were compared without placeholder reconstruction.
- Copy and content: the localized “处理中 / 已处理 Ns” behavior is unchanged; the QA state uses the same completed-duration meaning as the source.

**Findings**

No open P0, P1, or P2 visual findings. The implementation matches the requested line color exactly and matches the requested vertical distances within native text-rasterization tolerance.

**Comparison History**

- Iteration 1: the shared semantic label overlay rendered as `#F3F3F3`, and the 10 pt top token put the line about `0.75 pt` too far from the visible SF glyph edge.
- Fix: changed the neutral overlay to `7.5%` so AppKit / SwiftUI compositing resolves to `#F0F0F0`, and calibrated the top token to `9 pt`; the bottom token remains `18 pt`.
- Iteration 2: the combined reference/implementation image and direct pixel sampling confirmed exact line color, `12.75 pt` upper visible distance, and `21.25 pt` lower visible distance. Final result passed.

---

# Previous QA Record: Computer Use Preview

- source visual truth: `/Users/rocky/Desktop/截屏2026-07-13 11.38.55.png`
- implementation thumbnail: `build/visual-qa/computer-use/implementation-thumbnail.jpeg`
- implementation overlay: `build/visual-qa/computer-use/implementation-overlay-final.jpeg`
- combined comparison: `build/visual-qa/computer-use/comparison-overlay-final.png`
- viewport: source `2880 x 1800`; implementation `1155 x 768`
- final result: passed

**Full-View Comparison Evidence**

The reference and final implementation overlay were combined into one side-by-side image and inspected together. The compact preview stays at the Agent chat area's upper-right edge, uses the source screenshot rather than a placeholder, and preserves the full image aspect ratio. The expanded state dims the complete Agent window, keeps the screenshot centered with stable margins, and leaves a visible circular close control at the upper-right.

**Focused Region Comparison Evidence**

The upper-right thumbnail was checked in the live Debug app at `176 x 108` points. Its six-point radius, one-point border, restrained shadow, and 18-point outer inset follow the existing WillDeep surface language while retaining the Codex reference's compact placement. The expanded screenshot uses aspect-fit and remains fully visible without stretching or clipping.

**Findings**

No open P0, P1, or P2 visual findings.

**Primary Interactions Tested**

- Latest Computer Use screenshot appears only while the active turn is responding: passed by implementation and focused unit coverage.
- Thumbnail opens the full-window overlay: passed with live Computer Use control.
- Circular X closes and returns to the chat: passed with coordinate click.
- Escape closes and returns to the thumbnail: passed after focus handling was added.
- Clicking the dimmed backdrop closes the overlay: passed with coordinate click.

**Comparison History**

- Iteration 1: the unsigned Debug build could not use the signed app's Keychain session, so the real provider turn could not produce a screenshot.
- Iteration 2: a deterministic Debug-only fixture rendered the thumbnail and overlay; visual inspection found that Escape did not close because focus stayed in the composer.
- Iteration 3: overlay focus and aspect-fit were added; Escape passed, but the side-by-side comparison showed the dimmer covered only the chat column.
- Iteration 4: the presentation layer moved to the complete Agent window while retaining a chat-relative thumbnail inset. Full-window dimming, X, Escape, and backdrop close all passed. The fixture was then removed from production source.

---

# Design QA — Composer 模型选择器

- 日期：2026-07-15
- 设计源：`/Users/rocky/.codex/generated_images/019f649e-89c4-7df3-80be-9d715c940c84/exec-33165530-2290-407a-8edf-3a2382ae3f66.png`
- 实现截图（仅保留模型面板）：`artifacts/design-qa/model-picker-implementation-search.png`
- 视口：1196 × 768，macOS 浅色模式
- 验收状态：some.im 未登录；当前会话供应商为 DeepSeek；模型面板切换至 some.im 后搜索 `glm`

## 对照证据

- 全视图对照：`artifacts/design-qa/model-picker-full-comparison.png`
- 搜索状态聚焦对照：`artifacts/design-qa/model-picker-search-comparison.png`
- 搜索空状态：`artifacts/design-qa/model-picker-implementation-empty.png`

## 核对结果

- 结构：输入区保持轻量胶囊入口；完整面板包含搜索、场景入口、供应商导航、模型列表与固定说明栏。
- 交互：已实际验证打开面板、切换供应商、搜索 `glm`、无结果状态和清除搜索入口。
- 多供应商：搜索结果按供应商分组；当前验收环境仅配置 DeepSeek 与 some.im，因此不会伪造 OpenAI 或自定义供应商。
- 推荐与筛选：编程推荐、最近使用、Flash / Pro 筛选和完整目录均可从面板访问。
- 视觉：字体层级、8–12pt 主要间距、浅青选中态、分隔线、圆角和 SF Symbols 与设计源及应用现有视觉语言一致。
- 可访问性：模型入口、供应商、模型、关闭、清除搜索均暴露为可读按钮；搜索框可聚焦且有本地化占位文案。
- 文案：新增可见文案全部进入 String Catalog，包含简体中文与英文。

## 比较记录

1. 第一轮真机对照发现 P2：搜索结果虽能跨供应商查询，但列表是扁平结构，供应商归属主要依赖小标签。
2. 在 `Xedit/AgentComposerPickers.swift` 中改为按已配置供应商分组渲染，并重新编译、重启应用和复拍。
3. 第二轮对照确认分组标题、模型数量、行标签、搜索空状态和左侧供应商选中态均可见；未发现剩余 P0、P1 或 P2 问题。

final result: passed
