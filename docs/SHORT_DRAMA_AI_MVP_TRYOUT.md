# Short Drama AI MVP Tryout

> Last updated: 2026-06-29 | Baseline version: v1.109.0-rc468

这份文档用于试用当前短剧 AI MVP。它不是完整产品手册，只覆盖“不完美但可用”的主路径。

## 试用前准备

- 打开 `build/DerivedData/Build/Products/Debug/WillDeep.app`，或使用同版本打包产物。
- 在 Settings 里配置可用的 Agent 模型。
- 如需真实提交媒体任务，配置 some.im / Replicate 相关 token 和 workflow version。
- 如果不想打真实外网 API，可以只走 dry-run、manifest 导入和本地 Widget 验证。
- 如果还没有真实短剧项目，可先运行本地试用包生成器：

```bash
ruby scripts/short_drama_mvp_tryout_package.rb \
  build/ci/short_drama_mvp_tryout_package \
  build/ci/short_drama_mvp_tryout_package_report.md \
  build/ci/short_drama_mvp_tryout_package_report.json
```

## 主路径

1. 切到 Agent 模式，创建或打开一个短剧项目。
2. 在短剧侧栏确认能看到集、分镜、人物、场景和制作缺口。
3. 点击制作缺口里的「补主图」「补视频」或「审片」。
4. 检查聊天输入框里的结构化上下文：
   - `<short-drama-production-gap-action>`
   - `dry_run_arguments`
   - `submit_arguments`
   - `open_tasks_arguments`
   - `refresh_tasks_arguments`
5. 先让 Agent 执行 dry-run，确认范围合理后再正式提交。
6. 打开媒体任务侧栏，观察 pending / running / failed / completed 状态。
7. 刷新任务后，下一轮聊天应能接收到 `latest-media-task-refresh`。
8. 任务完成或 manifest 导回后，下一轮聊天应能接收到：
   - `latest-media-task-completion`
   - 或 `latest-media-import`
9. 如果有多张图片，打开候选图 Widget，选择一张图。
10. 对选中图片继续做设主图、图生视频、蒙版编辑、擦除或放大。

## 制作包路径

1. 在短剧侧栏导出制作包；或者使用 `build/ci/short_drama_mvp_tryout_package` 作为本地样例包。
2. 打开右侧 Widget 预览 `widget-preview.html`。
3. 如果使用 Ruby 或第三方 API 脚本，先看导出的：
   - `production-timeline.json`
   - `production-gap-report.json`
   - `production-shot-list.csv`
   - `media-import-manifest-template.json`
   - `production-review-template.csv`
   - `production-review-queue.csv`
4. 脚本生成本地产物后，调用 `import_media_manifest` 正式导回。
5. 脚本只提交远端异步任务、尚无本地产物时，调用：

```text
import_media_manifest(package_directory=<制作包目录>, dry_run=false, import_pending_tasks=true)
```

6. 导回后检查媒体任务侧栏，并确认聊天下一轮包含 `latest-media-import`。

## 本地试用包路径

1. 运行 `scripts/short_drama_mvp_tryout_package.rb`。
2. 先打开 `build/ci/short_drama_mvp_tryout_package/handoff-index.md`，按 start-here 顺序确认包内入口、命令、关键文件和剩余风险。
3. 再打开 `build/ci/short_drama_mvp_tryout_package/manual-smoke-checklist.md`，按包内清单记录 dry-run、正式导入、媒体任务侧栏和 Widget 动作结果。
4. 将人工验收结果填到 `build/ci/short_drama_mvp_tryout_package/manual-smoke-results-template.md` 或 `manual-smoke-results-template.json`；标为 pass/fail 的步骤必须保留截图、任务 ID 或聊天上下文片段作为 evidence。
5. 如具备真实 some.im / Replicate 账号、额度和网络，再把真实 provider smoke 结果填到 `provider-api-smoke-template.md/json`；不要记录 token、webhook secret 或私有回调 URL。
6. 填完任一 JSON 后运行 smoke 证据自检报告，确认失败、缺 evidence、待测项和 `next_actions` 都能在报告中看到：

```bash
ruby scripts/short_drama_mvp_smoke_evidence_report.rb \
  build/ci/short_drama_mvp_tryout_package \
  build/ci/short_drama_mvp_smoke_evidence_report.md \
  build/ci/short_drama_mvp_smoke_evidence_report.json
```

7. 打开 `build/ci/short_drama_mvp_tryout_package/widget-preview.html`，或在聊天里调用 `show_widget` 指向该 HTML。Widget 顶部的结构化按钮会通过 `sendToolAction` 把工具名和参数交回聊天窗口。
8. 先 dry-run：

```text
import_media_manifest(package_directory=build/ci/short_drama_mvp_tryout_package, dry_run=true, import_pending_tasks=true)
```

9. 再正式导入：

```text
import_media_manifest(package_directory=build/ci/short_drama_mvp_tryout_package, dry_run=false, import_pending_tasks=true)
```

10. 预期能看到 3 个本地产物、1 个 pending 远端视频任务、1 个 failed 修复任务；Widget/媒体任务侧栏会给出继续查看任务、按缺口排产和回写 review queue 的入口。
11. 点击 Widget 里的 `Dry-run import`、`Import manifest` 或 `Review queue`，确认聊天输入框收到的是结构化 `<widget-handoff-action>`，而不是只能靠自然语言 prompt 猜工具。
12. 运行 `scripts/short_drama_mvp_smoke_evidence_contract_test.rb`，确认默认未测、ready、缺 evidence、manual_failed 和 sensitive blocked 五种 smoke evidence readiness 分支都通过。
13. 运行 `scripts/short_drama_mvp_acceptance_report.rb`，确认生成的 `build/ci/short_drama_mvp_acceptance_report.md/json` 汇总了版本报告、试用包报告、Handoff Index、Acceptance Runbook、手动 smoke 模板、包内手测结果文件状态、pass/fail 步骤证据缺口、provider API smoke 模板、standalone smoke 证据自检报告、Smoke Evidence Readiness Matrix、Smoke Evidence Next Actions、当前手动 smoke 队列状态、交付就绪状态、非空剩余风险和交付文档入口。
14. 运行 `scripts/short_drama_mvp_handoff_bundle.rb`，确认生成的 `build/ci/short_drama_mvp_handoff_bundle.md/json` 显示 `handoff_mode`、`ready_for_release`、交付证据文件、阻塞项和下一步动作；未补完人工 smoke 时应是 trial package，而不是误称 ready。
15. 运行 `scripts/short_drama_mvp_handoff_bundle_contract_test.rb`，确认默认 trial、ready release、manual_failed、machine_failed、missing evidence 和 handoff file fingerprints 都通过，避免交接包把机器失败、人工失败、缺证据和文件被覆盖混成同一种状态。

## 图片编辑路径

1. 从候选图、媒体任务缩略图或检查项打开图片编辑器。
2. 画蒙版区域。
3. 点「发送到聊天」，确认上下文包含真实 `mask_path`。
4. 让 Agent 调用 `edit_image_with_mask`。
5. 提交后打开媒体任务侧栏查看 Replicate / some.im 编辑任务状态。

## 已知限制

- 当前 MVP 不承诺完整剪辑/NLE 自动装配。
- 当前 MVP 不新增更多 provider 专用 UI。
- 真实 some.im / Replicate 任务依赖外部账号、额度、网络和 provider 当前 API 行为。
- CI 只验证本地合约和构建；真实 API smoke 需要人工执行。

## 验收记录

人工 smoke 结果请记录到 [MANUAL_TEST_QUEUE.md](MANUAL_TEST_QUEUE.md) 的 `1.109.0-rc468 — 短剧 handoff file fingerprints` 小节。
