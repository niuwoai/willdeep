# Short Drama AI MVP Cutoff

> Last updated: 2026-06-28 | Baseline version: v1.109.0-rc452

## 收敛结论

当前目标先冻结为一个“不完美，但是可用”的 MVP。后续不再继续扩张新能力，优先做稳定化、验收、打包和交付说明。

## MVP 已纳入范围

- some.im 异步图片/视频任务接入统一媒体任务侧栏，支持创建、轮询、取消、完成产物导回和任务状态筛选。
- Replicate 图片放大、蒙版重绘、擦除等编辑任务接入媒体任务体系，并保留短剧分镜、资产和检查项锚点。
- 聊天窗口可接收最近一次媒体任务完成、刷新、图片选择、图片编辑提交、Widget 工具动作和 manifest 导回上下文。
- 右侧侧栏支持媒体任务、网页 Widget、图片蒙版编辑器和短剧项目管理。
- Widget 支持 `sendToolAction` 结构化回传，Skill/Ruby 生成的本地 HTML 可以嵌入右侧网页组件。
- 短剧项目支持集、分镜、人物、场景、参考图、候选图、制作缺口、检查项和制作包导出。
- 制作包支持 Ruby/第三方 API 脚本导出、manifest 导回、pending 远端任务登记、Widget 预览和审片 CSV 回写。
- 关键链路已建立 Ruby 合约测试，并接入本地 `scripts/run_tests.sh` 和 GitHub Actions；`short_drama_mvp_acceptance_report` 会汇总版本、试用包、手测模板、包内手测结果文件、当前手动 smoke 状态、交付就绪状态、剩余风险和交付文档证据；`version_consistency` 会守住交付就绪/剩余风险摘要不被删漏，并要求 cutoff 保留显式剩余风险条目。
- 本地可试用包生成器 `scripts/short_drama_mvp_tryout_package.rb` 可生成不调用外网 API 的制作包样例，用于 dry-run/import/Widget/review queue 手动 smoke；样例 Widget 使用 `sendToolAction` 回传结构化工具动作，包内包含 `manual-smoke-checklist.md` 和 `manual-smoke-results-template.md/json` 方便人工验收留证据。

## MVP 暂缓范围

- 不继续新增第三方 API provider 的专用 UI。
- 不继续扩展复杂剪辑/NLE 自动装配能力。
- 不继续扩展完整短剧工业化排产系统。
- 不继续拆更多大文件，除非构建或测试硬性失败。
- 不继续做真实外网 API 端到端调用，交付前只验证本地合约、构建和手动 smoke 流程。

## 可用版验收清单

最近一次执行：2026-06-28，基线 `v1.109.0-rc452`，以下命令均通过；Xcode 构建仅保留既有 warning。

- `scripts/run_tests.sh`
- `ruby scripts/version_consistency.rb build/version_report.md build/version_report.json`
- `ruby scripts/complexity_guard.rb build/ci/complexity_report.md build/ci/complexity_report.json`
- `ruby scripts/short_drama_media_contract_test.rb build/ci/short_drama_media_report.md build/ci/short_drama_media_report.json`
- `ruby scripts/media_import_context_contract_test.rb build/ci/media_import_context_report.md build/ci/media_import_context_report.json`
- `ruby scripts/media_task_refresh_contract_test.rb build/ci/media_task_refresh_report.md build/ci/media_task_refresh_report.json`
- `ruby scripts/production_gap_actions_contract_test.rb build/ci/production_gap_actions_report.md build/ci/production_gap_actions_report.json`
- `ruby scripts/widget_side_panel_contract_test.rb build/ci/widget_side_panel_report.md build/ci/widget_side_panel_report.json`
- `ruby scripts/image_edit_contract_test.rb build/ci/image_edit_report.md build/ci/image_edit_report.json`
- `ruby scripts/short_drama_mvp_tryout_package.rb build/ci/short_drama_mvp_tryout_package build/ci/short_drama_mvp_tryout_package_report.md build/ci/short_drama_mvp_tryout_package_report.json`
- `ruby scripts/short_drama_mvp_acceptance_report.rb build/ci/short_drama_mvp_acceptance_report.md build/ci/short_drama_mvp_acceptance_report.json`
- `xcodebuild -quiet -project Xedit.xcodeproj -scheme Xedit -configuration Debug -destination 'platform=macOS' -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build`
- GitHub Actions `Tests` workflow 的 `Run Go agent tests`（`go test ./...`，working directory: `willdeep-agent`）和 `Run XeditTests` 均通过。

## 手动 smoke 场景

- 创建或打开一个短剧项目，确认侧栏能看到集、分镜、人物、场景和制作缺口。
- 从缺口动作点击补主图/补视频/审片，确认聊天输入框出现对应结构化动作块。
- 提交或导入一个 pending 媒体任务，确认媒体任务侧栏展示状态，并可刷新。
- 打开候选图 Widget，选择一张图，确认聊天能接收到所选图和后续动作。
- 打开图片蒙版编辑器，画选区并发送到聊天，确认包含真实 `mask_path`。
- 导出制作包并打开 `widget-preview.html`，确认 Widget 侧栏展示来源和可用动作。
- 使用 `import_media_manifest(import_pending_tasks=true)` 导回 manifest，确认下一轮聊天能看到 `latest-media-import`。
- 或运行本地试用包生成器，使用 `build/ci/short_drama_mvp_tryout_package/manual-smoke-checklist.md` 验证 dry-run 导入、pending 任务登记、Widget handoff 和 review queue 回写入口，并把结果记录到包内 `manual-smoke-results-template.md/json`。

## 下一步策略

1. 只修构建、测试、明显崩溃和验收流程问题。
2. 保持 `1.109.0` MVP 基线，若继续改代码只递增 rc。
3. 使用 `scripts/short_drama_mvp_tryout_package.rb` 生成本地试用包，并继续补齐人工 smoke 记录。
4. 后续新增能力另起版本，不再塞进本轮 MVP。

## 当前剩余风险

- 未在本轮收口中调用真实 some.im / Replicate 外网 API，只验证本地工具链、上下文接力、任务登记、构建和合约。
- 本地试用包只验证 manifest/Widget/review queue 形态，不能替代真实 provider 账号、额度、网络和 API 行为验证。
- `scripts/short_drama_media_contract_test.rb` 接近 3000 行硬线，后续不要继续往里追加检查。
- `Xedit/AgentShortDramaProductionExporter.swift` 接近 3000 行硬线，后续只修 bug，不继续扩展。
