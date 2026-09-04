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
  maxOutputTokens: 256          // 可选，宿主会夹到上限内
});
```

非流式、单轮，要么给全文要么抛错。上限：最多 24 条消息、总计 32000 字符、输出 4096 token。

页面递上来的 `baseURL` 一律不认，密钥永远不出宿主。指定的 provider 必须在用户的 provider 库里，模型必须是该条目列出的（flashPrimary / proPrimary / flashAlternates）；`ollama` 只有用户开了本地加速才认。

失败原因会原样回到页面：`permissionDenied`、`emptyRequest`、`tooManyMessages`、`tooLong`、`unknownProvider`、`unknownModel`、`unavailable`、`emptyResponse`。**请为不可用准备回落**——待办插件默认让模型解析"明天下午三点"，模型不可用时回落到内置规则，用户那条待办不会因为断网就丢。

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
- 页面拿不到 devtools。把中间状态渲染到 DOM 上，或用 `executeCommand` 把信息回传给宿主命令，是可行的排查手段。
