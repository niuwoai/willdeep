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
