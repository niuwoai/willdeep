# Design QA：编辑器移除重复背景设置

## Comparison target

- Source visual truth：`artifacts/design-qa/editor-background-removal-1.247.0-rc4/reference-before.png`（900 × 557）。它记录用户指出的旧状态：编辑器分段导航仍有“背景”，并重复展示已经归属“Agent 外观”的工作区壁纸。
- Desired change：保留编辑器的编辑、格式、字体、工作区四项，彻底移除“背景”分段及其页面；Agent 外观继续作为壁纸与 Agent 背景效果的唯一入口。
- Rendered implementation：`artifacts/design-qa/editor-background-removal-1.247.0-rc4/implementation.png`（900 × 608）。这是 `1.247.0-rc4` Debug App 重启后，通过 macOS Computer Use 打开“设置 → 编辑器”得到的真实窗口截图。
- Focused comparison：`artifacts/design-qa/editor-background-removal-1.247.0-rc4/reference-vs-implementation.png`（900 × 368），上方为旧状态，下方为修复后实机标签区。
- Viewport：实现窗口 900 × 608 px；参考原图 734 × 486 px，等比归一为 900 × 557 px。聚焦标签区均归一到 900 px 宽，不进行额外设备密度换算。
- State：macOS 浅色模式，设置窗口，侧栏选中“编辑器”，编辑分段处于选中状态。

## Findings and comparison history

- 第一轮发现 `[P1]`：编辑器仍提供“背景”分段和完整壁纸页，与新设立的“Agent 外观”职责重复。用户可能在两个入口修改同一组持久化值，无法判断背景究竟属于编辑器还是 Agent。
- 修复：从 `EditorSettingsTab` 删除 `.background`，从编辑器分段列表和页面路由移除该项，并删除只服务于旧入口的重复 `backgroundSettings` / `backgroundSections` 视图。共享壁纸选择与持久化逻辑继续由 Agent 外观使用。
- 第二轮实机证据：Computer Use 读取到编辑器仅有“编辑 / 格式 / 字体 / 工作区”四个单选分段；无“背景”控件、空白占位或失效路由。未发现新的 P0、P1、P2 问题。

## Required fidelity surfaces

- Fonts and typography：标题、分段标签、表单标题和开关文字仍使用原有系统字体、字号与字重；移除标签后没有截断或异常换行。
- Spacing and layout rhythm：四个标签自动居中收拢，分隔线、左右内边距和表单纵向节奏保持一致；没有为已删除标签残留空位。
- Colors and visual tokens：沿用现有浅色设置页的系统蓝选中态、灰色分段底和中性表单表面；本次不改变设置页主题色。
- Image quality and asset fidelity：编辑器页不再加载壁纸缩略图；当前页面只使用系统控件和 SF Symbols，没有新增或替换图像资产。
- Copy and content：编辑、格式、字体、工作区四项保留；“背景”及其编辑器页面文案不再对用户可见。“Agent 外观”侧栏入口保持可见。

## Interaction and verification

- Computer Use 执行了 Debug App 重启、打开设置窗口和点击“编辑器”，随后读取真实无障碍树并捕获窗口截图。
- 无障碍树明确暴露四个单选按钮：编辑、格式、字体、工作区；未发现“背景”单选按钮。
- 定向 XCTest：`SettingsInformationArchitectureTests` 3/3 通过。
- 版本一致性检查通过：`1.247.0-rc4`；内部构建号 357，Help 与 Computer Use Helper 构建号 273。
- 原生 macOS App 不使用浏览器运行时，浏览器控制台检查不适用。

## Open questions

- 无。编辑器的格式、字体、工作区和编辑行为不在本次删除范围内。

## Implementation checklist

- [x] 删除编辑器“背景”分段。
- [x] 删除旧背景页面路由与重复视图。
- [x] 保留 Agent 外观中的背景配置。
- [x] 更新信息架构测试、版本与产品文档。
- [x] 重启 Debug App 并完成真实窗口检查。

## Follow-up polish

- 无阻塞性 P3 项。

final result: passed
