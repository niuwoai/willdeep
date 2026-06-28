#!/usr/bin/env bash
# =============================================================================
# run_tests.sh — Local one-shot：跑 XeditTests，并把 xcresult 解析成 json + md
#
# 用法：
#   scripts/run_tests.sh                # 跑全部 XeditTests
#   scripts/run_tests.sh -only-testing:XeditTests/AgentMarkdownTableFormatterTests
#
# 产物（默认在 build/ci/）：
#   - XeditTests.xcresult   xcodebuild 结果包
#   - xcodebuild.log        原始日志
#   - complexity_report.*   复杂度守门报告
#   - version_report.*      版本一致性报告
#   - short_drama_media_report.* 短剧媒体制作包/manifest/Ruby 模板契约报告
#   - widget_side_panel_report.* 网页组件侧栏/聊天接力契约报告
#   - image_edit_report.* 图片蒙版编辑/聊天接力契约报告
#   - media_task_refresh_report.* 媒体任务刷新/聊天接力契约报告
#   - media_import_context_report.* manifest 导回/聊天接力契约报告
#   - production_gap_actions_report.* 短剧制作缺口动作/聊天接力契约报告
#   - short_drama_mvp_tryout_package_report.* 短剧 MVP 本地试用包生成报告
#   - report.md             markdown 报告（CI 摘要 & 本地 quick look）
#   - report.json           机读格式（自动化下游用）
# =============================================================================

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${ROOT_DIR}/build/ci"
XCRESULT="${OUT_DIR}/XeditTests.xcresult"
LOG="${OUT_DIR}/xcodebuild.log"
REPORT_MD="${OUT_DIR}/report.md"
REPORT_JSON="${OUT_DIR}/report.json"

mkdir -p "${OUT_DIR}"
# xcodebuild 拒绝复用同名 result bundle，每次重跑前清掉
rm -rf "${XCRESULT}"

ruby "${ROOT_DIR}/scripts/complexity_guard.rb" "${OUT_DIR}/complexity_report.md" "${OUT_DIR}/complexity_report.json"
ruby "${ROOT_DIR}/scripts/version_consistency.rb" "${OUT_DIR}/version_report.md" "${OUT_DIR}/version_report.json"
ruby "${ROOT_DIR}/scripts/short_drama_media_contract_test.rb" "${OUT_DIR}/short_drama_media_report.md" "${OUT_DIR}/short_drama_media_report.json"
ruby "${ROOT_DIR}/scripts/widget_side_panel_contract_test.rb" "${OUT_DIR}/widget_side_panel_report.md" "${OUT_DIR}/widget_side_panel_report.json"
ruby "${ROOT_DIR}/scripts/image_edit_contract_test.rb" "${OUT_DIR}/image_edit_report.md" "${OUT_DIR}/image_edit_report.json"
ruby "${ROOT_DIR}/scripts/media_task_refresh_contract_test.rb" "${OUT_DIR}/media_task_refresh_report.md" "${OUT_DIR}/media_task_refresh_report.json"
ruby "${ROOT_DIR}/scripts/media_import_context_contract_test.rb" "${OUT_DIR}/media_import_context_report.md" "${OUT_DIR}/media_import_context_report.json"
ruby "${ROOT_DIR}/scripts/production_gap_actions_contract_test.rb" "${OUT_DIR}/production_gap_actions_report.md" "${OUT_DIR}/production_gap_actions_report.json"
ruby "${ROOT_DIR}/scripts/short_drama_mvp_tryout_package.rb" "${OUT_DIR}/short_drama_mvp_tryout_package" "${OUT_DIR}/short_drama_mvp_tryout_package_report.md" "${OUT_DIR}/short_drama_mvp_tryout_package_report.json"

EXTRA_ARGS=("$@")
if [ ${#EXTRA_ARGS[@]} -eq 0 ]; then
  EXTRA_ARGS=(-only-testing:XeditTests)
fi

echo "▶ xcodebuild test  ${EXTRA_ARGS[*]}"
ruby "${ROOT_DIR}/scripts/xcodebuild_ci.rb" \
  --log "${LOG}" \
  --pass-grace 180 \
  -- \
  xcodebuild test \
    -project "${ROOT_DIR}/Xedit.xcodeproj" \
    -scheme Xedit \
    -destination 'platform=macOS' \
    -resultBundlePath "${XCRESULT}" \
    -derivedDataPath "${OUT_DIR}/DerivedData" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    "${EXTRA_ARGS[@]}"
TEST_EXIT=$?

echo "▶ generating report → ${REPORT_MD}, ${REPORT_JSON}"
ruby "${ROOT_DIR}/scripts/xcresult_report.rb" "${XCRESULT}" "${REPORT_MD}" "${REPORT_JSON}"

echo "▶ report.md head:"
head -40 "${REPORT_MD}" || true

exit "${TEST_EXIT}"
