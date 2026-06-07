#!/usr/bin/env bash
# =============================================================================
# release.sh — VeilWriter (Xedit) Developer ID 打包 + 公证 + DMG 一键脚本
#
# 流程：
#   1. xcodebuild archive（Release + Developer ID 签名）
#   2. 从 archive 导出 .app（method=developer-id）
#   3. 用 create-dmg 或 hdiutil 打包成 .dmg
#   4. 签名 dmg（dmg 本身也要签，否则 Gatekeeper 会拦）
#   5. notarytool 提交公证并同步等待结果
#   6. stapler 把公证票钉到 dmg 上
#   7. spctl 自检
#
# 公证凭据：用 `xcrun notarytool store-credentials` 提前存进 Keychain
#   下面 NOTARY_PROFILE 引用的就是那个 profile 名。
#   首次使用前请先按 docs/RELEASE.md 跑一次 store-credentials。
#
# 用法:
#   scripts/release.sh                  # 跑测试 + 打包 + 公证 + 提示打 tag/push
#   scripts/release.sh --skip-notarize  # 只签名打包，不公证（本地快速验证用）
#   scripts/release.sh --skip-tests     # 跳过测试（不推荐；只在本机已知测试绿时用）
#   scripts/release.sh --dry-run        # 演练：跑测试 + xcodebuild 但不签名/不公证/不打 tag
#   scripts/release.sh --list-backups   # 只列出 build/release-history 下已备份的旧版本，不重新打包
#
# 回滚：
#   每次 release 成功后会把新出炉的 .app + .dmg 拷一份到
#   build/release-history/<version>/，并写 build/release-history/
#   latest.txt 标记上一次跑过的版本。需要快速回滚时：
#     1. ls build/release-history/                # 看可用版本
#     2. open build/release-history/<旧版本>/*.dmg # 直接拖回 Applications
#   线上分发的真正 source of truth 是 GitHub Releases，这里的本地备份
#   只是给开发机一份"还没 push 上去就先回滚"的兜底。
# =============================================================================

set -euo pipefail

# ----- 配置区（按需修改） ----------------------------------------------------
SCHEME="Xedit"                                          # xcodebuild scheme
CONFIGURATION="Release"
PROJECT_FILE="Xedit.xcodeproj"
PRODUCT_NAME="VeilWriter"                               # 最终 .app / .dmg 文件名
BUNDLE_ID="im.some.veilwriter"
TEAM_ID="ZH2S7D6PL6"                                    # Developer Team ID
SIGNING_IDENTITY="Developer ID Application: Beijing Alibaba information Technology Co., Ltd. (ZH2S7D6PL6)"
NOTARY_PROFILE="veilwriter-notary"                      # store-credentials 时取的名字
DMG_VOLUME_NAME="VeilWriter"
TEST_BUNDLE="XeditTests"                                # 跑哪个测试 target；UI 测试单独，不在这里跑

# ----- 路径 ----------------------------------------------------------------
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build/release"
ARCHIVE_PATH="${BUILD_DIR}/${PRODUCT_NAME}.xcarchive"
EXPORT_DIR="${BUILD_DIR}/export"
EXPORT_OPTIONS_PLIST="${BUILD_DIR}/ExportOptions.plist"
APP_PATH="${EXPORT_DIR}/${PRODUCT_NAME}.app"
# 历史发布产物归档区（每个版本一个子目录）。`build/release` 会在每次
# release 开头被 `rm -rf` 清空，所以备份要放在它的同级目录 `build/
# release-history`，避免被新一轮的清理一并干掉。
BACKUP_ROOT="${ROOT_DIR}/build/release-history"

# ----- 解析参数 -------------------------------------------------------------
SKIP_NOTARIZE=0
SKIP_TESTS=0
DRY_RUN=0
LIST_BACKUPS=0
for arg in "$@"; do
  case "$arg" in
    --skip-notarize) SKIP_NOTARIZE=1 ;;
    --skip-tests)    SKIP_TESTS=1 ;;
    --dry-run)       DRY_RUN=1; SKIP_NOTARIZE=1 ;;
    --list-backups)  LIST_BACKUPS=1 ;;
    -h|--help)
      sed -n '2,42p' "$0"; exit 0 ;;
    *) echo "未知参数: $arg"; exit 1 ;;
  esac
done

# --list-backups：列出 build/release-history 下已经备份过的旧版本，按
# mtime 倒序，方便找回滚目标。不依赖任何 build 上下文，所以放在最前面。
if [[ $LIST_BACKUPS == 1 ]]; then
  if [[ ! -d "$BACKUP_ROOT" ]]; then
    echo "（还没有任何备份。build/release-history 目录不存在。）"
    exit 0
  fi
  echo "可回滚的旧版本（mtime 新 → 旧）:"
  # 用 stat -f %m + sort 拿到按修改时间排序的列表（macOS 的 stat 没有 GNU 的 --format）。
  find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d \
    -exec stat -f '%m %N' {} \; 2>/dev/null \
    | sort -rn \
    | while read -r _ path; do
      version="$(basename "$path")"
      dmg="$(ls "$path"/*.dmg 2>/dev/null | head -n1)"
      if [[ -n "$dmg" ]]; then
        echo "  $version  →  $dmg"
      else
        echo "  $version  →  (无 dmg 备份，只有 .app)"
      fi
    done
  if [[ -f "${BACKUP_ROOT}/latest.txt" ]]; then
    echo ""
    echo "上一次成功 release: $(cat "${BACKUP_ROOT}/latest.txt")"
  fi
  exit 0
fi

# ----- 读版本号（从 pbxproj 抓 MARKETING_VERSION 的第一个值）---------------
VERSION="$(grep -m 1 'MARKETING_VERSION' "${ROOT_DIR}/${PROJECT_FILE}/project.pbxproj" \
  | sed -E 's/.*MARKETING_VERSION = "?([^";]+)"?;/\1/' | tr -d ' ')"
if [[ -z "$VERSION" ]]; then
  echo "❌ 没能从 pbxproj 抓到 MARKETING_VERSION"
  exit 1
fi
DMG_PATH="${BUILD_DIR}/${PRODUCT_NAME}-${VERSION}.dmg"

# ----- 记录起点 commit（最后输出 release 摘要用） ---------------------------
RELEASE_TAG="v${VERSION}"
LAST_TAG="$(git -C "$ROOT_DIR" describe --tags --abbrev=0 2>/dev/null || true)"
HEAD_SHA="$(git -C "$ROOT_DIR" rev-parse --short HEAD)"
HEAD_SUBJECT="$(git -C "$ROOT_DIR" log -1 --pretty=%s)"

echo "========================================="
echo "  ${PRODUCT_NAME} v${VERSION} Release"
echo "  Team:        ${TEAM_ID}"
echo "  Identity:    ${SIGNING_IDENTITY}"
echo "  Notarize:    $([[ $SKIP_NOTARIZE == 1 ]] && echo skip || echo yes)"
echo "  Tests:       $([[ $SKIP_TESTS == 1 ]] && echo skip || echo yes)"
echo "  Dry-run:     $([[ $DRY_RUN == 1 ]] && echo yes || echo no)"
echo "  HEAD:        ${HEAD_SHA} ${HEAD_SUBJECT}"
echo "  Last tag:    ${LAST_TAG:-<none>}"
echo "  Target tag:  ${RELEASE_TAG}"
echo "  Output:      ${DMG_PATH}"
echo "========================================="

# ----- 检查证书 -------------------------------------------------------------
if [[ $DRY_RUN == 0 ]]; then
  if ! security find-identity -v -p codesigning | grep -q "$SIGNING_IDENTITY"; then
    echo "❌ 钥匙串里找不到 Developer ID 证书："
    echo "    ${SIGNING_IDENTITY}"
    echo "  请到 Apple Developer → Certificates 下载 .cer 后双击导入"
    exit 1
  fi
else
  echo "⚠️  dry-run：跳过证书检查 / 公证 / staple / spctl，仅保证 build 通过"
fi

# ----- 清理上次产物 ---------------------------------------------------------
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$EXPORT_DIR"

# ----- Step 0: 测试 ---------------------------------------------------------
# 体检报告里点名要求：先跑测试，失败直接停，不浪费时间在打包公证上。
if [[ $SKIP_TESTS == 1 ]]; then
  echo ""
  echo "[0/8] --skip-tests 已跳过单元测试"
else
  echo ""
  echo "[0/8] xcodebuild test (${TEST_BUNDLE}) ..."
  # 直接看 xcodebuild 退出码。日志同步进 build/test.log 便于失败时排查。
  set +e
  xcodebuild test \
    -project "${ROOT_DIR}/${PROJECT_FILE}" \
    -scheme "$SCHEME" \
    -destination 'platform=macOS' \
    -only-testing:"$TEST_BUNDLE" \
    -resultBundlePath "${BUILD_DIR}/test-results.xcresult" \
    > "${BUILD_DIR}/test.log" 2>&1
  TEST_RC=$?
  set -e
  if [[ $TEST_RC -ne 0 ]]; then
    echo "❌ 测试失败 (exit=$TEST_RC)，停止 release"
    echo "   日志:        ${BUILD_DIR}/test.log"
    echo "   result bundle: ${BUILD_DIR}/test-results.xcresult"
    echo "   失败摘要："
    grep -E 'error:|FAILED|\*\* TEST FAILED' "${BUILD_DIR}/test.log" | tail -20 || true
    exit 1
  fi
  echo "  ✅ ${TEST_BUNDLE} 全绿"
fi

# ----- Step 1: archive ------------------------------------------------------
echo ""
echo "[1/8] xcodebuild archive ..."
if [[ $DRY_RUN == 1 ]]; then
  # dry-run 只校验 build 能过，不出 archive；签名身份在 dry-run 时换成 - 让 xcodebuild 不要去钥匙串找证书。
  xcodebuild \
    -project "${ROOT_DIR}/${PROJECT_FILE}" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "generic/platform=macOS" \
    CODE_SIGNING_ALLOWED=NO \
    build
  echo ""
  echo "✅ dry-run 完成：测试 ✅ + Release build ✅"
  echo "   未生成 archive / dmg；真实 release 请去掉 --dry-run"
  exit 0
fi

xcodebuild \
  -project "${ROOT_DIR}/${PROJECT_FILE}" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "generic/platform=macOS" \
  -archivePath "$ARCHIVE_PATH" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  archive

# ----- Step 2: 导出 .app（developer-id distribution） -----------------------
echo ""
echo "[2/8] xcodebuild -exportArchive ..."
cat > "$EXPORT_OPTIONS_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>${TEAM_ID}</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
</dict>
</plist>
EOF

xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTIONS_PLIST"

if [[ ! -d "$APP_PATH" ]]; then
  echo "❌ 导出失败，找不到 $APP_PATH"
  exit 1
fi

# ----- Step 3: 打包 DMG -----------------------------------------------------
echo ""
echo "[3/8] 打包 DMG ..."
if command -v create-dmg >/dev/null 2>&1; then
  # 拖拽安装页面：背景图可选，没设的话用纯白
  create-dmg \
    --volname "$DMG_VOLUME_NAME" \
    --window-pos 200 120 \
    --window-size 600 400 \
    --icon-size 100 \
    --icon "${PRODUCT_NAME}.app" 150 180 \
    --app-drop-link 450 180 \
    --no-internet-enable \
    "$DMG_PATH" \
    "$APP_PATH"
else
  echo "  · 未检测到 create-dmg，回落到 hdiutil（素面 dmg）"
  echo "  · 想要拖拽安装页面：brew install create-dmg"
  TMP_DMG_SRC="${BUILD_DIR}/dmg-src"
  rm -rf "$TMP_DMG_SRC"
  mkdir -p "$TMP_DMG_SRC"
  cp -R "$APP_PATH" "$TMP_DMG_SRC/"
  ln -s /Applications "$TMP_DMG_SRC/Applications"
  hdiutil create \
    -volname "$DMG_VOLUME_NAME" \
    -srcfolder "$TMP_DMG_SRC" \
    -ov -format UDZO \
    "$DMG_PATH"
fi

# ----- Step 4: 签名 DMG -----------------------------------------------------
# 不签名的 dmg 公证会通过，但用户从浏览器下载后 Gatekeeper 仍会因为
# "下载附加 quarantine 属性 + dmg 自身未签名" 而弹警告。签了才完整。
echo ""
echo "[4/8] codesign DMG ..."
codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$DMG_PATH"
codesign --verify --verbose "$DMG_PATH"

# ----- Step 5: 公证 ---------------------------------------------------------
if [[ $SKIP_NOTARIZE == 1 ]]; then
  echo ""
  echo "[5/8] --skip-notarize 已跳过公证"
  echo "      产物：$DMG_PATH"
  echo "      ⚠️ 这份 dmg 用户下载后 Gatekeeper 会拦，仅限本地验证用"
  # 跳过公证/staple/spctl 直接进 [8/8] 摘要
  SKIP_STAPLE=1
else
  SKIP_STAPLE=0
  echo ""
  echo "[5/8] notarytool submit ..."
  echo "      提交后会同步等待 Apple 审核（通常 2-15 分钟）"
  xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait
fi

# ----- Step 6: stapler ------------------------------------------------------
if [[ $SKIP_STAPLE == 0 ]]; then
  echo ""
  echo "[6/8] stapler staple ..."
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"

  # ----- Step 7: Gatekeeper 自检 --------------------------------------------
  echo ""
  echo "[7/8] spctl 自检 ..."
  spctl --assess --type open --context context:primary-signature --verbose "$DMG_PATH" || true
fi

# ----- Step 7.5: 备份发布产物 ------------------------------------------------
# 用户提出："部署时备份当前运行的代码，方便快速回滚"。最稳的回滚源是
# GitHub Releases 上的旧 dmg；但开发机本地保留一份也省得遇到紧急情况
# 还要联网下载。备份策略：每次跑完一份合法的 release，就把新出炉的
# .app + .dmg 整体拷一份到 build/release-history/<version>/，同时写一行
# build/release-history/latest.txt 记录"上一次跑过的版本是 X"。需要
# 回滚时跑 `scripts/release.sh --list-backups` 查看可用版本。
echo ""
echo "[7.5/8] 归档发布产物到 ${BACKUP_ROOT}/${VERSION}/ ..."
mkdir -p "${BACKUP_ROOT}/${VERSION}"
# 用 ditto 拷 .app（保留扩展属性与签名结构），cp -p 拷 .dmg（普通文件）。
ditto "$APP_PATH" "${BACKUP_ROOT}/${VERSION}/${PRODUCT_NAME}.app"
cp -p "$DMG_PATH" "${BACKUP_ROOT}/${VERSION}/"
echo "$VERSION" > "${BACKUP_ROOT}/latest.txt"
echo "  ✅ 已备份 .app + .dmg → ${BACKUP_ROOT}/${VERSION}/"

# ----- Step 8: 交互确认是否打 tag/push --------------------------------------
# CLAUDE.md §5：bugfix 升 rc，feature 升正式版位。release 完成后建议打 v{版本号} tag。
# 体检报告点名："不直接自动 push（破坏性操作要确认）"——这里走交互式 prompt。
echo ""
echo "[8/8] 打 tag & push?"

# 列出本次到上一个 tag 之间的 commit 范围，给用户判断要不要 tag
if [[ -n "${LAST_TAG:-}" ]]; then
  COMMIT_RANGE="${LAST_TAG}..HEAD"
  COMMIT_COUNT=$(git -C "$ROOT_DIR" rev-list --count "$COMMIT_RANGE" 2>/dev/null || echo "?")
  echo "  Commits since ${LAST_TAG}（${COMMIT_COUNT} 条）:"
  git -C "$ROOT_DIR" log --oneline "$COMMIT_RANGE" 2>/dev/null | head -20 | sed 's/^/    /'
  [[ "$COMMIT_COUNT" != "?" && "$COMMIT_COUNT" -gt 20 ]] && echo "    ... 还有 $((COMMIT_COUNT - 20)) 条未显示"
else
  COMMIT_RANGE="HEAD"
  echo "  没有上游 tag，无法显示 commit 范围"
fi

# 如果 tag 已经存在（脚本被重复执行），就不要重复打
if git -C "$ROOT_DIR" rev-parse -q --verify "refs/tags/${RELEASE_TAG}" >/dev/null; then
  echo "  ⚠️ tag ${RELEASE_TAG} 已存在，跳过打 tag。"
  TAG_ALREADY=1
else
  TAG_ALREADY=0
fi

# stdin 不是 TTY（CI / pipe）时跳过交互，留给人工后续操作
if [[ ! -t 0 ]]; then
  echo "  (stdin 非 TTY，跳过 tag/push 提示。请人工执行)"
elif [[ $TAG_ALREADY == 0 ]]; then
  echo ""
  echo "  版本：${RELEASE_TAG}"
  read -rp "  → 打 tag ${RELEASE_TAG} 并推送到 origin? (y/N) " ans
  case "${ans:-}" in
    y|Y|yes|YES)
      git -C "$ROOT_DIR" tag -a "${RELEASE_TAG}" -m "Release ${RELEASE_TAG}"
      echo "  ✅ 已打本地 tag ${RELEASE_TAG}"
      read -rp "  → 推送 tag + 当前分支到 origin? (y/N) " push_ans
      case "${push_ans:-}" in
        y|Y|yes|YES)
          CURRENT_BRANCH=$(git -C "$ROOT_DIR" rev-parse --abbrev-ref HEAD)
          git -C "$ROOT_DIR" push origin "$CURRENT_BRANCH"
          git -C "$ROOT_DIR" push origin "${RELEASE_TAG}"
          echo "  ✅ 已推送分支 $CURRENT_BRANCH 与 tag ${RELEASE_TAG}"

          # 推送后关注 GitHub Actions。push to main 会触发
          # .github/workflows/test.yml；要是测试在 CI 上挂了，
          # 本地哪怕全绿也得知道。用 gh run watch 同步等待最近
          # 一次 run 的结果；没装 gh 就提示用户去 web 看一下。
          if command -v gh >/dev/null 2>&1; then
            echo ""
            echo "  → 监视 GitHub Actions（最近一次工作流）..."
            # 给 GitHub 一个抓 push 事件的窗口，否则 gh run list 可能
            # 还看不到刚触发的那条 run。
            sleep 5
            # 拿最近一次 run 的 databaseId；--json id 只能在 CLI 里识别为 databaseId
            RUN_ID=$(gh run list --branch "$CURRENT_BRANCH" --limit 1 --json databaseId,headSha \
              --jq ".[] | select(.headSha == \"$(git -C "$ROOT_DIR" rev-parse HEAD)\") | .databaseId" 2>/dev/null || true)
            if [[ -n "$RUN_ID" ]]; then
              echo "    Run #${RUN_ID}（commit $(git -C "$ROOT_DIR" rev-parse --short HEAD)）"
              if gh run watch "$RUN_ID" --exit-status; then
                echo "  ✅ GitHub Actions 通过"
              else
                echo "  ⚠️ GitHub Actions 失败 — 必须看一下："
                echo "     gh run view $RUN_ID --log-failed"
                echo "     或网页：$(gh run view "$RUN_ID" --json url --jq .url 2>/dev/null || echo "<gh 取 url 失败>")"
                # 不直接 exit 1：本地 release 已经成功，备份产物也已生成，
                # 只是远程 CI 没过。让用户自行决定是否继续后续上传 dmg。
              fi
            else
              echo "  ⚠️ gh run list 没找到 HEAD 对应的 run，可能 push 还没被 GitHub 索引到"
              echo "     稍后手动看：gh run list --branch $CURRENT_BRANCH --limit 5"
            fi
          else
            echo ""
            echo "  ⚠️ 没装 gh — 请到浏览器看下 GitHub Actions 是否绿"
            REPO_URL=$(git -C "$ROOT_DIR" config --get remote.origin.url 2>/dev/null || true)
            if [[ -n "$REPO_URL" ]]; then
              # 把 git@github.com:foo/bar.git / https://github.com/foo/bar.git
              # 都转成 https://github.com/foo/bar/actions
              ACTIONS_URL=$(echo "$REPO_URL" \
                | sed -E 's#^git@github\.com:#https://github.com/#; s#\.git$##')/actions
              echo "     $ACTIONS_URL"
            fi
          fi
          ;;
        *)
          echo "  跳过 push（tag 已在本地，需要时手动 git push origin ${RELEASE_TAG}）"
          ;;
      esac
      ;;
    *)
      echo "  跳过 tag/push"
      ;;
  esac
fi

# ----- Release 摘要 ---------------------------------------------------------
echo ""
echo "========================================="
echo "  ✅ Release 完成"
echo "-----------------------------------------"
echo "  DMG:        $DMG_PATH"
echo "  版本:        $VERSION"
echo "  Tag:         $RELEASE_TAG $([[ $TAG_ALREADY == 1 ]] && echo '(已存在)' || echo '')"
echo "  HEAD:        $HEAD_SHA $HEAD_SUBJECT"
echo "  Commit 范围: ${COMMIT_RANGE}"
[[ $SKIP_NOTARIZE == 1 ]] && echo "  ⚠️ 跳过公证 — 这份 dmg 用户下载会被 Gatekeeper 拦，仅限本地验证用"
echo "========================================="
echo "  下一步：上传 dmg 到 GitHub Releases，标题写 ${RELEASE_TAG}"
