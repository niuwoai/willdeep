# 会话审批徽章与 Composer 图片预览 Design QA

**Findings**

- 最终对比未发现仍需处理的 P0、P1 或 P2 问题。
- [P3] 本次实机数据里没有仍处于待审批状态的会话，因此无法在不篡改用户会话数据、不额外发起模型请求的前提下捕获黑底徽章的真实侧栏截图。该表面改用用户参考图、实际组件源码与自动化契约测试交叉验收；颜色、字重、圆角与文案均为精确值，不依赖近似推断。

**Open Questions**

- 无阻塞问题。

**Implementation Checklist**

- [x] 会话标题旁“等待批准”改为黑底、白字、semibold 的胶囊徽章。
- [x] 严格模式说明删去“无害的标题更新自动执行”，五种语言同步收口。
- [x] Composer 图片缩略图成为独立、可访问的预览按钮。
- [x] 点击缩略图复用原生大图窗口，支持缩放、适应窗口、滚动、双击放大与 `Esc` 关闭。
- [x] 删除按钮保持独立，点击删除不会触发预览。
- [x] 通过真实 App 完成粘贴图片、打开大图与展开审批模式菜单的交互验收。

**Follow-up Polish**

- 无必须跟进项。

## Evidence

- Source visual truth:
  - `/var/folders/np/rjc0y5w52x324x21pv6g33440000gp/T/codex-clipboard-7f5d310b-b501-4e7d-a6ba-f53e1a22aa3d.png`
  - `/var/folders/np/rjc0y5w52x324x21pv6g33440000gp/T/codex-clipboard-1594cc40-d8ec-4475-ad79-486ea5398f8e.png`
- Implementation screenshots:
  - `/Users/rocky/Sites/Xedit/.artifacts/strict-mode-summary-final.png`
  - `/Users/rocky/Sites/Xedit/.artifacts/composer-image-thumbnail-final.png`
  - `/Users/rocky/Sites/Xedit/.artifacts/composer-image-preview-final.png`
- Same-input comparison board:
  - `/Users/rocky/Sites/Xedit/.artifacts/strict-mode-reference-vs-implementation.png`
- Viewport: WillDeep 主窗口 `1150 × 768 px`；图片预览窗口 `960 × 752 px`。
- Source pixels: 会话徽章参考 `508 × 465 px`；严格模式参考 `669 × 138 px`。
- Implementation pixels: 主窗口截图 `1150 × 768 px`；图片预览截图 `960 × 752 px`。
- CSS size: 不适用；这是原生 SwiftUI macOS 界面。
- Density normalization: 来源与实机证据均为固定像素 PNG。严格模式对照板只裁出对应行并居中拼接，没有拉伸内容。
- State: 审批模式菜单展开；Composer 已附加图片；缩略图点击后原生预览窗打开，AX 树确认窗口标题、图片尺寸、缩小、放大与适应窗口控件全部存在。
- Full-view evidence: `strict-mode-summary-final.png` 与 `composer-image-thumbnail-final.png` 证明菜单和附件在完整主窗口中未遮挡、未溢出。
- Focused-region evidence: `strict-mode-reference-vs-implementation.png` 同屏核对严格模式说明；`composer-image-preview-final.png` 验证大图显示与工具栏。

## Required Fidelity Surfaces

- Fonts and typography: 徽章使用现有 sidebar supporting font，字重由 medium 提升至 semibold；严格模式标题与说明沿用现有菜单层级。
- Spacing and layout rhythm: 徽章保留 7 pt 横向、2 pt 纵向内边距；缩略图维持 64 pt 与既有 6 pt 间距，未改变 Composer 高度节奏。
- Colors and visual tokens: 徽章严格使用 `Color.black` 与 `Color.white`，符合用户指定的黑白灰体系；没有引入新的彩色状态。
- Image quality and asset fidelity: Composer 与预览窗显示同一原图数据；预览默认适应窗口，图像未拉伸，工具栏显示真实 `334 × 69` 尺寸。
- Copy and content: 严格模式中文仅保留“安全相关写入或外部操作前询问。”；英文、西语、法语、日语同步删除标题更新例外。

## Comparison History

1. 初始实现中 Composer 缩略图依赖整块 `onTapGesture`，删除按钮与预览点击区域存在事件语义混叠风险。
2. 将预览目标改为明确的 `Button(action: onPreview)`，删除按钮继续作为独立按钮，并补齐本地化帮助与辅助功能标签。
3. 在真实 App 中附加用户提供的 PNG：AX 树出现“放大查看图片”按钮；点击后打开 `image.png` 原生窗口，显示 `334 × 69`、100%、缩小、放大和适应窗口。
4. 同屏对比严格模式参考与实机菜单，确认“标题更新”句子已经消失，菜单布局未因文案缩短发生异常。

final result: passed
