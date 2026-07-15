# Xomo × some.im 生图接入方案

> 状态：设计草案（待评审，未开始编码）
> 撰写日期：2026-07-15
> 目标：给 Xomo（工程名 veilpic）接入 AI 生图/改图能力，数据与计费统一走 some.im 中转站。

## 0. 背景与战略定位

- **some.im 是收银台**：作者自有的 API 中转站，按 token 计费，支持 LLM、文生图（text2img）、图生图（img2img）、蒙版重绘（inpaint）、擦除、放大。
- **Xedit/WillDeep 已通电**：已接 some.im，消费 LLM token。
- **Xomo 是下一个水龙头**：本身是完整的原生 macOS 图像编辑器（图层/选区/蒙版齐全），是承接「选区内 AI 改图」最理想的宿主。每一次 AI 改图 = 消费一次 some.im token = 给中转站创收。
- **收费模型**：建议 Xomo 本体免费/买断，**AI 功能按 token 消费走 some.im 余额**，不在 App 层做订阅；包月 token 套餐留给 some.im 平台层（已有 Coding Plan 机制）。

## 1. 可行性总览

两头都各有大量现成设施，中间只需焊有限胶水。

| 能力 | some.im 侧（Xedit 已有） | Xomo 侧（现成） | 需新建 |
|---|---|---|---|
| 文生图 text2img | ✅ `images/generations` | 写回 `importImageLayer` | client POST |
| 图生图 img2img | ✅ `images/edits` + `image` | 选区抠图 `copied(selection:)` | body 拼装解耦 |
| 蒙版重绘 inpaint | ✅ `images/edits` + `image`+`mask` | mask 导出 + 写回 `importImageLayerIntoSelection` | mask 语义转换 |
| 擦除 erase | ✅ 同 inpaint 路径 | 同上 | 同上 |
| 放大 upscale | ✅ `images/generations` | — | client |
| 扩图 outpaint | ❌ 无专门入口 | canvas resize 有 | 边缘 mask + canvas 胶水 |

**可复用比例**：some.im 网络/账户链路约 70-75% 可搬；Xomo 侧约 60% 现成。

## 2. some.im 侧接口契约（来自 Xedit 现有实现）

- **Base URL**：国际 `https://some.im/v1`；中国 `https://api.niuwoai.com/v1`；支持自定义与自动探测。
- **鉴权**：`Authorization: Bearer <apiKey>` + `X-App-Version` / `User-Agent`。生图请求**不带** login secret。
- **端点后缀映射**：
  - `imageGeneration` → `images/async-generations`（异步：提交→轮询→下载）
  - `imageEdit / imageErase / imageInpaint` → `images/edits`
  - `imageUpscale` → `images/generations`
  - `videoGeneration` → `videos/generations`
- **默认模型**：图 `gpt-image-2`（可由 `/api/v1/public/model-pricing` 动态发现能力）。
- **请求 body**：
  - 文生图：`{ model, prompt, size?, response_format: "b64_json" }`
  - 图生图：+ `image`（base64 data URL）
  - 蒙版重绘：+ `image` + `mask`（均 base64 data URL）
- **响应解析**：宽容匹配 `id/task_id/...`、`status/state/...`、`output/data/url/b64_json`（中转站回包结构不稳定，Xedit 的 `parse()` 已做兼容）。
- **账户/余额**：`account/balance` + `customer/me`；扣费在服务端按 key 记账，客户端余额只是展示缓存。

## 3. 复用与移植清单

### 可原样/近原样搬（纯 networking/model，仅 import Foundation）
- `SomeIMAsyncMediaIntegration.swift`（提交/轮询/取消/下载/状态归一，~409 行）
- `SomeIMIntegration.swift` 的 `SomeIMClient` + `SomeIMIntegrationStore` + DTO
- 轻量依赖类型：`AgentJSONValue`、`AgentMediaArtifact/Kind/Status`、`AgentNetworkSupport`（需改硬编码的 `WillDeep/...` User-Agent）
- **外部包 `SomeIMSharedSession`**（`github.com/xurenlu/SomeIMSharedSession.git`）——直接加 SPM 依赖复用登录态

### 必须剥离/重写
- body 拼装逻辑（现和 `AgentMediaTaskRegistry`/`AgentToolContext` 混在一起，需抽纯函数）
- 设置界面、选区/mask UI（Xedit 的 `SomeIMIntegrationSettingsView`、`AgentImageEditPanel` 属 Xedit UI，Xomo 自己做）
- 标识常量：bundle id、Keychain access group 需改；**新 App 必须加入同一 `ZH2S7D6PL6.com.someim.shared` entitlement 才能共享登录态**

### 忽略
- `SomeIMManagedRouting.swift`（LLM 路由，与生图无关）、`AgentShortDrama*`、Replicate/Kling 分支

## 4. Xomo 侧挂载点（来自架构调查）

### 选区 → mask PNG（现成一条龙）
```
document.selection?.rasterizedMask(canvasSize:)   // ImageEditorSelectionBoolean.swift:41
  → NSImage.alphaMaskImage(width:height:alpha:)     // ImageEditorSelectionCommands.swift:1096
  → NSImage.qingtuPNGData()                          // ImageDataEncoding.swift:5
```
注意：底层是 white+alpha，需加灰度转换成实心黑白 RGB（参考 `quickMaskOverlayImage`）。

### 写回（现成，自带 undo+history）
- 选区内重绘：`importImageLayerIntoSelection(_:sourceName:...)`（`ImageEditorImport.swift:161`，自动放进选区包围盒 + 生成图层 mask + feather）
- 文生图新图层：`importImageLayer(_:...)`（`ImageEditorImport.swift:130`）
- 选区抠图（img2img 输入）：`NSImage.copied(selection:layerFrame:canvasSize:feather:)`
- AI 返回图先跑 `NSImage.normalizedBitmapImage()` 再入库

### 命令/菜单挂载（三入口统一）
- 菜单：`ImageEditorMenuBar.swift` 的 `HStack` 加一栏 `Menu { aiMenu }`（照抄 Figma 导入）
- 面板：`ImageEditorView.swift:181-194` 集中的 `.sheet` 加一个 AI 面板
- **推荐**：注册进 `XomoAutomationRegistry` 为 `xomo.ai.generate` / `xomo.ai.inpaint` / `xomo.ai.outpaint` 命令，一次打通菜单 + CLI + MCP 三入口

### 异步/进度/凭证（有模板，需仿写）
- controller 模板：`XomoFigmaNodeImportController`（state enum + `@Published` + `requestGeneration` 软取消）
- loading UI：`ProgressView().controlSize(.small)` + `.disabled(controller.isLoading)`
- 网络抽象：`protocol XomoFigmaHTTPTransport { data(for:) async }` + typed-error client 模板（`XomoFigmaMetadataAPI.swift:68`）
- 凭证：`XomoFigmaKeychainCredentialStore`（`init(service:account:)` 已支持，换字符串即可）

## 5. 最大技术障碍（按优先级）

1. **流式进度 + 真取消**：Xomo 现有 transport 是一次性 GET、超时 20-30s；AI 是几十秒长任务，需扩 transport（流式 `bytes(for:)` 或长轮询）、拉长超时、接 `URLSessionTask.cancel()` 真中断（现有 `requestGeneration` 只丢结果不断网）。**与现有架构最不吻合的一块。**
2. **mask 语义对齐**：white+alpha → 实心黑白 RGB，且对齐 inverted/feather。
3. **坐标系 Y 翻转**：canvas 是 Y-up，发图/发 mask 前须对齐缩放与翻转，否则重绘错位。

## 6. MVP 切法与工作量

**MVP = 只打通「选区内 AI 重绘」一条路**：框选 → 输入 prompt → 调 some.im 蒙版重绘 → 结果贴回选区。
- 理由：价值最高（P 图核心诉求）、写回端全现成、每次点击即烧 token。
- 打通后，文生图 / 扩图是同一管线的变体。

**建议实现路径**：新建 `XomoAIImageClient`（仿 Figma client）+ `XomoAIGenerationController`（仿 Figma import controller）+ 复用 Keychain store，注册 `xomo.ai.*` 命令并在 `menuBar` 加 `aiMenu`/`.sheet`；inpaint 写回直接调 `importImageLayerIntoSelection`。

**工作量粗估**（一人，复用现成件）：
- MVP 单路（选区内重绘）：**3-8 个工作日**
- 补文生图 + 扩图 + 进度条 + 真取消：**再 +1 周左右**

## 7. 发布前置（不阻塞接入，单列）

- **签名主体迁移**：当前 Developer ID 是 "Beijing Alibaba information Technology Co., Ltd."，若要换个人主体需换 Apple Developer 账号 + 重新签名公证（迁移步骤届时单列）。
- **entitlement**：加入 `ZH2S7D6PL6.com.someim.shared` 共享 Keychain 组（与主体迁移相关，需一并规划）。

## 8. 待确认问题（评审时定）

1. some.im 的 `images/edits` 是否支持 outpaint 模型/参数？（客户端侧目前无封装，需服务端确认）
2. 蒙版重绘对 mask 格式的确切要求（实心黑白 vs alpha）？
3. MVP 是否接受「无百分比进度、仅转圈 + 可软取消」作为第一版，把真取消/流式进度放 fast-follow？
4. Xomo 与 Xedit 是否即刻共享同一 some.im 登录态（需 entitlement + 主体对齐），还是 MVP 阶段 Xomo 先独立登录？
