# Design QA：Profile、主按钮与会话侧栏

## Comparison target

- Source visual truth：用户提供的三张现状截图。
  - Profile 管理：`/Users/rocky/.codex/attachments/2638ac68-b1d5-45f3-9857-248441b76217/image-1.png`（1507 × 1060）。
  - Goal 任务页：`/Users/rocky/.codex/attachments/2638ac68-b1d5-45f3-9857-248441b76217/image-2.png`（2400 × 1587）。
  - 会话侧栏：`/Users/rocky/.codex/attachments/2638ac68-b1d5-45f3-9857-248441b76217/image-3.png`（465 × 1520）。
- Desired changes：Profile 先选 Provider 再选模型；内置 Profile 也可修改；默认规划模型改为 GPT-5.6 Sol；主操作按钮统一黑底白字；左侧会话列表可从当前 230 pt 起向右拖宽，并复用右侧栏的拖拽反馈，拖拽不得让聊天正文滚动到顶部。
- Rendered implementation：`/private/tmp/Xedit-profile-manager-design-qa.png`（1520 × 1040，原生 SwiftUI 以 2× 比例渲染，对应 760 × 520 pt）。
- Combined comparison：`/private/tmp/Xedit-profile-manager-comparison.png`。左侧为用户截图中的旧 Profile，右侧为本次原生渲染结果。
- State：macOS 浅色模式；Profile 管理器选中内置 `GPT-5.6 Sol Worker`；Provider 为 `some.im`；模型为 `gpt-5.6-sol`。

## Findings and comparison history

- 第一轮发现 `[P1]`：内置 Profile 的表单整体禁用，模型只能以文本字段出现，用户无法按 Provider → Model 的顺序选择；默认规划模型仍为价格较高的 Kimi K3。
- 修复：允许内置 Profile 覆盖 Provider 与模型；Provider 列表来自现有 Provider Library，模型列表按选中的 Provider 隔离并去重；默认规划 Profile 改为 GPT-5.6 Sol，同时保留 Kimi K3 供手动选择。
- 第一轮发现 `[P2]`：Profile 的“好”以及 Goal 流程内的启动执行、添加节点、启动任务等主按钮继续使用系统蓝强调色，与用户要求的黑底白字不符。
- 修复：Goal Dispatch 范围内所有非破坏性的 `borderedProminent` 主操作统一使用黑色 tint；停止任务等破坏性按钮继续保留红色语义。
- 第一轮发现 `[P1]`：左侧会话列表固定为 230 pt，没有可发现的拖拽边界；直接按实时宽度重排聊天列会使长会话阅读锚点不稳定。
- 修复：新增 230...520 pt 的可拖拽宽度，230 pt 同时作为不可突破的最小宽度；命中宽度、1 pt 分隔线、悬停与拖拽时的强调色反馈均与右侧面板一致。拖拽期间聊天列锁定在已提交宽度，松手后关闭动画并只重排一次，由既有 transcript scroll observer 保持阅读锚点。
- 第二轮原生渲染显示：内置 Profile 现已按 Provider、模型的顺序显示选择器，默认选中 GPT-5.6 Sol；“好”为黑底白字。代码与交互契约检查未发现新的 P0、P1、P2 问题。

## Required fidelity surfaces

- Fonts and typography：保留原生 macOS Form、Picker、列表与系统字体层级，不引入自定义字体或新的字号体系。
- Spacing and layout rhythm：Profile 详情仍使用原分组表单节奏，仅把两项字段调整为 Provider 在前、模型在后；会话侧栏只增加与右侧栏等宽的边界命中区。
- Colors and visual tokens：非破坏性主按钮使用黑色强调和白色前景；拖拽边界继续使用现有 accent color；危险操作保留红色。
- Image quality and asset fidelity：本次没有新增位图或图标资产；继续使用现有 SF Symbols 与原生控件。
- Copy and content：复用现有 i18n 文案键，不新增硬编码用户可见文本；“好”等既有本地化文案保持不变，仅调整视觉语义。

## Interaction and verification

- Profile 原生渲染测试验证内置 GPT-5.6 Sol Profile、Provider 选择器、模型选择器与黑色确认按钮能共同渲染。
- Profile Store 测试验证内置 Profile 的 Provider/模型覆盖可持久化，且 Provider 模型目录不会串到其他 Provider。
- 会话侧栏尺寸契约测试验证最小宽度为 230 pt，并复用右侧面板的 12 pt 命中区与 1 pt 分隔线。
- 拖拽实现沿用现有 transcript scroll observer，并在拖拽期间冻结聊天列宽度，避免逐帧重排造成正文位置跳顶。
- 定向 XCTest 55/55 通过；追加原生 Profile 渲染验收后，`AgentDispatchCoordinatorTests` 52/52 通过。
- Go 回归 `go test ./...` 通过。
- 版本一致性检查通过：`1.248.0-rc1`；主应用构建号 359，Help 与 Computer Use Helper 构建号 275。
- 任务相关源码的复杂度守卫通过：本次变更文件均低于 3000 行；`git diff --check` 通过。仓库全量扫描仍报告一个未触及的既有文件 `ComputerUseHelper/main.swift` 为 3023 行，不属于本次改动范围。

## Open questions

- 无。Provider 和模型选项直接使用当前 Provider Library 数据，不额外引入远端目录或新依赖。

## Implementation checklist

- [x] 默认规划模型改为 GPT-5.6 Sol。
- [x] 内置 Profile 支持先选 Provider、再选对应模型，并持久化覆盖。
- [x] Goal Dispatch 主按钮统一黑底白字，破坏性操作保留红色。
- [x] 左侧会话列表支持 230...520 pt 拖拽，并复用右侧栏反馈。
- [x] 拖拽过程冻结聊天列，松手后无动画重排，保护正文阅读位置。
- [x] 更新测试、版本号、CHANGELOG 与产品说明。

## Follow-up polish

- 无阻塞性 P3 项。

final result: passed
