# 完全访问审批菜单 Design QA

**Findings**

- 最终对比未发现仍需处理的 P0、P1 或 P2 问题。
- [P3] 实现保留了 WillDeep 现有的“工作区可写”第四档，因而菜单比 Codex 参考图多一行；这是产品能力差异，不影响层级、选中态或核心操作。

**Open Questions**

- 无阻塞问题。参考图只提供了菜单与底部入口局部，没有可运行的 Codex 原始界面，因此按用户指定的视觉语言与 WillDeep 原生 SwiftUI 约束验收，而不是逐像素复制菜单尺寸。

**Implementation Checklist**

- [x] 将“静默模式”展示名称替换为“完全访问”。
- [x] 使用 `exclamationmark.shield`，并把橙色限定为完全访问的风险语义色。
- [x] 为四种审批模式提供标题与说明，并显示明确的当前选中态。
- [x] 保持其余界面为黑白灰体系。
- [x] 去除 macOS 默认蓝色键盘焦点环造成的伪选中态。
- [x] 通过真实 App 交互验证模式切换、菜单展开和辅助功能选中态。

**Follow-up Polish**

- 无必须跟进项。

## Evidence

- Source visual truth:
  - `/var/folders/np/rjc0y5w52x324x21pv6g33440000gp/T/codex-clipboard-f53de1b6-bd1c-42da-a741-337e5f286705.png`
  - `/var/folders/np/rjc0y5w52x324x21pv6g33440000gp/T/codex-clipboard-0317458c-1acf-403c-a0a8-cd72e68e87e6.png`
- Implementation screenshots:
  - `/Users/rocky/Sites/Xedit/.artifacts/full-access-mode-menu-selected-final.png`
  - `/Users/rocky/Sites/Xedit/.artifacts/full-access-final-state.png`
- Same-input comparison board:
  - `/Users/rocky/Sites/Xedit/.artifacts/full-access-design-comparison.png`
- Viewport: WillDeep macOS window `1150 × 768 px`。
- Source pixels: menu reference `830 × 432 px`；pill reference `233 × 124 px`。
- Implementation pixels: full-window captures `1150 × 768 px`。
- CSS size: 不适用；这是原生 SwiftUI macOS 界面。
- Density normalization: 来源均为固定像素截图，未提供原始 points/deviceScaleFactor。比较板将对应局部置于等宽白色画布中，并仅对 pill 局部做等比例放大，未拉伸菜单内容。
- State: “完全访问”已选中，审批模式菜单展开；另验证菜单关闭后的 composer pill。
- Full-view evidence: `full-access-mode-menu-selected-final.png` 显示弹层未遮挡或挤出 composer，四种模式均完整可读，底部常驻入口未溢出。
- Focused-region evidence: `full-access-design-comparison.png` 同时放置 Codex 参考菜单/入口与 WillDeep 实现菜单/入口，核对风险盾牌、橙色语义、标题/说明层级、勾选位置和灰度背景。

## Required Fidelity Surfaces

- Fonts and typography: 使用系统字体；标题采用 semibold，说明采用更小的 regular/secondary，字重、行高和换行层级清楚。中文长说明保持两行内完整显示，无截断。
- Spacing and layout rhythm: 图标、标题、说明和尾部勾选对齐稳定；行间距、内边距、圆角与 macOS popover 体系一致；四行内容无溢出。
- Colors and visual tokens: 普通档位保持黑白灰；完全访问使用单一橙色语义，选中底色为低透明橙色，没有多余蓝色状态。
- Image quality and asset fidelity: 全部使用 SF Symbols 原生矢量图标；没有 emoji、手绘 SVG、占位图或模糊栅格资产。
- Copy and content: 每种模式均有本地化标题与行为说明；“完全访问”说明明确包含互联网与任意本机文件访问能力。

## Comparison History

1. 初次真实 App 对比发现 [P2] 智能审核行出现系统蓝色焦点环，与灰度体系及橙色唯一风险色冲突。
2. 在审批行按钮上禁用默认焦点绘制，并显式清理/重设辅助功能选中 trait。
3. 重新编译并再次打开真实 App：蓝色焦点环已消失；AX 树仅将当前模式标记为 selected；最终证据见 `full-access-mode-menu-selected-final.png` 与比较板。

final result: passed
