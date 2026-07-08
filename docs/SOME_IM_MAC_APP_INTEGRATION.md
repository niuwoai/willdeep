# some.im Mac App Integration

> Last updated: 2026-07-08 | Current version: v1.136.0-rc25

本文档说明 WillDeep macOS App 如何接入 some.im。目标是让用户用最短路径完成账号连接：在 WillDeep 里点击“在浏览器打开”，到 some.im 完成登录，然后回到 WillDeep 继续使用。API key、customer session 等敏感信息只保存在本机 Keychain，不进入 UI、日志、文档示例或 git。

## 目标体验

### 推荐路径：浏览器登录 some.im

1. 用户进入 Onboarding 的 some.im 步骤，或 Settings -> some.im。
2. WillDeep 自动生成浏览器登录请求，不要求用户先点“生成链接”。
3. 用户点击“在浏览器打开”。
4. some.im 页面完成登录，并提示用户回到 WillDeep。
5. WillDeep 轮询 some.im browser-status，拿到 app 专用 API key、customer session、账号信息和默认模型。
6. WillDeep 自动配置：
   - Agent provider：`some-im` + `someim-auto-flash`
   - Image Understanding / VL fallback：`some-im` + `qwen3-vl-plus`
   - 图片默认模型：`gpt-image-2`
   - 视频模型列表按 some.im 返回或用户设置走

### 可跳过路径：用户自己配置 provider

用户可以跳过 some.im，自己填一个 AI provider 的 API key 和模型。若所选主模型不支持图片输入，Onboarding 必须要求补充一个 VL/视觉模型配置：

- VL provider
- VL Base URL
- VL API key（该 provider 需要时）
- VL model

这个 fallback 仍应明确建议用户直接接入 some.im，因为 some.im 能一次性处理聊天、图片/视频生成和视觉兜底。

## 核心文件

| 文件 | 职责 |
| --- | --- |
| `Xedit/SomeIMIntegration.swift` | some.im 设置、账号存储、浏览器登录请求、状态轮询、账号余额、模型拉取、图片生成客户端 |
| `Xedit/SomeIMAsyncMediaIntegration.swift` | some.im 图片/视频异步媒体任务适配 |
| `Xedit/AppStateAgentSessions.swift` | 将 some.im 同步到 Agent provider library 和 image understanding |
| `Xedit/Onboarding/OnboardingView.swift` | 首启 provider / some.im / VL fallback 配置 |
| `Xedit/AgentModels.swift` | Provider preset、Agent 配置、模型是否支持图片输入的判断 |
| `Xedit/AgentSettingsStore.swift` | Agent 配置、provider library、Keychain 读写 |
| `Xedit/Localizable.xcstrings` / `Xedit/L10n.swift` | 设置页和 onboarding 的可见文案 |

## 浏览器登录协议

WillDeep 侧生成一次性登录请求：

- `code`：短随机码，用于服务端识别登录会话。
- `pairToken`：长随机配对 token，只放进浏览器登录 URL 和后续 `Authorization` header，不展示给用户。
- `url`：打开 some.im 的浏览器登录页，携带 `client_id=willdeep`、`code`、`pair_token` 等参数。

实现入口：

```swift
let request = try SomeIMClient.makeBrowserLoginRequest(settings: settings.normalized)
```

状态轮询：

```swift
let status = try await SomeIMClient.checkBrowserLoginStatus(
    request: request,
    settings: currentSettings
)
```

状态处理约定：

- `pending`：继续等待。
- `connected` + account + api key：保存凭据，配置 provider，清空当前登录请求。
- `connected` 但缺凭据：停止等待并显示明确错误。
- `expired`：清空当前登录请求，提示用户重新打开 some.im。
- 网络错误：短暂记录错误，轮询到 10 分钟截止。

## 本地存储边界

`SomeIMIntegrationStore` 是 some.im 本地状态入口：

- `saveSettings(_:)`：保存非敏感设置到 `UserDefaults`。
- `saveAccount(_:)`：保存账号摘要到 `UserDefaults`，用于显示邮箱、credits、默认模型。
- `saveAPIKey(_:)`：保存 some.im app 专用 API key 到 Keychain。
- `saveSessionToken(_:)`：保存 customer session token 到 Keychain。
- `loadClientLoginSecret()`：从环境变量 `WILLDEEP_CLIENT_LOGIN_SECRET` 或 Info.plist 注入值读取客户端登录签名 secret。

严禁：

- 把 API key、session token、client-login secret 写入示例文档、日志、提交信息或 UI 明文。
- 把 pair token、完整登录 URL 或二维码作为默认 UI 展示。
- 在 SwiftUI 里硬编码用户可见文案；必须走 `L10n` 和 `Localizable.xcstrings`。

## 成功登录后的同步

浏览器登录成功后必须做两件事。

### 1. 同步 Agent provider

```swift
appState.syncSomeIMProvider(settings: settings, apiKey: apiKey)
```

该方法应确保 provider library 中存在并激活 some.im entry：

- `providerID`: `some-im`
- `baseURL`: some.im 当前 base URL
- `apiKey`: Keychain 中读取出的 some.im app key
- `flashPrimary`: `someim-auto-flash`
- `proPrimary`: 沿用已有 pro 模型或默认文本模型
- `routingMode`: `.flash`

### 2. 同步 Image Understanding / VL fallback

```swift
appState.syncSomeIMImageUnderstanding(apiKey: apiKey)
```

默认值：

- `providerID`: `some-im`
- `baseURL`: 当前实现使用 `SomeIMRelayRegion.chinaBaseURL`
- `model`: `SomeIMIntegrationSettings.defaultVisionModel`，当前为 `qwen3-vl-plus`
- `apiKey`: same some.im app key

这一步保证主聊天模型是文本模型时，用户粘贴图片仍可先经 VL 模型生成描述，再交给主模型。

## Onboarding 设计

Onboarding 有两条互补路径。

### Provider 步骤

用户可以手动配置：

- provider
- base URL
- API key
- default model

保存时写入 `agentProviderLibrary` 并激活该 entry。若主模型不支持图片输入，必须展开 VL fallback 表单。

判断方式：

```swift
AgentConfiguration.modelAcceptsImageInput(model)
```

当前规则较保守：

- DeepSeek 非 `vl` 模型视为文本模型。
- `someim-auto*` 视为文本模型。
- 未知模型默认放行，避免误伤自定义多模态模型。

### some.im 步骤

用户推荐走 some.im 浏览器登录。该步骤：

- 进入即自动准备浏览器登录请求。
- 只提供“在浏览器打开”。
- 不显示邮箱验证码表单。
- 不显示二维码、随机码、完整 URL 或 pair token。
- 可跳过。

登录成功后同步 provider 和 VL fallback，然后用户继续走 Voice / Done 步骤。

## Settings -> some.im 设计

Settings 中的 some.im 页面与 Onboarding 保持同一心智：

- 自动准备浏览器登录请求。
- 主操作只有“在浏览器打开”。
- 登录完成后显示账号、credits、默认模型。
- 保留启用开关、region/base URL/API key 和模型列表等高级配置，但浏览器登录区不展示调试信息。

如果将来需要重新引入高级调试入口，应放进折叠区，并明确标注不适合普通用户。

## 图片/视频生成

同步 some.im 后，WillDeep 的图像和媒体工具应优先走 some.im：

- 普通 Agent 生图：`generate_image` 复用 `some_im_create_media_task`，默认提交 `images/async-generations` 并登记到媒体任务中心。
- 异步媒体任务：`SomeIMAsyncMediaClient.submit(...)` / `poll(...)` / `cancel(...)`，图片生成默认 `images/async-generations`，视频默认 `videos/generations`，图片编辑默认 `images/edits`。
- 同步图片低层客户端：`SomeIMClient.generateImage(...)` 仅作为兼容/低层能力保留，Agent 默认生图不应再用它阻塞等待同步响应。
- 默认图片模型：`gpt-image-2`
- 视频模型：由 Settings -> some.im 的首选视频模型列表控制
- some.im 媒体任务提交、轮询、取消请求的单次 `URLRequest.timeoutInterval` 应使用 600 秒 `AgentNetworkSupport.resourceTimeout`，避免客户端先于网关取消长耗时生图。

媒体任务完成后应进入统一媒体任务中心，由既有 artifact 下载与预览流程处理。

## API 与响应版本可观测性

客户端所有网络请求应继续使用：

- `AgentNetworkSupport.applyStandardHeaders(to:)`
- `X-App-Version`
- 统一 User-Agent

服务端或 relay 响应应暴露版本 header 或等价字段，便于排查版本错配。仓库版本位点必须由 `scripts/version_consistency.rb` 保持一致。

## 安全检查清单

- [ ] API key 和 session token 只进 Keychain。
- [ ] client login secret 只从环境变量或 Info.plist 注入读取。
- [ ] UI 不显示 pair token、完整浏览器登录 URL 或二维码。
- [ ] 日志、错误、测试 fixture 不含真实 token。
- [ ] 所有用户可见文案走 i18n。
- [ ] Onboarding 可跳过 some.im。
- [ ] 手动 provider 的文本模型路径要求 VL fallback。
- [ ] 成功登录后同时同步 provider library 和 image understanding。

## 推荐验证

静态检查旧 UI 是否残留：

```bash
rg -n "emailCodeLabel|sendCode\\(|verifyCode\\(|QRCode|browserLoginRequest\\.url\\.absoluteString" Xedit/Onboarding/OnboardingView.swift Xedit/SomeIMIntegration.swift
```

版本与本地化：

```bash
ruby scripts/version_consistency.rb
ruby scripts/i18n_validate_translations.rb Xedit
```

构建：

```bash
xcodebuild -project Xedit.xcodeproj \
  -scheme Xedit \
  -configuration Debug \
  -destination platform=macOS \
  -derivedDataPath build/DerivedData \
  build CODE_SIGNING_ALLOWED=NO
```

真实联调：

1. 清理本机 some.im account/API key/session token。
2. 打开 Onboarding 或 Settings -> some.im。
3. 确认页面自动准备登录请求。
4. 点击“在浏览器打开”。
5. 在 some.im 登录。
6. 回到 WillDeep，确认账号状态、provider library、image understanding 均已同步。
7. 用文本模型发一张图片，确认走 VL 描述兜底而不是直接把 `image_url` 发给文本模型。

## 变更时的发布要求

修改 Swift 代码或内置 skill 行为时：

1. 递增 rc 版本号。
2. 更新 `CHANGELOG.md`。
3. 更新 `product-overview.md`。
4. 跑 `scripts/version_consistency.rb`。
