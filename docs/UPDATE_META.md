# WillDeep 自动更新协议

WillDeep 使用 Sparkle 2 完成 macOS 应用的检查、下载、Ed25519 验签、退出、原子替换、失败回滚与重启。运行中的 `.app` 不会被当前进程直接覆盖；Sparkle 将安装工作交给独立 helper，在 WillDeep 退出后替换应用包。

## 公共接口

Sparkle appcast：

```text
GET /api/v1/public/app-updates/appcast.xml?app_id=willdeep&platform=macos&channel=stable
```

侧边栏版本提示继续使用 JSON 接口：

```text
GET /api/v1/public/app-updates/latest?app_id=willdeep&platform=macos&channel=stable&current_version=1.180.0-rc1
```

appcast 必须包含以下发布元数据：

- `latest_version`：面向用户的语义化版本，即 `sparkle:shortVersionString`。
- `bundle_version`：严格递增的正整数，即 `sparkle:version`；每次发布都必须增加。
- `download_url`：已签名并完成公证的 DMG 绝对地址。
- `file_size_bytes`：DMG 的精确字节数。
- `ed_signature`：Sparkle `sign_update` 对 DMG 生成的 Ed25519 签名。
- `minimum_system_version`：可选，最低 macOS 版本。
- `release_notes_url` 或 `release_notes`：可选，更新说明。
- `sha256`：用于后台审计与人工核验；Sparkle 安装信任以 Ed25519 签名为准。

macOS 更新记录缺少 `bundle_version`、`file_size_bytes` 或有效 `ed_signature` 时，服务端拒绝保存；已有不完整记录也不会生成可安装 appcast。修改为新的 `latest_version` 时，`bundle_version` 必须严格增加，同一版本修正签名或说明时可保持不变，但任何情况都不得降低。

## 发布流程

`scripts/release_mac_app.rb` 在完成 Developer ID 签名、DMG 制作和 Apple 公证后，会：

1. 调用 Sparkle 官方 `sign_update` 生成 `ed_signature` 和文件长度。
2. 上传带版本号的 DMG，并校验远端 SHA-256。
3. 使用 `SOMEIM_ADMIN_TOKEN` 创建或更新 muchtoken 的 `willdeep/macos/stable` 发布记录；`published_at` 使用数据库兼容的 UTC `YYYY-MM-DD HH:MM:SS` 格式。
4. 客户端下次自动检查或用户主动检查时，经 appcast 获取并安装该版本。

WillDeep 的 `release_notes_url` 固定为 `https://some.im/zh/products/willdeep/changelog`。该页面直接读取 stable appcast 当前发布记录中的 `release_notes`，因此更新窗口只展示本次发布说明，不再嵌入产品介绍页或完整仓库 CHANGELOG。发布脚本优先读取当前版本的 `### 用户可见变化`（英文可用 `### Highlights`）；未提供时仅从 Added、Changed、Fixed、Security、Removed、Deprecated 生成回退说明，Tests 与 Meta 永不进入更新弹窗。

如果 DMG 已公证并上传，但最后的元数据写入失败，可执行 `release_mac_app.rb --publish-metadata-only <DMG> --release-version <VERSION> --bundle-version <BUILD>`。脚本会重新校验 DMG 签名、公证票据、OSS 版本对象和 Sparkle 签名后再补发元数据，不重复构建、公证或上传。

Sparkle 私钥只保存在发布机器的登录钥匙串中，不进入源码、环境文件、构建日志或服务端数据库；客户端和仓库只保存公钥。
