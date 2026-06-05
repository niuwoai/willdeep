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

EXTRA_ARGS=("$@")
if [ ${#EXTRA_ARGS[@]} -eq 0 ]; then
  EXTRA_ARGS=(-only-testing:XeditTests)
fi

echo "▶ xcodebuild test  ${EXTRA_ARGS[*]}"
set +e
xcodebuild test \
  -project "${ROOT_DIR}/Xedit.xcodeproj" \
  -scheme Xedit \
  -destination 'platform=macOS' \
  -resultBundlePath "${XCRESULT}" \
  -derivedDataPath "${OUT_DIR}/DerivedData" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  "${EXTRA_ARGS[@]}" \
  | tee "${LOG}"
TEST_EXIT=${PIPESTATUS[0]}
set -e

echo "▶ generating report → ${REPORT_MD}, ${REPORT_JSON}"
ruby "${ROOT_DIR}/scripts/xcresult_report.rb" "${XCRESULT}" "${REPORT_MD}" "${REPORT_JSON}"

echo "▶ report.md head:"
head -40 "${REPORT_MD}" || true

exit "${TEST_EXIT}"
