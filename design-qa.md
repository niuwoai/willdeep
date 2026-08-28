# Design QA — 插件中心图标与批准按钮

- 日期：2026-08-27
- 参考图：`/var/folders/np/rjc0y5w52x324x21pv6g33440000gp/T/codex-clipboard-946e39d1-c701-445c-b03f-f59dce640554.png`
- 验收构建：WillDeep `1.296.0-rc8`（Build 524，Debug）
- 实现截图：`/var/folders/np/rjc0y5w52x324x21pv6g33440000gp/T/com.openai.sky.CUAService/WillDeep Screenshot 2026-08-27 at 12.45.14 PM.jpeg`

## 对照结果

| 检查项 | 结果 | 说明 |
| --- | --- | --- |
| 插件原始图标 | 通过 | Chrome、Computer Use、Documents、Figma、GitHub、Gmail 等均展示插件包原始资源，不再被模板色染黑。 |
| 原生单色图标 | 通过 | Browser 等原资源本身为单色的插件保持原貌，不再显示为整块黑色。 |
| 缺省图标 | 通过 | 缺失或无法读取资源时使用由插件标识稳定选出的彩色底板与 SF Symbol，同一插件刷新后样式不变。 |
| 批准按钮层级 | 通过 | “批准并启用”改为浅色系统强调色底板、强调色文字和细描边，连续排列时不再形成黑色视觉墙。 |
| 主次操作关系 | 通过 | 顶部安装按钮继续使用深色主操作样式，与卡片内批准操作形成清晰层级。 |
| 布局与可读性 | 通过 | 图标、文本、开关、菜单与卡片间距未发生挤压、裁切或错位。 |

## 结论

final result: passed

---

# 子代理原位干预 Design QA

- 日期：2026-08-28
- 验收构建：WillDeep `1.302.0-rc1`（Build 544，Debug）
- 目标：变种 1；默认折叠，点击「干预子代理」后在原位展开紧凑输入，支持下轮生效和打断发送。

## Findings

- 最终对比未发现 P0、P1 或 P2 问题；默认态与展开态均无裁切、挤压、错位或不可读文字。
- 「你 · 刚刚」与上一条 Worker 发言之间保留 16 pt 顶部间距，视觉上明确属于用户纠正，不会被误读成下一轮子代理正文。
- 默认态不渲染输入框，只保留当前活动与「干预子代理」入口；展开后仍保持单行输入和两枚操作按钮，没有形成第二个大型 composer。
- 实现沿用现有 Worker 工种色、聊天字体与 SF Symbols，因此和真实聊天卡一致；参考图更偏中性白卡，实现保留了现有运维工种的浅橙底色，这是遵循产品既有设计系统的有意差异。
- 空输入时两枚发送按钮处于禁用态，参考稿里按钮保持高亮；实现按真实交互约束处理，避免发送空指令，不构成视觉或功能缺陷。

## Open Questions

- 无阻塞问题。

## Implementation Checklist

- [x] 默认不显示输入框。
- [x] 点击「干预子代理」原位展开，再次点击「收起」折叠。
- [x] 「下轮生效」等待当前步骤结束后注入用户原文。
- [x] 「打断并发送」只取消当前 Worker 子步骤，随后注入用户原文。
- [x] 「你 · 刚刚」回执带等待、打断、已送达状态，并插入对应轮次之前。
- [x] 回执上方额外留白符合用户明确要求。
- [x] 前台、后台与托管模型回退路径共用同一干预通道。
- [x] 英、西、法、日、简中五语资源齐全；输入与按钮有稳定无障碍标识。
- [x] 原生 SwiftUI 编译、协议测试、状态渲染测试通过。

## Evidence

- Source visual truth: `/Users/rocky/.codex/generated_images/01a04734-ea29-7ac1-b6d7-67f4aae1ca00/exec-9b979ac7-27ed-41ce-9b8a-ee207849c346.png`
- Implementation screenshot: `/Users/rocky/Sites/Xedit/design-qa-assets/subagent-intervention-implementation.png`
- Density-normalized implementation: `/Users/rocky/Sites/Xedit/design-qa-assets/subagent-intervention-implementation-normalized.png`
- Same-input comparison board: `/Users/rocky/Sites/Xedit/design-qa-assets/subagent-intervention-reference-vs-implementation.png`
- Viewport: 原生 SwiftUI 夹具 `1024 × 672 pt`，light appearance；2× backing scale 生成 `2048 × 1344 px`。
- Source pixels: `1548 × 1016 px`。
- Implementation pixels: 原始 `2048 × 1344 px`；仅按密度归一化为 `1548 × 1016 px`，宽高比一致，无拉伸失真。
- CSS size: 不适用；这是原生 macOS SwiftUI 界面。
- State: 同一张验收板包含默认折叠态与点击入口后的展开态；Worker 处于第 4/32 轮、已完成 3 次工具调用、正在运行命令，并显示一条已应用的用户纠正回执。
- Full-view evidence: 对比板将参考图置顶、实现图置底，二者同宽、同状态、同密度，可同时检查完整卡片、输入显隐、按钮层级与纵向节奏。
- Focused-region evidence: 目标组件已占满 1548 px 宽的对比板，文字、回执和输入条在完整视图中清晰可读，无需额外裁切。

## Required Fidelity Surfaces

- Fonts and typography: 使用现有 `AgentDesign.chatSupportingFont` 层级；工种名 semibold、模型/进度 secondary、轮次 monospaced；标题夹具仅用于状态标注，不进入产品 UI。
- Spacing and layout rhythm: Worker 卡内部 6–7 pt 节奏；用户回执顶部 16 pt；输入容器 8 pt 内边距；折叠态只增加一条  divider + 操作行。
- Colors and visual tokens: 运维工种继续使用稳定橙色 rail/tint；用户回执与干预入口使用系统 accent；打断按钮使用系统红色危险语义；没有新造主题色。
- Image quality and asset fidelity: 全部可见图标来自 SF Symbols，真实实现截图为 PNG；归一化仅做确定性缩放，源图与原始实现均保留。
- Copy and content: 所有产品文案来自 `Localizable.xcstrings` / `L10n.AgentDelegation`，没有在 SwiftUI 产品代码里硬编码；测试夹具文案只存在于验收测试。

## Comparison History

1. 第一版真实渲染使用 `1500 × 900 pt` 夹具，2× 截图直接压到参考宽度后文字密度过小，不能算同 viewport 对比。
2. 夹具改为与参考宽高比一致的 `1024 × 672 pt`，以 2× 渲染后按密度归一化为 `1548 × 1016 px`；文字与操作区密度接近目标。
3. 首次同密度实现板包含多余第 1 轮和两行说明，展开态底部输入条被画布裁掉；删除非目标轮次与验收说明、收紧夹具间距后重新渲染。
4. 最终同屏检查：默认态无输入，展开态输入/普通发送/打断发送完整可见；「你 · 刚刚」顶部留白、工种色 rail、状态回执和按钮语义均符合选定变种。

final result: passed

---

# 补丁审批黑白操作与正文对齐 Design QA

**Findings**

- 最终对比未发现仍需处理的 P0、P1 或 P2 问题。
- [P3] 用户参考图与测试夹具的正文内容、背景皮肤不同，因此本次只对需要修复的三个稳定表面做精确比较：按钮语义色、卡片左边缘、展开图标；不对背景色和文案换行做像素级匹配。

**Open Questions**

- 无阻塞问题。

**Implementation Checklist**

- [x] “拒绝”从系统蓝色按钮改为中性灰描边。
- [x] “应用”改为黑底白字主操作。
- [x] 展开箭头、批量操作条与所有补丁审批入口移除 accent 蓝。
- [x] 聊天区审批卡整体与助手正文左边缘对齐。
- [x] 紧凑侧栏继续使用原有无额外正文 inset 的布局。
- [x] 原生 SwiftUI 渲染截图和自动化契约测试通过。

**Follow-up Polish**

- 无必须跟进项。

## Evidence

- Source visual truth:
  - `/var/folders/np/rjc0y5w52x324x21pv6g33440000gp/T/codex-clipboard-935c87d1-31b4-472b-963a-759f928fe035.png`
  - `/var/folders/np/rjc0y5w52x324x21pv6g33440000gp/T/codex-clipboard-5bfcec2a-17e7-4498-bbee-e5509cda1169.png`
- Implementation screenshot:
  - `/tmp/Xedit-confirmation-design-qa/patch-approval-monochrome-aligned.png`
- Same-input comparison board:
  - `/tmp/Xedit-confirmation-design-qa/patch-approval-reference-vs-implementation.png`
- Viewport: 原生 SwiftUI 测试夹具 `760 × 168 pt`，轻色 Rice Paper 界面皮肤。
- Source pixels: 聚焦组件 `1013 × 237 px`；完整聊天问题图 `1136 × 1034 px`。
- Implementation pixels: 原始截图 `1520 × 336 px`；归一化对照 `1072 × 237 px`。
- CSS size: 不适用；这是原生 SwiftUI macOS 界面。
- Density normalization: 来源保持 `1013 × 237 px`；实现按比例缩放到 `1072 × 237 px`，未拉伸，使用 24 px 白色间隔横向拼接。
- State: 单个文件编辑补丁处于 Pending，diff 收起，拒绝与应用均可操作。
- Full-view evidence: 实现截图同时包含助手正文和完整审批卡，可检查卡片外边缘、正文列与操作区布局。
- Focused-region evidence: 同屏对照板聚焦按钮、图标和 Pending 卡片；无需进一步裁切，目标细节在 237 px 高度下清晰可读。

## Required Fidelity Surfaces

- Fonts and typography: 标题、Pending 状态及按钮沿用现有原生字体层级；按钮使用 12 pt medium，未因自定义样式改变文案权重或截断。
- Spacing and layout rhythm: 卡片与正文共同从 `assistantContentHeadIndent` 起排；按钮高度 26 pt、圆角 7 pt、间距 8 pt，单文件和批量入口一致。
- Colors and visual tokens: 主操作严格使用轻色模式黑底白字；次操作为透明底中性灰描边；卡片内未残留 accent 蓝、彩色批量背景或彩色展开图标。
- Image quality and asset fidelity: 界面只使用系统 SF Symbols 与原生矢量文字，不涉及新增位图资产；截图为原生渲染 PNG，无压缩模糊或拉伸。
- Copy and content: 所有产品文案继续来自既有 `L10n.AgentPatch` 资源，本次没有新增或硬编码用户可见字符串。

## Comparison History

1. 初始截图中“拒绝”“应用”和展开箭头继承系统蓝色；补丁卡整体从可读列左侧起排，与助手正文错列。
2. 单文件、同回合批量和全部待处理操作统一接入既有 `AgentApprovalSecondaryButtonStyle` / `AgentApprovalPrimaryButtonStyle`；批量容器和展开图标改为灰度。
3. 聊天中的 `AgentPatchProposalList` 增加助手正文同款水平 inset，侧栏调用不变。
4. 重新生成原生实现截图并与问题截图同屏检查：主操作为黑底白字、次操作无蓝色，卡片外边缘与正文左边缘重合。

final result: passed

---

# 子代理派工卡可读性 Design QA

- 日期：2026-08-28
- 验收构建：WillDeep `1.302.0-rc5`（Debug）
- 实现截图：`design-qa-assets/subagent-card-legibility.png`（由 `AgentSubagentInterventionTests` 的设计验收用例原生渲染）
- 起因：用户对着真实运行中的派工卡提出「不好看」，逐条拆出五个问题。

## 对照结果

| 检查项 | 结果 | 说明 |
| --- | --- | --- |
| 工具标签带宾语 | 通过 | 一列三个「运行命令」变成「运行命令 `ruby sync.rb`」「运行命令 `file -I .env.local`」「读取文件 `.env.local`」，判断要不要打断有了依据。 |
| 换行由宽度决定 | 通过 | 第 1–3 轮三个静默轮合并成一行流式排布，不再一轮一行；到边界才换行。 |
| 单一左边缘 | 通过 | 所有行共用固定宽度的轮次沟槽，带文字的轮不再把标签右推 18 pt。 |
| 底栏不重复 | 通过 | 「当前正在思考下一步」已移除，顶部状态行仍在，一张卡不再把同一句话说两遍。 |
| 标签配色 | 通过 | 标签底改为中性 6% 主色，工种色只留给左侧竖条与 Worker 名，不再是同色三层叠加。 |
| 干预图标 | 通过 | 魔法棒换成 `hand.raised`；魔法棒在业界指「让模型生成」，与「用户插话纠正」语义相反。 |

## Findings

- 合并行会把跨轮的工具串到一起，因此保留轮次区间标记（`第1–3轮`），否则轮次编号在静默段直接消失。
- 宾语统一截断到 34 字符：脱敏发生在截断之前，所以 `${secret:…}` 引用即使被截断也不会漏出它指向哪条凭据（`AgentSubagentCardLegibilityTests` 钉住这条顺序）。
- 合并行的标签数上限 12：六个静默轮各调八个工具会堆出 48 个标签，那正是合并想消掉的噪音。

## 结论

final result: passed


---

# 子代理发言 Markdown 与两行干预输入 Design QA

- 日期：2026-08-28
- 验收构建：WillDeep `1.302.0-rc6`（Debug）
- 实现截图：`design-qa-assets/subagent-card-markdown.png`

## 对照结果

| 检查项 | 结果 | 说明 |
| --- | --- | --- |
| 表格渲染 | 通过 | `| Step | Command |` 管道行排成 `│` 分栏并带 `─┼─` 表头分隔线，单元格里的行内代码保留浅底。 |
| 标记不外露 | 通过 | `**`、`##`、`- `、围栏 ``` 均被消化，不再作为字面量出现在卡片上。 |
| 块间距 | 通过 | 表格、围栏、引用、分隔线前后留空行，结论句不再贴着表格最后一行。 |
| 干预输入两行 | 通过 | 定高两行，溢出竖向滚动而非撑高卡片；占位文案在空态显示。 |
| 键盘路径 | 通过 | 回车换行、⌘↩ 按下轮生效发送，五语帮助文案同步。 |

## Findings

- 表头与正文的第二条分栏线存在约 7 pt 的水平漂移：列宽按「CJK 记 2 格」计算，而等宽字体里 CJK 字形的实际步进并不恰好是拉丁字符的两倍。这一条与聊天正文的表格同源、同行为，不是本次引入，也不单独在这里修——要修就得连聊天正文一起改。
- 600 字符限额会把长表格从中间切断，因此渲染器必须能排版残缺表格；`AgentSubagentSpeechMarkdownTests` 有一条专门钉这个场景。

## 结论

final result: passed
