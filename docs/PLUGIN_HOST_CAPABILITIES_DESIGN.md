# 插件宿主能力设计：问模型、看 provider、定时被叫醒

> 状态：`ai.chat` / `providers.read` 已实现（1.300.0-rc5）；`schedule` 仅设计，未实现。
> 上位文档：[WILLDEEP_PLUGIN_SYSTEM_DESIGN.md](WILLDEEP_PLUGIN_SYSTEM_DESIGN.md)

## 为什么要有这一层

插件页面跑在一个 CSP 收紧的 WKWebView 里：`connect-src 'none'`，没有网络、没有密钥、
没有后台。这是对的——但如果宿主只给它一块画布，那插件跟一张本地 H5 页面没有区别，
装不装都一样。

真正的分界线是**插件能不能借宿主的手干事**：问一次模型、知道用户配了哪些 provider、
到点被叫醒。这三样宿主本来就有，插件缺的只是一条受控的通道。

设计上贯穿三条：

1. **密钥永不出宿主。** 插件拿到的永远是 id 与名字，不是 baseURL、更不是 key。
2. **能力必须在清单里声明。** 页面调用时宿主按 `permissions` 现场核，停用的插件立即失效。
3. **额度与副作用有硬上限。** 条数、字数、输出 token、并发、频率，都由宿主收口，
   插件报什么都夹到上限内。

---

## 一、`ai.chat`：问一次模型（已实现）

### 页面 API

```js
const result = await window.willdeep.ai.complete({
  system: '把一句话变成待办，只回 JSON',
  messages: [{ role: 'user', content: '明天下午三点前把发布验一遍，很急' }],
  provider: 'ollama',            // 可选，缺省=默认 provider
  model: 'gemma4:e4b-it-qat',    // 可选，缺省=该 provider 的 flash 档
  maxOutputTokens: 256           // 可选，宿主会夹到上限内
});
// → { text, model, providerID }
```

非流式、单轮、要么给全文要么抛错。刻意不先做流式：插件的典型用法是「读一句话给我结构化
结果」，流式只会让页面代码复杂一档。真需要流式再加 `onDelta` 回调。

### 路由

| 情况 | 用什么 |
| --- | --- |
| 不指定 provider | `agentConfiguration.resolved(for: .compression)` 的 **flash 档**——和上下文压缩、审批解释同一条辅助路线：便宜、快、用户早就配好了 |
| 指定了 provider | 必须在用户的 provider 库里；模型必须是这个 entry 列出来的（flashPrimary / proPrimary / flashAlternates） |
| 指定 `ollama` | 只有用户在设置里开了本地加速才认，模型必须是他自己填的那两个 |
| 其它 | 拒绝 `unknownProvider` |

页面递上来的 `baseURL` 一律不认——否则插件就能把用户的对话发去任意端点。

### 上限

`AgentPluginAIRequest`：最多 24 条消息、总计 32 000 字符、输出 4 096 token。
校验是纯函数（`AgentPluginAIRequestValidator`），不起模型、不起 WebView 就能测。

### 拒绝的理由会原样回到页面

`permissionDenied` / `emptyRequest` / `tooManyMessages` / `tooLong` /
`unknownProvider` / `unknownModel` / `unavailable` / `emptyResponse`。
插件据此决定是重试、换模型，还是回落到自己的本地实现——**这一点很重要**：
待办插件默认交给模型解析「明天下午三点」，模型不可用时回落到内置规则，
用户那条待办绝不会因为断网而丢。

---

## 二、`providers.read`：知道有哪些模型可选（已实现）

```js
const { providers } = await window.willdeep.ai.providers();
// [{ providerID, displayName, isActive, isLocal, models: [...], flashModel }]
```

只读、只给能标识和展示的字段。插件用它渲染一个模型选择器——待办插件的设置抽屉就是
这么做的：默认走「当前 provider 的 flash 档」，也可以钉死本机 Ollama 来处理，
数据不出机器。

`ai.chat` 隐含这项能力（否则插件没法知道自己能选什么），单独声明 `providers.read`
则是「只想展示、不打算调用」的场景。

---

## 三、`schedule`：到点叫醒插件（设计，未实现）

这是「已安排」能变成插件的前提。今天插件系统能承载目的地、页面、侧栏、命令、MCP 服务
和技能，**唯独没有「到点唤醒」和「起一个 agent 回合」**——而这恰好是「已安排」的核心。
照搬只会把原生界面换成 WebView、引擎还留在宿主里，集成度不升反降。

### 清单

```json
{
  "contributes": {
    "schedules": [
      {
        "id": "todo.morning-digest",
        "titleKey": "schedule.morningDigest",
        "cron": "0 9 * * 1-5",
        "timezone": "local",
        "command": "todo.digest",
        "mode": "command",
        "catchUp": "skip"
      },
      {
        "id": "todo.weekly-review",
        "cron": "0 18 * * 5",
        "command": "todo.weeklyReview",
        "mode": "agentTurn",
        "promptKey": "schedule.weeklyReviewPrompt",
        "workspace": "last"
      }
    ]
  },
  "permissions": ["schedule.run"]
}
```

- `mode: "command"`：到点由宿主执行插件的一条命令（跟用户点菜单同一条路：权限确认、
  mcpTool 派发、失败降级全部复用 `AgentPluginCommandExecutor`）。**不起模型、不花钱**，
  适合「把今天到期的待办算出来」这种纯计算。
- `mode: "agentTurn"`：到点由宿主起一个 agent 回合，prompt 来自插件，产物落到一个会话里。
  这是「已安排」真正需要的那一档，也是最贵的一档。

### 宿主侧要补的东西

| 件 | 说明 |
| --- | --- |
| 调度器 | 复用 `AgentRoutineScheduler` 的时基，不要第二套定时器 |
| 落盘 | 每条 schedule 的 `lastFiredAt` / `nextFireAt` 与最近 N 次结果，插件页面可读 |
| 补跑策略 | `catchUp: skip \| once`——App 没开的那几次是跳过还是补一次，用户可改 |
| 并发 | 同一条 schedule 不叠加执行；`agentTurn` 档共享现有的 provider 并发槽 |
| 可见性 | 「已安排」页面统一列出**宿主自己的 routine 与插件的 schedule**，用户在一个地方管 |
| 开关 | 每条 schedule 用户可单独停用；停用插件即全部失效 |
| 审批 | `agentTurn` 档首次触发要用户点头一次（和无人值守回合同一套审批档位） |

### 迁移路径

1. 先实现 `mode: "command"`：够 Todo 这类插件用（每天早上算一次今天到期）。
2. 再实现 `mode: "agentTurn"`，并把「已安排」的**界面**改写成插件页面，引擎仍在宿主。
3. 界面稳定后，再评估要不要把 routine 存储也交给插件——这一步可能永远不做，
   因为定时任务是产品的一等公民，不该依赖某个插件是否启用。

**不做的事**：不给插件后台常驻线程，不给插件自定义时基，不允许秒级触发
（最小粒度 1 分钟）。插件要的是「到点叫我」，不是「让我一直醒着」。

---

## 权限一览

| 权限 | 给什么 | 状态 |
| --- | --- | --- |
| `ai.chat` | `window.willdeep.ai.complete`，问一次模型 | 1.300.0-rc5 |
| `providers.read` | `window.willdeep.ai.providers`，只读的 provider/模型清单 | 1.300.0-rc5 |
| `schedule.run` | 清单里的 `schedules` 到点被宿主执行 | 设计中 |

前两项的实现在 `Xedit/AgentPluginAIBridge.swift`，页面桥在
`Xedit/AgentPluginPageHost.swift` 的 bootstrap 脚本里。
