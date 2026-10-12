# WillDeep 的 some.im 模型依赖

> 更新：2026-10-12 | 版本：1.417.0-rc3

| 请求模型 | 用途 |
| --- | --- |
| `someim-auto-flash` | 随心托管新任务默认模型、审核卡片解释 |
| `someim-auto-pro` | 当前任务明确生成失败后的接手候选 |
| `someim-auto-premium` | 当前任务后续回合仍明确失败时的接手候选 |
| `someim-security-guard` | 工具安全审核，与任务难度分类无关 |
| `someim-32b-compressor` | 上下文压缩 |
| `someim-judge` | 其他辅助请求；托管不再使用它做领域、难度或输出质检 |
| `gpt-image-2` | 默认生图 |
| `qwen3-vl-plus` | 默认图片理解 |

视频生成模型由用户配置。托管只使用通用模型族，不查询套餐权益，不选编程专用模型族。

网关路由别名的物理上游、价格和上下文窗口应以服务端配置与模型目录为准，客户端不保证某个档位一定更擅长当前任务。

执行规则见 [随心托管设计](SOME_IM_MANAGED_ROUTING_DESIGN.md)。
