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
#   - project_build_guard_report.* 项目级构建排队/缓存报告
#   - computer_use_helper_contract_report.* Computer Use Helper 能力契约报告
#   - chrome_extension_contract_report.* Chrome 扩展能力契约报告
#   - short_drama_media_report.* 短剧媒体制作包/manifest/Ruby 模板契约报告
#   - widget_side_panel_report.* 网页组件侧栏/聊天接力契约报告
#   - roundtable_interaction_contract_report.* 专家圆桌交互契约报告
#   - image_edit_report.* 图片蒙版编辑/聊天接力契约报告
#   - media_task_refresh_report.* 媒体任务刷新/聊天接力契约报告
#   - video_studio_server_report.* Video Studio 异步提交/轮询/下载契约报告
#   - video_studio_drama_report.json 短剧存储/局部更新/媒体路径契约报告（跑在 /usr/bin/ruby 2.6 上）
#   - video_studio_skill_report.json  创作技能存储契约报告（同样跑在 2.6 上）
#   - media_import_context_report.* manifest 导回/聊天接力契约报告
#   - production_gap_actions_report.* 短剧制作缺口动作/聊天接力契约报告
#   - short_drama_mvp_tryout_package_report.* 短剧 MVP 本地试用包生成报告
#   - short_drama_mvp_smoke_evidence_report.* 短剧 MVP 包内 smoke 证据核验报告
#   - short_drama_mvp_smoke_evidence_contract_report.* 短剧 MVP smoke 证据 readiness 矩阵报告
#   - short_drama_mvp_acceptance_report.* 短剧 MVP 交付验收摘要报告
#   - short_drama_mvp_handoff_bundle.* 短剧 MVP 可交接证据包索引
#   - short_drama_mvp_handoff_bundle_contract_report.* 短剧 MVP handoff bundle 状态矩阵报告
#   - xcresult_report_contract_report.* 测试报告器"绝不假绿"契约报告
#   - report.md             markdown 报告（CI 摘要 & 本地 quick look）
#   - report.json           机读格式（自动化下游用）
# =============================================================================

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${ROOT_DIR}/build/ci"
LOCAL_XCODE_CACHE_ROOT="${WILLDEEP_XCODE_CACHE_ROOT:-${HOME}/Library/Caches/WillDeep/Xcode/Xedit}"
DERIVED_DATA="${WILLDEEP_XCODE_DERIVED_DATA_PATH:-${LOCAL_XCODE_CACHE_ROOT}/DerivedData}"
SOURCE_PACKAGES_DIR="${WILLDEEP_XCODE_SOURCE_PACKAGES_DIR:-${LOCAL_XCODE_CACHE_ROOT}/SourcePackages}"
PACKAGE_CACHE_DIR="${WILLDEEP_XCODE_PACKAGE_CACHE_DIR:-${LOCAL_XCODE_CACHE_ROOT}/PackageCache}"
XCRESULT="${OUT_DIR}/XeditTests.xcresult"
LOG="${OUT_DIR}/xcodebuild.log"
REPORT_MD="${OUT_DIR}/report.md"
REPORT_JSON="${OUT_DIR}/report.json"

mkdir -p "${OUT_DIR}" "${DERIVED_DATA}" "${SOURCE_PACKAGES_DIR}" "${PACKAGE_CACHE_DIR}"

# Drop the previous run's verdict before doing anything else. Everything between
# here and the reporter can abort under `set -e` (a contract guard failing, the
# build blowing up), and a leftover `"ok": true` from an earlier run would then
# sit on disk looking exactly like this run's result. No report beats a stale
# green one.
rm -f "${REPORT_JSON}" "${REPORT_MD}"

ruby "${ROOT_DIR}/scripts/complexity_guard.rb" "${OUT_DIR}/complexity_report.md" "${OUT_DIR}/complexity_report.json"
ruby "${ROOT_DIR}/scripts/version_consistency.rb" "${OUT_DIR}/version_report.md" "${OUT_DIR}/version_report.json"
ruby "${ROOT_DIR}/scripts/i18n_add_keys_contract_test.rb" "${OUT_DIR}/i18n_add_keys_contract_report.md" "${OUT_DIR}/i18n_add_keys_contract_report.json"
ruby "${ROOT_DIR}/scripts/computer_use_helper_contract_test.rb" "${OUT_DIR}/computer_use_helper_contract_report.md" "${OUT_DIR}/computer_use_helper_contract_report.json"
ruby "${ROOT_DIR}/scripts/chrome_extension_contract_test.rb" "${OUT_DIR}/chrome_extension_contract_report.md" "${OUT_DIR}/chrome_extension_contract_report.json"
ruby "${ROOT_DIR}/scripts/short_drama_media_contract_test.rb" "${OUT_DIR}/short_drama_media_report.md" "${OUT_DIR}/short_drama_media_report.json"
ruby "${ROOT_DIR}/scripts/widget_side_panel_contract_test.rb" "${OUT_DIR}/widget_side_panel_report.md" "${OUT_DIR}/widget_side_panel_report.json"
ruby "${ROOT_DIR}/scripts/plugin_command_contract_test.rb" "${OUT_DIR}/plugin_command_report.md" "${OUT_DIR}/plugin_command_report.json"
ruby "${ROOT_DIR}/scripts/roundtable_interaction_contract_test.rb" "${OUT_DIR}/roundtable_interaction_contract_report.md" "${OUT_DIR}/roundtable_interaction_contract_report.json"
ruby "${ROOT_DIR}/scripts/image_edit_contract_test.rb" "${OUT_DIR}/image_edit_report.md" "${OUT_DIR}/image_edit_report.json"
ruby "${ROOT_DIR}/scripts/media_task_refresh_contract_test.rb" "${OUT_DIR}/media_task_refresh_report.md" "${OUT_DIR}/media_task_refresh_report.json"
ruby "${ROOT_DIR}/scripts/video_studio_server_test.rb" "${OUT_DIR}/video_studio_server_report.md" "${OUT_DIR}/video_studio_server_report.json"
# 用 macOS 自带的 /usr/bin/ruby（2.6）跑短剧存储契约：mcp.json 把插件解释器钉死
# 成它，拿 homebrew 的 3.x 跑绿过一次 filter_map，用户机器上直接 NoMethodError。
/usr/bin/ruby "${ROOT_DIR}/scripts/video_studio_drama_test.rb" > "${OUT_DIR}/video_studio_drama_report.json"
# 创作技能的存储契约（模板只读、用户副本、reset、compose 顺序、路径逃逸）。
# 同样钉死 2.6 解释器：技能存储跑在插件的 MCP 进程里。
/usr/bin/ruby "${ROOT_DIR}/scripts/video_studio_skill_test.rb" > "${OUT_DIR}/video_studio_skill_report.json"
ruby "${ROOT_DIR}/scripts/media_import_context_contract_test.rb" "${OUT_DIR}/media_import_context_report.md" "${OUT_DIR}/media_import_context_report.json"
ruby "${ROOT_DIR}/scripts/production_gap_actions_contract_test.rb" "${OUT_DIR}/production_gap_actions_report.md" "${OUT_DIR}/production_gap_actions_report.json"
ruby "${ROOT_DIR}/scripts/short_drama_mvp_tryout_package.rb" "${OUT_DIR}/short_drama_mvp_tryout_package" "${OUT_DIR}/short_drama_mvp_tryout_package_report.md" "${OUT_DIR}/short_drama_mvp_tryout_package_report.json"
ruby "${ROOT_DIR}/scripts/short_drama_mvp_smoke_evidence_report.rb" "${OUT_DIR}/short_drama_mvp_tryout_package" "${OUT_DIR}/short_drama_mvp_smoke_evidence_report.md" "${OUT_DIR}/short_drama_mvp_smoke_evidence_report.json"
ruby "${ROOT_DIR}/scripts/short_drama_mvp_smoke_evidence_contract_test.rb" "${OUT_DIR}/short_drama_mvp_smoke_evidence_contract_report.md" "${OUT_DIR}/short_drama_mvp_smoke_evidence_contract_report.json"
ruby "${ROOT_DIR}/scripts/short_drama_mvp_acceptance_report.rb" "${OUT_DIR}/short_drama_mvp_acceptance_report.md" "${OUT_DIR}/short_drama_mvp_acceptance_report.json"
ruby "${ROOT_DIR}/scripts/short_drama_mvp_handoff_bundle.rb" "${OUT_DIR}/short_drama_mvp_acceptance_report.json" "${OUT_DIR}/short_drama_mvp_handoff_bundle.md" "${OUT_DIR}/short_drama_mvp_handoff_bundle.json"
ruby "${ROOT_DIR}/scripts/short_drama_mvp_handoff_bundle_contract_test.rb" "${OUT_DIR}/short_drama_mvp_handoff_bundle_contract_report.md" "${OUT_DIR}/short_drama_mvp_handoff_bundle_contract_report.json"
# WillDeepCore：包测试与边界守卫放在 xcodebuild 之前。
#
# 它最快——包里 53 条纯逻辑测试连编带跑不到 5 秒，而 App 那边要先建十几分钟。
# 失败也最该早暴露：如果核心判据都不对，没必要再去等整个 App 编完。
# 边界守卫见 docs/BUILD_MODULARIZATION_DESIGN.md：包一旦引入 SwiftUI/AppState
# 就不再独立，而那不会有编译错误来提醒。
ruby "${ROOT_DIR}/scripts/willdeep_core_boundary_test.rb" "${OUT_DIR}/willdeep_core_boundary_report.md" "${OUT_DIR}/willdeep_core_boundary_report.json"
( cd "${ROOT_DIR}/Packages/WillDeepCore" && swift test )

ruby "${ROOT_DIR}/scripts/xcresult_report_contract_test.rb" "${OUT_DIR}/xcresult_report_contract_report.md" "${OUT_DIR}/xcresult_report_contract_report.json"

EXTRA_ARGS=("$@")
if [ ${#EXTRA_ARGS[@]} -eq 0 ]; then
  EXTRA_ARGS=(-only-testing:XeditTests)
fi

echo "▶ xcodebuild test  ${EXTRA_ARGS[*]}"
ruby "${ROOT_DIR}/scripts/project_build_guard.rb" \
  --workspace "${ROOT_DIR}" \
  --name xedit-tests \
  --kind xcode-test \
  --artifact "${XCRESULT}" \
  --fingerprint-file "Xedit.xcodeproj/project.pbxproj" \
  --fingerprint-file "Xedit.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved" \
  --fingerprint-file "scripts/xcodebuild_ci.rb" \
  --json-report "${OUT_DIR}/project_build_guard_report.json" \
  --markdown-report "${OUT_DIR}/project_build_guard_report.md" \
  --replace-artifacts \
  -- \
  ruby "${ROOT_DIR}/scripts/xcodebuild_ci.rb" \
    --log "${LOG}" \
    --pass-grace 180 \
    -- \
    xcodebuild test \
      -project "${ROOT_DIR}/Xedit.xcodeproj" \
      -scheme XeditUnitTests \
      -destination 'platform=macOS' \
      -resultBundlePath "${XCRESULT}" \
      -derivedDataPath "${DERIVED_DATA}" \
      -clonedSourcePackagesDirPath "${SOURCE_PACKAGES_DIR}" \
      -packageCachePath "${PACKAGE_CACHE_DIR}" \
      -skipPackageUpdates \
      -onlyUsePackageVersionsFromResolvedFile \
      -enableCodeCoverage NO \
      -showBuildTimingSummary \
      COMPILATION_CACHE_ENABLE_CACHING="${WILLDEEP_XCODE_COMPILATION_CACHE:-YES}" \
      COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS="${WILLDEEP_XCODE_CACHE_REMARKS:-NO}" \
      COMPILER_INDEX_STORE_ENABLE="${WILLDEEP_XCODE_INDEX_STORE:-NO}" \
      CODE_SIGNING_ALLOWED=NO \
      CODE_SIGNING_REQUIRED=NO \
      CODE_SIGN_IDENTITY="" \
      "${EXTRA_ARGS[@]}"
TEST_EXIT=$?

echo "▶ generating report → ${REPORT_MD}, ${REPORT_JSON}"
# The reporter exits non-zero when it cannot verify the run (0 = passed,
# 1 = failed, 2 = unknown). Capture it instead of letting `set -e` abort here so
# the report head still prints, then surface it to the caller — a report that
# could not parse the xcresult must never leave us exiting 0.
REPORT_EXIT=0
ruby "${ROOT_DIR}/scripts/xcresult_report.rb" "${XCRESULT}" "${REPORT_MD}" "${REPORT_JSON}" \
  --log "${LOG}" --test-exit "${TEST_EXIT}" || REPORT_EXIT=$?

echo "▶ report.md head:"
head -40 "${REPORT_MD}" || true

if [ "${TEST_EXIT}" -ne 0 ]; then
  exit "${TEST_EXIT}"
fi
exit "${REPORT_EXIT}"
