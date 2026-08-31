# 待办右侧详情与多标签设计验收 — 1.310.0-rc1

final result: passed

## 证据与状态

- Source visual truth: `/Users/rocky/.codex/generated_images/01a048c6-0f5d-7312-b46b-f96f088e9069/exec-01ef628b-5221-469b-8c15-e899b7428f0e.png`，最新修订设计集第 2 张。
- Implementation: `http://127.0.0.1:38766/`；生产插件 UI 调用真实 Ruby MCP，12 条隔离演示数据，不访问用户待办。
- Implementation screenshot: `build/todo-design-qa/todo-inspector-host-light.png`。
- Full-view comparison: `build/todo-design-qa/todo-inspector-comparison.png`（左设计、右实现）。
- Focused comparison: `build/todo-design-qa/date-detail-comparison.png`，检查月历、时刻、无终止时间、优先级与保存按钮。
- Source pixels: 1487×1058；等比缩至 1439×1024（不拉伸），与 1440×1024 CSS px、1× 密度实图对齐，画布宽差 1px。
- State: 中文、浅色、界面标签筛选（6/12）、第一条任务详情打开、2026-08-31 18:00、高优先级、界面/修复标签；最终截图包含键盘焦点环。
- Additional captures: `build/todo-design-qa/todo-inspector-compact.png`（620×900）、`todo-inspector-narrow.png`（390×844）、`todo-inspector-dark-english.png`（1440×1024，英文/深色）。

## Findings 与迭代

1. [P2，已修复] 初版详情 430px 偏窄、卡片背景过深、任务文字偏小。详情扩大到 462px，卡片背景降为 2% 前景混合，标题 17px、元信息 14px；重新截图比较。
2. [P1，已修复] 原生确认框在嵌入式预览中阻塞。取消或切换任务使用详情栏内“继续编辑 / 放弃修改”；真实操作验证保留草稿与放弃不落盘。
3. [P1，已修复] 宿主深色强调色为浅色，原白色按钮文字会消失。按钮与选中日期文字改用页面背景令牌；深色实测前景 `rgb(28,28,30)`、背景 `rgb(242,242,244)`。
4. [P2，已修复] 选中日期铺满网格宽度。日期按钮改为居中的 30×30px，方向键跨月后再回到 31 日，重新捕获全图和局部对照确认。
5. [P1，已修复] Xcode 旧打包步骤只复制 `ui/index.html`。改为完整 `ui` 目录，并增加脚本/样式/全部图标文件的资源检查。

无剩余 P0/P1/P2 视觉问题。

## 五项视觉核对

- 字体与排版：系统字体 / PingFang SC；详情标题 21px、任务标题 17px、正文/元信息 14px、标签 13px，长中文换行不溢出；主次层级与参考一致。
- 间距与布局：1440px 内容区为左侧两列卡片 + 462px 详情；项目、标签、日期、优先级顺序一致。620/390px 抽屉占据右侧/整屏、背景 inert、底部保存可达，页面横向溢出为 0。
- 颜色与令牌：参考的蓝色选择/按钮转换为 WillDeep 宿主既定灰阶交互令牌（浅色黑、深色白），不是另创主题；标签保留低饱和分类色，紧急/高/中/低保留既有语义色。深色选择态对比度已修复。
- 资产：无装饰插画；图标使用官方 Heroicons v2.2.0 outline 本地文件及 MIT 许可证，保持离线可用，无自绘图标/占位图。
- 文案与内容：项目、多标签、日期与“无终止时间”齐全，中英字典键一致；日期按当前界面语言格式化。保留现有“一句话记待办”能力与本地解析回退。

## 交互验证

- [x] 点击项目/时间均进入统一详情，可修改项目、标签和日期。
- [x] 新标签、移除标签、清空截止日期落盘；失败提示保留草稿、重试成功。
- [x] 取消时继续编辑保留草稿，放弃修改恢复原数据；切换任务先确认。
- [x] 任一/同时包含标签、项目叠加、无标签与清除筛选。
- [x] 月历方向键跨月、无终止时间清空时刻并禁用时刻控件、窄屏焦点限制。
- [x] 英文/深色页面无控制台错误；81 项 Ruby 服务端 + 11 项 Node 模型/资源检查通过。
- [x] 原生 `AgentPluginSystemTests` 36 项通过（`build/fast-tests/report.md`）；Debug App 内 17 个待办 UI 资源 SHA-256 与源码完全一致。

## 可接受差异与后续打磨

- [P3] 详情的标签搜索独立成行，候选列表限高滚动，容纳真实标签数量；未复制概念图仅两条候选的静态浮层。
- [P3] 全天采用原生复选框、优先级采用原生下拉，保留真实控件的键盘和辅助功能行为。
- 参考图的月份日期排布有生成图误差；实现使用真实公历，2026-08-01 为周六、08-31 为周一。
- 原生宿主的完整测试/正式签名发行另由测试和发布报告证明；本报告不将浏览器验收等同于已发布。

---

# 历史验收：Worker 监控卡片

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
