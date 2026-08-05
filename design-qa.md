# Design QA：会话级后台任务管理器

## Source truth

- 主布局与渐进展开：`/Users/rocky/.codex/generated_images/019fcfee-266d-7280-9f83-109a835e6d42/exec-3c659ba6-bebf-4ca8-ba96-cdb3a5a93263.png`
- stdout/stderr 双栏方向：`/Users/rocky/.codex/generated_images/019fcfee-266d-7280-9f83-109a835e6d42/exec-4cb18b5a-9a9c-49ea-9884-b4c954f7acc3.png`
- 交互基线：列表/时间线负责扫描，单任务在列表内渐进展开；宽侧栏默认双栏，窄侧栏退化为标签页。

## Rendered implementation

- 真实 SwiftUI 截图：`build/visual-qa/background-task-manager/implementation.png`
- 1x 归一化截图：`build/visual-qa/background-task-manager/implementation-1x.png`
- 同画布全量对照：`build/visual-qa/background-task-manager/comparison-full.png`
- 视口：626 × 1024 pt；原始实现截图：1252 × 2048 px（2x）；归一化实现截图与参考侧栏：626 × 1024 px（1x）。
- 状态：当前会话、全部状态、一个运行任务已展开、一个最近失败任务折叠、自动跟随开启、stdout/stderr 双栏。

## Comparison coverage

### Full viewport

`comparison-full.png` 在同一输入中左侧放置 626 × 1024 的主参考侧栏，右侧放置同视口同状态的真实实现。检查范围包括标题、会话与状态筛选、任务分组、运行态卡片、展开详情、日志区和最近完成任务。

### Focused interaction

双栏日志的方向以第二张参考图为准，并在全量对照右侧的展开态中验证：stdout 与 stderr 分属独立有界控制台，具备独立颜色、行数、复制操作与自动跟随。低于 520 pt 时改为纵向双栏或标签页，避免横向挤压。

## Surface review

- Typography：沿用 WillDeep 原生系统字体与等宽日志字体；层级、字重、行高均可辨识，无截断标题。
- Layout：筛选区、运行中/最近完成分组和详情均在 626 pt 侧栏内完整显示；无重叠、溢出或不可达控件。
- Colors：沿用现有皮肤的 panel/control/accent/hairline；运行、失败和 stderr 颜色语义明确，未引入新的品牌色。
- Images/icons：全部使用现有 SF Symbols，没有伪造图标或占位资产。
- Copy/i18n：所有面向用户的文本均来自 `L10n.AgentJobs` 和 `Localizable.xcstrings`，中英文资源齐全。

## Findings and iterations

1. 初始实现支持双栏，但宽侧栏首次打开默认落在标签页，偏离已选组合方案。Severity：P2。
2. 修复：当侧栏宽度不小于 520 pt 时默认选择 stdout/stderr 双栏；窄侧栏仍默认标签页，并保留用户手动切换能力。
3. 重新渲染同视口对照后，P2 已消除。未发现剩余 P0、P1 或 P2；原生系统控件与 ImageGen 概念稿在色温、按钮外观上的差异属于对既有 WillDeep 设计系统的有意适配。

## Verification

- `AgentBackgroundJobsTests`：38/38 通过，包含真实 SwiftUI 截图夹具。
- 相关侧栏、Composer、会话模型/Provider 与滚动策略测试：82/82 通过。
- 本地化资源可编译且 JSON 有效；版本一致性检查通过；`git diff --check` 通过。

final result: passed
