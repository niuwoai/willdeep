# Worker 监控卡片设计验收

**证据**

- Source visual truth: `/Users/rocky/.codex/generated_images/01a048c6-0f5d-7312-b46b-f96f088e9069/exec-915961f1-4c4e-48e6-b71a-86072850a945.png`
- Implementation screenshot: `/Users/rocky/Sites/Xedit/build/agent-subagent-monitor-preview.png`
- Full-view comparison: `/Users/rocky/Sites/Xedit/build/agent-subagent-monitor-comparison.png`
- Source pixels: `2117 × 743`
- Implementation pixels: `2400 × 840`，由 `1200 × 420 pt` 原生 SwiftUI 组件以 `2×` 密度离屏渲染
- Density normalization: 两张图等比归一到 `1600 px` 宽后纵向合并；归一后高度分别约为 `562 px` 与 `560 px`
- CSS size: 不适用；这是 macOS 原生 SwiftUI 组件，不是 Web 页面
- State: 浅色模式、Worker 运行中、`15/18` 轮、`22` 次工具调用、详情收起

**Findings**

- 未发现仍需处理的 P0、P1 或 P2 问题。
- 字体与排版：身份、任务、当前阶段、指标和最近动作层级清楚；中文系统字体、字重和截断策略与 WillDeep 现有聊天排版一致。
- 间距与布局节奏：三列信息架构、两处分隔、底部最近动作区与参考图一致；实现略更紧凑，属于聊天记录中的有意密度约束，不影响层级或可读性。
- 颜色与视觉令牌：使用现有 Worker 工种紫色、系统背景色、分隔色与三级文本色；阶段轨道和运行状态点保持同一语义色。
- 图片与资产质量：本组件没有外部图片、Logo 或装饰素材；人物、文件和折叠图标均使用原生 SF Symbols，未使用占位图或手工 SVG。
- 文案与内容：Worker 名称、模型、任务、阶段、轮次、工具调用、运行时长、最近动作与运行详情均完整可见，且正式实现全部走 i18n。
- 可用性：阶段轨道提供可访问性标签；运行详情按钮可展开完整 Worker 历史；窄宽度会切换为纵向紧凑布局。

**Focused Region Comparison**

- 未另做局部裁切。归一后的全宽对照图中，三列标题、四段阶段轨道、三个指标及底部动作行均可清晰辨认，已足以判断字体、对齐、颜色和控件状态。

**Comparison History**

1. 初次离屏预览发现系统原生 `ProgressView` 在无窗口环境中渲染为黄色轨道并出现禁用标记，属于 P2 状态与颜色漂移。
2. 将其替换为生产组件内的确定性四节点阶段轨道，保留系统颜色令牌并明确当前节点、已完成段和未完成段。
3. 重新以相同 `1200 × 420 pt`、`2×`、浅色、运行中状态渲染；最新实现截图和合并对照图显示轨道已恢复为紫色，节点和标签对齐，无剩余 P0/P1/P2。

**Open Questions**

- 无阻塞问题。参考图的卡片纵向留白更宽；实现为适配真实聊天记录保留较紧凑密度，当前归类为可接受的产品约束。

**Implementation Checklist**

- [x] 三列 Worker 监控摘要
- [x] 四阶段确定性轨道
- [x] 轮次、工具调用与运行时长
- [x] 最近动作与可展开运行详情
- [x] 窄宽度回退布局
- [x] i18n 与辅助功能标识
- [x] 同状态、同主题、等宽归一视觉对照

**Follow-up Polish**

- [P3] 若后续聊天可读宽度进一步放宽，可把摘要区纵向内边距再增加 `2–4 pt`，让视觉节奏更接近概念稿。

final result: passed
