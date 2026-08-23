# WillDeep 依赖的 some.im 服务端模型清单

> 用途:核对 some.im relay 后台是否已配置 WillDeep 运行所需的全部模型。
> 这些是 **some.im relay 上的虚拟模型名**(不是原始上游模型)。
> 最后更新:2026-07-09 · 对应版本:1.136.0-rc37
> 代码来源:`Xedit/AgentManagedRoutingModels.swift`(`SomeIMManagedModel`,1.287.0-rc3 前在 `Xedit/AgentModels.swift`)、`Xedit/SomeIMIntegration.swift`(`SomeIMIntegrationSettings`)。

## 一、省心托管路由 · 主调用模型(必须配)

省心托管(managed routing)每个用户轮由裁判决定域(coding/general)与档位(low/high/premium),
再结合当前 some.im 账号是否有 coding plan,最终解析到下面 9 个主调用模型之一。
`target_model` 不在 allowlist 内会被拒绝,回退到本地 (domain, tier, hasCodingPlan) 映射。

| 模型 ID | 域 · 档位 | 备注 |
|---|---|---|
| `someim-coding-plan-low` | plan · low | 有 coding plan 时,无论裁判域是 coding 还是 general,low 都走它 |
| `someim-coding-plan-high` | plan · high | canonical 拼写是 **high**（历史误拼 `hight` 的兼容映射已退役，代码只认 `high`） |
| `someim-coding-plan-premium` | plan · premium | 有 coding plan 时的升档目标 |
| `someim-code-low` | no-plan coding · low | 无 coding plan 且裁判域为 coding |
| `someim-code-high` | no-plan coding · high | 无 coding plan 且裁判域为 coding |
| `someim-code-premium` | no-plan coding · premium | 无 coding plan 且裁判域为 coding |
| `someim-auto-flash` | no-plan general · low | 无 coding plan 且裁判域为 general |
| `someim-auto-pro` | no-plan general · high | 无 coding plan 且裁判域为 general |
| `someim-auto-premium` | no-plan general · premium | 无 coding plan 且裁判域为 general |

## 二、裁判模型(必须配)

| 模型 ID | 用途 |
|---|---|
| `someim-judge` | 轻量路由 / 输出质检裁判 = 官方**非思考 DeepSeek**(无人设虚拟链)。**不可**作为某轮主模型,故不在 allowlist 内(`Xedit/AgentManagedRoutingModels.swift` 的 `SomeIMManagedModel.allowlist`) |

## 三、多模态默认模型(非托管路径)

| 模型 ID | 用途 | 来源 |
|---|---|---|
| `gpt-image-2` | 默认生图模型 | `SomeIMIntegration.swift:74` `defaultImageModel` |
| `qwen3-vl-plus` | 默认视觉 / 图片理解模型 | `SomeIMIntegration.swift:75` `defaultVisionModel` |
| （视频生成） | **无硬编码默认**,由用户在设置里选 `preferredVideoModel`(默认空) | `SomeIMIntegration.swift` |

## 四、默认 DeepSeek provider preset(非 some.im 虚拟模型,供参考)

WillDeep 内置的默认 provider preset 用直连 DeepSeek 命名 `deepseek-v4-flash` / `deepseek-v4-pro`
(`Xedit/AgentProviderPresetModels.swift` 附近)。这不属于 `someim-*` 虚拟模型;若你的 some.im relay 也想承接这条,
后台需另有这两个,但**省心托管本身只依赖上面第一、二节的 10 个 `someim-*`**。

## 五、核对清单(复制到 some.im 后台逐个确认)

```
someim-coding-plan-low
someim-coding-plan-high
someim-coding-plan-premium
someim-code-low
someim-code-high
someim-code-premium
someim-auto-flash
someim-auto-pro
someim-auto-premium
someim-judge
gpt-image-2
qwen3-vl-plus
```

> 注:`someim-coding-plan-hight`(少字母)是历史误拼,现已统一为 `-high`(旧的兼容映射已退役),
> 后台只配 `high` 即可,**无需**配这个错误拼写。
