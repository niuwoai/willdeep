# WillDeep 发布手册（Developer ID + 双重公证 + DMG + OSS）

> 一句话：用 `ruby scripts/release_mac_app.rb` 完成 Release 编译、App 公证、DMG 公证和 OSS 上传；首次使用前需要准备 Developer ID 证书、Keychain 公证凭据和 `.env.local`。

---

## 一、首次准备（只做一次）

### 1. 装好 Developer ID Application 证书

钥匙串里执行下面这条，应当看到 `Developer ID Application: Beijing Alibaba ... (ZH2S7D6PL6)`：

```bash
security find-identity -v -p codesigning
```

如果没有：

1. 登录 https://developer.apple.com → Certificates, Identifiers & Profiles。
2. 左侧 Certificates → 右上 ➕ 新增 → 选 **Developer ID Application**（不是 Mac App Distribution）。
3. 按提示用 Keychain Access 生成 CSR（"钥匙串访问" → 菜单 → 证书助理 → 从证书颁发机构请求证书）。
4. 上传 CSR、下载 .cer、双击导入钥匙串。

> 提示：Developer ID 证书只有 Team Admin / Account Holder 角色才能签发；普通 Member 看不到这个选项。如果你不是 Admin，找团队管理员申请。

### 2. 生成 App-Specific Password（公证密码）

> 这是个**只用来给 notarytool 用的一次性密码**，不是你 Apple ID 本身的密码。生成后建议存一份在 1Password 之类的密码管理器里。

操作步骤：

1. 浏览器打开 https://account.apple.com（Apple ID 管理后台，不是 developer.apple.com）。
2. 用**绑定到 Apple Developer 账户的同一个 Apple ID** 登录。
3. 在「登录与安全」（Sign-In and Security）面板里，找到「**专用密码**」（App-Specific Passwords）—— 如果你没找到这个入口，意味着这个 Apple ID 还没开两步验证（2FA），先开 2FA。
4. 点「**生成专用密码**」(Generate an app-specific password)。
5. 给它取个标签，例如 `notarytool-willdeep`。
6. 屏幕会显示一串形如 `xxxx-xxxx-xxxx-xxxx` 的密码 —— **现在抄下来**，关掉之后再也看不到原文。

### 3. 把公证密码存进 Keychain

不要把密码直接放在脚本里。`notarytool` 提供了 `store-credentials` 子命令，把上面那串密码加密存到 macOS Keychain，以后脚本只引用 profile 名：

```bash
xcrun notarytool store-credentials veilwriter-notary \
  --apple-id "你的 Apple ID 邮箱" \
  --team-id "ZH2S7D6PL6" \
  --password "刚才生成的 xxxx-xxxx-xxxx-xxxx"
```

- `veilwriter-notary` 是默认 profile 名，可通过 `.env.local` 的 `NOTARY_PROFILE` 或命令行 `--notary-profile` 覆盖。
- `--team-id` 是你的 Developer Team ID（WillDeep 是 `ZH2S7D6PL6`）。
- 成功会输出 `This process stores your credentials securely in the Keychain.`

验证一下：

```bash
xcrun notarytool history --keychain-profile veilwriter-notary
```

能列出历史（哪怕是空的）就说明配置好了。

### 4.（可选）装 create-dmg 让 DMG 更漂亮

```bash
brew install create-dmg
```

没装也能跑（脚本会回落到 `hdiutil` 出素面 dmg），装了能得到带 Applications 拖拽快捷方式的安装页。

### 5. 准备 `.env.local`

```bash
cp .env.example .env.local
```

至少填写 `WILLDEEP_CLIENT_LOGIN_SECRET`。`AIPIPE_API_KEY` 会作为构建环境传入但不会写入日志；OSS 凭据既可以放在本机 `~/.ossutilconfig`，也可以使用 `.env.local` 中的 `OSS_ACCESS_KEY_ID`、`OSS_ACCESS_KEY_SECRET`、`OSS_ENDPOINT`。`.env.local` 已被 Git 忽略，禁止提交真实凭据。

---

## 二、日常发布

```bash
# 先做无副作用演练，只检查路径、版本和配置
ruby scripts/release_mac_app.rb --dry-run

# 完整流程：测试 → Release archive → App 公证 → DMG 公证 → OSS
ruby scripts/release_mac_app.rb

# 本地签名打包，不公证也不上传
ruby scripts/release_mac_app.rb --skip-notarize --skip-upload

# 已在其他流程跑完测试时跳过测试
ruby scripts/release_mac_app.rb --skip-tests
```

产物路径：`build/mac-releases/veilwriter/WillDeep-<版本号>.dmg`。默认上传两个对象：

- `oss://sz-trans/mac-apps/WillDeep-<版本号>.dmg`
- `oss://sz-trans/mac-apps/latest/WillDeep.dmg`

JSON 和 Markdown 发布报告位于同一构建目录。旧的 `scripts/release.sh` 仍保留给本地备份、tag/push 等历史工作流，但不负责 OSS 上传。

发布前的检查清单：

- [ ] `CHANGELOG.md` 已经写了本次条目。
- [ ] `MARKETING_VERSION` 已经按规则更新（bugfix 递增 rc，新功能升正式版位）。
- [ ] 一份干净的 `git status`，没有未提交的脏改动。
- [ ] 跑过 `xcodebuild ... build` 确认无警告。

---

## 三、脚本做了什么（按步骤拆解）

| 步 | 命令 | 干什么 |
|---|---|---|
| 1 | `.env.local` 白名单加载 | 只加载发布需要的凭据键；敏感值从日志中统一脱敏 |
| 2 | `xcodebuild test` | 默认先跑 `XeditTests`，失败立即停止 |
| 3 | `xcodebuild archive` | 以 Release 配置产出 `.xcarchive` |
| 4 | `xcodebuild -exportArchive` | 用 `method=developer-id` 导出 Developer ID 签名的 `.app` |
| 5 | `notarytool submit App ZIP` | 单独公证 App，成功后把票据装订到 App |
| 6 | `create-dmg` 或 `hdiutil` | 把已装订 App 与 Applications 快捷方式打成 DMG |
| 7 | `codesign DMG` | 使用同一 Developer ID 身份签名最终 DMG |
| 8 | `notarytool submit DMG` | 单独公证最终分发物，成功后装订 DMG 票据 |
| 9 | `codesign` / `stapler` / `spctl` | 校验签名、公证票据和 Gatekeeper 状态 |
| 10 | `ossutil cp` | 上传版本对象与 `latest` 对象，并通过 `ossutil stat` 复核 |

---

## 四、常见坑

### 公证失败：`Invalid` / `code object is not signed at all`
- `ENABLE_HARDENED_RUNTIME` 必须是 YES（项目里已设）。
- 第三方动态库（如果将来引入）必须每个都签名 + hardened runtime。
- 排查：`xcrun notarytool log <submission-id> --keychain-profile veilwriter-notary` 拿到 JSON 报告，里面会指出具体哪个二进制有问题。

### `errSecInternalComponent` / 签名时报 Keychain 错
- 多半是钥匙串解锁状态丢了。终端执行 `security unlock-keychain ~/Library/Keychains/login.keychain-db` 再重跑。
- CI 场景：用 `security create-keychain` 建一个专门的 keychain，并 `security set-keychain-settings -lut 21600` 延长解锁时间。

### `notarytool` 一直 `In Progress`
- 现在偶尔会卡，但极少超过 30 分钟。脚本会一直等。
- 真要提前看状态：`xcrun notarytool history --keychain-profile veilwriter-notary`。

### App-Specific Password 找不到入口
- 必须开 2FA。开了之后入口才会出现在 https://account.apple.com → 登录与安全。

### Gatekeeper 还是拦
- 用 `spctl -a -vvv -t install path/to.dmg` 看具体原因。
- 公证完成但没 staple → 用户离线时仍会被拦。脚本第 6 步做了 staple，别跳过。
- 也可能是浏览器下载时附加的 quarantine 属性引起的提示框，公证过的应用第一次打开仍会问"你下载了 X，确定打开吗？"，这是正常的——不是拒绝，是确认。

---

## 五、撤销与重发

万一发出去的版本有大坑，notarization 本身没有"撤销"动作 —— 你能做的：

1. 立刻发新版（rc + 1）+ 新公证票。
2. 在下载页 / GitHub Releases 把旧 dmg 删掉，写明"已撤回，请升级到 vX"。
3. 如果是签名密钥泄露级别的事故，到 Apple Developer 后台 Revoke 该 Developer ID 证书 —— 这会让所有用该证书签过的 app 都失效，慎用。

---

## 六、本地备份与快速回滚

rc3 起 `release.sh` 在每次成功打包后自动把新出炉的 `.app` 与 `.dmg` 整体拷一份到：

```
build/release-history/<版本号>/
```

同时把"上一次跑过的版本号"写进 `build/release-history/latest.txt`。这套备份**不会**被下一次 `release.sh` 开头的 `rm -rf build/release` 清掉（它在 `build/release-history` 下，是同级目录）。`build/` 整目录已在 `.gitignore` 里，所以备份不会污染仓库。

```bash
# 看本地有哪些可回滚的旧版本（按时间倒序）
scripts/release.sh --list-backups

# 直接装上一个旧版本（开发机）
open build/release-history/1.54.0/WillDeep-1.54.0.dmg
```

线上分发的真正 source of truth 仍然是 **GitHub Releases**。本地这份只是给开发机一份"还没 push 上去就先回滚"的兜底；正式回滚动作要把旧 dmg 重新放回下载页。

---

## 七、监视 GitHub Actions

`push` 到 `main` 会触发 `.github/workflows/test.yml`，在 macos-15 上跑一遍 XeditTests。本地 `release.sh` 在你确认 push 之后会同步盯一下这条 run：

- 装了 `gh` CLI 时，脚本调 `gh run watch --exit-status` 同步等待。失败会打印 `gh run view --log-failed` 提示你看红条。
- 没装 `gh` 时，脚本把仓库的 `actions/` URL 打到屏幕上让你自己开浏览器看。

如果你看到 `⚠️ GitHub Actions 失败`：本地这次 release 已经成功（dmg 也备份过了），只是远程 CI 没过。先别上传 dmg 到 Releases，把 CI 问题修了再发新 rc。
