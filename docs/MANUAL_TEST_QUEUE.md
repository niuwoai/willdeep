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
- ✅ 该版本的短剧试用文档指针检查已被后续 `version_consistency`
  机器守门覆盖；当前入口以最新短剧 smoke 小节为准。

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

## 1.109.0-rc443 — 短剧人工 smoke 队列顺序守门

- ✅ 运行 `ruby scripts/version_consistency.rb ...` →
  报告 sources 中同时包含 `Manual smoke latest short drama section`
  和 `Manual smoke last short drama section`，且二者都指向 `1.109.0-rc443`。
- ✅ 该版本的短剧试用文档指针检查已被后续 `version_consistency`
  机器守门覆盖；当前入口以最新短剧 smoke 小节为准。

## 1.109.0-rc444 — 短剧过期指针 smoke 守门

- ✅ 运行 `ruby scripts/version_consistency.rb ...` →
  报告 sources 中包含 `Manual smoke pending short drama pointer versions`，
  且所有待测短剧文档指针都指向 `1.109.0-rc444`。
- ✅ 该版本的短剧试用文档指针检查已被后续 `version_consistency`
  机器守门覆盖；当前入口以最新短剧 smoke 小节为准。

## 1.109.0-rc445 — 短剧交付验收入口守门

- ✅ 运行 `ruby scripts/version_consistency.rb ...` →
  报告 `Delivery Gates` 中包含本地一键验收、远端 Go agent 测试和
  远端 XeditTests 三类入口，且全部为 `PASS`。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_CUTOFF.md](SHORT_DRAMA_AI_MVP_CUTOFF.md) →
  “可用版验收清单”同时包含 `scripts/run_tests.sh`、GitHub Actions
  `Tests` workflow 的 `go test ./...` 和 `Run XeditTests`。
- ✅ 该版本的短剧试用文档指针检查已被后续 `version_consistency`
  机器守门覆盖；当前入口以最新短剧 smoke 小节为准。

## 1.109.0-rc446 — 短剧人工 smoke 结果模板

- ✅ 运行 `ruby scripts/short_drama_mvp_tryout_package.rb ...` →
  样例包包含 `manual-smoke-results-template.md` 和
  `manual-smoke-results-template.json`，报告 Markdown/JSON 中能看到
  两个结果模板路径。
- ✅ 打开 `build/ci/short_drama_mvp_tryout_package/manual-smoke-results-template.md` →
  表格覆盖 dry-run 导入、正式导入、`latest-media-import`、Widget
  结构化 handoff 和 review queue dry-run；所有状态初始为 `untested`。
- ✅ 运行 `ruby scripts/version_consistency.rb ...` →
  报告 `Delivery Gates` 包含试用包人工 smoke 结果模板守门，且为 `PASS`。
- ✅ 该版本的短剧试用文档指针检查已被后续 `version_consistency`
  机器守门覆盖；当前入口以最新短剧 smoke 小节为准。

## 1.109.0-rc447 — 短剧交付验收摘要

- ✅ 运行 `ruby scripts/short_drama_mvp_acceptance_report.rb ...` →
  `build/ci/short_drama_mvp_acceptance_report.md/json` 显示 pass，
  evidence 包含版本报告、试用包报告、试用包目录、手动 smoke checklist/results、
  cutoff、tryout 和 manual queue。
- ✅ 运行 `ruby scripts/version_consistency.rb ...` →
  报告 `Delivery Gates` 包含短剧验收摘要本地/远端接线守门，且为 `PASS`。
- ✅ 打开 GitHub Actions `Tests` workflow →
  job summary 和 artifact 中包含 `short_drama_mvp_acceptance_report.md/json`。
- ✅ 该版本的短剧试用文档指针检查已被后续 `version_consistency`
  机器守门覆盖；当前入口以最新短剧 smoke 小节为准。

## 1.109.0-rc448 — 短剧验收摘要手动状态

- ✅ 运行 `ruby scripts/short_drama_mvp_acceptance_report.rb ...` →
  Markdown 报告包含 `Manual Smoke Status`，JSON 报告包含
  `manual_smoke_summary`，能看到 passed / pending / failed 计数和待办项标题。
- ✅ 打开 `build/ci/short_drama_mvp_acceptance_report.md` →
  `Manual Smoke Status` 中至少列出当前 rc448 小节剩余待测项，方便交付时继续人工 smoke。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向 `1.109.0-rc448 — 短剧验收摘要手动状态`。
- ✅ 该版本的短剧验收摘要状态检查已被 rc449 的交付就绪报告覆盖；当前入口以最新短剧 smoke 小节为准。

## 1.109.0-rc449 — 短剧交付就绪与剩余风险摘要

- ✅ 运行 `ruby scripts/short_drama_mvp_acceptance_report.rb ...` →
  Markdown 报告包含 `Handoff Readiness` 和 `Remaining Risks`，
  JSON 报告包含 `handoff_readiness` 与 `remaining_risks`。
- ✅ 打开 `build/ci/short_drama_mvp_acceptance_report.json` →
  在机器检查通过且当前小节仍有待测项时，顶层 `status` 保持 `pass`，
  但 `handoff_readiness.overall` 显示 `manual_pending`。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向 `1.109.0-rc449 — 短剧交付就绪与剩余风险摘要`。
- ✅ 该版本的交付就绪摘要检查已被 rc450 的 `version_consistency`
  机器守门覆盖；当前入口以最新短剧 smoke 小节为准。

## 1.109.0-rc450 — 短剧交付就绪摘要守门

- ✅ 运行 `ruby scripts/version_consistency.rb ...` →
  报告 `Delivery Gates` 包含
  `Short drama acceptance report preserves handoff readiness summary`，且为 `PASS`。
- ✅ 运行 `ruby scripts/short_drama_mvp_acceptance_report.rb ...` →
  报告 checks 包含 `delivery gates include handoff readiness summary`，且为通过。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向 `1.109.0-rc450 — 短剧交付就绪摘要守门`。
- ✅ 该版本的交付就绪摘要守门已被 rc451 的显式剩余风险守门覆盖；当前入口以最新短剧 smoke 小节为准。

## 1.109.0-rc451 — 短剧显式剩余风险守门

- ✅ 运行 `ruby scripts/version_consistency.rb ...` →
  报告 `Delivery Gates` 包含
  `Short drama cutoff preserves explicit remaining risks`，且为 `PASS`。
- ✅ 运行 `ruby scripts/short_drama_mvp_acceptance_report.rb ...` →
  报告 checks 包含 `cutoff keeps explicit remaining risks`，且为通过。
- ✅ 打开 `build/ci/short_drama_mvp_acceptance_report.json` →
  顶层 `remaining_risks` 至少包含一条来自 cutoff 的真实剩余风险，不出现
  “No remaining risks found” 兜底文案。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向 `1.109.0-rc451 — 短剧显式剩余风险守门`。
- ✅ 该版本的显式剩余风险守门已被 rc452 的手测结果文件摘要覆盖；当前入口以最新短剧 smoke 小节为准。

## 1.109.0-rc452 — 短剧手测结果文件摘要

- ✅ 运行 `ruby scripts/short_drama_mvp_acceptance_report.rb ...` →
  Markdown 报告包含 `Manual Results File`，JSON 报告包含
  `manual_results_summary`。
- ✅ 打开 `build/ci/short_drama_mvp_acceptance_report.json` →
  `manual_results_summary.overall_status` 显示包内
  `manual-smoke-results-template.json` 的状态，默认模板应为 `untested`，
  且 `handoff_readiness.overall` 仍显示 `manual_pending`。
- ✅ 将试用包 `manual-smoke-results-template.json` 中某一步临时标为
  `fail` 后重跑验收脚本 → `manual_results_summary.failed_count` 增加，
  且 `handoff_readiness.overall` 显示 `manual_failed`；测完要还原模板。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向 `1.109.0-rc452 — 短剧手测结果文件摘要`。
- ✅ 该版本的手测结果文件摘要已被 rc453 的手测证据摘要覆盖；当前入口以最新短剧 smoke 小节为准。

## 1.109.0-rc453 — 短剧手测证据摘要

- ✅ 运行 `ruby scripts/short_drama_mvp_acceptance_report.rb ...` →
  Markdown 报告包含 `Manual Evidence`，JSON 报告包含
  `manual_evidence_summary`。
- ✅ 打开 `build/ci/short_drama_mvp_acceptance_report.json` →
  默认未测模板下 `manual_evidence_summary.required_count` 为 0，
  `handoff_readiness.overall` 仍显示 `manual_pending`。
- ✅ 将试用包 `manual-smoke-results-template.json` 中某一步临时标为
  `pass` 且不填 `evidence` 后重跑验收脚本 → `manual_evidence_summary.missing_count`
  增加，且 `handoff_readiness.overall` 保持 `manual_pending`；测完要还原模板。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向 `1.109.0-rc453 — 短剧手测证据摘要`。
- ✅ 该版本的手测证据摘要已被 rc454 的 provider smoke 模板覆盖；当前入口以最新短剧 smoke 小节为准。

## 1.109.0-rc454 — 短剧 provider smoke 模板

- ✅ 运行 `ruby scripts/short_drama_mvp_tryout_package.rb ...` →
  样例包包含 `provider-api-smoke-template.md` 和
  `provider-api-smoke-template.json`。
- ✅ 打开 `build/ci/short_drama_mvp_tryout_package/provider-api-smoke-template.json` →
  schema 为 `willdeep.short_drama.provider_api_smoke.v1`，步骤覆盖
  some.im 图片/视频异步任务与 Replicate 放大/蒙版编辑，初始状态均为
  `untested`。
- ✅ 运行 `ruby scripts/short_drama_mvp_acceptance_report.rb ...` →
  Markdown 报告包含 `Provider API Smoke Templates`，JSON 报告包含
  `provider_api_smoke_summary`，且默认模板不会触发外网 API。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向 `1.109.0-rc454 — 短剧 provider smoke 模板`。
- ✅ 该版本的 provider smoke 模板已被 rc455 的 provider smoke 证据守门覆盖；当前入口以最新短剧 smoke 小节为准。

## 1.109.0-rc455 — 短剧 provider smoke 证据守门

- ✅ 运行 `ruby scripts/short_drama_mvp_acceptance_report.rb ...` →
  JSON 报告的 `provider_api_smoke_summary` 包含
  `evidence_required_count`、`evidence_present_count`、
  `evidence_missing_count` 和 `evidence_missing_items`。
- ✅ 打开 `build/ci/short_drama_mvp_acceptance_report.json` →
  默认 provider smoke 模板全为 `untested` 时，`provider_api_smoke_summary.evidence_required_count`
  为 0，且 `handoff_readiness.overall` 仍由本地手测状态决定。
- ✅ 将试用包 `provider-api-smoke-template.json` 中某一步临时标为
  `pass` 且不填 `evidence` 后重跑验收脚本 →
  `provider_api_smoke_summary.evidence_missing_count` 增加，且
  `handoff_readiness.overall` 显示 `manual_pending`；测完要还原模板。
- ✅ 将试用包 `provider-api-smoke-template.json` 中某一步临时标为
  `fail` 后重跑验收脚本 → `provider_api_smoke_summary.failed_count`
  增加，且 `handoff_readiness.overall` 显示 `manual_failed`；测完要还原模板。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向 `1.109.0-rc455 — 短剧 provider smoke 证据守门`。
- ✅ 该版本的 provider smoke 证据守门已被 rc456 的 standalone smoke 证据自检报告覆盖；当前入口以最新短剧 smoke 小节为准。

## 1.109.0-rc456 — 短剧 smoke 证据自检报告

- ✅ 运行 `ruby scripts/short_drama_mvp_tryout_package.rb ...` →
  样例包的 checklist、Widget 和 tryout package report 都包含
  `short_drama_mvp_smoke_evidence_report.rb` 命令。
- ✅ 运行 `ruby scripts/short_drama_mvp_smoke_evidence_report.rb ...` →
  生成 `short_drama_mvp_smoke_evidence_report.md/json`，默认模板下
  `readiness.overall` 为 `manual_pending`，且脚本不调用 some.im / Replicate。
- ✅ 打开 `build/ci/short_drama_mvp_smoke_evidence_report.json` →
  报告同时包含 `manual_results_summary`、`provider_api_smoke_summary`
  和 `readiness`。
- ✅ 将试用包 `manual-smoke-results-template.json` 中某一步临时标为
  `pass` 且不填 `evidence` 后重跑自检脚本 →
  `readiness.missing_evidence_count` 增加，且 `readiness.overall`
  显示 `manual_pending`；测完要还原模板。
- ✅ 将试用包 `provider-api-smoke-template.json` 中某一步临时标为
  `fail` 后重跑自检脚本 → `readiness.failed_count` 增加，且
  `readiness.overall` 显示 `manual_failed`；测完要还原模板。
- ✅ 运行 `ruby scripts/short_drama_mvp_acceptance_report.rb ...` →
  Markdown 报告包含 `Smoke Evidence Report`，JSON 报告包含
  `smoke_evidence_report`，并把该报告路径列入 evidence。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向 `1.109.0-rc456 — 短剧 smoke 证据自检报告`。
- ✅ 该版本的 standalone smoke 证据自检报告已被 rc457 的 next actions 覆盖；当前入口以最新短剧 smoke 小节为准。

## 1.109.0-rc457 — 短剧 smoke 证据下一步建议

- ✅ 运行 `ruby scripts/short_drama_mvp_smoke_evidence_report.rb ...` →
  JSON 报告包含 `next_actions`，Markdown 报告包含 `Next Actions`。
- ✅ 默认模板全为 `untested` 时 →
  `next_actions` 包含 `finish_manual_smoke` 和
  `record_provider_smoke_or_keep_risk`，交付人能看到具体待补项，而不是只看到
  `manual_pending`。
- ✅ 将试用包 `manual-smoke-results-template.json` 中某一步临时标为
  `pass` 且不填 `evidence` 后重跑自检脚本 →
  `next_actions` 包含 `add_evidence`；测完要还原模板。
- ✅ 将试用包 `provider-api-smoke-template.json` 中某一步临时标为
  `fail` 后重跑自检脚本 → `next_actions` 包含
  `resolve_failed_smoke`，且 `readiness.overall` 显示 `manual_failed`；测完要还原模板。
- ✅ 运行 `ruby scripts/short_drama_mvp_acceptance_report.rb ...` →
  Markdown 报告包含 `Smoke Evidence Next Actions`，JSON 报告包含
  `smoke_evidence_next_actions`。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向 `1.109.0-rc457 — 短剧 smoke 证据下一步建议`。
- ✅ 该版本的 smoke evidence next actions 已被 rc458 的试用包 handoff index 覆盖；当前入口以最新短剧 smoke 小节为准。

## 1.109.0-rc458 — 短剧试用包交付索引

- ✅ 运行 `ruby scripts/short_drama_mvp_tryout_package.rb ...` →
  样例包包含 `handoff-index.md` 和 `handoff-index.json`。
- ✅ 打开 `build/ci/short_drama_mvp_tryout_package/handoff-index.json` →
  schema 为 `willdeep.short_drama.tryout_handoff_index.v1`，`start_here`
  至少包含读索引、dry-run、打开 Widget、记录 smoke evidence、生成 evidence report。
- ✅ 打开 `build/ci/short_drama_mvp_tryout_package/handoff-index.md` →
  Markdown 包含 `Start Here`、`Key Files`、`Commands` 和 `Remaining Risks`。
- ✅ 运行 `ruby scripts/short_drama_mvp_acceptance_report.rb ...` →
  Markdown 报告包含 `Handoff Index`，JSON 报告包含 `handoff_index`，并把
  handoff index 路径列入 evidence。
- ✅ 运行 `ruby scripts/version_consistency.rb ...` →
  delivery checks 包含 `Tryout package preserves handoff index` 且为通过。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  本地试用包路径先指向 `handoff-index.md`，底部“验收记录”指向
  `1.109.0-rc458 — 短剧试用包交付索引`。

## 1.109.0-rc460 — 短剧基线同步与编辑器选区内存修复

- ✅ 本版本没有新增短剧制作能力；短剧试用包、handoff index、manual smoke
  模板和 provider smoke 模板沿用 rc458 的已记录入口。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向
  `1.109.0-rc460 — 短剧基线同步与编辑器选区内存修复`。
- ⏳ 在 Agent 中触发一条超过 3000 字符的流式长回复 →
  聊天气泡预览应保留开头和结尾，中间显示省略提示；点击提示卡应打开完整内容。
- ⏳ 在 Editor 模式打开 `~/Sites/mylinux/novel/` 下任一章节并反复拖选文本 →
  进程内存应保持稳定，不应因选区变化持续暴涨。

## 1.109.0-rc461 — 短剧 smoke 证据敏感信息守门

- ✅ 本版本没有新增短剧制作能力；本轮只收敛 smoke evidence 留证据时的敏感信息守门。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向
  `1.109.0-rc461 — 短剧 smoke 证据敏感信息守门`。
- ✅ 运行 `ruby scripts/short_drama_mvp_smoke_evidence_report.rb ...` →
  Markdown 报告包含 `Sensitive Evidence Guard`，JSON 报告包含
  `sensitive_findings` 和 `sensitive_evidence_count`。
- ✅ 在 provider smoke JSON 的 evidence 中放入脱敏测试用 Bearer/token URL 样例 →
  smoke evidence report 应返回 fail，readiness 为 `blocked`，并且报告只输出
  字段位置和 pattern kind，不回显原始密钥或 URL。
- ✅ 运行 `ruby scripts/short_drama_mvp_acceptance_report.rb ...` →
  报告包含 `Smoke Evidence Sensitive Guard`，并把 sensitive findings 纳入
  `handoff_readiness`。
- ⏳ 用真实 some.im / Replicate smoke 留证据时，只记录脱敏 task id、截图、
  本地产物路径或 sanitized request id，不要粘贴 provider token、webhook secret
  或私有 callback URL。

## 1.109.0-rc462 — 短剧 smoke 证据脱敏指南

- ✅ 本版本没有新增短剧制作能力；本轮只把 provider/manual smoke evidence 的脱敏填写说明放进试用包与验收摘要。
- ✅ 运行 `ruby scripts/short_drama_mvp_tryout_package.rb ...` →
  样例包包含 `smoke-evidence-redaction-guide.md`。
- ✅ 打开 `build/ci/short_drama_mvp_tryout_package/smoke-evidence-redaction-guide.md` →
  Markdown 包含 `Allowed Evidence`、`Never Paste` 和 `Sensitive findings: 0`。
- ✅ 打开 `build/ci/short_drama_mvp_tryout_package/handoff-index.md` →
  `Key Files` 包含 `Smoke evidence redaction guide`。
- ✅ 运行 `ruby scripts/short_drama_mvp_acceptance_report.rb ...` →
  Markdown 报告包含 `Smoke Evidence Redaction Guide`，JSON evidence 列表包含 guide 路径。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向
  `1.109.0-rc462 — 短剧 smoke 证据脱敏指南`。

## 1.109.0-rc463 — 短剧 handoff pending reasons

- ✅ 本版本没有新增短剧制作能力；本轮只把交付未 ready 的原因从 `manual_pending`
  拆成可读、可审计的 pending reasons。
- ✅ 运行 `ruby scripts/short_drama_mvp_acceptance_report.rb ...` →
  JSON 报告包含 `handoff_pending_reasons`，Markdown 报告包含
  `Handoff Pending Reasons`。
- ✅ 默认试用包仍未填写 manual/provider smoke JSON 时 →
  `handoff_pending_reasons` 至少包含 `package_manual_results_untested`
  和 `provider_smoke_untested`。
- ✅ 运行 `ruby scripts/version_consistency.rb ...` →
  delivery checks 仍为通过，并检查 acceptance report 保留
  `handoff_pending_reasons` 与 `provider_smoke_untested`。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向
  `1.109.0-rc463 — 短剧 handoff pending reasons`。

## 1.109.0-rc464 — 短剧 acceptance runbook

- ✅ 本版本没有新增短剧制作能力；本轮只把试用包验收命令和 handoff 判定口径收进包内 runbook。
- ✅ 运行 `ruby scripts/short_drama_mvp_tryout_package.rb ...` →
  样例包包含 `acceptance-runbook.md` 和 `acceptance-runbook.json`。
- ✅ 打开 `build/ci/short_drama_mvp_tryout_package/acceptance-runbook.md` →
  Markdown 包含重新生成试用包、smoke evidence report、MVP acceptance report、
  `scripts/run_tests.sh` 和 `Handoff Decision`。
- ✅ 打开 `build/ci/short_drama_mvp_tryout_package/handoff-index.md` →
  `Commands` 包含 acceptance report 与完整本地 gate 入口。
- ✅ 运行 `ruby scripts/short_drama_mvp_acceptance_report.rb ...` →
  Markdown 报告包含 `Acceptance Runbook`，JSON 报告包含 `acceptance_runbook`。
- ✅ 运行 `ruby scripts/version_consistency.rb ...` →
  delivery checks 会检查试用包和 acceptance report 持续保留 acceptance runbook。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向
  `1.109.0-rc464 — 短剧 acceptance runbook`。

## 1.109.0-rc465 — 短剧 smoke evidence readiness matrix

- ✅ 本版本没有新增短剧制作能力；本轮只把 smoke evidence report 的关键 readiness 分支纳入本地和远端合约测试。
- ✅ 运行 `ruby scripts/short_drama_mvp_smoke_evidence_contract_test.rb ...` →
  报告包含 5 个场景：`default_pending`、`ready`、`missing_evidence`、
  `manual_failed` 和 `sensitive_blocked`。
- ✅ `default_pending` 场景保持 `manual_pending`，并输出
  `finish_manual_smoke` 与 `record_provider_smoke_or_keep_risk`。
- ✅ `ready` 场景输出 `ready` 和 `ready_to_handoff`。
- ✅ `missing_evidence` 场景保持 `manual_pending`，并输出 `add_evidence`。
- ✅ `manual_failed` 场景输出 `manual_failed` 和 `resolve_failed_smoke`。
- ✅ `sensitive_blocked` 场景输出 `blocked` 和 `redact_sensitive_evidence`，
  命令非 0，但 Markdown/JSON 不回显 fake bearer value。
- ✅ 运行 `scripts/run_tests.sh` →
  本地一键验收会生成 `short_drama_mvp_smoke_evidence_contract_report.md/json`。
- ✅ GitHub Actions `Tests` workflow →
  远端会运行 `Run short-drama MVP smoke evidence contract guard`，并上传矩阵报告与场景目录。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向
  `1.109.0-rc465 — 短剧 smoke evidence readiness matrix`。

## 1.109.0-rc466 — 短剧 handoff bundle

- ✅ 本版本没有新增短剧制作能力；本轮只把 acceptance report 收敛成可交接的 handoff bundle。
- ✅ 运行 `ruby scripts/short_drama_mvp_handoff_bundle.rb ...` →
  输出 `short_drama_mvp_handoff_bundle.md/json`，包含 `handoff_mode`、
  `ready_for_release`、readiness、blocking items、next actions、handoff files 和 remaining risks。
- ✅ 默认试用包 manual/provider smoke 仍未填写时 →
  `handoff_mode` 应为 `trial_package_with_explicit_pending_reasons`，
  `ready_for_release` 应为 `false`，不会把试用包误标为 ready。
- ✅ 运行 `scripts/run_tests.sh` →
  本地一键验收会在 acceptance report 后生成 handoff bundle。
- ✅ GitHub Actions `Tests` workflow →
  远端会运行 `Generate short-drama MVP handoff bundle`，并把 Markdown/JSON 上传为 artifact。
- ✅ 打开 `build/ci/short_drama_mvp_tryout_package/acceptance-runbook.md` →
  命令列表包含 `short_drama_mvp_handoff_bundle.rb`，required reports 包含
  `short_drama_mvp_handoff_bundle.json`。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向 `1.109.0-rc466 — 短剧 handoff bundle`。

## 1.109.0-rc467 — 短剧 handoff bundle contract

- ✅ 本版本没有新增短剧制作能力；本轮只把 handoff bundle 的关键状态转换纳入本地和远端合约测试。
- ✅ 运行 `ruby scripts/short_drama_mvp_handoff_bundle_contract_test.rb ...` →
  报告包含 5 个场景：`default_trial`、`ready_release`、
  `manual_failed`、`machine_failed` 和 `missing_handoff_evidence`。
- ✅ `default_trial` 场景保持 `trial_package_with_explicit_pending_reasons`，
  且 `ready_for_release=false`。
- ✅ `ready_release` 场景输出 `ready_release_candidate` 和
  `ready_for_release=true`。
- ✅ `manual_failed` 场景保持 trial package，但 `blocking_items` 包含
  `handoff_not_release_ready`。
- ✅ `machine_failed` 场景输出 `blocked_machine_handoff`，命令非 0，
  且 `blocking_items` 包含 `machine_checks_failed`。
- ✅ `missing_handoff_evidence` 场景命令非 0，且 `blocking_items` 包含
  `handoff_evidence_missing`。
- ✅ `scripts/run_tests.sh` 和 GitHub Actions `Tests` workflow →
  都会运行 handoff bundle contract，并上传报告与场景目录。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向
  `1.109.0-rc467 — 短剧 handoff bundle contract`。

## 1.109.0-rc468 — 短剧 handoff file fingerprints

- ✅ 本版本没有新增短剧制作能力；本轮只给 handoff bundle 的交付证据文件补上可追溯元数据。
- ✅ 运行 `ruby scripts/short_drama_mvp_handoff_bundle.rb ...` →
  `handoff_files` 中的普通文件包含 `size_bytes` 和 64 位十六进制 `sha256`，
  目录包含 `file_count`。
- ✅ Markdown `Handoff Files` 小节会显示文件 size、SHA-256 前缀或目录文件数，交接时能快速判断 artifact 是否被覆盖或拿错。
- ✅ 运行 `ruby scripts/short_drama_mvp_handoff_bundle_contract_test.rb ...` →
  `default_trial` 场景包含 `handoff files include fingerprints` 检查。
- ✅ 运行 `ruby scripts/version_consistency.rb ...` →
  delivery checks 会守住 `Digest::SHA256`、`size_bytes`、`sha256`、
  `file_count` 和 contract 中的 fingerprint 检查。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向
  `1.109.0-rc468 — 短剧 handoff file fingerprints`。

## 1.109.0-rc469 — 短剧 handoff todos

- ✅ 本版本没有新增短剧制作能力；本轮只把最终 handoff bundle 的下一步动作收敛成机器可读、可展示的 `handoff_todos`。
- ✅ 运行 `ruby scripts/short_drama_mvp_handoff_bundle.rb ...` →
  JSON 中包含 `handoff_todos`，每条待办都有 `order`、`phase`、`kind`、
  `title`、`detail`、`command` 和 `items`。
- ✅ 默认未补完人工/provider smoke 的 trial 包会包含 `manual_smoke`、
  `provider_smoke` 和 `verify` 阶段，交接人可以按顺序补证据并重新生成
  acceptance / handoff bundle。
- ✅ ready release 场景会包含 `release` 阶段的 `release_candidate_handoff`
  待办，不再只靠 `ready_for_release=true` 让人猜下一步。
- ✅ 运行 `ruby scripts/short_drama_mvp_handoff_bundle_contract_test.rb ...` →
  `default_trial` 场景包含 `handoff todos include manual provider and verify phases`，
  `ready_release` 场景包含 `release todo is present`。
- ✅ 运行 `ruby scripts/version_consistency.rb ...` →
  delivery checks 会守住 `handoff_todos`、`build_handoff_todos`、
  `## Handoff Todos`、`regenerate_acceptance_and_handoff` 和 contract 中的 todo 检查。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向
  `1.109.0-rc469 — 短剧 handoff todos`。

## 1.109.0-rc470 — 短剧 handoff todo evidence

- ✅ 本版本没有新增短剧制作能力；本轮只把 handoff todo 继续补成“点开就知道改哪个文件、跑哪条复验命令”的交接清单。
- ✅ 运行 `ruby scripts/short_drama_mvp_handoff_bundle.rb ...` →
  `handoff_todos` 每条待办包含 `evidence_paths` 和 `verification_command`，
  Markdown `Handoff Todos` 小节会显示 Evidence 与 Verify 行。
- ✅ 默认 trial 包的 manual/provider 待办会指向 `manual-smoke-results-template.json`、
  `provider-api-smoke-template.json` 和 `short_drama_mvp_smoke_evidence_report.rb`
  复验命令。
- ✅ ready release 场景的 release todo 会带证据路径，并用
  `short_drama_mvp_handoff_bundle_contract_test.rb` 作为复验命令。
- ✅ 运行 `ruby scripts/short_drama_mvp_handoff_bundle_contract_test.rb ...` →
  报告包含 `handoff todos point at evidence files`，并继续覆盖
  `release todo is present`。
- ✅ 运行 `ruby scripts/version_consistency.rb ...` →
  delivery checks 会守住 `todo_evidence_paths`、`verification_command`、
  `evidence_paths` 和 contract 中的 todo evidence 检查。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向
  `1.109.0-rc470 — 短剧 handoff todo evidence`。

## 1.109.0-rc471 — 短剧 handoff todo summary

- ✅ 本版本没有新增短剧制作能力；本轮只把交接包的待办列表再收敛成一屏可读的 `handoff_todo_summary`。
- ✅ 运行 `ruby scripts/short_drama_mvp_handoff_bundle.rb ...` →
  JSON 中包含 `handoff_todo_summary`，Markdown `Handoff Todos` 小节顶部显示
  total、phase counts、evidence paths、verification commands、
  machine replay required 和 release todo present。
- ✅ 默认 trial 包的 summary 会显示 `manual_smoke`、`provider_smoke`
  和 `verify` 阶段，并标记 `machine_replay_required=true`。
- ✅ ready release 场景的 summary 会显示 `release` 阶段、
  `release_ready_todo_present=true`，并且不把它误标成 trial replay。
- ✅ 运行 `ruby scripts/short_drama_mvp_handoff_bundle_contract_test.rb ...` →
  报告包含 `handoff todo summary covers trial work` 和
  `handoff todo summary covers ready release`。
- ✅ 运行 `ruby scripts/version_consistency.rb ...` →
  delivery checks 会守住 `handoff_todo_summary`、
  `build_handoff_todo_summary`、`machine_replay_required`、
  `release_ready_todo_present` 和 contract 中的 summary 检查。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向
  `1.109.0-rc471 — 短剧 handoff todo summary`。

## 1.109.0-rc472 — 短剧指针同步 / 编辑器 Paper 当前行高亮修正

- ✅ 本版本没有新增短剧制作能力；短剧 MVP 验收口径延续
  `1.109.0-rc471 — 短剧 handoff todo summary`。
- ✅ 编辑器 Paper 主题当前行高亮从不透明米灰改为低透明品牌绿洗色，
  正文区和行号栏继续复用同一主题色。
- ✅ `EditorCoreBehaviorTests` 新增回归测试，守住 Paper 当前行高亮为低透明、
  偏品牌绿的轻量提示色。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向
  `1.109.0-rc472 — 短剧指针同步 / 编辑器 Paper 当前行高亮修正`。

## 1.109.0-rc473 — 短剧指针同步 / 编辑器软换行行号修正

- ✅ 本版本没有新增短剧制作能力；短剧 MVP 验收口径延续
  `1.109.0-rc471 — 短剧 handoff todo summary`。
- ✅ 编辑器行号尺只在逻辑行起始 fragment 绘制行号，长行软换行延续视觉行
  不再重复显示同一个行号。
- ✅ 当前行高亮按光标所在 TextKit glyph fragment 对齐正文，不再把软换行延续行、
  下一行行号区或行号与文本之间的小缝误染色。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向
  `1.109.0-rc473 — 短剧指针同步 / 编辑器软换行行号修正`。

## 1.109.0-rc474 — 短剧专家激活 / no-workspace 会话迁移

- ✅ Composer 底部显示“专家”入口；默认不激活短剧制作专家。
- ✅ 未激活短剧制作专家时，普通 Agent 请求不暴露 `short_drama_*` 工具。
- ✅ 激活短剧制作专家后，短剧项目创建、分镜、媒体任务和制作包相关工具恢复可用。
- ✅ 在 “No workspace” 会话里先发送一条消息，再通过 composer 选择 workspace；同一会话应移动到所选 workspace 分组，消息历史不丢失。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  主路径第 1 步提示先激活“短剧制作”专家，底部“验收记录”指向
  `1.109.0-rc474 — 短剧专家激活 / no-workspace 会话迁移`。

## 1.109.0-rc475 — 短剧专家单向激活 / 侧栏门禁

- ✅ Composer 底部“专家”入口中，短剧专家默认未激活。
- ✅ 激活短剧专家后，该专家保持勾选且不能再从菜单里变回未激活。
- ✅ 未激活短剧专家时，右侧侧栏菜单不显示“短剧”；外部短剧面板打开请求也不会打开短剧面板。
- ✅ 激活短剧专家后，右侧侧栏菜单恢复“短剧”入口，短剧面板可正常打开。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向
  `1.109.0-rc475 — 短剧专家单向激活 / 侧栏门禁`。

## 1.109.0-rc476 — 短剧指针同步 / 终端捷径录制

- ✅ 本版本没有新增短剧制作能力；短剧 MVP 验收口径延续
  `1.109.0-rc471 — 短剧 handoff todo summary`。
- ✅ Agent 右侧终端面板标签上方显示录制按钮；开始录制后在终端输入可记录为捷径。
- ✅ 停止录制后生成的终端捷径显示在终端标签上方，可点击回放到当前终端。
- ✅ 终端捷径菜单支持改名和删除。
- ✅ 在登录/密码等不回显输入阶段录制时，隐藏输入保存为受保护片段；回放时只有当前终端也处于不回显状态才会输入。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向
  `1.109.0-rc476 — 短剧指针同步 / 终端捷径录制`。

## 1.109.0-rc477 — 短剧指针同步 / Composer 更多设置专家入口

- ✅ 本版本没有新增短剧制作能力；短剧 MVP 验收口径延续
  `1.109.0-rc471 — 短剧 handoff todo summary`。
- ✅ Composer 底部“更多设置”中显示专家开关列表，短剧制作专家默认关闭。
- ✅ 打开短剧制作专家开关后，该专家保持开启且不能再关闭。
- ✅ Composer 宽度充足时，执行器、插件、专家会逐步从“更多设置”直接显示到底部控制行。
- ✅ Composer 宽度不足时，执行器、插件、专家仍收进“更多设置”，不挤压左侧会话栏和输入区。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向
  `1.109.0-rc477 — 短剧指针同步 / Composer 更多设置专家入口`。

## 1.109.0-rc478 — 短剧指针同步 / 终端输入延迟修复

- ✅ 本版本没有新增短剧制作能力；短剧 MVP 验收口径延续
  `1.109.0-rc471 — 短剧 handoff todo summary`。
- ✅ Agent 右侧终端未开始录制时，普通键入不触发录制用 echo 状态查询。
- ✅ 点击“开始录制”后，终端输入仍能记录为捷径，echo-off 输入仍作为受保护片段处理。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向
  `1.109.0-rc478 — 短剧指针同步 / 终端输入延迟修复`。

## 1.109.0-rc481 — 短剧指针同步 / Agent 启动性能修复

- ✅ 本版本没有新增短剧制作能力；短剧 MVP 验收口径延续
  `1.109.0-rc471 — 短剧 handoff todo summary`。
- ✅ Agent 右侧侧栏打开时，窗口不会在同一帧同步强制 resize / redraw。
- ✅ 打开终端侧栏时，侧栏壳子先出现，默认本地 shell 延后启动，不再把点击反馈拖到 shell 启动完成后。
- ✅ Agent 右侧终端未开始录制时，普通键入不触发录制用 echo 状态查询。
- ✅ 开始录制后，连续普通键入复用 echo 状态缓存；终端收到非预期输出、缓存过期或进程重启后才重新读取 echo 状态。
- ✅ echo-off 输入仍作为受保护片段处理，并且只能在回放时当前终端也处于 echo-off 状态才输入。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向
  `1.109.0-rc481 — 短剧指针同步 / Agent 启动性能修复`。

## 1.109.0-rc483 — 短剧指针同步 / 终端捷径落盘持久化

- ✅ 本版本没有新增短剧制作能力；短剧 MVP 验收口径延续
  `1.109.0-rc471 — 短剧 handoff todo summary`。
- ✅ 终端录制生成的捷径写入 `Application Support/WillDeep/terminal-shortcuts/shortcuts.json`，退出 App 后重新进入仍显示。
- ✅ 旧版 `com.willdeep.terminalShortcuts.v1` 数据首次读取时会迁移到新 JSON 文件。
- ✅ 终端捷径改名后立即落盘，重启后仍显示新标题。
- ✅ echo-off 输入仍只落 Keychain 引用，`shortcuts.json` 不包含密码/Token 明文。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向
  `1.109.0-rc483 — 短剧指针同步 / 终端捷径落盘持久化`。

## 1.109.0-rc484 — 短剧指针同步 / 等待审批不开右栏

- ✅ 本版本没有新增短剧制作能力；短剧 MVP 验收口径延续
  `1.109.0-rc471 — 短剧 handoff todo summary`。
- ✅ Agent 工具调用进入等待审批、危险确认或 `ask_user` 等用户输入状态时，chat 区显示内联审批卡片，右侧任务监控不会因此自动展开。
- ✅ 用户手动打开任务监控时，仍能看到等待审批相关状态。
- ✅ 后台任务、上下文压缩、媒体任务、待办、工作文件和学习事件仍按原逻辑触发任务监控自动展开。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向
  `1.109.0-rc484 — 短剧指针同步 / 等待审批不开右栏`。

## 1.109.0-rc485 — 短剧指针同步 / 审查窗口不抢焦点

- ✅ 本版本没有新增短剧制作能力；短剧 MVP 验收口径延续
  `1.109.0-rc471 — 短剧 handoff todo summary`。
- ✅ Agent composer 底部“审查”按钮本身不可聚焦。
- ✅ 审查 diff 预览窗口打开后，标题、复制/关闭按钮、分隔线、滚动 diff 文本和外层容器都不会接收 SwiftUI 焦点。
- ✅ 复制按钮仍能把完整 diff 写入剪贴板；关闭按钮仍能关闭窗口。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向
  `1.109.0-rc485 — 短剧指针同步 / 审查窗口不抢焦点`。

## 1.109.0-rc486 — 短剧指针同步 / 变更列表默认收起

- ✅ 本版本没有新增短剧制作能力；短剧 MVP 验收口径延续
  `1.109.0-rc471 — 短剧 handoff todo summary`。
- ✅ Agent composer 上方默认只显示“xx 个文件已更改 +x -y 审查”吸附栏，不显示前 3 个文件列表。
- ✅ 点击“审查”后的展开图标后，文件列表卡片出现，并继续支持“再显示 N 个文件”。
- ✅ 再次点击收起图标后，文件列表卡片隐藏，“审查”仍可打开完整 diff。
- ✅ 切换到另一个 Agent session 时，文件列表展开状态不会串到新会话。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向
  `1.109.0-rc486 — 短剧指针同步 / 变更列表默认收起`。

## 1.109.0-rc487 — 短剧指针同步 / Agent 变更归因

- ✅ 本版本没有新增短剧制作能力；短剧 MVP 验收口径延续
  `1.109.0-rc471 — 短剧 handoff todo summary`。
- ✅ 启动一轮 Agent 对话时，右侧“产物”和底部“xx 个文件已更改”不会展示本轮开始前已经存在的本地脏文件。
- ✅ `run_command` 或补丁工具真正改动文件后，只把相对基线发生变化的路径归因到当前会话。
- ✅ 审查 diff 预览只包含已归因文件，不混入用户原有未归因改动。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向
  `1.109.0-rc487 — 短剧指针同步 / Agent 变更归因`。

## 1.109.0-rc488 — 短剧指针同步 / Agent 受保护机密

- ✅ 本版本没有新增短剧制作能力；短剧 MVP 验收口径延续
  `1.109.0-rc471 — 短剧 handoff todo summary`。
- ✅ Agent composer 的受保护机密占位符只影响通用 Agent 工具执行边界，不改变短剧项目、分镜、制作包、Widget、handoff bundle 和 smoke evidence 合约。
- ✅ 工具结果、后台任务输出和错误消息会脱敏 `${secret:...}` 解析出的真实值；短剧 smoke evidence 仍按既有敏感信息守门处理证据。
- ✅ XCTest 默认使用内存凭据仓库，避免短剧/Agent 测试宿主触发真实 `com.willdeep.credentials` 钥匙串弹窗。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向
  `1.109.0-rc488 — 短剧指针同步 / Agent 受保护机密`。

## 1.109.0-rc489 — 短剧指针同步 / 终端总是允许

- ✅ 本版本没有新增短剧制作能力；短剧 MVP 验收口径延续
  `1.109.0-rc471 — 短剧 handoff todo summary`。
- ✅ `terminal_send_command` 审批卡片可显示“总是允许”，并按完整命令行记忆。
- ✅ `terminal_send_control` 审批卡片可显示“总是允许”，并按 `ctrl_c` / `enter` / `escape` 分别记忆。
- ✅ 允许 `ctrl_c` 不会自动允许 `enter` 或其它终端控制键。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向
  `1.109.0-rc489 — 短剧指针同步 / 终端总是允许`。

## 1.109.0-rc490 — 短剧指针同步 / Agent secret 加固

- ✅ 本版本没有新增短剧制作能力；短剧 MVP 验收口径延续
  `1.109.0-rc471 — 短剧 handoff todo summary`。
- ✅ Agent secret 占位符改为纯随机 ID，不暴露用户填写的 label；委托型 AI 执行器不会解析 `${secret:...}` 明文。
- ✅ Keychain envelope 会保留 secret 原文，URL/base64 transform 和工具回传脱敏不改变短剧制作包、Widget、handoff bundle 与 smoke evidence 合约。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向
  `1.109.0-rc490 — 短剧指针同步 / Agent secret 加固`。

## 1.109.0-rc491 — 短剧指针同步 / SSH 远端只读

- ✅ 本版本没有新增短剧制作能力；短剧 MVP 验收口径延续
  `1.109.0-rc471 — 短剧 handoff todo summary`。
- ✅ Agent `run_command` 的 SSH 风险识别只影响通用命令授权边界，不改变短剧项目、分镜、制作包、Widget、handoff bundle 和 smoke evidence 合约。
- ✅ `ssh host cat /var/log/...`、`ssh host ping ...` 会按远端只读命令处理；远端 `rm -rf`、读取 `~/.ssh/id_rsa` 和交互式 `ssh host` 仍需要人工授权或危险确认。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向
  `1.109.0-rc491 — 短剧指针同步 / SSH 远端只读`。

## 1.109.0-rc492 — 短剧指针同步 / 终端快照一屏

- ✅ 本版本没有新增短剧制作能力；短剧 MVP 验收口径延续
  `1.109.0-rc471 — 短剧 handoff todo summary`。
- ✅ Agent `terminal_snapshot` 只影响侧边栏终端上下文读取，不改变短剧项目、分镜、制作包、Widget、handoff bundle 和 smoke evidence 合约。
- ✅ 侧边栏终端快照默认只读取 live 底部可见屏幕，不再把最近 scrollback/history 一起送进模型上下文。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向
  `1.109.0-rc492 — 短剧指针同步 / 终端快照一屏`。

## 1.109.0-rc493 — 短剧指针同步 / 请求详情截断

- ✅ 本版本没有新增短剧制作能力；短剧 MVP 验收口径延续
  `1.109.0-rc471 — 短剧 handoff todo summary`。
- ✅ Agent 错误详情面板只影响请求排查 UI，不改变短剧项目、分镜、制作包、Widget、handoff bundle 和 smoke evidence 合约。
- ✅ 超长 request summary / request body 在 UI 中间省略，仍可复制完整详情排查服务商 HTTP 错误。
- ✅ 打开 [SHORT_DRAMA_AI_MVP_TRYOUT.md](SHORT_DRAMA_AI_MVP_TRYOUT.md) →
  底部“验收记录”指向
  `1.109.0-rc493 — 短剧指针同步 / 请求详情截断`。

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
