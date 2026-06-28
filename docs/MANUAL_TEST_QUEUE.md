# Manual Smoke-Test Queue

> Last updated: 2026-06-28

CI 只能保编译/单测过。一系列改 UI、改窗口、改 SwiftUI 状态机的特性
都得人坐到机器前面点。这个文件按版本累积着每次发版后我提醒你
「你需要手动 smoke 这几样」的清单。**测过的请打勾或直接删行**，
留下来的就是还没测的；下次 onboarding / dogfooding 时优先消化。

约定：
- ⏳ = 还没测
- ✅ = 已测、通过
- ❌ = 已测、有 bug（请在行后写 issue link 或一句描述）

---

## 1.78.0-rc116 — sheet @Published 死循环修复

- ⏳ 打开「设置 → MCP → 新服务器」按钮 → sheet 正常浮出来，不再让
  PID 100% CPU 卡死；新建一个测试 MCP server 走完保存流程
- ⏳ 同样从 `AgentMCPServerCreationCoordinator.open(draft:)` 外部推入
  草稿（例如 agent 学习提示出一个 MCP 建议）→ sheet 也正常出，不
  在 SheetMoveHelper 动画里炸

## 1.79.0-rc1 / rc2 / rc3 — Plan 自动执行 banner

- ⏳ Plan 模式下让 agent 输出一个普通 plan（不带破坏性词）→
  composer 上方浮 banner，倒计时 8s 走完应自动 Execute、Agent 开始
  执行
- ⏳ Plan 模式下让 agent 输出含 `rm -rf` / `git push --force` 的 plan
  → banner 出现但进度条灰显、倒计时不归零；只能手点 Execute
- ⏳ Banner 出现后用户在 composer 敲键 → banner 立刻消失，保持
  Plan 模式（Execute 没被触发）
- ⏳ 勾「本工作区不再询问」+ Execute → 下次同 workspace 的新 plan 应
  跳过 banner 直接 confirm
- ⏳「设置 → AI 服务商 → Plan auto-execution」section 可见；toggle 
  「Scan plan for destructive keywords」关掉后 banner 倒计时对带
  `rm -rf` 的 plan 也照常自动 fire
- ⏳「Re-enable Plan prompt for this workspace」按钮只在当前 workspace
  之前勾过「记住」时显示；点了之后下次新 plan 就绪 banner 回来

## 1.80.0-rc1 — Agent 拆独立窗口

- ⏳ Cmd+Shift+A 从 editor 窗口按 → 「WillDeep Agent」窗口浮出
- ⏳ 跟随聚焦：开两个 workspace 窗口 A、B + agent 窗口，点 A 焦点
  → agent 显示 A 的 transcript；点 B → agent 切到 B 的 transcript
  （scroll 位置、composer 草稿应该都是 B 自己的）
- ⏳ 关掉所有 editor 窗口只留 agent 窗口 → 看到「No editor window
  open / Open Workspace…」占位；点按钮选目录 → 新 editor 起来、占
  位消失
- ⏳ AgentChatHeader 右上角 `rectangle.split.2x1` 按钮 → 把对应的
  editor 窗口抬到前台
- ⏳ Agent 窗口聚焦时切 editor 窗口（即从 agent 跳到 editor）→
  registry.current 应该**不**因 agent 失焦而变；agent 窗口里看的
  内容跟你刚才聚焦的那个 editor 一致

## 1.81.0-rc1 — Workflow（codex 同款 fan-out）

- ⏳ Composer 输 `/` → palette 里能看到 `/research`、`/code-review`、
  `/bug-hunt`、`/competitor` 4 个 workflow 命令，都用 `wand.and.rays`
  图标
- ⏳ 输 `/research how do mac apps usually do auto-update` → 选中后
  transcript 出 workflow 卡片，6 个 sub-agent 并发跑（5 search +
  1 synthesize），完成后报告应填到卡片正文
- ⏳ 输 `/code-review` 在一个有 working tree diff 的 repo 里 →
  4 个 sub-agent 并发跑，4 dimensions 全部出报告
- ⏳ 输 `/bug-hunt` 不带 hint → picker 跑完后 hunters 并发，最后 synth
  出去重后的 bug 列表
- ⏳ 输 `/competitor Notion, Obsidian, Logseq` → 3 个 scout 并发 +
  1 个 synthesize；对比表正确
- ⏳ Workflow 卡片右上角 chevron 折叠展开看每个 sub-agent 的状态、
  耗时、token；卡片 footer 显示累计 token
- ⏳ Workflow 跑完后，用户在 composer 正常发消息和 agent 对话 →
  agent **不应该**看到 workflow card 的内容（验证 4 个 AgentClient
  都正确跳过 `.workflowReport`）；只有用户主动 quote 卡片内容时
  agent 才看得到
- ⏳ Workflow 跑到一半切 session / 切 workspace 窗口 → 卡片仍正确显示
  在原 session，新 session 看不到（runtime 隔离）

## 1.109.0-rc436 — 短剧 AI 制作 MVP 收口

- ⏳ 打开或新建一个短剧项目 → 右侧短剧侧栏能看到集、分镜、人物、
  场景、参考图状态、制作缺口和媒体任务徽标。
- ⏳ 在项目或分集的制作缺口区点击「补主图 / 补视频 / 审片」→
  聊天输入框出现对应 `<short-drama-production-gap-action>`，并包含
  dry-run 参数、正式提交参数、打开/刷新媒体任务参数。
- ⏳ 通过 some.im 或 manifest 导入登记一个 pending 图片/视频任务 →
  媒体任务侧栏显示运行中任务，手动刷新后聊天下一轮能看到
  `latest-media-task-refresh`。
- ⏳ 完成或导入一个带多张图片的媒体任务 → 打开候选图 Widget，选择
  一张图后聊天下一轮能看到所选图片和设主图/蒙版/放大/图生视频动作。
- ⏳ 打开图片蒙版编辑器，画选区并点「发送到聊天」→ 聊天输入框包含
  真实 `mask_path`，并给出 `edit_image_with_mask` 的可执行参数。
- ⏳ 导出短剧制作包 → 自动打开或可手动打开 `widget-preview.html`，
  Widget 侧栏显示来源、制作包路径和可用动作。
- ⏳ 调用 `import_media_manifest(import_pending_tasks=true)` 导回制作包 →
  媒体任务侧栏显示导回任务，聊天下一轮能看到 `latest-media-import`。
- ⏳ 检查项修复流：从检查项打开蒙版/放大/补拍任务，任务完成后仍保留
  `review_item_id`，并可关闭对应检查项。

## 1.109.0-rc438 — 短剧 MVP 本地试用包

- ⏳ 运行 `ruby scripts/short_drama_mvp_tryout_package.rb ...` →
  `build/ci/short_drama_mvp_tryout_package_report.md/json` 显示 pass，
  样例包包含 `widget-preview.html`、manifest、timeline、gap report、
  review template/queue 和 outputs。
- ⏳ 用 `import_media_manifest(package_directory=build/ci/short_drama_mvp_tryout_package, dry_run=true, import_pending_tasks=true)` →
  dry-run 汇总应显示 3 个可导入产物、1 个 pending 任务、1 个 failed 修复任务。
- ⏳ 用同一 package 正式导入 →
  媒体任务侧栏能看到 completed / pending / failed 三类任务，且 `latest-media-import`
  写入聊天上下文。
- ⏳ 打开样例 `widget-preview.html` →
  Widget 侧栏能显示来源路径、制作包目录和 `import_media_manifest` / gap plan /
  review queue 等 handoff 入口。

## 1.109.0-rc442 — 短剧收口文档版本守门

- ⏳ 运行 `ruby scripts/version_consistency.rb ...` →
  报告 sources 中包含短剧 cutoff、tryout 和手动 smoke 队列三类检查。
- ⏳ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  顶部基线和底部“验收记录”都指向 `1.109.0-rc442`。
- ⏳ 打开 [MANUAL_TEST_QUEUE.md](MANUAL_TEST_QUEUE.md) →
  最新短剧 smoke 小节是 `1.109.0-rc442 — 短剧收口文档版本守门`。

## 1.109.0-rc440 — 短剧 MVP 试用包内置手动 smoke 清单

- ⏳ 运行 `ruby scripts/short_drama_mvp_tryout_package.rb ...` →
  样例包包含 `manual-smoke-checklist.md`，报告 Markdown/JSON 中能看到
  `manual_smoke_checklist_path`。
- ⏳ 打开 `build/ci/short_drama_mvp_tryout_package/manual-smoke-checklist.md` →
  清单覆盖 dry-run 导入、正式导入、媒体任务侧栏、`latest-media-import`
  和 Widget 结构化动作验收步骤。
- ⏳ 按清单执行到 Widget 动作部分 → `Dry-run import`、`Import manifest`、
  `Review queue` 均能把结构化 `<widget-handoff-action>` 放入聊天输入框。

## 1.109.0-rc439 — 短剧 MVP 试用包结构化 Widget 动作

- ⏳ 打开 `build/ci/short_drama_mvp_tryout_package/widget-preview.html` →
  顶部能看到 `Dry-run import`、`Import manifest`、`Review queue` 三个结构化动作按钮。
- ⏳ 点击 `Dry-run import` →
  聊天输入框出现 `<widget-handoff-action>`，其中 `handoff_tool=import_media_manifest`，
  `handoff_arguments` 包含 `dry_run=true, import_pending_tasks=true`。
- ⏳ 点击 `Review queue` →
  聊天输入框出现 `handoff_tool=short_drama_import_review_csv`，
  参数指向 `production-review-queue.csv` 且 `dry_run=true`。

---

## 已知 phase 2（不算 bug，是延迟做的功能）

按 plan 留到后续版本：

- Workflow 中途 stop 按钮 —— 现在只能等完成或 Cmd+Q
- 让 agent 主动派 workflow（`run_workflow` 工具）—— 现在只能用户 slash
- 用户自定义 workflow（YAML/JSON 加进 ~/.willdeep/workflows/）
- Workflow 卡片实时倒计时（当前秒数）
- Plan 自动执行的 token 估算显示
- 多语言：workflow 内置 agent prompt 是英文写死的；UI 文案已走 L10n

---

## 怎么用这个文档

- 每次发新版要补 smoke 项时：在最下面加新 H2 section
- 测过的项打 ✅ 或直接删行
- 发现 bug 写 `❌ <一句话描述>`，然后 spawn 一个 task 修
- 长期不动的 ⏳ 项目要么是低优先级、要么我忘了催 —— 隔一阵翻一下
