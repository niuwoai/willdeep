# Design QA：Composer 图标灰阶修复

## Comparison target

- Source visual truth：`artifacts/design-qa/composer-icons-1.247.0-rc3/reference.png`（871 × 195）。这是用户提供的真实 App 截图，显示 Composer 的文件夹、电脑、执行器、对话模式和审核图标仍被系统强调色渲染为蓝色。
- Rendered implementation：`artifacts/design-qa/composer-icons-1.247.0-rc3/implementation-full.png`（1068 × 768）。这是 `1.247.0-rc3` Debug App 重启后，通过 macOS Computer Use 读取真实 WillDeep 窗口得到的截图。
- Focused implementation region：`artifacts/design-qa/composer-icons-1.247.0-rc3/implementation-composer.png`（871 × 172）。从完整窗口裁出 Composer，并等比标准化到与参考图相同的 871 px 宽度。
- Combined comparison evidence：`artifacts/design-qa/composer-icons-1.247.0-rc3/reference-vs-implementation.png`（871 × 367），上方为用户截图，下方为修复后实机 Composer。
- Viewport：实现完整窗口 1068 × 768 px；Composer 对照区域统一为 871 px 宽。两份截图均为 macOS 浅色模式原生像素截图，不做设备密度换算，仅等比归一宽度。
- State：新聊天、无工作区、无分支、普通模式、智能审核、空输入框；实现与参考的核心 Composer 状态一致。

## Findings

- 第一轮发现 `[P1]`：`Menu` 与无边框 `Button` 会绕过局部 `foregroundStyle`，继续继承 macOS 蓝色 accent tint。证据是参考截图中的工作区、运行位置、WillDeep、普通和智能审核图标均为蓝色。影响是 Composer 视觉没有满足只使用黑、白、灰的明确要求。
- 修复：在 `ComposerCard` 边界增加 `.tint(AgentComposerChrome.iconPrimary)`，同时保留 `.symbolRenderingMode(.monochrome)`；所有内部系统控件继承统一灰阶 tint，不再回退到系统蓝色。
- 第二轮实机证据：组合对照图下半部分中的文件夹、电脑、锤子、对话气泡、盾牌、机密、麦克风和发送图标均只使用黑、白、灰。未发现仍可见的蓝色 Composer 图标，也未发现新的 P0、P1、P2 问题。

## Required fidelity surfaces

- Fonts and typography：修复仅覆盖图标 tint；文字字体、字号、字重、行高、截断和抗锯齿与参考状态一致，无意外变化。
- Spacing and layout rhythm：Composer 外框、上下栏位置、控件间距、圆角和内边距保持原布局；实机截图未见裁切、重叠或跳位。
- Colors and visual tokens：Composer 图标现统一映射到 `iconPrimary`、`iconSecondary`、`iconMuted`、`iconDisabled` 与反色 `actionForeground`；系统蓝色 accent 不再透入控件图标。
- Image quality and asset fidelity：该区域只使用原生 SF Symbols，没有位图、品牌插画、手绘 SVG 或替代占位资产；符号轮廓保持清晰。
- Copy and content：选择文件夹、本地处理、无分支、WillDeep、选择模型、普通和智能审核等内容保持不变。

## Interaction and verification

- Computer Use 成功读取重启后的真实 WillDeep 窗口和 Composer 控件树；本轮只读检查，没有触发发送、选择工作区或修改设置。
- 定向 XCTest：`AgentInteractionTargetMetricsTests` 3/3 通过，其中 Composer 回归同时锁定单色渲染、灰阶语义色和根层 tint。
- 版本一致性检查通过：`1.247.0-rc3`；内部构建号 356，Help 与 Computer Use Helper 构建号 272。
- 原生 macOS App 不使用浏览器运行时，浏览器控制台检查不适用。

## Open questions

- 无。用户要求仅针对 Composer 图标；窗口其他区域的统计插件彩色图标不属于本次范围。

## Implementation checklist

- [x] 切断 Composer 对系统蓝色 tint 的继承。
- [x] 保留黑、白、灰的选中、禁用和反色层级。
- [x] 补充源码回归和真实 App 视觉对照。
- [x] 重新构建、测试并启动 Debug App。

## Follow-up polish

- 无阻塞性 P3 项。

final result: passed
