# WillDeep 发布手册（Developer ID + 双重公证 + DMG + OSS）

> 一句话：发布由 **new83d 仓库的 `scripts/release_mac_apps.rb`** 执行，本仓库不再自带发布脚本；首次使用前需要准备 Developer ID 证书、Keychain 公证凭据和 `.env.local`。

> **入口变更（1.375.0-rc5）**：本仓库原有的 `scripts/release_mac_app.rb` 与
> `scripts/release.sh` 已删除。它们在很久以前就没有任何调用方了，而本文档一直
> 指向它们，属于误导。WillDeep 在 new83d 的发布配置里 slug 是 `veilwriter`。
> 第一节（证书与公证凭据）和"常见坑"与具体脚本无关，仍然有效。

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

至少填写 `WILLDEEP_CLIENT_LOGIN_SECRET` 与 `SOMEIM_ADMIN_TOKEN`。前者仅在构建期注入需要的登录能力，后者仅用于发布 some.im appcast 元数据；两者都会从发布日志中脱敏。`AIPIPE_API_KEY` 会作为构建环境传入但不会写入日志；OSS 凭据既可以放在本机 `~/.ossutilconfig`，也可以使用 `.env.local` 中的 `OSS_ACCESS_KEY_ID`、`OSS_ACCESS_KEY_SECRET`、`OSS_ENDPOINT`。`.env.local` 已被 Git 忽略，禁止提交真实凭据。

---

## 二、日常发布

发布在 **new83d 仓库**执行，不在本仓库：

```bash
cd ~/Sites/new83d

# 无副作用演练：只检查路径、版本、架构和配置
ruby scripts/release_mac_apps.rb --only veilwriter --dry-run

# 常规预发布（rc）：默认不推 Sparkle 自动更新
ruby scripts/release_mac_apps.rb --only veilwriter --run-tests --skip-update-metadata

# 本地验证：不公证、不上传
ruby scripts/release_mac_apps.rb --only veilwriter --skip-notarize --skip-upload

# 完整参数
ruby scripts/release_mac_apps.rb --help
```

也可以直接用 `release-macos-app` skill，它封装了同一套流程。

### 关于 appcast（自动更新）

**默认不推送 appcast**，除非当次明确要发。appcast 是推送通道，用户不点也会
收到更新，而预发布只编 arm64——推给 Intel 存量用户会装成打不开的包，且旧版本
已被覆盖。产物、`latest` 链接和 GitHub Release 照常发，被关掉的只是自动更新
这一条通道。

### 关于架构

带 `-rc` 的版本走 arm64 快路（省约 45% 构建时间），正式版仍出 universal。
`--arm64-only` / `--universal` 可强制覆盖。两种架构使用各自的 DerivedData
目录，交替发布不会互相踩掉增量树。

---

## 三、常见坑

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

## 四、撤销与重发

万一发出去的版本有大坑，notarization 本身没有"撤销"动作 —— 你能做的：

1. 立刻发新版（rc + 1）+ 新公证票。
2. 在下载页 / GitHub Releases 把旧 dmg 删掉，写明"已撤回，请升级到 vX"。
3. 如果是签名密钥泄露级别的事故，到 Apple Developer 后台 Revoke 该 Developer ID 证书 —— 这会让所有用该证书签过的 app 都失效，慎用。

---

