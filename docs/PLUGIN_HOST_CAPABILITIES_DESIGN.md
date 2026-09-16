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
  streamID: 'ask-1'              // 可选，给了才有流式增量，也才停得掉
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

### 结构化产出：声明工具，不要约定围栏（1.360.0-rc1）

```js
const result = await window.willdeep.ai.complete({
  system: '你是短剧编剧',
  messages: [{ role: 'user', content: '写这一集' }],
  tools: [{
    name: 'write_episode',                 // 小写字母、数字、下划线，≤48 字符
    description: '交出这一集的剧本内容',
    parameters: [
      { name: 'title', type: 'string', description: '本集标题' },
      { name: 'script', type: 'string', description: '完整台词正文', required: true },
    ],
  }],
});
// → { text, model, providerID, toolCalls: [{ name, arguments }] }
```

**这些工具不会被执行。** 宿主只是把 schema 交给模型，再把模型填好的参数原样递回页面——
它是一个带类型的返回信封，不是一次真正的工具调用。页面拿不到任何执行能力，描述符的风险
等级恒为只读，审批与沙箱层面没有可授予的权限。`arguments` 是模型填的那串 JSON，宿主不
解读内容，页面自己 `JSON.parse`（要防它解不开）。

存在的理由：在此之前页面靠围栏约定收结构化产出（「只输出一个 ```xxx 代码块」），而模型
隔三差五回一个普通的 ```json，于是整块产出被当成闲聊丢掉，草稿一个字没改，用户既看不到
结果也看不到错误。围栏是写在提示词里的口头约定，工具 schema 是协议——字段名和类型由
provider 那一侧强制。

`toolCalls` 恒在。空数组表示模型选择用正文回答，页面据此回落到自己的文本解析，而不是当成
失败——不支持工具的 provider 和只肯写正文的模型都还得能用。反过来，模型填了参数但内容
不可用，是一次**明确的坏产出**，不该回落：那会把一次失败悄悄变成没发生。

**已知边界**：`AgentToolParameter` 只支持 `string` / `integer` / `boolean` / `stringArray`
四种标量类型，表达不了对象数组。需要返回一批对象的阶段（短剧工坊的批量集、整集分镜）仍走
围栏路径。要覆盖它们，得先扩展宿主的工具 schema 模型，那会动到主 Agent 的工具描述生成层。

### 附图片与视频（1.377.0-rc1，桥 2.6.0）

```js
const caps = window.willdeep.capabilities || [];
const result = await window.willdeep.ai.complete({
  system: '按合规红线审核这组画面',
  messages: [{
    role: 'user',
    content: '审核第 3 镜的首尾帧与成片',
    imagePaths: caps.includes('ai.images') ? [startFramePath, endFramePath] : [],
    videoPaths: caps.includes('ai.videos') ? [clipPath] : [],
  }],
  provider: 'some-im', model: 'qwen3.8-max',
});
```

- 字段只认 **user** 消息；挂在 system / assistant 上整条拒（`mediaOnNonUserMessage`）。
- 路径必须在**本插件的生成目录**里（宿主 `generated-images/`），判据与 `ai.generateImage`
  的 `referenceImagePaths` 相同：规范化后父目录恰好是媒体根，拒绝符号链接、相对路径、目录
  （`mediaOutsidePluginData`）。插件要审自己目录外的文件，先把它放（硬链接）进来。
- 图片在宿主侧限边 1568 像素、转 JPEG；解不出来报 `unreadableMedia`。
- 视频由宿主按时间均匀抽 8 帧（每段中点），当作有序图片发出，并在正文末尾追加一行说明哪几张
  是哪个视频的第几秒。不依赖 provider 支持 `video_url`。
- 上限：一次请求 12 张图、2 个视频（`tooManyImages` / `tooManyVideos`）。
- 选的模型不收图时当场拒（`modelRejectsMedia`），判定沿用主聊天的识图模型表。
- 能力分两项探测：Web 宿主（willdeep-rs）只声明 `ai.images`，带 `videoPaths` 会被拒
  （`videosUnsupported`）。

### 上限

`AgentPluginAIRequest`：最多 24 条消息、总计 32 000 字符、输出 4 096 token，
最多 4 个工具、每个工具最多 12 个参数。工具声明不合规的整条丢弃而**不做修正**——
页面按自己声明的名字去认返回值，宿主替它改了名它就永远认不到。超出工具数量上限则
拒绝整条请求（`tooManyTools`）。
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

## 四、MCP 服务反向请求出图（已实现，1.378.0-rc1）

页面出图走 `window.willdeep.ai.generateImage`。可插件的 MCP 服务是一个没有页面的独立进程，
主 Agent 在聊天里调用插件工具时只到得了它，走不到页面桥。为了不让插件自己再配一份出图
key，宿主允许插件 MCP 服务在处理 `tools/call` 期间**反过来向宿主发请求**，形状与 MCP 协议
里的 `sampling/createMessage` 相同。

### 协商

宿主只对**插件来源的 stdio 服务**在 `initialize` 里宣告：

```json
{ "capabilities": { "extensions": { "io.willdeep/host-requests": { "methods": ["willdeep/images/generate"] } } } }
```

插件据此判断宿主支不支持。没有这一项（旧宿主、willdeep-rs、用户手工配置的服务）时，
插件应当直接报「当前宿主不支持出图」，而不是发出请求再干等。

### 请求

插件在工具调用还没返回时，往 stdout 写一行：

```json
{"jsonrpc":"2.0","id":"img-1","method":"willdeep/images/generate",
 "params":{"prompt":"…","model":"gpt-image-2","size":"1024x1536","referenceImagePaths":["…"]}}
```

- `id` **用字符串**：宿主自己发出的请求 id 是整数，两边混用同一种会撞号。
- `params` 与页面桥 `ai.generateImage` 共用同一个校验器 `AgentPluginImageRequestValidator`，
  权限（`ai.image`）、参考图路径钳制、输出目录也完全相同（`AgentPluginImageGeneration`）。
- 宿主把响应写回 stdin，成功时 `result` 为 `{ mediaURL, filePath, model, providerID }`。

### 错误码

| code | 含义 |
| --- | --- |
| -32601 | 非插件服务，或方法不认识 |
| -32602 | 参数不合校验（空提示词、模型不在白名单、尺寸不合法等） |
| -32000 | 出图失败，`message` 是原因（无 `ai.image` 权限、上游报错、参考图越界） |
| -32001 | 宿主处理超过 600 秒 |

### 超时

宿主等工具结果的计时在**每处理完一次反向请求后重新开始**：出一张图往往比服务的
工具超时还长，不重置的话插件永远等不到第二张。单次反向请求本身封顶 600 秒，防止上游
挂住后 MCP 连接的串行队列永远卡着。

插件一次工具调用可以串行发多条反向请求，但宿主处理期间该连接不接新工具调用，
所以工具应当自己限制一次出图的张数。

实现：`Xedit/AgentMCPHostRequests.swift`、`Xedit/AgentMCPBridge.swift`（`waitForResponse` 的
`onServerRequest`）；测试 `XeditTests/AgentMCPHostRequestsTests.swift` 用一个真实的 ruby stdio
服务走完整往返。

---

## 权限一览

| 权限 | 给什么 | 状态 |
| --- | --- | --- |
| `ai.chat` | `window.willdeep.ai.complete`，问一次模型；1.360.0-rc1 起可声明 `tools` 收结构化产出 | 1.300.0-rc5 |
| `providers.read` | `window.willdeep.ai.providers`，只读的 provider/模型清单 | 1.300.0-rc5 |
| `schedule.run` | 清单里的 `schedules` 到点被宿主执行 | 设计中 |

前两项的实现在 `Xedit/AgentPluginAIBridge.swift`，页面桥在
`Xedit/AgentPluginPageHost.swift` 的 bootstrap 脚本里。
