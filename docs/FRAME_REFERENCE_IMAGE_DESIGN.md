# 首尾帧生成附角色参照图设计

> Last updated: 2026-09-12 | 状态：**方案已确认，尚未动代码**（2026-09-12 用户拍板两条：附谁的脸走「界面多选 + 预勾选」，模型默认切 nano-banana-2 且两个都开参照图。第 8 节三项待确认未答复前不进入实现）
> 关联版本：基于 1.371.0-rc1（工作分支 `fix/todo-attach-and-inline-edit` 之后另起分支）
> 适用范围：短剧工坊插件（`willdeep-video-studio`）的首尾帧生成，以及宿主给插件页的图像生成接口
> 关联文档：`docs/SHORT_DRAMA_MVP_*`、muchtoken 的 `docs/15-API接口规范.md`
> 一句话：首尾帧生成现在只发一段文本，本设计把「角色形象图」作为参照图一起送上去，让同一个角色跨镜头、跨集保持同一张脸。

---

## 0. 需求来源

用户在「05 首尾帧」这一步提出：

> 现在生成首帧图，是只有文本，没有附参照图的，我希望改一下，能附人脸（角色）作为参照图。但是我不清楚 gpt-image-2 能否引用参照图中的人脸？或者 nano-banana-2 能同时参照一下人脸，做出就用这个人脸中的首帧呢，这样才能保持人脸一致

问题里的那个疑问先回答，它决定了方案形状：**两个模型都支持参照图，而且都支持多张**。详见第 2 节的实测结论。

---

## 1. 现状盘点

### 1.1 生成链路：四层各自白名单，文本之外的字段进不去

| 位置 | 现在干什么 |
| --- | --- |
| `PluginExamples/video-studio/ui/src/App.tsx:1794` | 首尾帧那一栏的按钮，调 `generateFrames(kind)` |
| `PluginExamples/video-studio/ui/src/App.tsx:1404` | `generateFrames`：取 `shotDraft.startPrompt` / `endPrompt`，落盘镜头，再调 `drawImages(prompt, count)` |
| `PluginExamples/video-studio/ui/src/App.tsx:665` | `drawImages`：请求体只有 `{ prompt, provider:'some-im', model, size:'1024x1536' }`。并发 2，最小间隔 1 秒 |
| `Xedit/AgentPluginPageHost.swift:361` | 注入 `window.willdeep.ai.generateImage`，桥接到 `aiGenerateImage` |
| `Xedit/AgentPluginAIBridge.swift:128` | `AgentPluginImageRequest` 只有 `prompt` / `model` / `size` 三个字段 |
| `Xedit/AgentPluginAIBridge.swift:211` | 校验器只读 `prompt`/`provider`/`model`/`size`，**其余键直接丢弃** |
| `Xedit/AgentPluginAIBridge.swift:574` | `runPluginImageGeneration` → `SomeIMClient.generateImage` |
| `Xedit/SomeIMIntegration.swift:986` | 端点写死 `images/generations`，请求体只有 `model`/`prompt`/`size` |

Ruby 服务端**不在生成路径上**，它只负责记账：`drama.recordImage` → `drama.record_image`（`PluginExamples/video-studio/server/lib/drama_service.rb:457`），把候选追加进 `startCandidates` / `endCandidates`，并用 `generated_media_path`（`drama_service.rb:625`）把 `filePath` 钳死在插件媒体根目录内、拒绝符号链接。

所以「多送一个字段」在任何一层漏改都会被静默丢掉，**不会报错**。这是本设计最容易出错的地方，第 7 节为此单列守卫。

### 1.2 宿主已经有带参照图的实现，但插件页够不着

`Xedit/AgentMediaTools.swift:218` 的 `editGeneratedImage` 和 `:138` 的 `editImageWithMask` 都会带参照图，走 `Xedit/AgentMediaTools.swift:1123` 的 `someIMRequestBody`，把图编成 base64 data URL 塞进**单个 `image` 键**。这条路只对 Agent 工具开放，插件页没有入口；而且它是单图，对不上「多张脸」。

真正可以照抄的先例是**视频生成**：`App.tsx:1440` 已经在把 `referenceImagePath: start.filePath` 递给宿主。同一套「插件页交本地文件路径、宿主自己读字节」的信任模型直接复用即可。

### 1.3 角色形象图：可定位，且已经在受信目录里

`PluginExamples/video-studio/ui/src/types.ts:47` 的 `Character` 带 `candidates: FrameCandidate[]` 和 `selectedCandidateID`；选中的那张由 `App.tsx:1562` 按 id 在本角色的 candidates 里查。落盘实测（`plugin-data/willdeep-video-studio/dramas.json`）：

```
name= 陈默  selectedCandidateID= 732ed42d-…  identityVersion= 1  nCand= 2
mediaURL= willdeep-plugin://bundle/__media__/willdeep-generated-image-20260909-142236.png
filePath= /Users/rocky/Library/…/plugin-data/willdeep-video-studio/generated-images/willdeep-generated-image-20260909-142236.png
```

两点要点：

- **`filePath` 才是能当参照图用的那个**。`mediaURL` 只是 `__media__/` 下的裸文件名，是给 `<img src>` 用的另一种表示，两者不可互换。
- `filePath` 本来就落在 `AgentPluginGeneratedMediaResolver.directory(pluginID:)` 返回的那个目录里，所以参照图参数可以用**同一个根**做钳制，不新增信任面。

### 1.4 镜头不知道自己有哪些角色

`types.ts:38` 的 `Shot` 和服务端 `drama_service.rb:72` 的 `SHOT_DEFAULTS` 都**没有**角色关联字段。实际落盘的镜头键只有：

```
actionEnd, actionStart, cameraIntent, dialogue, draft, draftRev, duration,
endCandidates, endPrompt, id, order, rev, selectedEndID, selectedStartID,
startCandidates, startPrompt, summary, title
```

唯一的隐含线索是 `dialogue[].speaker`（自由文本名字，不是角色 id），而且**实测抽样的镜头 `dialogue` 是空数组**——分镜里无对白镜头很常见。这一条直接否掉了「纯靠说话人自动推断」的方案：它会在大量镜头上静默附不上任何脸。

### 1.5 模型列表是硬编码的，四处各存一份

- `App.tsx:16` `const imageModels: ImageModel[] = ['gpt-image-2', 'nano-banana-2']`
- `types.ts:62` `export type ImageModel = 'gpt-image-2' | 'nano-banana-2'`
- `drama_service.rb:9` `IMAGE_MODELS = %w[gpt-image-2 nano-banana-2].freeze`
- `AgentPluginAIBridge.swift:133` `static let allowedModels = ["gpt-image-2", "nano-banana-2"]`

默认值 `gpt-image-2`、张数 4 在 `App.tsx:133`。provider 固定 `some-im`，尺寸固定 `1024x1536`。

---

## 2. 上游到底支持什么（实测，不是推断）

### 2.1 两个模型都支持参照图，都支持多图

| 模型 | 上游形态 | 参照图字段 |
| --- | --- | --- |
| `gpt-image-2` | OpenAI 严格 edits，multipart/form-data | 单图 `image`，多图自动切 `image[]`（`muchtoken/internal/asyncmedia/openai_image.go:336`） |
| `nano-banana-2` | GRSAI `/v1/draw/nano-banana`，JSON | 原生 `urls` 数组（`muchtoken/internal/asyncmedia/grsai_async.go:177`），另兼容塞一份 `image_url` |

### 2.2 对外正路是 generations 带参照图，edits 已经下线

实测 `POST https://some.im/v1/images/edits` 返回 **HTTP 410**，报错正文就指向替代路径（`muchtoken/internal/gateway/image_edits_gone.go:9`）：

> POST /v1/images/edits has been removed; use POST /v1/images/generations (optional image_url or reference_image_url) and GET /v1/images/generations/{task_id} for results.

所以**不要照着 edits 那套写**。顶层可用的参照图字段（`muchtoken/internal/gateway/openai_images_payload.go:23`）：`image_url`、`reference_image_url`、`image_urls[]`、`reference_image_urls[]`、`images[]`，上限 9 张。

### 2.3 能力端点对图像模型一个字都给不出来

`/v1/models` 和 `/v1/model-capabilities` **在设计上只吐 LLM**：`muchtoken/internal/gateway/model_capabilities.go:121` 注释写明「image / video 模型不在本接口的范围内」，`internal/gateway/models_list.go:14` 的判据是 `billing_mode == llm_token` 或 `capability_kinds` 含 `llm`，图像模型按图计费，两条都不满足。实测 49 条记录里图像模型 0 条。

更刺眼的是 `generation_task_types`——本来就该区分 `text_to_image` / `image_to_image` / `multi_image_to_image` 的那个字段，枚举早在 `muchtoken/internal/pricing/catalog_meta.go:26` 定好了，**线上返回全是空数组**。

结论：**客户端现在没有任何公开信号可以判断「哪个图像模型吃参照图」**，只能继续硬编码。这一条写进第 8 节作为后续项。

### 2.4 计费按请求判定，附几张脸直接影响单价

`muchtoken/internal/asyncmedia/image_gen_kind.go:11`：0 张参照图算 `text_to_image`，1 张算 `image_to_image`，≥2 张算 `multi_image_to_image`，计费口径同（`internal/pricing/mediataskkind.go:33`）。所以界面上必须让用户看得见自己勾了几张脸——这不是装饰，是花钱的口径。

---

## 3. 已确认决策（2026-09-12）

1. **附谁的脸 = 界面多选 + 预勾选。** 在首尾帧那一栏加一个角色多选控件，默认预先勾好，用户可改。不动持久化格式。
2. **模型 = 默认切 `nano-banana-2`，两个都开参照图。** 人物一致性是 nano-banana 这一族的主打能力；`gpt-image-2` 保留可选，也带参照图。

### 3.1 对决策 1 的一处收窄（实现时定，已在 1.4 给出依据）

用户拍板时的表述是「按说话人预勾选」。但 1.4 的落盘实测显示无对白镜头的 `dialogue` 是空数组，只认说话人会让预勾选在大量镜头上**恒为空**，等于没有预勾选。所以预勾选的判据放宽为：

> 把角色名字在本镜头的 `summary`、`actionStart`、`actionEnd`、`startPrompt` / `endPrompt` 以及 `dialogue[].speaker` 里做出现匹配，命中即预勾选。

仍然只是**预勾选**，一律可改，所以匹配错了代价是用户取消一个勾，不是生成错一张图。匹配用 `key()` 同级的归一化（NFC + 去空白），中文名不做分词。

---

## 4. 方案

### 4.1 分层改动

**插件 UI（`PluginExamples/video-studio/ui/src/`）**

- `types.ts`：`ImageModel` 默认值语义不变；新增参照图请求字段类型。
- `App.tsx:16`：`imageModels` 顺序调整，`nano-banana-2` 在前；`App.tsx:133` 默认值改成 `'nano-banana-2'`。
- 首尾帧栏新增角色多选：数据源是 `drama.characters` 里**已锁定形象图**的角色（`selectedCandidateID` 非空且能查到候选）。没锁形象图的角色置灰并说明「先在『角色固化』里锁一张形象图」。
- `drawImages` 增加 `referenceImagePaths: string[]` 参数，取自各角色选中候选的 `filePath`（**不是 `mediaURL`**）。
- 角色形象图自己的生成路径（`App.tsx:699` 也走 `drawImages`）显式传空数组，保持纯文生图——给角色画形象图时拿自己的脸当参照没有意义。

**宿主（`Xedit/`）**

- `AgentPluginAIBridge.swift:128` `AgentPluginImageRequest` 增加 `referenceImagePaths: [String]`。
- `AgentPluginAIBridge.swift:211` 校验器读该字段，并逐条钳制：
  - 必须是绝对路径，且规范化后落在 `AgentPluginGeneratedMediaResolver.directory(pluginID:)` 之内；
  - 拒绝符号链接（和 Ruby 侧 `generated_media_path` 同一条判据）；
  - 必须是常规文件、必须是图片扩展名、单张受现有媒体大小上限约束；
  - 张数上限 **9**（跟上游一致），超出即报错而不是静默截断。
- `runPluginImageGeneration`（`AgentPluginAIBridge.swift:574`）在有参照图时改走带参照图的客户端路径，无参照图时保持现在的 `SomeIMClient.generateImage` 不变。
- 桥接版本号（`AgentPluginPageBridgeVersion.swift`）升次版本，能力串保持 `ai.image`——这是同一能力的扩展，不是新能力，不需要插件重新申请权限。

**插件清单**：`permissions` 已含 `ai.image`，无需改。参照图读取发生在宿主侧，插件只递路径。

### 4.2 本地文件怎么变成参照图（已定，靠读代码定的，没花钱）

结论：**data URL 走不通，必须先上传换一个公网 URL。**

判据在网关代码里，不需要实测：

- gpt-image-2 走 OpenAI 严格 edits，网关拿到参照图地址后用普通 HTTP GET 去取字节——`muchtoken/internal/asyncmedia/openai_image.go:271` 的 `fetchImageBytesForOpenAI` 是 `http.NewRequestWithContext(ctx, GET, url)` 加 `Do`，Go 的 HTTP 客户端取不了 `data:` 开头的地址。
- nano-banana-2 走 GRSAI，`urls` 数组是原样透给上游的，data URL 同样落不了地。
- 整个 `internal/asyncmedia` 与 `internal/gateway` 里**没有任何一处解码输入侧的 data URL**。那些 `data:` 前缀判断全是 SSE 行解析，那些 base64 解码全是在处理**上游返回的结果**。

现成的上传通道已经有了，而且文档里就是为这件事写的（`muchtoken/web/public/llms.txt:65`）：

| 端点 | 用途 |
| --- | --- |
| `POST /api/v1/customer/tmp-files` | 服务端中转，多部分表单 `file` 字段，直接返回 `public_url` |
| `POST /api/v1/customer/tmp-files/upload-url` + PUT + `/complete` | 浏览器直传后验真，客户端用不上 |

要点：

- **认证**：`Authorization: Bearer sk_...` 网关 API Key 即可（`internal/authapi/customer_api_key_auth.go:52`），不必是登录会话。注意 `docs/15-API接口规范.md:97` 写的是「不使用 sk_... 网关 API Key」，与代码矛盾——那行文档是陈的。
- **限制**（`internal/authapi/customer_tmp_files.go:20`）：8 MB、24 小时、只收真 JPEG/PNG/GIF/WebP，按魔术字节嗅探且必须与声明的扩展名一致。角色形象图实测 1.9–2.5 MB PNG，在限额内。
- **前缀不同**：上传在 `/api/v1`，推理在 `/v1`。
- 返回的 `public_url` 直接作为 `reference_image_urls[]` 的元素。

于是宿主侧的实现形状定了：**收一组本地路径 → 逐个上传换 URL → 带着 URL 调生成**。上传结果可以按文件内容哈希缓存，24 小时内同一张脸不必重复上传。

顺带记一条：客户端**无法通过能力发现知道这条上传通道存在**——`internal/asyncmedia/capabilities.go` 只描述了 URL 形状的字段，一个字没提上传。见第 8 节。

---

## 5. 失败路径

| 情况 | 表现 |
| --- | --- |
| 一个角色都没锁形象图 | 多选控件显示空状态，文案指向「角色固化」那一步；生成按钮仍可用，退回纯文生图 |
| 勾了脸但参照图文件已不在 | 宿主校验失败并报明确原因（哪张、为什么）；**不静默退回纯文生图**，否则用户会以为附上了 |
| 参照图超过 9 张 | 界面在勾到第 10 个时拦下并说明上限；宿主侧同样拦，不截断 |
| 上游拒绝参照图 | 把上游原因透出到界面，并提示可换另一个模型；不自动改模型 |
| 生成中切换镜头 | 沿用现有 `busy` 门禁，不新增行为 |

---

## 6. 刻意不做

- **不给 `Shot` 加持久化的 `characterIDs`。** 用户选的是界面多选方案，加字段要动数据格式和老数据兼容，收益是「选择能记住」，不值这个代价。代价是换镜头后要重勾——如果用起来嫌烦，再作为独立一件事讨论。
- **不做模型能力自动发现。** 2.3 的结论是公开接口给不出信号，要做得先改 muchtoken，见第 8 节。
- **不碰 Ruby 服务端的记账路径。** 参照图不进候选记录：候选记的是「这张图是什么」，参照图是「怎么生成的」，混进去会让 `record_image` 的必填契约变形。若以后要追溯，另加字段。

---

## 7. 验收与测试计划

1. **宿主校验器的单测**（`XeditTests/AgentPluginSystemTests.swift:994` 那条契约测试要一并更新）：
   - 目录外的路径被拒；符号链接被拒；非图片被拒；第 10 张被拒；
   - 空数组等价于现在的纯文生图请求（保证不回归）。
2. **插件 UI 的行为验证**：沿用本次 todo 那套「桩接口 + 浏览器」的做法，断言勾选后请求体真的带上了 `filePath`、角色形象图生成路径仍然不带参照图、预勾选在无对白镜头上也能命中。
3. **守卫**：1.1 说的「四层各自白名单、漏改静默丢字段」必须有守卫。扩展本次新增的 `scripts/plugin_command_contract_test.rb`，或另起一条，钉住：宿主校验器读了参照图字段、UI 传了 `filePath` 而不是 `mediaURL`、张数上限四层一致。反验必做（抽掉任一处即红）。
4. **端到端**：需要真实调用，见 4.2，要用户点头。

---

## 8. 已确认决策（2026-09-12 第二轮）

用户对下面三条的原文是「都同意，且我都授权」。

1. **端到端实测做。** 但要验的东西已经换了：原本它要验「data URL 行不行」，那一问 4.2 靠读代码结案了。所以这笔钱改花在真正不确定的那段——上传换 URL 再带参照图生成，出来的脸到底像不像锁定的那张形象图。
2. **muchtoken 补图像模型的能力声明。** 落法：给 `/v1/model-capabilities` 加**按需包含**的开关（默认返回不变，避免动已有调用方的线格式），并把图像模型的 `generation_task_types` 填上——字段和枚举早就在 `internal/pricing/catalog_meta.go:26` 定好了，只是没人往里写。顺带在 `internal/asyncmedia/capabilities.go` 里把 4.2 那条上传通道写进去：客户端现在没法通过能力发现知道它存在。再顺手改掉 `docs/15-API接口规范.md:97` 那行与代码矛盾的认证说明。
3. **默认张数从 4 降到 2。** 附参照图后计费口径从 `text_to_image` 跳到 `multi_image_to_image`，一次 4 张比现在贵不少。2 张够挑，也不至于让用户在不知情下翻倍。纯文生图路径（角色形象图那一步）不受影响。
