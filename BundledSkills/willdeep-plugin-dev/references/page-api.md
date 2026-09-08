# 页面 API：`window.willdeep.*`

`localWeb` 和 `mcpApp` 两种页面都跑在隔离的 WKWebView 里。宿主在文档 `<head>` 后注入一段 bootstrap 脚本，页面能用的全部东西就是下面这些。

## 环境约束

CSP 由宿主注入，页面改不了：

```
default-src 'self' 'unsafe-inline' data: blob:;
script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline';
img-src 'self' data: blob:; connect-src 'none'; frame-src 'none';
object-src 'none'; base-uri 'none'; form-action 'none';
```

`connect-src 'none'` 意味着 `fetch`、`XMLHttpRequest`、WebSocket、EventSource 全都不通。外部 `<script src>` 和 `<link href>` 也加载不了——所有资源必须打进包里，用相对路径引用。

宿主预置了四个 CSS 变量，跟随用户主题：`--willdeep-bg`、`--willdeep-fg`、`--willdeep-secondary`、`--willdeep-accent`。用它们上色，深浅色就都对。

## 上下文

```js
const ctx = window.willdeep.getContext();
// { destinationID, selectedItemID, workspaceReference, sessionReference, locale, colorScheme }

window.addEventListener('willdeep:context-changed', (e) => {
  render(e.detail);   // 主题切换、侧栏选中项变化、locale 变化都会触发
});
```

`workspaceReference` 只在声明了 `workspace.read` / `workspace.write` 时给，`sessionReference` 只在声明了 `conversation.read` 时给，其余情况是 `null`。永远不会给聊天正文或文件内容。`conversation.read` 还是 `session.open` host 命令的通行证——没声明就打不开会话。

## 通知宿主

```js
window.willdeep.selectItem('issue-42');  // 设置侧栏选中项，itemID 上限 512 字符
window.willdeep.refresh();               // 请求宿主重新加载本目的地
```

两个都是即发即忘，没有返回值。

## 执行命令

```js
try {
  const result = await window.willdeep.executeCommand('issues.refresh', { scope: 'open' });
  // result 是命令返回的字符串（mcpTool 命令即工具输出），host 命令返回 undefined
} catch (err) {
  // err.message 是宿主给的失败原因
}
```

host 命令一律返回 `undefined`——包括 `session.open`。它是否成功只能靠 catch 判断：

```js
try {
  await window.willdeep.executeCommand('recall.openSession', { sessionID: hit.sessionID });
  // 跳转成功，主区已经切到那个会话，插件页被顶掉
} catch (err) {
  // err.message 区分得出：没权限 / sessionID 非法 / 会话目录尚未装载完成 / 会话不存在
}
```

`session.open` 要求插件声明 `conversation.read`；`sessionID` 传 UUID 字符串（参数值到宿主一律按字符串处理，别传对象或数字）。

约束（超了直接静默丢弃，不会执行）：

- 命令 ID ≤ 160 字符，且必须在清单的 `commands` 里声明过。
- 参数最多 64 个键，必须是合法 JSON 对象，序列化后 ≤ 64 KiB。
- 参数值到宿主侧会按字符串处理。

## 问模型（需要 `ai.chat`）

```js
const { text, model, providerID } = await window.willdeep.ai.complete({
  system: '把一句话变成待办，只回 JSON',
  messages: [{ role: 'user', content: '明天下午三点前把发布验一遍' }],
  provider: 'ollama',           // 可选，缺省用默认 provider 的 flash 档
  model: 'gemma4:e4b-it-qat',   // 可选，必须是该 provider 列出来的模型
  streamID: 'ask-1'             // 可选，给了才有流式增量，也才停得掉
});
```

要么给全文要么抛错。上限：最多 24 条消息、总计 32000 字符（system 也算在内），同一个页面最多 2 条请求并行。输出长度页面指定不了，由用户在设置里给 provider 配的上限决定。

带 `streamID` 时增量走 `willdeep:ai-delta` 事件，`detail` 是 `{streamID, delta}`。没有「流结束」事件，以 `complete()` 那个 promise 落定为准。

停止用 `await window.willdeep.ai.cancel(streamID)`（桥 2.3.0 起）：

```js
const streamID = 'ask-' + Date.now();
const pending = window.willdeep.ai.complete({ system, messages, streamID });
// 用户按了停止
await window.willdeep.ai.cancel(streamID);   // pending 以「已取消」reject
```

取消是真取消，底层请求会中断。页面被关掉时宿主也会把它在跑的请求全停掉——切到别处让页面离屏不算关掉，那种情况请求继续跑，切回来照常拿结果。

页面递上来的 `baseURL` 一律不认，密钥永远不出宿主。指定的 provider 必须在用户的 provider 库里，模型必须是该条目列出的（flashPrimary / proPrimary / flashAlternates）；`ollama` 只有用户开了本地加速才认。

失败原因会原样回到页面：`permissionDenied`、`emptyRequest`、`tooManyMessages`、`tooLong`、`unknownProvider`、`unknownModel`、`unavailable`、`emptyResponse`、`tooManyConcurrentRequests`、`cancelled`。**请为不可用准备回落**——待办插件默认让模型解析"明天下午三点"，模型不可用时回落到内置规则，用户那条待办不会因为断网就丢。

## 读 provider 清单（需要 `providers.read` 或 `ai.chat`）

```js
const { providers } = await window.willdeep.ai.providers();
// [{ providerID, displayName, isActive, isLocal, models: [...], flashModel }]
```

只读，只给能标识和展示的字段，没有 baseURL 和 key。用它渲染模型选择器。

## 生成图片（需要 `ai.image`）

```js
const image = await window.willdeep.ai.generateImage({
  prompt: '电影感竖屏人物定妆照，冷色侧光',
  provider: 'some-im',
  model: 'gpt-image-2', // 或 nano-banana-2
  size: '1024x1536'
});
// { mediaURL, filePath, model, providerID: 'some-im' }
```

宿主只接受 `some-im`、`gpt-image-2` / `nano-banana-2` 和三种受控尺寸；提示词最多 8000 字。API Key 始终留在 Keychain。生成文件写入当前插件隔离的数据目录，页面通过只读 `mediaURL` 展示；单个媒体文件上限 32 MiB。

## 引用技能（需要 `skills.read`）

页面自己实现 `$` 选择器，宿主负责给清单和做注入：

```js
const { skills } = await window.willdeep.skills.list();
// [{ identifier, name, description, source: 'bundled'|'user'|'plugin', tier? }]

await window.willdeep.ai.complete({
  system: '你是短剧总策划。',
  messages: [{ role: 'user', content: '写个复仇题材的开篇' }],
  skills: ['hongguo-drama']   // 只递 identifier
});
```

清单只含用户当前**启用**的技能，包含插件自带的那些。页面拿不到 SKILL.md 正文，
也拿不到它在磁盘上的路径：宿主按 identifier 读出正文、截断、拼成一条 system
消息插在最前面。

一次请求最多引用 3 个技能，每个技能正文截断到 8000 字符，且这部分不占页面自己
那 32000 字的额度。引用了目录里不存在的 identifier 会直接报错而不是静默跳过——
否则模型会在缺了技能的情况下若无其事地照答。没声明 `skills.read` 时，
`skills.list` 和带 `skills` 的 `ai.complete` 都会被拒。

## 读工作区文件（需要 `workspace.read`）

只读，且只在**本机**工作区里。远端会话（工作区在服务器上）一律拒——本机解析出来的路径是另一台机器的答案。

```js
const { entries } = await window.willdeep.fs.list('src');
// [{ name, path, isDirectory, byteSize }]，点开头的条目不列

const { text, truncated } = await window.willdeep.fs.read('README.md');
// 单次最多 256 KiB，超了 truncated 为 true

const { matches } = await window.willdeep.fs.search({ query: 'TODO', path: 'src', limit: 50 });
// ["<绝对路径>:<行号>:<该行内容>", …]；regex: true 时 query 按正则解释
```

路径可以是相对当前工作区根的，也可以是 `fs.list` 回给你的绝对路径。三个入口都经宿主的工作区守卫：`../` 越界、绝对路径越界、以及**解析后指向根外的软链接**都会被拒，报错文案能区分「没权限」和「路径不对」。

装了 ripgrep 就走 ripgrep（尊重 `.gitignore`，快得多），没装则回落到逐文件扫描。

## 自己的存储

不需要权限：每个插件一个命名空间，互相读不到，写的是宿主的 Application Support，不碰用户工作区。

```js
await window.willdeep.storage.set('draft', { title: '第三集', beats: [] });
const { value } = await window.willdeep.storage.get('draft');
const { keys } = await window.willdeep.storage.keys();
await window.willdeep.storage.remove('draft');
```

值是任意可 JSON 序列化的东西。单值上限 64 KiB，单插件总量上限 1 MiB，超了**报错**而不是静默丢弃。

`localStorage` 现在也活得下来了（1.327.0-rc1 起）：每个插件有自己的持久化 WebKit 仓，刷新、重开页面、重启 App 都不丢。**但仍然优先用 `storage`**——所有插件页面共用同一个源（`willdeep-plugin://bundle/`），隔离全靠分仓这一层，而 `storage` 的边界是宿主按插件 ID 划的，更硬；`storage` 还有明确的容量上限和报错，`localStorage` 满了只会抛一个含糊的异常。macOS 13 上没有分仓 API，那里 `localStorage` 依旧刷新即空，`storage` 则一切照常。

插件被卸载时，它的 WebKit 仓会一并删掉——留着会让「删了再装」拿到上一次的残留状态。

## 宿主事件

```js
await window.willdeep.events.on('turn.finished', ({ sessionID }) => refresh());
window.willdeep.events.off('turn.finished');           // 或传入具体回调
```

| 事件 | 何时触发 | 需要权限 |
| --- | --- | --- |
| `session.changed` | 当前会话切换（含新建、关到空） | `conversation.read` |
| `turn.started` | 一个回合开始跑 | `conversation.read` |
| `turn.finished` | 一个回合跑完（无论成败） | `conversation.read` |
| `workspace.changed` | 当前会话的工作区根变了 | `workspace.read` |

没声明对应权限的插件，`events.on` 直接报错。订阅前宿主一个观察者都不挂，别为「可能会用」提前订。

## 写工作区文件（需要 `workspace.write`）

```js
const { path, byteSize } = await window.willdeep.fs.write('docs/draft.md', text);
```

走的是 Agent 改文件同一条路：路径守卫、打开中的编辑器同步刷新、改动登记进 Changes 面板，全都继承。只能写当前会话的主工作区根，单次 512 KiB 封顶。

改一段而不是整文件覆盖，用 `patch`：

```js
const { occurrences } = await window.willdeep.fs.patch(
  'docs/draft.md',
  '## 旧标题',
  '## 新标题',
  { replaceAll: false }
);
```

与 Agent 的 `edit_file` 共用同一套实现，所以「找不到」「不唯一」「改了个寂寞」三种失败的判定和报错跟 Agent 完全一致。**优先用 `patch`**：`fs.read` 会在 256 KiB 处截断，拿截断过的文本回 `write` 等于把超出部分悄悄删掉；`patch` 没有这个问题，也不会踩掉别人同时对同一文件做的其它修改。文件在编辑器里开着时以缓冲区为准，用户没存盘的改动不会被当成不存在。

## 跑命令（需要 `process.execute`）

```js
const { summary, output } = await window.willdeep.process.run('git status --short');
```

三道门，顺序固定：

1. 恶意命令名单是硬地板，命中的**连确认框都不弹**——用户在一个插件页面上没有足够上下文判断 `curl … | sh` 到底在装什么；
2. 只读命令（`SafeCommand` 判为 `alwaysSafe`）直接跑；
3. 其余一律弹确认框，把插件名、完整命令、工作目录摊开给用户看。

这道确认框**不看审批档位**：完全访问是用户对自己指挥的 Agent 的授权，不是对第三方页面的授权。执行时带与 Agent 同款的沙箱，前台运行，120 秒封顶。

确认框上有「这条命令以后不再询问」。勾上记住的是**这一条命令的完整原文**，不是前缀、更不是「这个插件以后随便跑」：`git status` 被记住，不会让 `git push --force` 跟着免检。记忆绑在包摘要上，插件一升级全部失效；卸载插件时一并清掉；每个插件最多记 40 条。

## 调试插件页面

插件页默认拿不到 devtools。插件中心底部「给插件作者」里有一个开关，打开后页面就能被 Safari 的网页检查器连上（还要在 Safari 里启用「开发」菜单，且切换后要重新打开页面）。

开关默认关，也不会给页面多一分能力——但检查器能读到页面内存里的一切，包括它刚从 `ai.complete` 拿回来的内容，所以别长期开着。

## 代发网络请求（需要 `network.access` + `networkDomains`）

```js
const { status, headers, body } = await window.willdeep.net.fetch('https://api.example.com/v1/items', {
  method: 'POST',
  headers: { 'X-Trace': 'abc' },
  body: JSON.stringify({ a: 1 })
});
```

页面自己发不出请求（自定义 scheme + CSP），所以由宿主代发。`network.access` 只是开关，真正决定「能连谁」的是 manifest 里的 `networkDomains`：

- 只走 https，明文和其它 scheme 一律拒；
- 主机必须命中白名单，`*.example.com` 匹配子域但**不匹配裸域名**，两个都要就写两条；
- 回环与内网地址一律拒，**哪怕写进了白名单**——插件页不该成为打本机服务的跳板；
- 跳转会重新过一遍白名单，`Host` 之类的头由宿主接管，页面改不了；
- 请求体 512 KiB、响应体 2 MiB、超时 20 秒。

白名单空着等于一个请求都发不出去：声明了权限却没写域名，不是「随便连」。

## 剪贴板与通知

```js
await window.willdeep.clipboard.write('复制走的文本');      // 需要 clipboard.write
await window.willdeep.notify({ title: '导出完成', body: '3 个文件' });  // 需要 notifications
```

通知抬头会自动带上插件名，否则用户没法把噪音关到具体某个插件头上。

## 把活交给 Agent（需要 `conversation.write`）

```js
await window.willdeep.chat.insert('把这三集的分镜整理成表格');  // 只填输入框
await window.willdeep.chat.send('把这三集的分镜整理成表格');    // 直接起一个回合
```

这是最省事的扩展路径：Agent 能做的事（读写文件、跑命令、调工具、委派子代理）都不必再等宿主开新 API，写成一句话递过去就行。

代价是它**会花钱、会让 Agent 动工作区**，所以 `conversation.write` 与只读的 `conversation.read` 是两个权限，在安装面板上按敏感档呈现。递过去的文本上限 8000 字，且当成普通用户输入走同一条发送路径——审批档位、沙箱、委派策略一个都不绕。

## 版本与能力探测

```js
window.willdeep.version;        // '2.0.0'，加能力升 minor，改签名升 major
window.willdeep.capabilities;   // ['fs.search', 'storage', 'events', 'chat.send', …]
```

用了新 API 的插件装到旧宿主上，调用那一刻只会抛 `undefined is not a function`，用户看到白屏。**先探再用**：

```js
if ((window.willdeep.capabilities || []).includes('fs.search')) { … } else { /* 降级 */ }
```

清单只增不减：某个能力真要下线，会先在清单里消失一个版本，再抽掉函数。

## MCP App 页面

`runtime: "mcpApp"` 的页面用标准 MCP App 协议跟宿主通话，走 `window.postMessage`（宿主已经把 `message` 事件桥到原生侧）：

```js
window.postMessage({ jsonrpc: '2.0', id: 1, method: 'ui/initialize' }, '*');
```

握手顺序不能颠倒：

1. 页面发 `ui/initialize`，宿主回 `protocolVersion`、`hostInfo`、`hostCapabilities`、`hostContext`。
2. 页面发 `ui/notifications/initialized`。**在这之后**才能调 `tools/call` 和 `resources/read`，早了会收到 `-32002 MCP App is not initialized`。
3. 之后宿主会用 `ui/notifications/host-context-changed` 推送主题、locale 和 WillDeep 上下文的变化。

支持的方法：`ui/initialize`、`ui/notifications/initialized`、`ping`、`tools/call`、`resources/read`。宿主主动发的有 `ui/notifications/host-context-changed` 和离开页面时的 `ui/resource-teardown`。

`tools/call` 只能调**本插件清单里声明过、且属于本页面 `server` 的**工具；`resources/read` 只能读同一个 server 的 resource。单条消息 ≤ 64 KiB。

注意页面里 `parent === window`：如果你的框架把消息 post 给 `parent`，它会回到自己身上形成自回声。宿主只接受 `event.source === window` 且带 `jsonrpc: "2.0"` 和字符串 `method` 的消息。

## 调试

- 页面加载失败时宿主会自动重灌一次，仍失败则在页面上写明错误。看到白页先查 `entryPath` 和资源体积。
- 单个包内资源上限 8 MiB，超过的资源请求会失败。
- 需要 devtools 时在插件中心「给插件作者」里打开网页检查器（见上）。不想开检查器时，把中间状态渲染到 DOM 上，或用 `executeCommand` 把信息回传给宿主命令，也是可行的排查手段。
