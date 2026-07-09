# WillDeep 依赖的 some.im 服务端模型清单

> 用途:核对 some.im relay 后台是否已配置 WillDeep 运行所需的全部模型。
> 这些是 **some.im relay 上的虚拟模型名**(不是原始上游模型)。
> 最后更新:2026-07-09 · 对应版本:1.136.0-rc30
> 代码来源:`Xedit/AgentModels.swift`(`SomeIMManagedModel`)、`Xedit/SomeIMIntegration.swift`(`SomeIMIntegrationSettings`)。

## 一、省心托管路由 · 主调用模型(必须配)

省心托管(managed routing)每个用户轮由裁判决定域(coding/general)与档位(low/high/premium),
最终解析到下面 5 个主调用模型之一(`SomeIMManagedModel.allowlist`,`Xedit/AgentModels.swift:409`)。
`target_model` 不在这 5 个之内会被拒绝,回退到本地 (domain, tier) 映射。

| 模型 ID | 域 · 档位 | 备注 |
|---|---|---|
| `someim-coding-plan-low` | coding · low | |
| `someim-coding-plan-high` | coding · high | canonical 拼写是 **high**（历史误拼 `hight` 的兼容映射已退役，代码只认 `high`） |
| `someim-coding-plan-premium` | coding · premium | 升档目标 |
| `someim-auto-flash` | general · low | 同时是**默认文本模型**(`SomeIMIntegrationSettings.defaultTextModel`) |
| `someim-auto-pro` | general · high | |

## 二、裁判模型(必须配)

| 模型 ID | 用途 |
|---|---|
| `someim-judge` | 轻量路由 / 输出质检裁判 = 官方**非思考 DeepSeek**(无人设虚拟链)。**不可**作为某轮主模型,故不在 allowlist 内(`Xedit/AgentModels.swift:404`) |

## 三、多模态默认模型(非托管路径)

| 模型 ID | 用途 | 来源 |
|---|---|---|
| `gpt-image-2` | 默认生图模型 | `SomeIMIntegration.swift:74` `defaultImageModel` |
| `qwen3-vl-plus` | 默认视觉 / 图片理解模型 | `SomeIMIntegration.swift:75` `defaultVisionModel` |
| （视频生成） | **无硬编码默认**,由用户在设置里选 `preferredVideoModel`(默认空) | `SomeIMIntegration.swift` |

## 四、默认 DeepSeek provider preset(非 some.im 虚拟模型,供参考)

WillDeep 内置的默认 provider preset 用直连 DeepSeek 命名 `deepseek-v4-flash` / `deepseek-v4-pro`
(`Xedit/AgentModels.swift` 附近)。这不属于 `someim-*` 虚拟模型;若你的 some.im relay 也想承接这条,
后台需另有这两个,但**省心托管本身只依赖上面第一、二节的 6 个 `someim-*`**。

## 五、核对清单(复制到 some.im 后台逐个确认)

```
someim-coding-plan-low
someim-coding-plan-high
someim-coding-plan-premium
someim-auto-flash
someim-auto-pro
someim-judge
gpt-image-2
qwen3-vl-plus
```

> 注:`someim-coding-plan-hight`(少字母)是历史误拼,现已统一为 `-high`(旧的兼容映射已退役),
> 后台只配 `high` 即可,**无需**配这个错误拼写。
