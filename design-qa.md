# Design QA：调度项目工作区后置选择

## Comparison target

- Source visual truth：用户提供的既有“定义这个项目”页面，`/var/folders/np/rjc0y5w52x324x21pv6g33440000gp/T/codex-clipboard-dc9de11c-0893-4502-bf38-e27206e89a10.png`（2194 × 1480 px）。
- Intended change：保留原页面的信息结构，改为先进入页面、再从页头选择工作目录；目录绑定前锁定项目定义区，绑定后允许填写与创建。
- Rendered implementation：`/tmp/Xedit-dispatch-goal-setup-design-qa.png`（2200 × 1400 px；生产 SwiftUI 组件，1100 × 700 pt，2× density）。
- Source/final comparison：`/private/tmp/Xedit-dispatch-setup-comparison.png`（2200 × 700 px）。左侧为用户截图，右侧为最终无工作区初始态。
- State：Rice Paper 浅色皮肤；Agent 正文 16 pt、1.6 倍行高；无工作区；默认 DeepSeek V4 Pro Planner；默认仅选择 DeepSeek V4 Flash Worker。

## Findings

- 页头右侧新增“选择项目工作区”按钮，初始入口清楚且不挤压标题；绑定后同一位置切换为“更改工作目录”。
- 无工作区时，工作区卡片保持可读并以橙色提示“请先选择工作区”；目标陈述、AI 检查、验收清单、Planner、执行环境和 Worker 统一降级并禁用，避免形成可以输入却无法创建的半成品状态。
- 主操作区保留右下角位置，新增 secondary“取消”按钮；“创建项目”在目录及必填内容未就绪时保持禁用。
- Planner 默认值明确显示为 DeepSeek V4 Pro Planner，Worker 默认仅勾选 DeepSeek V4 Flash Worker；信息层级、卡片节奏与原页面一致。
- 最终原生渲染和组合对照未发现新的 P0、P1、P2 问题。

## Required fidelity surfaces

- Fonts and typography：目标陈述、验收清单、AI 建议目标及诊断正文统一读取 Agent 窗口正文字体、字号和行高；标题与卡片标签继续沿用现有系统字体层级。
- Spacing and layout rhythm：继续使用左侧定义区、右侧配置卡片和底部操作条的原有布局；新增页头按钮与底部取消按钮均沿用现有 macOS 控件间距。
- Colors and visual tokens：沿用 Rice Paper 背景、现有卡片描边、禁用透明度和橙色警示色；未引入新的硬编码颜色。
- Image quality and asset fidelity：不新增位图资产；工作区、Planner、环境与 Worker 图标继续使用现有 SF Symbols。
- Copy and content：新增文案均进入中英文本地化资源；没有在 SwiftUI 视图中硬编码用户可见文本。

## Interaction and verification

- “新建调度项目”直接创建可持久化的无工作区草稿并打开定义页，不再提前弹出目录选择器。
- 选择目录后校验目录存在性及运行中项目冲突，成功后原地绑定、解锁页面并聚焦目标输入；失败时保留草稿与当前页面。
- 取消会删除尚未创建的临时草稿并留在调度台，不产生 Goal 或聊天消息。
- 一个 DeepSeek V4 Flash Worker Profile 可按 Provider 并发上限同时执行多个就绪节点；额外 Worker Profile 仅扩展模型池与故障转移顺序。
- `AgentDispatchCoordinatorTests` 62/62 通过，覆盖草稿创建、目录绑定、取消、默认路由、单 Profile 多节点并行和本页生产组件渲染。
- `git diff --check`、版本一致性、复杂度与本地化资源校验作为最终交付门禁执行。

## Open questions

- 无。并行度继续由 Provider 并发设置统一控制，无需让用户为了并行重复添加同一个 Worker Profile。

## Implementation checklist

- [x] 新建项目直接进入定义页，并在页头提供目录选择/更改入口。
- [x] 目录绑定前禁用填写和配置，绑定后原地解锁。
- [x] 默认 DeepSeek V4 Pro Planner 与单个 DeepSeek V4 Flash Worker。
- [x] 支持同一 Worker Profile 多节点并行和用户补选 Worker。
- [x] AI 草稿与验收正文继承 Agent 正文字体、字号和行高。
- [x] 主按钮旁增加 secondary“取消”按钮。
- [x] 同步版本号、CHANGELOG、产品概览、自动化测试与视觉 QA。

## Follow-up polish

- 无阻塞性 P3 项。

final result: passed
