# Design QA：会话内定时任务卡片

## Source truth

- 用户提供的 Codex 桌面截图：`/var/folders/np/rjc0y5w52x324x21pv6g33440000gp/T/codex-clipboard-69a7a7a4-52ad-42d3-9d9a-b4b7aaca70db.png`
- 聚焦参考卡片：`design-qa-evidence/scheduled-task-reference-card-1.234.0-rc8.png`
- 参考卡片逻辑密度画布：`design-qa-evidence/scheduled-task-reference-card-logical-density-1.234.0-rc8.png`
- 视觉基线：会话正文内展示中性的圆角任务卡，左侧为时钟图标，中间为任务名和频率，右侧提供明确的“打开”操作；侧边栏继续用时钟标识提示关联会话。

## Rendered implementation

- 真实 SwiftUI 卡片截图：`design-qa-evidence/scheduled-task-implementation-card-1.234.0-rc8.png`
- 同画布上下对照：`design-qa-evidence/scheduled-task-reference-vs-implementation-1.234.0-rc8.png`
- 实现视口：520 × 112 pt；原始截图为 1040 × 224 px（2x），验收图归一化为 520 × 112 px（1x）。
- 状态：浅色米纸皮肤、启用中的 30 分钟间隔任务、中文界面、可打开任务详情。

## Comparison coverage

### Full component

对照图上半部分为 Codex 参考卡，下半部分为生产 SwiftUI 实现。卡片本身就是本次完整目标区域，因此全组件与聚焦区域相同；用户原始整屏截图已先行检查，用于确认卡片在会话栏和侧边栏之间的关系。

### Primary interaction

“打开”按钮沿用 Xedit 的定时任务详情路径：写入对应任务 ID，切换至定时任务主页面，并清理冲突侧面板。自动化测试验证了完整状态转换。

## Surface review

- Typography：系统字体 13 pt 中等字重标题、12 pt 次级信息与按钮；层级和参考一致，长标题单行截断。
- Layout：卡片最小高度 64 pt、圆角 12 pt、图标底座 36 pt、最大宽度 460 pt；宽度会适配 Xedit 会话内容区，参考图中的较窄宽度不被硬编码。
- Colors：使用现有皮肤的 `panelFill`、`hoverFill`、`hairline` 与文本色；米纸色温是对 Xedit 设计系统的有意适配。
- Images/icons：使用现有 SF Symbols `clock` / `checkmark.circle`，没有自绘或占位图标。
- Copy/i18n：按钮、完成状态和频率均走本地化资源；中英文资源齐全，任务名称来自数据模型。

## Findings and iterations

1. 首轮实现的背景和描边先于外层高度约束，实际可见卡片略矮。Severity：P2。
2. 修复：先应用 64 pt 最小高度，再绘制背景与描边；重新截图后卡片 chrome 与目标一致。
3. 第二轮图标底座对比度偏低。Severity：P3。
4. 修复：改用皮肤的 hover fill，保持中性但让时钟入口更易扫描。
5. 最终对照未发现剩余 P0、P1 或 P2；卡片宽度和色温差异均是对 Xedit 现有布局与皮肤的有意适配。

## Verification

- `AgentSidebarListVisualMetricsTests`：19/19 通过，覆盖布局常量、生产 SwiftUI 截图和“打开”导航状态转换。
- `Localizable.xcstrings`：JSON 有效且 Xcode string catalog 编译通过。
- 版本一致性：前端、Go agent、帮助包和浏览器扩展统一为 `1.234.0-rc8`。
- 已知仓库门禁：既有 `XeditTests/XeditTests.swift` 为 3027 行，导致全局复杂度检查失败；本次改动文件未超过限制。

final result: passed
