# 历史变更记录 8

[返回当前变更记录](../../CHANGELOG.md)

## 1.109.0-rc468 - 2026-06-29

### Changed
- **短剧 handoff file fingerprints（1.109.0-rc468）** —— `scripts/short_drama_mvp_handoff_bundle.rb` 的 `handoff_files` 现在会为普通文件输出 `size_bytes` 与 SHA-256，为目录输出 `file_count`。
- `scripts/short_drama_mvp_handoff_bundle_contract_test.rb` 的 default_trial 场景新增 `handoff files include fingerprints` 检查，守住文件指纹和目录计数。
- `scripts/version_consistency.rb` 新增守门，确保 handoff bundle 持续保留 `Digest::SHA256`、`size_bytes`、`sha256`、`file_count` 和 contract 中的 fingerprint 检查。
- `SHORT_DRAMA_AI_MVP_CUTOFF.md`、`SHORT_DRAMA_AI_MVP_TRYOUT.md` 和 `MANUAL_TEST_QUEUE.md` 同步把当前人工验收入口更新为 `1.109.0-rc468 — 短剧 handoff file fingerprints`。
- 版本号从 **1.109.0-rc467** 提升为 **1.109.0-rc468**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / Mobile Gateway / Agent Harness 与短剧验收指针同步。

## 1.109.0-rc467 - 2026-06-29

### Changed
- **短剧 handoff bundle contract（1.109.0-rc467）** —— 新增 `scripts/short_drama_mvp_handoff_bundle_contract_test.rb`，用本地 acceptance JSON 构造默认 trial、ready release、manual_failed、machine_failed 和 missing evidence 五种交接包状态。
- 新合约会验证 `handoff_mode`、`ready_for_release`、blocking items、next actions 和命令退出码，防止后续把机器失败、人工失败、缺交付证据和 ready 状态混成同一种结论。
- `scripts/run_tests.sh` 和 GitHub Actions `Tests` workflow 接入该合约，并把 `short_drama_mvp_handoff_bundle_contract_report.md/json` 与场景目录上传为 artifacts。
- `scripts/version_consistency.rb` 新增守门，确保本地/远端 acceptance 持续运行 handoff bundle 状态矩阵。
- `SHORT_DRAMA_AI_MVP_CUTOFF.md`、`SHORT_DRAMA_AI_MVP_TRYOUT.md` 和 `MANUAL_TEST_QUEUE.md` 同步把当前人工验收入口更新为 `1.109.0-rc467 — 短剧 handoff bundle contract`。
- 版本号从 **1.109.0-rc466** 提升为 **1.109.0-rc467**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / Mobile Gateway / Agent Harness 与短剧验收指针同步。

## 1.109.0-rc466 - 2026-06-29

### Changed
- **短剧 handoff bundle（1.109.0-rc466）** —— 新增 `scripts/short_drama_mvp_handoff_bundle.rb`，读取 acceptance report 后生成最终交接包 Markdown/JSON。
- handoff bundle 会输出 `handoff_mode`、`ready_for_release`、readiness、blocking items、next actions、handoff files 和 remaining risks；默认未补完 manual/provider smoke 的试用包会明确显示为 `trial_package_with_explicit_pending_reasons`，不会误称 ready。
- `scripts/run_tests.sh` 和 GitHub Actions `Tests` workflow 接入 handoff bundle，并把 `short_drama_mvp_handoff_bundle.md/json` 写入 job summary 与 artifacts。
- 试用包 `acceptance-runbook.md/json` 与 `handoff-index.md/json` 增加 handoff bundle 命令和 required report 指针，接手人可从包内直接跑完整交付索引。
- `scripts/version_consistency.rb` 新增守门，确保本地/远端 acceptance 持续生成 handoff bundle，且脚本保留交付模式、证据文件、下一步动作和剩余风险。
- `SHORT_DRAMA_AI_MVP_CUTOFF.md`、`SHORT_DRAMA_AI_MVP_TRYOUT.md` 和 `MANUAL_TEST_QUEUE.md` 同步把当前人工验收入口更新为 `1.109.0-rc466 — 短剧 handoff bundle`。
- 版本号从 **1.109.0-rc465** 提升为 **1.109.0-rc466**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / Mobile Gateway / Agent Harness 与短剧验收指针同步。

## 1.109.0-rc465 - 2026-06-29

### Changed
- **短剧 smoke evidence readiness matrix（1.109.0-rc465）** —— 新增 `scripts/short_drama_mvp_smoke_evidence_contract_test.rb`，用本地试用包构造默认未测、ready、缺 evidence、manual_failed 和 sensitive blocked 五种 smoke evidence 场景。
- 新合约会验证 readiness、`next_actions` 和 sensitive evidence 脱敏输出，确保 raw fake bearer value 不进入 Markdown/JSON 报告。
- `scripts/run_tests.sh` 和 GitHub Actions `Tests` workflow 接入该合约，并把 `short_drama_mvp_smoke_evidence_contract_report.md/json` 与场景目录上传为 artifacts。
- `scripts/short_drama_mvp_acceptance_report.rb` 新增 `Smoke Evidence Readiness Matrix` 小节和 JSON `smoke_evidence_contract_report` 证据，总验收报告会显示矩阵场景结果。
- `scripts/version_consistency.rb` 新增守门，确保本地/远端 acceptance 持续运行 smoke evidence readiness matrix，并确保 acceptance report 持续展示该矩阵。
- `SHORT_DRAMA_AI_MVP_CUTOFF.md`、`SHORT_DRAMA_AI_MVP_TRYOUT.md` 和 `MANUAL_TEST_QUEUE.md` 同步把当前人工验收入口更新为 `1.109.0-rc465 — 短剧 smoke evidence readiness matrix`。
- 版本号从 **1.109.0-rc464** 提升为 **1.109.0-rc465**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / Mobile Gateway / Agent Harness 与短剧验收指针同步。

## 1.109.0-rc464 - 2026-06-29

### Changed
- **短剧 acceptance runbook（1.109.0-rc464）** —— `scripts/short_drama_mvp_tryout_package.rb` 现在会在试用包内生成 `acceptance-runbook.md/json`，列出重新生成试用包、smoke evidence report、MVP acceptance report 和完整本地 gate 的命令。
- `handoff-index.md/json` 增加 acceptance report 与 `scripts/run_tests.sh` 入口；接手人不用从多份文档里手动拼验收顺序。
- `scripts/short_drama_mvp_acceptance_report.rb` 新增 `Acceptance Runbook` 小节和 JSON `acceptance_runbook` 证据，验收报告会检查 runbook schema、关键命令和 `manual_pending` 判定口径。
- `scripts/version_consistency.rb` 新增守门，确保试用包持续保留 acceptance runbook，且 acceptance report 持续展示该交付入口。
- `SHORT_DRAMA_AI_MVP_CUTOFF.md`、`SHORT_DRAMA_AI_MVP_TRYOUT.md` 和 `MANUAL_TEST_QUEUE.md` 同步把当前人工验收入口更新为 `1.109.0-rc464 — 短剧 acceptance runbook`。
- 版本号从 **1.109.0-rc463** 提升为 **1.109.0-rc464**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / Mobile Gateway / Agent Harness 与短剧验收指针同步。

## 1.109.0-rc463 - 2026-06-29

### Changed
- **短剧 handoff pending reasons（1.109.0-rc463）** —— `scripts/short_drama_mvp_acceptance_report.rb` 现在输出 `handoff_pending_reasons` 和 Markdown 的 `Handoff Pending Reasons` 小节，明确列出机器检查失败、手测队列 pending、包内 manual smoke 未测、provider smoke 未测、证据缺失或 sensitive guard 阻断等原因。
- 交付报告不再只给 `manual_pending` 结论；接手人可以直接看到下一步要填哪几个包内手测步骤、是否只是保留真实 provider 外网风险。
- `scripts/version_consistency.rb` 新增守门，确保 handoff pending reasons 和 provider smoke untested 原因持续保留。
- `SHORT_DRAMA_AI_MVP_CUTOFF.md`、`SHORT_DRAMA_AI_MVP_TRYOUT.md` 和 `MANUAL_TEST_QUEUE.md` 同步把当前人工验收入口更新为 `1.109.0-rc463 — 短剧 handoff pending reasons`。
- 版本号从 **1.109.0-rc462** 提升为 **1.109.0-rc463**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / Mobile Gateway / Agent Harness 与短剧验收指针同步。

## 1.109.0-rc462 - 2026-06-29

### Changed
- **短剧 smoke 证据脱敏指南（1.109.0-rc462）** —— `scripts/short_drama_mvp_tryout_package.rb` 现在会在试用包内生成 `smoke-evidence-redaction-guide.md`，明确 allowed evidence、Never Paste 和被 sensitive guard 阻断后的修复步骤。
- Widget 预览、manual smoke checklist、provider API smoke 模板、handoff index、tryout package report 和 acceptance report 都会暴露该指南路径，交接人不用靠口头记忆判断哪些 evidence 能写。
- `scripts/version_consistency.rb` 新增守门，确保试用包和 acceptance report 持续保留 smoke evidence redaction guide。
- `SHORT_DRAMA_AI_MVP_CUTOFF.md`、`SHORT_DRAMA_AI_MVP_TRYOUT.md` 和 `MANUAL_TEST_QUEUE.md` 同步把当前人工验收入口更新为 `1.109.0-rc462 — 短剧 smoke 证据脱敏指南`。
- 版本号从 **1.109.0-rc461** 提升为 **1.109.0-rc462**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / Mobile Gateway / Agent Harness 与短剧验收指针同步。

## 1.109.0-rc461 - 2026-06-29

### Security
- **短剧 smoke 证据敏感信息守门（1.109.0-rc461）** —— `scripts/short_drama_mvp_smoke_evidence_report.rb` 现在会扫描手测/provider smoke JSON 中的 API key、Bearer token、webhook secret、`sk-` 风格密钥、带签名或 token 的 URL，并在报告中只输出脱敏定位信息。
- `scripts/short_drama_mvp_acceptance_report.rb` 会把 sensitive findings 纳入 `handoff_readiness`；一旦 evidence 中出现疑似密钥或私有回调 URL，交付状态直接变为 `blocked`。
- `scripts/version_consistency.rb` 新增守门，确保 standalone smoke evidence report 与 acceptance report 持续保留敏感信息扫描、脱敏输出和 `Smoke Evidence Sensitive Guard` 小节。
- `SHORT_DRAMA_AI_MVP_CUTOFF.md`、`SHORT_DRAMA_AI_MVP_TRYOUT.md` 和 `MANUAL_TEST_QUEUE.md` 同步把当前人工验收入口更新为 `1.109.0-rc461 — 短剧 smoke 证据敏感信息守门`。
- 版本号从 **1.109.0-rc460** 提升为 **1.109.0-rc461**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / Mobile Gateway / Agent Harness 与短剧验收指针同步。

## 1.109.0-rc460 - 2026-06-28

### Fixed
- **长消息预览保留头尾（1.109.0-rc460）** —— Agent 正在流式输出的超长消息不再只显示前 3000 字符，而是在同一预算内保留消息开头和结尾，并在中间插入省略提示，避免结论、报错或用户最后要求被截掉。
- 截断提示文案改为明确显示“保留前后片段 / 省略字符数”，中英文 i18n 同步更新；新增单测覆盖头尾保留预览行为。
- **编辑器选区内存稳定化（1.109.0-rc460）** —— Editor 模式选中文本时不再把完整选区文本作为 `@Published` 状态广播，避免拖选过程中反复刷新 Agent/sidebar 视图树并放大内存分配。
- 选区行号、选中行数计算改为直接在 `NSString` 上扫描，不再为每次选区变化创建 prefix/selected 子串数组；实时发布给 Agent 上下文的选区文本按 6000 字符预算截断，完整右键附件流程保持原逻辑。
- 版本号从 **1.109.0-rc458** 提升为 **1.109.0-rc460**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / Mobile Gateway / Agent Harness 与短剧验收指针同步。

## 1.109.0-rc458 - 2026-06-28

### Changed
- **短剧试用包交付索引（1.109.0-rc458）** —— `scripts/short_drama_mvp_tryout_package.rb` 现在会在样例包内生成 `handoff-index.md/json`，集中列出 start-here 执行顺序、关键文件、dry-run/import/review queue/smoke evidence 命令和剩余风险。
- `scripts/short_drama_mvp_acceptance_report.rb` 新增 `Handoff Index` 小节，并把 `handoff_index` 纳入 JSON 验收报告；`scripts/version_consistency.rb` 新增守门，确保试用包持续暴露该交付入口。
- `SHORT_DRAMA_AI_MVP_CUTOFF.md`、`SHORT_DRAMA_AI_MVP_TRYOUT.md` 和 `MANUAL_TEST_QUEUE.md` 同步把当前人工验收入口更新为 `1.109.0-rc458 — 短剧试用包交付索引`。
- 版本号从 **1.109.0-rc457** 提升为 **1.109.0-rc458**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / 短剧 cutoff/tryout 文档同步。

## 1.109.0-rc457 - 2026-06-28

### Changed
- **短剧 smoke 证据下一步建议（1.109.0-rc457）** —— `scripts/short_drama_mvp_smoke_evidence_report.rb` 现在会输出 `next_actions`，按 JSON 解析错误、schema 漂移、失败 smoke、缺 evidence、本地手测待完成和 provider smoke 待记录分别给出下一步。
- `scripts/short_drama_mvp_acceptance_report.rb` 新增 `Smoke Evidence Next Actions` 小节，并把 standalone smoke evidence report 的 `next_actions` 纳入 JSON 报告，交付时不再只看到 `manual_pending` 这个结论。
- `scripts/version_consistency.rb` 新增守门，确保 standalone smoke evidence report 和 acceptance report 持续保留下一步建议。
- `SHORT_DRAMA_AI_MVP_CUTOFF.md`、`SHORT_DRAMA_AI_MVP_TRYOUT.md` 和 `MANUAL_TEST_QUEUE.md` 同步把当前人工验收入口更新为 `1.109.0-rc457 — 短剧 smoke 证据下一步建议`。
- 版本号从 **1.109.0-rc456** 提升为 **1.109.0-rc457**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / 短剧 cutoff/tryout 文档同步。

## 1.109.0-rc456 - 2026-06-28

### Changed
- **短剧 smoke 证据自检报告（1.109.0-rc456）** —— 新增 `scripts/short_drama_mvp_smoke_evidence_report.rb`，可读取试用包内 `manual-smoke-results-template.json` 与 `provider-api-smoke-template.json`，输出独立 Markdown/JSON 报告，明确 `ready`、`manual_pending`、`manual_failed` 或 `blocked`。
- 本地 `scripts/run_tests.sh` 和 GitHub Actions `Tests` workflow 现在都会在生成试用包后生成 `short_drama_mvp_smoke_evidence_report.md/json`，并把报告加入 job summary 与 artifacts。
- `scripts/short_drama_mvp_acceptance_report.rb` 现在会汇总 standalone smoke evidence report，并在交付验收报告中展示 `Smoke Evidence Report` 小节；`scripts/version_consistency.rb` 新增守门，防止该自检入口从本地/远端验收链路中脱落。
- `SHORT_DRAMA_AI_MVP_CUTOFF.md`、`SHORT_DRAMA_AI_MVP_TRYOUT.md` 和 `MANUAL_TEST_QUEUE.md` 同步把当前人工验收入口更新为 `1.109.0-rc456 — 短剧 smoke 证据自检报告`。
- 版本号从 **1.109.0-rc455** 提升为 **1.109.0-rc456**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / 短剧 cutoff/tryout 文档同步。

## 1.109.0-rc455 - 2026-06-28

### Changed
- **短剧 provider smoke 证据守门（1.109.0-rc455）** —— `scripts/short_drama_mvp_acceptance_report.rb` 现在会统计 provider smoke 中 pass/fail 行的 evidence 填写情况，并输出 `evidence_required_count`、`evidence_present_count`、`evidence_missing_count` 与缺失项。
- `handoff_readiness` 现在会把真实 provider smoke 的 failed 行计入 `manual_failed`；pass/fail 行缺少 evidence 时保持 `manual_pending`。默认 `untested` provider smoke 仍作为剩余风险暴露，不阻断本地 MVP 验收。
- `scripts/version_consistency.rb` 新增守门，确保 provider smoke 摘要持续包含 evidence 质量判断。
- `SHORT_DRAMA_AI_MVP_CUTOFF.md`、`SHORT_DRAMA_AI_MVP_TRYOUT.md` 和 `MANUAL_TEST_QUEUE.md` 同步把当前人工验收入口更新为 `1.109.0-rc455 — 短剧 provider smoke 证据守门`。
- 版本号从 **1.109.0-rc454** 提升为 **1.109.0-rc455**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / 短剧 cutoff/tryout 文档同步。

## 1.109.0-rc454 - 2026-06-28

### Changed
- **短剧 provider smoke 模板（1.109.0-rc454）** —— `scripts/short_drama_mvp_tryout_package.rb` 现在会生成 `provider-api-smoke-template.md/json`，覆盖 some.im 图片/视频异步任务与 Replicate 放大/蒙版编辑的真实 provider smoke 证据格式。
- `scripts/short_drama_mvp_acceptance_report.rb` 新增 `provider_api_smoke_summary` 和 Markdown 的 `Provider API Smoke Templates` 小节，让交付报告能看到真实 provider smoke 模板、provider 覆盖和 capability 覆盖；CI 仍不调用外网 API。
- `scripts/version_consistency.rb` 新增守门，确保试用包持续包含 provider API smoke 模板，并确保验收报告持续汇总这些模板。
- `SHORT_DRAMA_AI_MVP_CUTOFF.md`、`SHORT_DRAMA_AI_MVP_TRYOUT.md` 和 `MANUAL_TEST_QUEUE.md` 同步把当前人工验收入口更新为 `1.109.0-rc454 — 短剧 provider smoke 模板`。
- 版本号从 **1.109.0-rc453** 提升为 **1.109.0-rc454**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / 短剧 cutoff/tryout 文档同步。

## 1.109.0-rc453 - 2026-06-28

### Changed
- **短剧验收报告补手测证据摘要（1.109.0-rc453）** —— `scripts/short_drama_mvp_acceptance_report.rb` 现在会统计包内 `manual-smoke-results-template.json` 中 pass/fail 步骤的 evidence 填写情况，输出 `manual_evidence_summary` 和 Markdown 的 `Manual Evidence` 小节。
- `handoff_readiness` 在手测步骤标为 pass/fail 但 evidence 为空时会保持 `manual_pending`，避免“状态已填”被误读成“交付证据已齐”。
- `scripts/version_consistency.rb` 新增守门，确保验收报告持续保留手测证据摘要能力。
- `SHORT_DRAMA_AI_MVP_CUTOFF.md`、`SHORT_DRAMA_AI_MVP_TRYOUT.md` 和 `MANUAL_TEST_QUEUE.md` 同步把当前人工验收入口更新为 `1.109.0-rc453 — 短剧手测证据摘要`。
- 版本号从 **1.109.0-rc452** 提升为 **1.109.0-rc453**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / 短剧 cutoff/tryout 文档同步。

## 1.109.0-rc452 - 2026-06-28

### Changed
- **短剧验收报告读取包内手测结果文件（1.109.0-rc452）** —— `scripts/short_drama_mvp_acceptance_report.rb` 现在会解析试用包 `manual-smoke-results-template.json`，输出 `manual_results_summary` 和 Markdown 的 `Manual Results File` 小节。
- `handoff_readiness` 会同时考虑 manual queue 与包内手测结果文件；若结果文件出现 failed 步骤，整体交付状态会显示 `manual_failed`。
- `scripts/version_consistency.rb` 新增守门，确保验收报告持续保留手测结果文件摘要能力。
- `scripts/version_consistency.rb` 的短剧 pending 指针检查允许当前无待办指针，避免 `MANUAL_TEST_QUEUE.md` 最新短剧小节全 ✅ 后被误判为缺失版本。
- `SHORT_DRAMA_AI_MVP_CUTOFF.md`、`SHORT_DRAMA_AI_MVP_TRYOUT.md` 和 `MANUAL_TEST_QUEUE.md` 同步把当前人工验收入口更新为 `1.109.0-rc452 — 短剧手测结果文件摘要`。
- 版本号从 **1.109.0-rc451** 提升为 **1.109.0-rc452**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / 短剧 cutoff/tryout 文档同步。

## 1.109.0-rc451 - 2026-06-28

### Changed
- **短剧显式剩余风险纳入交付守门（1.109.0-rc451）** —— `scripts/short_drama_mvp_acceptance_report.rb` 现在会检查 cutoff 中至少保留一条真实剩余风险，避免交付摘要在风险被误删时兜底成“无剩余风险”。
- `scripts/version_consistency.rb` 新增 `Short drama cutoff preserves explicit remaining risks` delivery gate，并要求验收报告保留 `cutoff keeps explicit remaining risks` 检查。
- `AgentBackgroundJobsTests` 的运行任务计数用例改用 Debug/test-only job snapshot 注入，避免完整 Swift Testing 并发套件里真实 `Process` 退出时序导致偶发红灯。
- `SHORT_DRAMA_AI_MVP_CUTOFF.md`、`SHORT_DRAMA_AI_MVP_TRYOUT.md` 和 `MANUAL_TEST_QUEUE.md` 同步把当前人工验收入口更新为 `1.109.0-rc451 — 短剧显式剩余风险守门`。
- 版本号从 **1.109.0-rc450** 提升为 **1.109.0-rc451**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / 短剧 cutoff/tryout 文档同步。

## 1.109.0-rc450 - 2026-06-28

### Changed
- **短剧交付就绪摘要纳入版本一致性守门（1.109.0-rc450）** —— `scripts/version_consistency.rb` 现在会检查短剧验收报告持续输出 `handoff_readiness`、`remaining_risks`、`Handoff Readiness` 和 `Remaining Risks`，防止交付就绪/剩余风险摘要在后续改动中被删漏。
- `scripts/short_drama_mvp_acceptance_report.rb` 会反向确认版本报告中存在该 delivery gate，确保本地验收摘要和版本一致性守门互相接住。
- 稳定 `AgentBackgroundJobsTests` 的后台任务计数 drain 用例，改用短暂后台任务自然完成，避免 shell/沙箱子进程信号时序导致完整 Xcode 套件偶发红灯。
- `SHORT_DRAMA_AI_MVP_CUTOFF.md`、`SHORT_DRAMA_AI_MVP_TRYOUT.md` 和 `MANUAL_TEST_QUEUE.md` 同步把当前人工验收入口更新为 `1.109.0-rc450 — 短剧交付就绪摘要守门`。
- 版本号从 **1.109.0-rc449** 提升为 **1.109.0-rc450**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / 短剧 cutoff/tryout 文档同步。

## 1.109.0-rc449 - 2026-06-28

### Changed
- **短剧验收摘要补交付就绪状态（1.109.0-rc449）** —— `scripts/short_drama_mvp_acceptance_report.rb` 现在输出 `handoff_readiness` 和 `remaining_risks`，Markdown 报告新增 `Handoff Readiness` / `Remaining Risks`，明确区分机器守门通过、人工 smoke 待测和当前剩余风险。
- `SHORT_DRAMA_AI_MVP_CUTOFF.md`、`SHORT_DRAMA_AI_MVP_TRYOUT.md` 和 `MANUAL_TEST_QUEUE.md` 同步把当前人工验收入口更新为 `1.109.0-rc449 — 短剧交付就绪与剩余风险摘要`。
- 版本号从 **1.109.0-rc448** 提升为 **1.109.0-rc449**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / 短剧 cutoff/tryout 文档同步。

## 1.109.0-rc448 - 2026-06-28

### Changed
- **短剧验收摘要补手动 smoke 状态（1.109.0-rc448）** —— `scripts/short_drama_mvp_acceptance_report.rb` 现在会解析 `MANUAL_TEST_QUEUE.md` 当前短剧小节，输出 `manual_smoke_summary`，在 Markdown/JSON 中展示 ✅/⏳/❌ 计数和待办项标题，交付时能同时看到机器证据和人工剩余项。
- `SHORT_DRAMA_AI_MVP_CUTOFF.md`、`SHORT_DRAMA_AI_MVP_TRYOUT.md` 和 `MANUAL_TEST_QUEUE.md` 同步把当前人工验收入口更新为 `1.109.0-rc448 — 短剧验收摘要手动状态`。
- 版本号从 **1.109.0-rc447** 提升为 **1.109.0-rc448**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / 短剧 cutoff/tryout 文档同步。

## 1.109.0-rc447 - 2026-06-28

### Added
- **短剧交付验收摘要报告（1.109.0-rc447）** —— 新增 `scripts/short_drama_mvp_acceptance_report.rb`，汇总 `version_report`、本地试用包报告、手动 smoke 结果模板、cutoff/tryout/manual queue 指针，生成 `short_drama_mvp_acceptance_report.md/json`，方便交付时一眼确认短剧 MVP 可用版证据。
- 本地 `scripts/run_tests.sh` 与 GitHub Actions `Tests` workflow 接入短剧验收摘要报告，并上传/追加到 CI summary；`scripts/version_consistency.rb` 新增 Delivery Gate，防止本地和远端验收漏跑该报告。
- `SHORT_DRAMA_AI_MVP_CUTOFF.md`、`SHORT_DRAMA_AI_MVP_TRYOUT.md` 和 `MANUAL_TEST_QUEUE.md` 同步把当前人工验收入口更新为 `1.109.0-rc447 — 短剧交付验收摘要`。
- 版本号从 **1.109.0-rc446** 提升为 **1.109.0-rc447**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / 短剧 cutoff/tryout 文档同步。

## 1.109.0-rc446 - 2026-06-28

### Added
- **短剧人工 smoke 结果模板（1.109.0-rc446）** —— `scripts/short_drama_mvp_tryout_package.rb` 生成的本地试用包新增 `manual-smoke-results-template.md` 和 `manual-smoke-results-template.json`，用于记录 dry-run 导入、正式导入、`latest-media-import`、Widget 结构化动作和 review queue dry-run 的人工验收 evidence。
- 试用包 JSON/Markdown 报告新增结果模板路径，并自检结果模板覆盖关键步骤且初始状态为 `untested`；`scripts/version_consistency.rb` 新增交付守门，防止试用包以后漏掉人工 smoke 结果模板。
- `SHORT_DRAMA_AI_MVP_CUTOFF.md`、`SHORT_DRAMA_AI_MVP_TRYOUT.md` 和 `MANUAL_TEST_QUEUE.md` 同步把当前人工验收入口更新为 `1.109.0-rc446 — 短剧人工 smoke 结果模板`。
- 版本号从 **1.109.0-rc445** 提升为 **1.109.0-rc446**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / 短剧 cutoff/tryout 文档同步。

## 1.109.0-rc445 - 2026-06-28

### Fixed
- **短剧交付验收入口纳入版本一致性守门（1.109.0-rc445）** —— `scripts/version_consistency.rb` 现在会检查 cutoff 是否明确写出本地一键 `scripts/run_tests.sh`、远端 `go test ./...` 和 GitHub Actions `Run XeditTests` 门槛，防止交付说明漏跑关键路径。
- `SHORT_DRAMA_AI_MVP_CUTOFF.md` 的可用版验收清单补充本地一键入口和远端 CI Go/Xedit 验收入口；试用文档与人工 smoke 队列同步指向 `1.109.0-rc445 — 短剧交付验收入口守门`。
- 前台 `run_command` 改为同步 drain stdout/stderr pipe，避免短命令在进程退出时偶发丢掉最后一段 stdout，稳定本轮交付验收。
- 版本号从 **1.109.0-rc444** 提升为 **1.109.0-rc445**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / 短剧 cutoff/tryout 文档同步。

## 1.109.0-rc444 - 2026-06-28

### Fixed
- **短剧过期指针 smoke 纳入版本一致性守门（1.109.0-rc444）** —— `scripts/version_consistency.rb` 现在会检查仍处于 `⏳` 状态的短剧文档指针 smoke，防止人工队列继续要求当前试用文档指向旧版本。
- 将已被新版覆盖的 rc442/rc443 短剧文档指针检查标为机器守门已覆盖，并新增 `1.109.0-rc444 — 短剧过期指针 smoke 守门` 作为当前人工验收入口。
- 版本号从 **1.109.0-rc443** 提升为 **1.109.0-rc444**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / 短剧试用文档同步。

## 1.109.0-rc443 - 2026-06-28

### Fixed
- **短剧人工 smoke 队列顺序纳入版本一致性守门（1.109.0-rc443）** —— `scripts/version_consistency.rb` 现在同时检查语义最新版短剧 smoke 小节和文档中最后一个短剧 smoke 小节，防止试用文档指向的新验收入口夹在旧小节中间。
- 短剧试用文档的人工 smoke 记录入口更新为 `1.109.0-rc443 — 短剧人工 smoke 队列顺序守门`，方便交付前直接定位最新人工验收项。
- 版本号从 **1.109.0-rc442** 提升为 **1.109.0-rc443**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / 短剧试用文档同步。

## 1.109.0-rc442 - 2026-06-28

### Fixed
- **短剧收口文档纳入版本一致性守门（1.109.0-rc442）** —— `scripts/version_consistency.rb` 现在会同时检查 `SHORT_DRAMA_AI_MVP_CUTOFF.md`、`SHORT_DRAMA_AI_MVP_TRYOUT.md` 和 `MANUAL_TEST_QUEUE.md` 的短剧基线/验收小节版本，防止短剧可用版文档指向旧 smoke 小节。
- 修正短剧试用文档的人工 smoke 记录入口，当前基线、验收记录和手动队列最新短剧小节统一指向 `1.109.0-rc442`。
- 版本号从 **1.109.0-rc441** 提升为 **1.109.0-rc442**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / 短剧试用文档同步。

## 1.109.0-rc441 - 2026-06-28

### Fixed
- **run_command stdout 收尾读取稳定化（1.109.0-rc441）** —— 前台 `run_command` 在进程结束后改为同步 drain stdout/stderr pipe 剩余数据，避免 GitHub macOS runner 偶发出现命令 `exit=0` 但最后一段 stdout 未进入 payload，导致 `runCommandClosesStandardInputForHeadlessCLIs` 间歇失败。
- 版本号从 **1.109.0-rc440** 提升为 **1.109.0-rc441**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / 短剧试用文档同步。

## 1.109.0-rc440 - 2026-06-28

### Added
- **短剧 MVP 试用包内置手动 smoke 清单（1.109.0-rc440）** —— `scripts/short_drama_mvp_tryout_package.rb` 现在会生成 `manual-smoke-checklist.md`，把 dry-run 导入、正式导入、媒体任务侧栏、`latest-media-import` 和 Widget 结构化动作验收步骤放进试用包本身。
- 试用包 JSON/Markdown 报告新增 `manual_smoke_checklist_path`，并自检清单必须覆盖 `<widget-handoff-action>` 与 `short_drama_import_review_csv`，避免交付包只适合机器跑、不适合人验收。
- 版本号从 **1.109.0-rc439** 提升为 **1.109.0-rc440**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / 短剧试用文档同步。

## 1.109.0-rc439 - 2026-06-28

### Changed
- **短剧 MVP 试用包 Widget 改为结构化动作（1.109.0-rc439）** —— `widget-preview.html` 现在生成 `sendToolAction` 按钮，直接携带 `import_media_manifest` dry-run / 正式导入和 `short_drama_import_review_csv` review queue dry-run 参数，保留 `sendPrompt` 作为兜底。
- `scripts/short_drama_mvp_tryout_package.rb` 新增结构化 Widget 动作检查，确保本地试用包覆盖网页 Widget 到聊天窗口的工具动作回传路径。
- 版本号从 **1.109.0-rc438** 提升为 **1.109.0-rc439**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / 短剧试用文档同步。

## 1.109.0-rc438 - 2026-06-28

### Added
- **短剧 MVP 本地试用包生成器（1.109.0-rc438）** —— 新增 `scripts/short_drama_mvp_tryout_package.rb`，可在 `build/ci/short_drama_mvp_tryout_package` 生成不调用外网 API 的制作包样例，覆盖 completed 本地产物、pending 远端视频任务、失败修复项、review queue、gap report 和 Widget handoff。
- 本地 `scripts/run_tests.sh` 与 GitHub Actions 新增试用包生成步骤，并产出 `short_drama_mvp_tryout_package_report.md/json` 与可下载样例包，避免“可试用包”只停留在文档里。
- 版本号从 **1.109.0-rc437** 提升为 **1.109.0-rc438**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / 短剧试用文档 / CI 配置同步。

## 1.109.0-rc437 - 2026-06-28

### Fixed
- **短剧/媒体工具扩容后不再误触发上下文压缩（1.109.0-rc437）** —— 自动压缩判断改为只按可被压缩的会话历史 token 触发，固定工具 schema 开销不再让短聊天在小窗口模型下提前进入压缩。
- `agent token estimate includes tool schemas without exploding short chats` 测试上限同步到当前 94 个工具的规模，仍保留工具 schema 估算不能失控的守门。
- 版本号从 **1.109.0-rc436** 提升为 **1.109.0-rc437**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc436 - 2026-06-28

### Changed
- **manifest 导回写入聊天运行时上下文（1.109.0-rc436）** —— `import_media_manifest` 正式导入本地产物、登记 pending 远端任务或记录失败任务后，会写入 `<latest-media-import>`，下一轮聊天可直接看到 package、manifest、pending/completed/failed 任务和继续动作。
- 新增 `AgentMediaImportContext.swift` 与 `scripts/media_import_context_contract_test.rb`，并接入本地测试和 GitHub Actions，守住 Ruby/Skill/第三方 API 制作包导回后的聊天接力。
- 新增 `docs/SHORT_DRAMA_AI_MVP_CUTOFF.md`，冻结本轮短剧 AI 能力为可用 MVP，记录验收命令、暂缓范围、手动 smoke 场景和剩余风险。
- 版本号从 **1.109.0-rc435** 提升为 **1.109.0-rc436**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc435 - 2026-06-28

### Changed
- **短剧制作缺口精确接力（1.109.0-rc435）** —— 项目和分集的“补主图 / 补视频 / 审片”按钮会分别写入 `<short-drama-production-gap-action>`，直接携带 dry-run、正式提交、打开/刷新媒体任务和检查项处理参数。
- 新增 `scripts/production_gap_actions_contract_test.rb` 并接入本地测试与 GitHub Actions，守住制作缺口动作条到聊天窗口的结构化接力。
- 版本号从 **1.109.0-rc434** 提升为 **1.109.0-rc435**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc434 - 2026-06-28

### Changed
- **媒体任务刷新写入聊天运行时上下文（1.109.0-rc434）** —— “媒体任务”侧栏手动刷新运行中/卡住任务后，会记录 `latest-media-task-refresh`，下一轮聊天可读取刷新原因、范围、任务句柄和刷新后的运行/失败/完成统计。
- 新增 `AgentMediaTaskRefreshContext.swift` 与 `scripts/media_task_refresh_contract_test.rb`，并接入本地测试和 GitHub Actions，守住手动刷新与聊天协作的接力契约。
- 版本号从 **1.109.0-rc433** 提升为 **1.109.0-rc434**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc433 - 2026-06-28

### Changed
- **短剧侧栏制作缺口动作条（1.109.0-rc433）** —— 项目卡里的“制作缺口”从单个文本入口升级为动作条，缺主图、缺视频、未解决检查项和缺人物/场景参考图会分别给出可点击动作。
- 新增 `AgentShortDramaProductionGapActions.swift` 承载制作缺口 UI；主短剧侧栏文件减少到 2588 行，继续向拆分热点文件推进。
- 短剧媒体合约更新为检查新的缺口动作条和参考图直提闭包；版本号从 **1.109.0-rc432** 提升为 **1.109.0-rc433**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc432 - 2026-06-28

### Changed
- **图片蒙版上下文携带真实 mask_path（1.109.0-rc432）** —— 图片蒙版侧栏的“发送到聊天”对通用图片也可见；当用户已经画选区但尚未手动导出时，会先导出当前蒙版并把真实 `current_mask_path` 写入聊天上下文。
- `edit_image_with_mask` 的 `submit_with_existing_mask_arguments` / `submit_inpaint_arguments` / `submit_erase_arguments` 会优先使用真实 `mask_path`，方便聊天、Skill 或 Ruby 脚本直接继续提交 Replicate / some.im 编辑任务。
- 新增 `scripts/image_edit_contract_test.rb` 并接入本地测试与 GitHub Actions，发布 `image_edit_report.md/json`，守住图片蒙版编辑到聊天接力的关键契约。
- 版本号从 **1.109.0-rc431** 提升为 **1.109.0-rc432**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc431 - 2026-06-28

### Changed
- **Widget 侧栏协作合约测试（1.109.0-rc431）** —— 新增 `scripts/widget_side_panel_contract_test.rb`，用独立 Ruby 合约守住右侧网页组件面板的推荐动作/可用动作必须写入 `latest-widget-tool-action`。
- 本地 `scripts/run_tests.sh` 与 GitHub Actions 会运行并发布 `widget_side_panel_report.md/json`，避免 Skill/Ruby 生成网页工作台与聊天窗口的结构化接力后续回退。
- 版本号从 **1.109.0-rc430** 提升为 **1.109.0-rc431**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc430 - 2026-06-28

### Changed
- **侧边栏 Widget 动作写入聊天上下文（1.109.0-rc430）** —— 右侧网页组件面板里的推荐动作和可用动作点击后，会同步记录 `latest-widget-tool-action`，聊天窗口下一轮可读取明确工具名、参数、来源和侧边栏动作标签。
- 侧边栏仍保留原有安全直达预览：打开媒体任务、刷新远端任务、打开蒙版、候选图、短剧分镜板或 Skill/Ruby 生成的本地 HTML 时，不会直接提交付费生成或修改检查项。
- 版本号从 **1.109.0-rc429** 提升为 **1.109.0-rc430**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc429 - 2026-06-28

### Changed
- **远端媒体任务动作本地定位（1.109.0-rc429）** —— `sendToolAction` 的本地预览支持 `replicate_poll_prediction` / `some_im_poll_media_task` / `replicate_cancel_prediction` / `some_im_cancel_media_task`。
- 远端 poll 动作会按 `task_id`、远端 id、status URL 或 cancel URL 匹配本地媒体任务，打开对应任务范围并立即刷新；远端 cancel 动作只打开匹配任务范围供核对，避免本地暗中取消。
- 版本号从 **1.109.0-rc428** 提升为 **1.109.0-rc429**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc428 - 2026-06-28

### Changed
- **结构化网页动作本地预览（1.109.0-rc428）** —— 新增 `AgentWidgetLocalActionPreview`，`sendToolAction` 会先对安全本地动作做预处理，再把结构化动作发送到聊天。
- 本地预处理覆盖打开/刷新媒体任务侧栏、打开图片蒙版编辑器、生成短剧分镜/候选图 Widget、生成通用候选图 Widget、加载本地 `show_widget` HTML；不会直接提交生成、放大、删除或关闭检查项等有成本/改状态动作。
- 版本号从 **1.109.0-rc427** 提升为 **1.109.0-rc428**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc427 - 2026-06-28

### Changed
- **候选图按钮结构化接力（1.109.0-rc427）** —— 媒体任务候选图和通用候选图 Widget 的选图、打开蒙版、擦除、放大、图生视频按钮接入 `sendToolAction`。
- `sendToolAction` 携带 `<image-choice>` / `<media-task-image-choice>` 时也会记录 `latest-image-choice`，带短剧分镜或人物/场景资产锚点的选择动作仍能在下一轮聊天里直接回填主图、参考图或继续编辑。
- 版本号从 **1.109.0-rc426** 提升为 **1.109.0-rc427**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc426 - 2026-06-28

### Changed
- **短剧分镜板按钮结构化接力（1.109.0-rc426）** —— 短剧分镜板里的全剧/单集批量图片视频、查看/刷新任务、导出制作包、候选图选择、蒙版重绘/擦除和主图放大按钮改用 `sendToolAction`。
- 新增 `toolActionButton` 统一把工具名、参数、备注和 action key 编码为 Widget 结构化动作，避免 HTML 按钮继续依赖自然语言 prompt 反推工具调用。
- 版本号从 **1.109.0-rc425** 提升为 **1.109.0-rc426**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc425 - 2026-06-28

### Changed
- **网页组件结构化工具动作回传（1.109.0-rc425）** —— 新增 `AgentWidgetToolAction`，Widget 可通过 `sendToolAction({tool, arguments, note, action_key})` 把明确工具动作交回聊天，而不是只能发送自然语言提示。
- Widget WebView 桥会校验工具名、参数和备注长度，记录 `latest-widget-tool-action`，并把 `<widget-tool-action>` 注入聊天；下一轮模型请求也会携带 `latest-widget-tool-action`，方便 Skill/Ruby 短剧网页、审片页和候选图页稳定接力到工具调用。
- `show_widget` 工具描述补充 `sendToolAction` 用法；版本号从 **1.109.0-rc424** 提升为 **1.109.0-rc425**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc424 - 2026-06-28

### Changed
- **媒体任务完成写入聊天运行时上下文（1.109.0-rc424）** —— 新增 `AgentMediaTaskCompletionContext`，在异步媒体任务完成队列 drain 时记录最近完成任务的 provider、状态、产物路径、短剧锚点和后续动作。
- 下一轮模型请求会携带 `latest-media-task-completion`，可直接继续候选图选择、设为分镜主图、图生视频、蒙版编辑、擦除、放大、打开分镜板或关闭检查项；图片编辑任务完成时也会刷新 `latest-image-edit-submission`。
- 版本号从 **1.109.0-rc423** 提升为 **1.109.0-rc424**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc423 - 2026-06-28

### Changed
- **蒙版编辑提交写入聊天运行时上下文（1.109.0-rc423）** —— 新增 `AgentImageEditSubmission`，记录最近一次 Replicate / some.im 蒙版重绘或擦除任务的 source image、mask、任务句柄、provider、状态、远端轮询地址和短剧锚点。
- 图片蒙版面板和 `edit_image_with_mask` 工具提交任务后都会更新当前 runtime 的 `latest-image-edit-submission`；下一轮模型请求会直接携带该结构化块，便于继续刷新任务、重开带旧蒙版的编辑器、选择完成产物、图生视频或关闭短剧检查项。
- 版本号从 **1.109.0-rc422** 提升为 **1.109.0-rc423**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc422 - 2026-06-28

### Changed
- **候选图选择写入聊天运行时上下文（1.109.0-rc422）** —— Widget 内的图片候选按钮发送聊天提示前，会先解析 `<image-choice>` / `<media-task-image-choice>` / `<short-drama-image-choice>` 并记录为当前会话的 `latest-image-choice`。
- 下一轮模型请求会携带结构化 `latest-image-choice`，包含 `image_path`、短剧分镜/资产锚点、推荐工具和 post-select 动作键，后续图生视频、蒙版编辑、擦除、放大或短剧主图选择不必从长聊天里反查用户点了哪张图。
- 带短剧分镜锚点的“选择”动作会同步调用本地短剧 store 更新分镜主图；带人物/场景资产锚点的选择会把图片加入资产参考图，侧栏与聊天协作更贴近真实制作流。
- 版本号从 **1.109.0-rc421** 提升为 **1.109.0-rc422**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc421 - 2026-06-28

### Changed
- **网页组件支持重载源 HTML（1.109.0-rc421）** —— Widget 来源区在 `source_path` / `html_path` 指向 `.html`、`.htm` 或 `.svg` 文件时显示刷新按钮。
- 刷新会重新读取最新源 HTML，创建新的 `AgentWidget` 并放回当前 runtime 的 Widget 历史，同时保留原 `contextLines`，追加 `reloaded_from_widget_id`、`reloaded_at` 和最新 `html_path`，方便 Skill/Ruby 脚本重跑后直接在侧栏查看新预览。
- 版本号从 **1.109.0-rc420** 提升为 **1.109.0-rc421**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc420 - 2026-06-28

### Changed
- **网页组件路径边界共享（1.109.0-rc420）** —— 新增 `AgentWidgetPathResolver.swift`，统一 Widget HTML、源文件和制作包目录的本地安全路径解析。
- `show_widget` 工具、右侧网页组件面板和 Widget 来源区现在共用 workspace / 系统临时目录 / WillDeep 短剧导出目录边界，减少 Skill/Ruby 网页嵌入、制作包预览和 Finder 定位规则漂移。
- 版本号从 **1.109.0-rc419** 提升为 **1.109.0-rc420**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc419 - 2026-06-28

### Changed
- **网页组件来源区拆分（1.109.0-rc419）** —— 将 Widget 来源摘要、源 HTML/制作包路径展示和 Finder 定位动作从 `AgentSidePanel.swift` 拆到独立 `AgentWidgetSourceRows.swift`。
- `AgentSidePanel.swift` 从 1952 行降到 1854 行，继续低于 2000 行软线；后续拆整个 `AgentSidePanelWidgetView` 或继续扩展 Skill/Ruby 网页接力时边界更清楚。
- 版本号从 **1.109.0-rc418** 提升为 **1.109.0-rc419**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc418 - 2026-06-28

### Changed
- **网页组件来源可定位（1.109.0-rc418）** —— 右侧网页组件详情里的源 HTML 路径和制作包目录现在提供 Finder 定位按钮。
- 定位动作复用 Widget 面板已有路径安全边界，仅允许 workspace、系统临时目录或 WillDeep 短剧导出目录内的源文件/制作包，方便从 Skill/Ruby 嵌入网页回到脚本产物继续排查或导回。
- 版本号从 **1.109.0-rc417** 提升为 **1.109.0-rc418**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc417 - 2026-06-28

### Changed
- **网页组件显示 Skill/Ruby 来源（1.109.0-rc417）** —— `AgentWidget` 现在会从 `source_label`、`source_path`、`package_directory` 和 `widget_context` 提取来源摘要。
- 右侧网页组件面板的最近列表和详情头部会显示来源、HTML 路径、制作包目录和上下文说明，方便用户识别 Skill/Ruby 脚本生成的短剧预览、候选图网页或制作包仪表盘，并继续把动作接力到聊天。
- 版本号从 **1.109.0-rc416** 提升为 **1.109.0-rc417**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc416 - 2026-06-28

### Changed
- **媒体产物缩略图交互拆分（1.109.0-rc416）** —— 将 `AgentMediaArtifactThumbnail` 从 `AgentMediaArtifactViews.swift` 拆到独立 `AgentMediaArtifactThumbnail.swift`。
- 候选图网页组件继续留在 `AgentMediaArtifactViews.swift`；本地缩略图的设分镜主图、设人物/场景参考图、加入聊天附件、Replicate 放大和打开蒙版编辑入口独立维护，后续接图片编辑工具时边界更清楚。
- 版本号从 **1.109.0-rc415** 提升为 **1.109.0-rc416**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc415 - 2026-06-28

### Changed
- **任务监控快照拆分（1.109.0-rc415）** —— 将 `AgentTaskMonitorSnapshot` 从 `AgentTaskMonitorRail.swift` 拆到独立 `AgentTaskMonitorSnapshot.swift`。
- 任务监控 rail 主文件继续回落，侧栏自动展开、媒体任务摘要和聊天窗口协作状态的快照契约可以独立维护，后续扩展异步短剧任务状态不会继续挤在 UI 文件里。
- 版本号从 **1.109.0-rc414** 提升为 **1.109.0-rc415**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc414 - 2026-06-28

### Changed
- **媒体任务行拆分（1.109.0-rc414）** —— 将 `AgentMediaTaskRow` 从 `AgentMediaTasks.swift` 拆到独立 `AgentMediaTaskRow.swift`。
- 单条任务的刷新/取消、短剧锚点、候选图、完成图片转视频和检查项关闭等行级逻辑独立维护；任务中心主文件继续回落，避免后续扩展异步媒体制作时逼近 2000 行软阈值。
- 版本号从 **1.109.0-rc413** 提升为 **1.109.0-rc414**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc413 - 2026-06-28

### Changed
- **媒体任务侧栏支撑组件拆分（1.109.0-rc413）** —— 将媒体任务状态筛选和侧栏通用 UI 行拆到 `AgentMediaTaskPanelSupport.swift`。
- `AgentMediaTasks.swift` 从 1907 行降到安全线内，后续继续扩展 some.im / Replicate / Skill/Ruby 异步任务、候选图、蒙版和短剧制作侧栏时，不必继续把主任务注册/轮询文件越堆越高。
- 版本号从 **1.109.0-rc412** 提升为 **1.109.0-rc413**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc412 - 2026-06-28

### Changed
- **媒体任务侧栏支持只刷新卡住任务（1.109.0-rc412）** —— “媒体任务”侧栏在当前范围存在可刷新且超过 30 分钟未更新的运行中任务时，会显示“刷新卡住”按钮。
- “刷新卡住”只轮询这批长时间未更新的 some.im、Replicate 或带 HTTPS status URL 的 Skill/Ruby 任务，不再必须刷新全部运行中任务，适合整剧批量生成时先处理最可疑的远端任务。
- 版本号从 **1.109.0-rc411** 提升为 **1.109.0-rc412**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc411 - 2026-06-28

### Changed
- **媒体任务卡住状态外层可见（1.109.0-rc411）** —— 聊天头部侧栏按钮和任务监控 rail 会优先显示超过 30 分钟未更新的运行中媒体任务。
- 任务监控 rail 会把卡住任务作为失败之后的第二优先级聚焦对象，行内显示“未更新 Nm”；从 rail 发送状态到聊天时也会带出 `stale_active_count` / `stale_active_tasks` 和刷新参数。
- 版本号从 **1.109.0-rc410** 提升为 **1.109.0-rc411**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc410 - 2026-06-28

### Changed
- **媒体任务识别长时间未更新（1.109.0-rc410）** —— “媒体任务”侧栏会统计并筛选超过 30 分钟未更新的运行中任务，任务行显示“超过 N 分钟未更新”的提示。
- “发送状态到聊天”会额外写入 `stale_active_count` 和 `stale_active_tasks`，并携带刷新/轮询参数，让 Agent 先刷新 some.im、Replicate 或 Skill/Ruby 异步任务，再决定等待、取消或重试。
- 版本号从 **1.109.0-rc409** 提升为 **1.109.0-rc410**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc409 - 2026-06-28

### Changed
- **媒体任务聊天接力携带时间线（1.109.0-rc409）** —— 媒体任务自动完成通知、单任务上下文和侧栏范围状态接力都会写入创建时间、更新时间和完成时间。
- 聊天窗口接手 some.im、Replicate 或 Skill/Ruby 异步任务时，能根据 `created_at` / `updated_at` / `finished_at` 判断是继续等待、立即刷新、重试失败任务，还是从完成产物进入候选图、蒙版、放大或图生视频。
- 版本号从 **1.109.0-rc408** 提升为 **1.109.0-rc409**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc408 - 2026-06-28

### Changed
- **媒体任务行显示创建/更新/完成时间（1.109.0-rc408）** —— “媒体任务”侧栏每条任务现在会显示创建时间和更新时间；已完成任务会额外显示完成时间。
- 用户查看 some.im、Replicate 或 Skill/Ruby 异步图片/视频任务时，可以直接判断任务多久没更新、是否刚完成，不必只靠状态文案猜远端是否还在推进。
- 版本号从 **1.109.0-rc407** 提升为 **1.109.0-rc408**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc407 - 2026-06-28

### Changed
- **媒体任务筛选空态区分无任务和无匹配（1.109.0-rc407）** —— “媒体任务”侧栏在当前范围有任务、但状态筛选结果为空时，会显示“当前筛选暂无任务”，并提供“查看全部任务”入口。
- 真正没有任何媒体任务时仍保留原空态说明；用户切到运行中、需处理或已完成筛选后，不会再误以为 some.im、Replicate 或 Skill/Ruby 任务都消失了。
- 版本号从 **1.109.0-rc406** 提升为 **1.109.0-rc407**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc406 - 2026-06-28

### Changed
- **媒体任务摘要支持快捷筛选（1.109.0-rc406）** —— “媒体任务”侧栏摘要区新增运行中、需处理、已完成和全部快捷按钮。
- 用户看到异步任务统计后，可以直接从摘要区切换到对应状态列表，不必再回到上方分段控件查找，适合整集/全剧批量生成后快速聚焦运行中任务、失败任务或已完成产物。
- 版本号从 **1.109.0-rc405** 提升为 **1.109.0-rc406**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc405 - 2026-06-28

### Changed
- **媒体任务侧栏摘要补完成态统计（1.109.0-rc405）** —— “媒体任务”侧栏摘要区除了运行中和需要处理外，现在会展示已完成任务数、完成图片任务数和完成视频任务数。
- some.im、Replicate、Skill/Ruby 异步任务批量跑完后，用户不必切到“已完成”筛选才能先判断本轮图片/视频产物是否已经回到 App；聊天的状态接力仍保留完整完成图片/视频后续动作。
- 版本号从 **1.109.0-rc404** 提升为 **1.109.0-rc405**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc404 - 2026-06-28

### Changed
- **推荐-only Widget 也可发送动作清单（1.109.0-rc404）** —— 当网页组件只有 `recommended_tool`、没有额外 handoff actions 时，组件标题行会显示“动作清单”按钮。
- 推荐型 Skill/Ruby widget 现在也能把推荐工具、参数、直达语义和 widget 上下文写回聊天，不再依赖“可用动作”区域出现后才有完整动作清单出口。
- 版本号从 **1.109.0-rc403** 提升为 **1.109.0-rc404**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc403 - 2026-06-28

### Changed
- **Widget 动作清单补直达语义（1.109.0-rc403）** —— “发送清单”写入聊天的 `<widget-action-list>` 现在会为推荐动作和每个 handoff 动作附带用户可读标题、`local_direct` 标记和 help 说明。
- 聊天窗口接手 Skill/Ruby 制作包、审片页或候选图页面时，能区分“先本地打开侧栏/网页/蒙版”的动作和“需要 dry-run 或确认后调用工具”的动作，减少下一步执行时的歧义。
- 版本号从 **1.109.0-rc402** 提升为 **1.109.0-rc403**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc402 - 2026-06-28

### Changed
- **Widget 动作清单可一键发送到聊天（1.109.0-rc402）** —— 右侧“网页组件”侧栏的“可用动作”标题行新增“发送清单”，会把推荐工具、全部 handoff 动作、工具参数和 widget 上下文写入聊天输入框。
- Skill/Ruby 制作包、审片页、候选图或媒体任务状态页动作很多时，聊天窗口可以一次性看到完整可接力工具清单，再决定先 dry-run、刷新异步任务、打开候选图、蒙版编辑、放大、导入 manifest 或回写审片 CSV。
- 版本号从 **1.109.0-rc401** 提升为 **1.109.0-rc402**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc401 - 2026-06-28

### Changed
- **Widget 可用动作列表支持展开全部（1.109.0-rc401）** —— 右侧“网页组件”侧栏的“可用动作”默认仍显示前 6 个，但当 Skill/Ruby 制作包、审片页或候选图页面提供更多 handoff 时，会显示动作总数和“展开全部/收起”切换。
- 展开状态只保存在当前侧栏视图本地，不写入 AppState 或项目数据；长制作包页面的导入、审片、任务刷新、候选图、蒙版、放大等动作不再因为数量超过 6 个而被藏起来。
- 版本号从 **1.109.0-rc400** 提升为 **1.109.0-rc401**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc400 - 2026-06-28

### Changed
- **Widget 远端取消动作先定位媒体任务（1.109.0-rc400）** —— 右侧“网页组件”侧栏点击 `replicate_cancel_prediction` 或 `some_im_cancel_media_task` 推荐/可用动作时，会先按本地任务句柄、远端 ID、状态 URL 或取消 URL 匹配媒体任务并打开对应侧栏范围。
- 本地侧栏只做核对和定位，不直接调用取消；完整取消动作仍写回聊天，由 Agent 在上下文里确认后再执行，避免网页组件按钮产生隐藏的远端取消副作用。
- 版本号从 **1.109.0-rc399** 提升为 **1.109.0-rc400**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc399 - 2026-06-28

### Changed
- **Widget 远端任务刷新动作本地直达（1.109.0-rc399）** —— 右侧“网页组件”侧栏点击 `replicate_poll_prediction` 或 `some_im_poll_media_task` 推荐/可用动作时，会先按 `task_id`、`prediction_id`、`remote_task_id`、`status_url` 或 `cancel_url` 匹配本地媒体任务。
- 找到任务后会打开对应媒体任务侧栏范围并立即调用现有 poller 刷新状态；找不到本地任务时仍会打开全量媒体任务侧栏，并把完整远端刷新动作写回聊天继续执行。取消动作仍只交给聊天确认，不做本地暗取消。
- 版本号从 **1.109.0-rc398** 提升为 **1.109.0-rc399**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc398 - 2026-06-28

### Changed
- **Widget 制作包导入/审片动作增加本地辅助入口（1.109.0-rc398）** —— 右侧“网页组件”侧栏点击 `import_media_manifest` 推荐或 handoff 动作时，会先尝试从 `widget_preview_path`、`package_directory` 或 `manifest_path` 同目录打开 `widget-preview.html` 制作包预览。
- `short_drama_import_review_csv` 推荐或 handoff 动作会先打开短剧侧栏查看审片上下文；两类动作仍会把完整参数写回聊天，由 Agent 按 dry-run 或确认再执行真正导入/回写，避免侧栏点击产生隐藏写入。
- 版本号从 **1.109.0-rc397** 提升为 **1.109.0-rc398**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc397 - 2026-06-28

### Changed
- **Widget 推荐动作复用本地直达（1.109.0-rc397）** —— 右侧“网页组件”侧栏顶部的 `recommended_tool` 现在会转换为内部 handoff，并复用同一套本地直达处理。
- 推荐动作如果是 `show_widget`、`show_image_choice_widget`、`list_media_tasks`、`open_image_editor` 或短剧分镜/候选图入口，会先打开对应侧栏或组件，再把完整 `<widget-recommended-action>` 写回聊天，避免推荐入口和“可用动作”入口行为不一致。
- 版本号从 **1.109.0-rc396** 提升为 **1.109.0-rc397**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc396 - 2026-06-28

### Changed
- **Widget 媒体任务查看动作本地直达（1.109.0-rc396）** —— 右侧“网页组件”侧栏点击 `list_media_tasks` handoff 动作时，会直接打开媒体任务侧栏。
- `list_media_tasks` 参数带 project / episode / shot / asset / review_item / scope 锚点时会复用对应筛选范围；没有锚点时打开全量媒体任务。点击后仍会把完整 handoff 写回聊天，方便模型继续刷新、处理失败或导回产物。
- 版本号从 **1.109.0-rc395** 提升为 **1.109.0-rc396**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc395 - 2026-06-28

### Fixed
- **Widget handoff 嵌套参数保真（1.109.0-rc395）** —— 右侧“网页组件”侧栏解析 handoff 参数时，会把 `recommended_arguments`、`widget_arguments` 等 `*_arguments` 中的嵌套逗号参数完整保留。
- Skill/Ruby 制作包常见的 `recommended_arguments=package_directory=..., dry_run=true, import_pending_tasks=true` 不再被截成只有 `package_directory`；本地打开网页组件或候选图后，Widget context 仍能把完整后续导入参数交给聊天窗口。
- 版本号从 **1.109.0-rc394** 提升为 **1.109.0-rc395**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc394 - 2026-06-28

### Changed
- **Widget show_widget 网页动作本地直达（1.109.0-rc394）** —— 右侧“网页组件”侧栏点击 `show_widget` handoff 动作时，如果参数携带 `html_path`，会直接本地读取并打开对应 Skill/Ruby 生成的 HTML/SVG 网页组件。
- 本地直达沿用工具层的安全边界：仅允许当前工作区、系统临时目录和 WillDeep 短剧导出目录内的 `.html` / `.htm` / `.svg`，文件需为非空 UTF-8 且不超过 1MB；完整 handoff 仍会写回聊天，便于继续导入 manifest、回写审片 CSV 或刷新媒体任务。
- `show_widget` handoff 在“可用动作”中显示为“打开网页组件”并带“直达”标记，让 Ruby 制作包预览、短剧 Skill 看板和外部 API 结果页能从侧栏直接打开。
- 版本号从 **1.109.0-rc393** 提升为 **1.109.0-rc394**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc393 - 2026-06-28

### Changed
- **Widget 通用候选图动作本地直达（1.109.0-rc393）** —— 右侧“网页组件”侧栏点击 `show_image_choice_widget` handoff 动作时，如果参数携带 `image_paths` / `candidate_image_paths` / `image_path`，会本地生成通用候选图选择器并打开 Widget 侧栏。
- 通用候选图直达复用现有 `AgentImageChoiceWidgetBuilder`，保留 project/episode/shot/asset/review 锚点和源动作上下文；点击后仍会把完整 handoff 写回聊天，方便模型继续选主图、蒙版编辑、擦除、放大或图生视频。
- Widget “可用动作”补充更多用户可读标题，包括“关闭检查项”“批量生成”“生成分镜媒体”“生成资产参考”“图生视频”“放大图片”“导入制作包”“回写审片 CSV”“刷新/取消远端任务”等。
- 版本号从 **1.109.0-rc392** 提升为 **1.109.0-rc393**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc392 - 2026-06-28

### Changed
- **Widget 可用动作展示直达语义（1.109.0-rc392）** —— 右侧“网页组件”侧栏会把常见 handoff 工具显示为更清晰的标题和图标，例如“打开媒体任务”“刷新媒体任务”“打开蒙版”“打开分镜看板”“打开候选图”。
- 对可本地直达的动作增加“直达”标记；底层工具名和参数仍保留显示，点击后继续写回聊天，兼顾用户可读性和模型接力上下文。
- 版本号从 **1.109.0-rc391** 提升为 **1.109.0-rc392**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc391 - 2026-06-28

### Changed
- **Widget 短剧网页组件动作本地直达（1.109.0-rc391）** —— 右侧“网页组件”侧栏点击 `short_drama_show_storyboard_widget` 或 `short_drama_show_image_choice_widget` handoff 动作时，会本地生成对应短剧分镜看板或候选图选择器并打开 Widget 侧栏。
- 直达逻辑复用现有 `AgentShortDramaStoryboardWidgetBuilder` 和当前媒体任务摘要，不调用外部 API、不修改短剧数据；聊天 handoff 仍完整保留，方便模型继续排产、审片或发起 some.im / Replicate 任务。
- 短剧媒体合约测试同步覆盖 Widget 查看类动作本地直达；版本号从 **1.109.0-rc390** 提升为 **1.109.0-rc391**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc390 - 2026-06-28

### Changed
- **Widget 图片编辑动作直达蒙版面板（1.109.0-rc390）** —— 右侧“网页组件”侧栏点击 `open_image_editor` 或 `short_drama_open_image_editor` handoff 动作时，会先本地打开图片蒙版编辑面板。
- 本地直达会保留 `image_path` / `artifact_path`、可选 `mask_path`、`operation=erase|inpaint` 以及 project/episode/shot/asset/review 锚点；聊天接力仍保留完整 handoff，方便提交 some.im / Replicate 编辑任务后继续回填短剧分镜或检查项。
- 短剧媒体合约测试同步覆盖 Widget 图片编辑动作本地直达；版本号从 **1.109.0-rc389** 提升为 **1.109.0-rc390**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc389 - 2026-06-28

### Changed
- **Widget 刷新任务动作触发本地轮询（1.109.0-rc389）** —— 右侧“网页组件”侧栏点击 `short_drama_refresh_media_tasks` handoff 动作时，会在打开对应媒体任务筛选范围后，立即刷新该范围内运行中的 some.im、Replicate 和可 HTTPS 轮询的通用媒体任务。
- `short_drama_open_media_tasks` 仍只做本地打开；刷新动作仍会把完整 handoff 写回聊天，方便模型继续处理失败任务、补齐缺失分镜或关闭检查项。
- 短剧媒体合约测试同步覆盖 Widget 刷新动作本地轮询；版本号从 **1.109.0-rc388** 提升为 **1.109.0-rc389**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc388 - 2026-06-28

### Changed
- **Widget 动作直达媒体任务侧栏（1.109.0-rc388）** —— 右侧“网页组件”侧栏点击 `short_drama_open_media_tasks` / `short_drama_refresh_media_tasks` handoff 动作时，会先解析 `project_id`、`episode_id`、`shot_id`、`asset_kind`、`asset_id`、`review_item_id` 和 `scope`，本地打开对应媒体任务侧栏过滤范围。
- 动作仍会写回聊天，保留模型继续刷新、处理失败、生成补图/补视频或关闭检查项的能力；用户不必等模型执行工具才看到当前异步任务状态。
- 短剧媒体合约测试同步覆盖 Widget 任务动作本地直达；版本号从 **1.109.0-rc387** 提升为 **1.109.0-rc388**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc387 - 2026-06-28

### Changed
- **候选图 Widget 补 post-select 动作摘要（1.109.0-rc387）** —— `show_image_choice_widget` 的网页组件 contextLines 现在会写入 `post_select_action_keys`，提前说明选中候选图后可用的视频、编辑、擦除、放大、任务状态和检查项动作。
- 工具返回说明同步提示模型优先读取 `post_select_action_keys` 与结构化 `post_select_*` 字段，减少选图后继续调用 some.im、Replicate 或短剧任务工具时的参数猜测。
- 短剧媒体合约测试同步覆盖通用候选图 Widget 的 post-select 摘要；版本号从 **1.109.0-rc386** 提升为 **1.109.0-rc387**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc386 - 2026-06-28

### Changed
- **网页组件动作解析兼容紧凑 handoff（1.109.0-rc386）** —— `AgentWidget.handoffActions` 现在兼容冒号、等号两种键值行，并能识别单行 `action=..., tool=..., arguments=...`。
- Skill/Ruby、短剧制作包或媒体任务上下文把工具动作压成一行时，右侧“网页组件”侧栏也能显示为可点击动作，并把完整参数尾部送回聊天，避免逗号参数被截断。
- 短剧媒体合约测试同步覆盖 Widget 紧凑 handoff 解析；版本号从 **1.109.0-rc385** 提升为 **1.109.0-rc386**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc385 - 2026-06-28

### Changed
- **网页组件侧栏显式展示多动作接力（1.109.0-rc385）** —— `AgentWidget` 现在会从 contextLines 中解析 `*_tool` / `*_arguments` 动作，保留原有 `recommended_tool` 的同时，把 Widget 派生动作作为独立 handoff actions。
- 右侧“网页组件”侧栏新增“可用动作”按钮组，可把 `open_widget_tasks_tool`、`refresh_widget_tasks_tool`、`resolve_widget_review_tool` 等动作连同完整 Widget 上下文写回聊天，方便 Skill/Ruby 看板直接接续短剧异步任务状态。
- 短剧媒体合约测试同步覆盖 Widget 多动作解析和侧栏聊天接力；版本号从 **1.109.0-rc384** 提升为 **1.109.0-rc385**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc384 - 2026-06-28

### Changed
- **show_widget 补项目/分集任务范围接力（1.109.0-rc384）** —— `show_widget` 只携带 `project_id` 或 `project_id + episode_id` 时，也会自动派生 `short_drama_open_media_tasks` / `short_drama_refresh_media_tasks` 参数。
- 整剧网页组件会生成 `scope=project`，单集网页组件会生成 `scope=episode`；Skill/Ruby 生成的整剧或分集看板回到聊天后，可直接打开对应异步媒体任务状态。
- 短剧媒体合约测试同步覆盖 `show_widget` 的项目/分集范围派生 handoff；版本号从 **1.109.0-rc383** 提升为 **1.109.0-rc384**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc383 - 2026-06-28

### Changed
- **show_widget 自动派生短剧任务范围接力（1.109.0-rc383）** —— `show_widget` 携带短剧分镜、检查项或资产锚点时，会自动在 Widget contextLines 中补 `short_drama_open_media_tasks` / `short_drama_refresh_media_tasks` 参数。
- 当网页组件带 `review_item_id` 时，contextLines 还会补 `short_drama_resolve_review_item` 参数；Skill/Ruby 审片网页回到聊天后，可以直接打开检查项任务范围、刷新异步任务或关闭检查项。
- 短剧媒体合约测试同步覆盖 `show_widget` 的短剧任务范围派生 handoff；版本号从 **1.109.0-rc382** 提升为 **1.109.0-rc383**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc382 - 2026-06-28

### Changed
- **show_widget 补审片检查项锚点（1.109.0-rc382）** —— `show_widget` 现在支持可选 `review_item_id` 参数，并会把它写入 Widget contextLines。
- Skill/Ruby 生成的审片、修复队列或蒙版返工网页可以直接锚定到短剧检查项，聊天窗口从网页组件接手后能继续打开检查项任务范围、刷新相关异步任务或关闭检查项。
- 短剧媒体合约测试同步覆盖 `show_widget` 的 `review_item_id` 参数与上下文保留；版本号从 **1.109.0-rc381** 提升为 **1.109.0-rc382**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc381 - 2026-06-28

### Changed
- **show_widget 自动保留 html_path 上下文（1.109.0-rc381）** —— Skill/Ruby 脚本调用 `show_widget(html_path=...)` 嵌入本地 HTML/SVG 网页时，Widget contextLines 现在会自动写入 `html_path`。
- 聊天窗口从网页组件接手时无需调用方额外重复传 `source_path`，也能定位原始网页文件，继续读取、复查或重新生成 Skill/Ruby 产物。
- 短剧媒体合约测试同步覆盖 `show_widget` 的 `html_path` 上下文保留；版本号从 **1.109.0-rc380** 提升为 **1.109.0-rc381**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc380 - 2026-06-28

### Changed
- **图片蒙版编辑提交补通用任务状态交接（1.109.0-rc380）** —— 图片蒙版编辑面板提交 Replicate / some.im 任务后，`<image-edit-task-submitted>` 现在会携带 `list_media_tasks` 的 active/all 查询参数和 `target_task_id`。
- 非短剧锚定的通用图片编辑任务也能从聊天窗口继续跟踪异步状态；短剧分镜、检查项和资产范围的打开/刷新参数继续保留。
- 短剧媒体合约测试同步覆盖图片编辑提交后的通用媒体任务状态交接；版本号从 **1.109.0-rc379** 提升为 **1.109.0-rc380**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc379 - 2026-06-28

### Changed
- **通用候选图 Widget 补候选动作上下文（1.109.0-rc379）** —— `show_image_choice_widget` 和短剧候选图选择器现在会在调用方传入的 contextLines 之外追加 `<image-choice-widget>`，列出锚点、候选图路径和前 12 张候选图的选择/蒙版编辑/擦除/放大/图生视频参数。
- 由 Skill、聊天工具或短剧流程生成的候选图网页组件，不再只依赖按钮点击返回 `<image-choice>`，聊天窗口可直接读取 Widget 上下文继续接手图片编辑与短剧制作。
- 短剧媒体合约测试同步覆盖通用候选图 Widget 的候选动作上下文；版本号从 **1.109.0-rc378** 提升为 **1.109.0-rc379**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc378 - 2026-06-28

### Changed
- **媒体任务候选图 Widget 补聊天上下文（1.109.0-rc378）** —— 从媒体任务侧栏打开的“候选图”网页组件现在会携带 `<media-task-image-choice-widget>` contextLines，列出任务锚点、候选图路径和前 12 张候选图的选择/编辑/擦除/放大/图生视频参数。
- 这样聊天窗口在接手侧栏候选图 Widget 时，不必只依赖 HTML 按钮发送的 `<media-task-image-choice>`，也能直接理解每张候选图可执行的推荐工具参数。
- 短剧媒体合约测试同步覆盖候选图 Widget contextLines；版本号从 **1.109.0-rc377** 提升为 **1.109.0-rc378**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc377 - 2026-06-28

### Changed
- **manifest 导回工具结果补项目任务刷新交接（1.109.0-rc377）** —— `import_media_manifest` 返回的 `<media-import-follow-up>` 现在会在本批任务归并到同一个短剧项目 UUID 时，直接写入项目级 `short_drama_open_media_tasks` 和 `short_drama_refresh_media_tasks` 参数。
- Widget context 里的项目级任务交接也同步补上刷新入口；聊天窗口即使只拿到工具结果、不打开网页组件，也能打开或刷新当前短剧项目的异步媒体任务侧栏。
- 短剧媒体合约测试同步覆盖 manifest follow-up 的项目级打开/刷新任务交接；版本号从 **1.109.0-rc376** 提升为 **1.109.0-rc377**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc376 - 2026-06-28

### Changed
- **manifest Widget 补项目媒体任务打开交接（1.109.0-rc376）** —— `import_media_manifest` 自动排入制作包 Widget 时，如果本批任务能归并到同一个短剧项目 UUID，会在 `<media-import-widget-handoff>` 中写入 `short_drama_open_media_tasks` 工具和 `project_id=..., scope=project` 参数。
- 这让网页组件回到聊天窗口后，可以直接打开对应项目的媒体任务侧栏，而不是只依赖任务 ID 和 `list_media_tasks` 状态查询；非 UUID 项目路径不会输出该调用参数，避免误把路径当 `project_id`。
- 短剧媒体合约测试同步覆盖 manifest Widget 的项目级媒体任务打开交接；版本号从 **1.109.0-rc375** 提升为 **1.109.0-rc376**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc375 - 2026-06-28

### Changed
- **manifest 导回媒体任务侧栏按同项目自动过滤（1.109.0-rc375）** —— `import_media_manifest` 导回 pending/failed 任务并优先打开“媒体任务”侧栏时，如果本次导回任务都锚定到同一个短剧项目，会自动使用项目级 `AgentMediaTaskScope` 过滤。
- 跨项目或无短剧锚点导回仍打开全局媒体任务侧栏，避免误筛；同项目制作包导回则直接看到该短剧项目的异步任务状态。
- 短剧媒体合约测试同步覆盖 manifest 导回后的项目级媒体任务过滤；版本号从 **1.109.0-rc374** 提升为 **1.109.0-rc375**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc374 - 2026-06-28

### Changed
- **manifest 导回 pending/failed 时优先打开媒体任务侧栏（1.109.0-rc374）** —— `import_media_manifest` 仍会把制作包 `widget-preview.html` 排入网页组件，但当本次导回存在 pending 或 failed 任务时，右侧侧栏会优先打开“媒体任务”。
- 无待处理任务时仍直接打开网页组件；这样 Ruby/第三方 API 导回异步任务后，用户第一眼看到的是任务状态，完成态导回则继续优先看制作包预览。
- 短剧媒体合约测试同步覆盖 pending/failed 导回的媒体任务侧栏优先级；版本号从 **1.109.0-rc373** 提升为 **1.109.0-rc374**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc373 - 2026-06-28

### Changed
- **manifest 自动网页组件补媒体任务计数摘要（1.109.0-rc373）** —— `import_media_manifest` 自动排入的制作包 Widget handoff 现在会写入 `task_count`、`pending_task_count`、`failed_task_count` 和 `completed_task_count`。
- 聊天窗口从网页组件接手时，可以先按计数判断是刷新 pending、处理失败，还是继续候选图选择、视频生成和审片回写流程。
- 短剧媒体合约测试同步覆盖自动 Widget 的任务计数摘要；版本号从 **1.109.0-rc372** 提升为 **1.109.0-rc373**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc372 - 2026-06-28

### Changed
- **manifest 自动网页组件补媒体任务状态索引（1.109.0-rc372）** —— `import_media_manifest` 自动排入的制作包 Widget 现在会把本次导回创建或更新的 `task_ids`、`pending_task_ids` 和 `failed_task_ids` 写入 `<media-import-widget-handoff>`。
- Widget handoff 同步附带 `list_media_tasks` 的 active/all 状态查询参数；用户从网页组件回到聊天时，模型能直接定位异步任务侧栏状态，而不是只知道制作包文件路径。
- 短剧媒体合约测试同步覆盖自动 Widget 的任务索引和状态查询字段；版本号从 **1.109.0-rc371** 提升为 **1.109.0-rc372**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc371 - 2026-06-28

### Changed
- **manifest 自动网页组件补完整制作包上下文（1.109.0-rc371）** —— `import_media_manifest` 自动排入的制作包 Widget 现在会携带 `widget_preview_path`、`timeline_path`、`gap_report_path`、`shot_list_path`、`review_template_path` 和 `review_queue_path`。
- Widget handoff 同步包含 dry-run/正式 `import_media_manifest` 参数，以及 `short_drama_import_review_csv` 修复队列回写参数；Ruby/第三方 API 产物导回后，右侧网页组件和聊天窗口可直接继续排产、审片和回写检查项。
- 短剧媒体合约测试同步覆盖 manifest 自动 Widget 的完整制作包上下文；版本号从 **1.109.0-rc370** 提升为 **1.109.0-rc371**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc370 - 2026-06-28

### Changed
- **manifest 导回后自动打开制作包网页组件（1.109.0-rc370）** —— `import_media_manifest` 正式导回制作包产物或 pending 远端任务后，如果同目录存在 `widget-preview.html`，会自动排入右侧“网页组件”并打开侧栏。
- 自动排入的 Widget 会携带 `<media-import-widget-handoff>`，包括 package、manifest、source、`recommended_tool=import_media_manifest` 和 `dry_run=true, import_pending_tasks=true` 参数；导回后的网页组件可继续预检、登记异步任务和复查制作包。
- 短剧媒体合约测试同步覆盖 manifest 导回自动排队 Widget；版本号从 **1.109.0-rc369** 提升为 **1.109.0-rc370**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc369 - 2026-06-28

### Changed
- **manifest 导回后的网页预览提示携带 Widget 上下文（1.109.0-rc369）** —— `import_media_manifest` 导回制作包后，返回的 `show_widget` 示例现在包含 `source_label`、`source_path`、`package_directory`、`recommended_tool` 和 `recommended_arguments`。
- Ruby/第三方 API 脚本把产物导回后，聊天窗口打开 `widget-preview.html` 时可继续保留 dry-run 预检、pending 远端任务登记和正式导入参数，不再只是打开一个孤立 HTML。
- 短剧媒体合约测试同步覆盖 manifest 导回后的 Widget 上下文字段；版本号从 **1.109.0-rc368** 提升为 **1.109.0-rc369**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc368 - 2026-06-28

### Changed
- **制作包预览时间线/缺口/CSV 按钮补完整 handoff（1.109.0-rc368）** —— 初始制作包预览和 Ruby 脚本重写后的 `widget-preview.html` 中，时间线、缺口报告和 CSV 审片按钮都会把对应 `<production-package-handoff>` 或 `<ruby-media-script-handoff>` 一并送回聊天。
- 这些按钮现在保留 timeline、gap report、CSV、`import_media_manifest` dry-run/正式导入和 `short_drama_import_review_csv` 回写参数，聊天窗口接手时不再只拿到自然语言计划。
- 短剧媒体合约测试同步覆盖 timeline/gap/CSV 按钮 handoff；版本号从 **1.109.0-rc367** 提升为 **1.109.0-rc368**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc367 - 2026-06-28

### Changed
- **Ruby 预览失败处理按钮带完整 handoff（1.109.0-rc367）** —— Ruby 媒体脚本生成的 `widget-preview.html` 中，“分析失败”和“重跑失败”按钮现在通过 `JSON.dump` 写入完整 prompt，并把 `<ruby-media-script-handoff>` 一并带回聊天。
- 失败分析和失败重跑提示现在可直接复用 `dry_run_import_arguments` / `submit_import_arguments`，聊天窗口不再需要猜制作包、manifest、pending 远端任务和回写路径。
- 短剧媒体合约测试同步覆盖失败按钮 handoff；版本号从 **1.109.0-rc366** 提升为 **1.109.0-rc367**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc366 - 2026-06-28

### Changed
- **Ruby 媒体脚本运行接力补结构化参数（1.109.0-rc366）** —— 短剧侧栏“运行脚本”写入聊天的提示现在包含 `<ruby-media-script-run-handoff>`，列出 package、Ruby 脚本、私有 env 示例、timeline、gap report、CSV、manifest、outputs 和 widget 路径。
- 结构块还带出建议命令、`import_media_manifest` dry-run/正式导入、pending 远端任务登记、修复队列回写、网页预览参数和安全提示，方便聊天窗口直接接手 Ruby/Skill 调第三方 API 后的回流。
- 短剧媒体合约测试同步覆盖 Ruby 脚本运行 handoff；版本号从 **1.109.0-rc365** 提升为 **1.109.0-rc366**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc365 - 2026-06-28

### Changed
- **侧栏导出制作包后自动打开网页组件（1.109.0-rc365）** —— 从短剧侧栏导出整剧或单集制作包后，会自动读取 `widget-preview.html` 排入右侧“网页组件”，并在状态消息里标注打开结果。
- 手动“预览网页”也复用同一套 `<production-package-handoff>` contextLines，包含 manifest、timeline、gap report、CSV、导入、审片回写和修复队列回写参数；侧栏导出和聊天工具导出的网页组件上下文保持一致。
- 短剧媒体合约测试同步覆盖侧栏导出自动预览和完整 handoff；版本号从 **1.109.0-rc364** 提升为 **1.109.0-rc365**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc364 - 2026-06-28

### Changed
- **自动制作包预览上下文包入 production-package-handoff（1.109.0-rc364）** —— `short_drama_export_production_package` 自动排入右侧网页组件的 `AgentWidget.contextLines` 现在用 `<production-package-handoff>` 包住完整制作包上下文，并标注 `action: short_drama_export_production_package_widget`。
- 网页组件按钮或侧栏推荐动作回到聊天时，模型能按同一结构块识别制作包路径、manifest、timeline、gap report、CSV、导入、审片回写和修复队列回写参数。
- 短剧媒体合约测试同步覆盖自动预览 widget 的 handoff 边界；版本号从 **1.109.0-rc363** 提升为 **1.109.0-rc364**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc363 - 2026-06-28

### Changed
- **自动制作包预览携带完整 handoff 上下文（1.109.0-rc363）** —— `short_drama_export_production_package` 自动排入右侧网页组件的 `AgentWidget` 现在携带完整制作包上下文，包括 manifest、widget、timeline、gap report、shot list、审片模板、修复队列路径。
- 该 widget 的 contextLines 同步携带 `import_media_manifest` dry-run/正式导入、审片 CSV 回写、修复队列回写和 `show_widget` 参数；用户从网页组件按钮回到聊天时，聊天窗口能继续拿到全套制作包 handoff。
- 短剧媒体合约测试同步覆盖自动预览 widget 的 contextLines；版本号从 **1.109.0-rc362** 提升为 **1.109.0-rc363**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc362 - 2026-06-28

### Changed
- **制作包导出后自动打开网页预览（1.109.0-rc362）** —— 在对话 runtime 中调用 `short_drama_export_production_package` 后，工具会读取刚生成的 `widget-preview.html`，排入 `AgentWidgetRegistry`，并请求打开右侧“网页组件”面板。
- 工具返回新增 `Widget panel` 状态；如果不是对话 runtime 或预览文件不可读，会明确说明未排队，但不会影响制作包导出。
- 短剧媒体合约测试同步覆盖导出工具自动排队制作包预览组件；版本号从 **1.109.0-rc361** 提升为 **1.109.0-rc362**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc361 - 2026-06-28

### Changed
- **制作包导出工具返回结构化接力参数（1.109.0-rc361）** —— `short_drama_export_production_package` 的工具返回现在直接包含 `<production-package-handoff>`，列出制作包目录、manifest、widget、timeline、gap report、CSV 路径，以及 `import_media_manifest` dry-run/正式导入、审片 CSV、修复队列和 `show_widget` 参数。
- 聊天窗口从短剧制作包导出结果接手时，可以直接按结构化参数预检导入、正式导入、回写审片、回写修复队列或打开网页组件，不必再从路径列表里猜下一步。
- 短剧媒体合约测试同步覆盖工具返回的 handoff 字段；版本号从 **1.109.0-rc360** 提升为 **1.109.0-rc361**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc360 - 2026-06-28

### Changed
- **制作包修复队列推荐动作可一键交回聊天（1.109.0-rc360）** —— 初始导出的 `widget-preview.html` 和 Ruby 重写版都会在“修复队列推荐动作”里为每条未解决检查项提供“交给聊天处理”按钮。
- 按钮会发送 `<short-drama-review-queue-action>`，包含 `fix_production_review_queue_item`、`recommended_tool`、`recommended_arguments`、同检查项任务流水入口和关闭检查项参数；聊天窗口可直接接手执行重绘、擦除、放大、补拍、查看任务或关闭检查项。
- 短剧媒体合约测试同步覆盖初始预览与 Ruby 预览的一键聊天接力；版本号从 **1.109.0-rc359** 提升为 **1.109.0-rc360**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc359 - 2026-06-28

### Changed
- **初始制作包预览展示修复队列推荐动作（1.109.0-rc359）** —— 初始导出的 `widget-preview.html` 现在和 Ruby 重写版一样，会展示前 20 条未解决检查项的 `recommended_tool`、`recommended_arguments`、任务流水参数和关闭检查项参数。
- 用户刚导出制作包、不运行 Ruby 媒体脚本时，也能从网页组件直接接力处理 `production-review-queue.csv` 的修复动作，不必再打开 CSV 手动查每行参数。
- 短剧媒体合约测试同步覆盖初始预览的修复队列推荐动作区；版本号从 **1.109.0-rc358** 提升为 **1.109.0-rc359**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc358 - 2026-06-28

### Changed
- **Ruby 制作预览展示修复队列推荐动作（1.109.0-rc358）** —— Ruby 媒体脚本重写的 `widget-preview.html` 现在会读取 `production-review-queue.csv`，展示前 20 条未解决检查项的 `recommended_tool`、`recommended_arguments`、任务流水参数和关闭检查项参数。
- 外部脚本跑完后，用户从网页组件回到聊天窗口时，可以直接看到修复队列每行推荐的执行动作，不必再打开 CSV 手动查工具参数。
- 短剧媒体合约测试同步覆盖 Ruby 预览的修复队列推荐动作区；版本号从 **1.109.0-rc357** 提升为 **1.109.0-rc358**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc357 - 2026-06-28

### Changed
- **检查项修复队列 CSV 补可执行接力字段（1.109.0-rc357）** —— `production-review-queue.csv` 现在新增 `recommended_tool`、`recommended_arguments`、`secondary_tool`、`secondary_arguments`、`open_review_tasks_arguments`、`refresh_review_tasks_arguments` 和 `resolve_review_arguments`。
- Ruby Skill、第三方修复脚本或聊天窗口读取修复队列后，可直接按检查项类型执行蒙版重绘、擦除、放大、补拍、查看同一检查项任务流水或关闭检查项，不必重新推断工具参数。
- 拆出 `AgentShortDramaProductionReviewQueue.swift` 承载修复队列导出逻辑，保持导出器主文件低于 3000 行；版本号从 **1.109.0-rc356** 提升为 **1.109.0-rc357**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc356 - 2026-06-28

### Changed
- **制作包资产关联分镜补可执行批量参数（1.109.0-rc356）** —— `production-gap-report.json` 的 `assets[]` 现在新增 `linked_shot_image_dry_run_arguments` / `linked_shot_image_submit_arguments` / `linked_shot_video_dry_run_arguments` / `linked_shot_video_submit_arguments`。
- Ruby Skill 或第三方排产脚本补完人物/场景参考图后，可直接调用这些 `short_drama_generate_batch_media(shot_ids=...)` 参数推进关联分镜的补主图或补视频，不必自行拼接 `shot_ids`。
- 制作包 Markdown、网页预览提示和短剧媒体合约测试同步覆盖关联分镜可执行参数；版本号从 **1.109.0-rc355** 提升为 **1.109.0-rc356**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc355 - 2026-06-28

### Changed
- **制作包资产缺口报告补关联分镜索引（1.109.0-rc355）** —— `production-gap-report.json` 的 `assets[]` 现在新增 `linked_shot_count` 和 `linked_shot_ids`，按分集/分镜顺序列出人物或场景资产关联到的分镜。
- Ruby Skill 或第三方排产脚本补完人物/场景参考图后，可直接用这些分镜 ID 优先推进相关镜头的补主图、补视频或检查项修复，避免资产制作和分镜排产脱节。
- 制作包 Markdown、网页预览提示和短剧媒体合约测试同步覆盖关联分镜索引；版本号从 **1.109.0-rc354** 提升为 **1.109.0-rc355**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc354 - 2026-06-28

### Fixed
- **单集制作包只导出本集引用资产（1.109.0-rc354）** —— 当 `short_drama_export_production_package` 传入 `episode_id` 时，导出器现在会按该集分镜引用过滤人物和场景。
- 单集制作包的 `production-package.json`、`media-import-manifest-template.json`、`production-gap-report.json` 和网页预览不再携带无关集的人物/场景参考图缺口，避免 Ruby Skill 或第三方脚本误给整部剧资产排产。
- 短剧媒体合约测试同步覆盖单集导出的角色/场景裁剪；版本号从 **1.109.0-rc353** 提升为 **1.109.0-rc354**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc353 - 2026-06-28

### Fixed
- **单集制作包缺口批量动作保留 episode 范围（1.109.0-rc353）** —— 当 `short_drama_export_production_package` 只导出某一集时，`production-gap-report.json` 的 `batch_actions` 现在会带上 `episode_id`。
- Ruby Skill 或第三方排产脚本读取单集制作包后，批量补主图/补视频会限制在当前集内，不会因为只有 `project_id` 而误排整部短剧的缺口。
- 短剧媒体合约测试同步覆盖 episode scope 的 batch action 前缀和制作包说明；版本号从 **1.109.0-rc352** 提升为 **1.109.0-rc353**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc352 - 2026-06-28

### Changed
- **制作包缺口报告补单镜正式提交参数（1.109.0-rc352）** —— `production-gap-report.json` 的缺主图/缺视频分镜现在除了 `image_dry_run_arguments` / `video_dry_run_arguments`，还会输出 `image_submit_arguments` / `video_submit_arguments`。
- Ruby Skill 或第三方排产脚本读取缺口报告后，可先调用单镜 dry-run 预检，再直接使用同一分镜的 submit 参数正式提交 `short_drama_generate_shot_media`，不必自行拼接 `dry_run=false`。
- 短剧媒体合约测试同步覆盖单镜 submit 字段和制作包说明；版本号从 **1.109.0-rc351** 提升为 **1.109.0-rc352**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc351 - 2026-06-28

### Changed
- **单分镜媒体生成支持 dry-run 预检（1.109.0-rc351）** —— `short_drama_generate_shot_media` 新增 `dry_run` 参数，可先校验分镜、prompt、model、endpoint、图片尺寸和视频参考图，不提交 some.im 任务。
- 制作包预览和 Ruby 模板重写版的单镜“补主图 / 补视频”按钮改为先 `dry_run=true`，确认后再 `dry_run=false`；短剧侧栏分镜上下文也输出单镜图片/视频 dry-run 与正式提交两套参数。
- 短剧媒体合约测试同步覆盖单分镜 dry-run schema、工具返回、侧栏上下文和制作包按钮；版本号从 **1.109.0-rc350** 提升为 **1.109.0-rc351**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc350 - 2026-06-28

### Changed
- **资产参考图生成支持 dry-run 预检（1.109.0-rc350）** —— `short_drama_generate_asset_media` 新增 `dry_run` 参数，可先校验人物/场景资产、prompt、model、size 和 endpoint，而不提交 some.im 任务。
- 制作包缺口报告、短剧聊天上下文和网页预览的资产参考图动作同步输出 `generate_reference_dry_run_arguments` / `generate_asset_reference_dry_run_arguments`，正式提交参数显式带 `dry_run=false`，方便 Skill/Ruby 自动排产先预检再花额度。
- 短剧媒体合约测试同步覆盖资产参考图 dry-run schema、工具返回和制作包接力；版本号从 **1.109.0-rc349** 提升为 **1.109.0-rc350**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc349 - 2026-06-28

### Changed
- **制作包缺口报告纳入人物/场景参考图（1.109.0-rc349）** —— `production-gap-report.json` 现在新增 `missing_asset_reference_count` 和 `assets[]`，逐个人物/场景列出参考图数量、是否缺参考图、打开/刷新资产任务参数，以及缺图时的 `short_drama_generate_asset_media` 参数。
- 制作包 Markdown 和网页预览的“按缺口报告排产”提示同步要求优先读取资产参考图缺口，再安排补主图、补视频和检查项处理；短剧 Skill 或 Ruby 脚本可用同一 gap report 先补齐角色定妆与场景板。
- 短剧媒体合约测试同步覆盖资产参考图 gap 字段；版本号从 **1.109.0-rc348** 提升为 **1.109.0-rc349**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc348 - 2026-06-28

### Changed
- **制作包网页任务入口补刷新接力（1.109.0-rc348）** —— 制作包预览和 Ruby 模板重写后的网页预览中，分镜、分集、检查项和人物/场景资产的任务入口现在会同时提示 `short_drama_open_media_tasks` 与 `short_drama_refresh_media_tasks`。
- 人物/场景资产网页动作新增 `short_drama_generate_asset_media` 再生成参考图参数；用户从 Skill/Ruby 生成的网页组件回到聊天时，可直接刷新异步任务状态、继续补参考图或处理检查项。
- 短剧媒体合约测试同步覆盖网页预览刷新与资产再生成接力；版本号从 **1.109.0-rc347** 提升为 **1.109.0-rc348**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc347 - 2026-06-28

### Changed
- **资产完成图聊天接力补任务刷新与再生成入口（1.109.0-rc347）** —— 带人物/场景资产锚点的图片任务完成后，自动通知、完整任务上下文和范围摘要都会输出资产任务打开/刷新参数，以及 `short_drama_generate_asset_media` 再生成参考图参数。
- 用户从侧栏或聊天看到资产参考图后，可直接刷新同一人物/场景的任务流水、继续生成更多参考图，或沿用已有绑定、蒙版编辑、擦除和放大动作继续短剧资产制作。
- 短剧媒体合约测试同步覆盖资产任务刷新与再生成接力；版本号从 **1.109.0-rc346** 提升为 **1.109.0-rc347**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc346 - 2026-06-28

### Changed
- **show_widget 支持 Skill 临时网页文件（1.109.0-rc346）** —— `show_widget(html_path:)` 现在允许读取系统临时目录中的 `.html` / `.htm` / `.svg` 文件，方便 Ruby Skill 或第三方脚本先写临时网页，再嵌入右侧「网页组件」侧栏。
- 安全边界仍保留：只允许 workspace、系统临时目录或 WillDeep 短剧导出目录，继续校验扩展名、1MB 上限，并由 WKWebView CSP 禁网络和禁导航。
- 短剧媒体合约测试同步覆盖临时目录白名单；版本号从 **1.109.0-rc345** 提升为 **1.109.0-rc346**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc345 - 2026-06-28

### Changed
- **媒体任务缩略图可一键绑定人物/场景参考图（1.109.0-rc345）** —— 带 `project_id + asset_kind + asset_id` 锚点的图片产物，现在可在媒体任务侧栏缩略图上直接设为短剧人物/场景参考图。
- 点击后会更新短剧 store、打开短剧侧栏，并向聊天输入 `<short-drama-asset-reference-attached>`，携带查看资产任务、继续生成资产参考图、蒙版编辑、擦除和放大参数。
- 短剧媒体合约测试同步覆盖缩略图资产参考图入口；版本号从 **1.109.0-rc344** 提升为 **1.109.0-rc345**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc344 - 2026-06-28

### Changed
- **通用第三方异步任务识别更多产物字段（1.109.0-rc344）** —— `AgentGenericMediaStatusClient` 的 provider-neutral 轮询现在会把 `media_url`、`download_url`、`artifact_url`、`file_url` 等常见字段纳入完成判断和产物下载。
- 轮询响应里的 `media` / `images` / `videos` / `artifacts` / `files` 数组也会被收集，短剧 Skill、Ruby 制作包或第三方 API 返回常规媒体 URL 后，侧栏任务可自动下载产物并继续回流聊天。
- 短剧媒体合约测试同步覆盖这些输出键；版本号从 **1.109.0-rc343** 提升为 **1.109.0-rc344**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc343 - 2026-06-28

### Changed
- **制作包 Ruby 模板补 Replicate Predictions 请求体（1.109.0-rc343）** —— Ruby 模板新增 `WILLDEEP_MEDIA_REQUEST_PRESET=replicate_predictions`，会把通用媒体任务 JSON 转为 Replicate `/v1/predictions` 需要的 `{version,input}`。
- `source_image_data_url` / `mask_data_url` 会映射到 Replicate `input.image` / `input.mask`，并支持 `WILLDEEP_REPLICATE_EXTRA_INPUT_JSON` 注入模型参数，方便短剧制作包调用 Replicate 放大、擦除和蒙版重绘类工作流。
- `.env` 示例、制作包 Markdown 说明和短剧媒体合约测试同步覆盖该 preset；版本号从 **1.109.0-rc342** 提升为 **1.109.0-rc343**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc342 - 2026-06-28

### Changed
- **任务监控范围摘要补完成视频接力（1.109.0-rc342）** —— 完整媒体任务侧栏和右侧任务监控 rail 发送范围状态到聊天时，现在会统计并输出 `completed_video_tasks`。
- 完成视频摘要包含 `video_path`、打开/刷新分镜任务、回到分镜板、审片和关联检查项处理参数；用户从侧边栏中间看到异步视频完成后，可直接让聊天继续短剧审片或修复。
- 版本号从 **1.109.0-rc341** 提升为 **1.109.0-rc342**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc341 - 2026-06-28

### Changed
- **制作包预览支持视频审片接力（1.109.0-rc341）** —— 初始导出的 `widget-preview.html` 和 Ruby 模板运行后重写的制作包预览，在分镜已有视频产物时都会显示「审片视频」按钮。
- 按钮输出 `<short-drama-production-video-action>`，携带 `video_path`、项目/分集/分镜锚点、打开/刷新分镜任务和回到分镜板参数，让交给 Skill/Ruby/第三方 API 的制作包也能直接回到聊天审片和问题回写流程。
- 版本号从 **1.109.0-rc340** 提升为 **1.109.0-rc341**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。

## 1.109.0-rc340 - 2026-06-28

### Changed
- **网页分镜板支持视频审片接力（1.109.0-rc340）** —— 短剧网页分镜板的分镜卡片在已有视频产物时会显示「审片视频」按钮。
- 按钮会输出 `<short-drama-widget-video-action>`，携带 `video_path`、项目/分集/分镜锚点、打开/刷新分镜任务和回到分镜板参数，让嵌入网页组件也能直接进入视频审片、连续性检查和问题回写流程。
- 版本号从 **1.109.0-rc339** 提升为 **1.109.0-rc340**。pbxproj×6 / Go agent / Help Info.plist / README badge×2 / product-overview / docs ×2 同步。
