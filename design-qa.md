# Design QA：Agent 工具与统计信息间距

- source visual truth path: `/var/folders/np/rjc0y5w52x324x21pv6g33440000gp/T/codex-clipboard-dc47af6d-075b-4d9e-a585-eee5dda06447.png`
- implementation screenshot path: `/private/tmp/Xedit-activity-timeline-design-qa.png`
- viewport: 原始问题截图为 `1376 × 797 px`；生产组件测试画布为 `760 × 360 pt`，导出 `1520 × 720 px`（2× Retina）
- density normalization: 以生产组件的 2× Retina 输出检查字形、图标和垂直节奏；原始截图仅作为问题区域与相对间距基准，不做像素级字号对齐
- state: 浅色主题；正文后接实时工具调用信息，历史统计信息由 TextKit 定向测试覆盖

## Full-view comparison evidence

原图中正文与工具/统计信息之间留白接近一整行，连续两条灰色工具信息之间也有明显的额外空档。修正后的生产组件渲染中，正文到工具区使用正文基准字号的 `0.7×` 间距；实时工具行内部使用 `2 pt` 间距，并与正文使用同一字号和行高来源。

## Focused region comparison evidence

- 正文 → 工具/统计信息：`AgentChatHistoryRendererTests` 验证历史消息的自定义空白段高度等于 `baseFontSize × 0.7`，并验证气泡样式应用后该高度不会被覆盖。
- 实时工具区：`AgentSidebarListVisualMetricsTests` 直接渲染生产 `AgentLiveActivityTimeline`，截图显示工具信息与正文层级清晰且没有原图中的整行空档。
- 工具行内部：生产组件常量与测试共同锁定为 `2 pt`；折叠后的工具摘要保持正文同源字号和行高。

## Required fidelity surfaces

- Fonts and typography: 通过；正文、工具信息和统计信息使用同一 Agent 字体大小与行高设置，灰度和层级语义保持不变。
- Spacing and layout rhythm: 通过；正文到元信息为 `0.7×` 基准字号，工具行内部为 `2 pt`。
- Colors and visual tokens: 通过；沿用现有 Agent 前景色与次级文本色，没有引入新颜色。
- Image quality and asset fidelity: 通过；继续使用系统/现有工具图标，没有新增或替换位图资产。
- Copy and content: 通过；仅调整排版，不改变工具摘要、统计内容或本地化文案。

## Findings

没有遗留的 P0、P1 或 P2 问题。实现截图使用米纸主题，而问题截图是系统浅色背景；这是测试夹具的主题差异，不影响本轮字号、行高和相对间距判断。

## Comparison history

1. 首轮回归发现历史统计空白段的固定高度会被后续气泡段落样式覆盖，同时工具附件使测试的纯文本精确匹配失真。
2. 修复为在气泡样式应用后重放元信息空白段样式，并将工具前缀断言调整为只验证换行前缀。
3. 重新运行两套定向测试，共 78 项全部通过；修订后的生产组件截图未发现可操作的 P0/P1/P2 差异。

## Implementation checklist

- [x] 正文与工具/统计信息之间使用 `0.7×` 字号空白
- [x] 连续工具信息使用紧凑的 `2 pt` 行间距
- [x] 历史消息与实时消息共用 Agent 字号和行高设置
- [x] 定向渲染与排版回归测试通过

final result: passed
