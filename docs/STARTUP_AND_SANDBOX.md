# 启动路径 & 工具执行沙箱边界

> 面向维护者的速查文档。只讲「怎么跑起来」和「Agent 动手时的边界在哪」，附代码位点（`文件:行`）方便定位。基线 v1.129.0-rc34。

---

## 一、启动路径（App 能启动）

### 1. 入口与窗口

| 环节 | 位点 | 说明 |
| --- | --- | --- |
| `@main` | [XeditApp.swift](../Xedit/XeditApp.swift) | `struct WillDeepApp: App` |
| AppDelegate | 同上，`@NSApplicationDelegateAdaptor(WillDeepAppDelegate.self)` | 桥接 AppKit 生命周期 |
| Scenes | 同上 | 主编辑器 `WindowGroup`、URL 打开窗口、Agent 单例 `Window`、`Settings` |

每个编辑器窗口持有**独立的** `AppState`（`@StateObject`），通过 `EditorAppStateRegistry.shared` 跟踪当前焦点窗口；Agent 窗口跟随焦点编辑器的上下文。

### 2. AppDelegate 生命周期（[AIPipeBootstrap.swift](../Xedit/AIPipeBootstrap.swift)）

- `applicationDidFinishLaunching`：`AIPipeBootstrap.initialize()`（无 API key 则空转）→ `AppUpdateChecker.checkForUpdatesOnLaunch()`（后台）→ 注册通知 delegate → 安装 Fn 语音监听与语音模型控制器。
- `applicationWillTerminate` / `applicationShouldTerminate`：`AIPipe.flush()` + **`AgentSessionStore.flushPendingWrites()`**（同步排空会话写队列，保证退出前落盘，⌘Q 不丢最后一条消息）。

### 3. `AppState.init` 启动序列（[AppState.swift](../Xedit/AppState.swift)）

按顺序做的**同步磁盘 I/O**（都很小，纯 JSON）：

1. `EditorSettingsStore.load()` — 编辑器设置
2. `AgentSettingsStore.loadProviderLibrary()` / `.load()` — provider 库 + legacy 配置
3. `RecentItemsStore.loadFiles()/loadFolders()` — 最近项
4. `AgentSettingsStore.loadKnownModelIDs / …AlwaysAllowedCommands` 等
5. `AgentRoutineStore.loadAll()` + 启动调度器

会话目录由后台 utility task 调用 `AgentSessionStore.loadCatalog()` 单次扫描，结果回到主线程后与启动期间新建的内存会话合并。空白草稿仅由侧边栏可见性规则隐藏，不再在启动或新建会话时自动删盘。

随后挂订阅与钩子（非阻塞）：registry 的 `objectWillChange` 转发、media task 轮询、终端按需 provider、三条后台完成钩子（job / media / subagent）、会话保存失败通知、终端设置跨实例同步。

### 4. 会话是懒加载的

`loadCatalog()` 在后台单次读取每个会话文件，同时派生侧边栏索引和用量快照；侧边栏会话的 `messages` 留空，并由 `MetadataOnlySessionTracker` 记住谁还是「仅 metadata」。用户**点开某会话**时才 `load(id:)` 全量物化消息（[AppStateAgentSessions.swift](../Xedit/AppStateAgentSessions.swift)）。因此侧栏有几百个会话也不会把目录扫描压到主线程。

> 写队列与目录索引会叠加尚未落盘及正在落盘的 pending 快照，避免第二个 `AppState`（如设置窗口）在写窗口期漏掉刚创建或刚更新的会话；自动删空会话逻辑已经移除。详见会话异步写管线与 CHANGELOG。

### 5. 冷启动设计原则（README「设计哲学」）

- **冷启动延迟是功能，不快就是 bug。**
- **主线程是神圣的**：摸磁盘/网络的活尽量后台化（会话写盘、更新检查、media 轮询都不阻塞 UI）。
- **打开文件 ≠ 扫描目录**：只有显式 Open Folder（⇧⌘O）才建文件树。
- Quick Open 列表按项目根 SHA-256 缓存，重开项目 ⌘P 立即可用。

### 6. 退出/析构安全

`AppState.deinit`：取消所有后台 Task（git 刷新、quickOpen、agent 请求）与订阅、停 media 轮询、释放全部 security-scoped 访问权限。进程退出前由 AppDelegate `flushPendingWrites()` 兜底会话落盘。

---

## 二、工具执行的沙箱边界

核心策略集中在 [AgentToolAuthorization.swift](../Xedit/AgentToolAuthorization.swift)（`AgentSandboxMode` / `AgentSandboxPolicy`）。

### 1. 四档沙箱模式（`AgentSandboxMode`，行 25-30）

| 模式 | 写 | 网络 | 凭证/HOME |
| --- | --- | --- | --- |
| `readOnly` | ✗ | ✗ | 屏蔽 |
| `workspaceWrite` | 仅 workspace + temp | ✗ | 屏蔽 |
| `workspaceWriteNetwork` | 仅 workspace + temp | ✓ | 屏蔽 |
| `escalated` | 不沙箱 | ✓ | 真实 HOME/凭证 |

最终用哪档由 [AppStateAgentToolDecisions.swift](../Xedit/AppStateAgentToolDecisions.swift) `sandboxModeForToolExecution()` 依据「命令风险 + 审批来源」决定。

### 2. shell 命令怎么被关起来（seatbelt）

`AgentSandboxPolicy.shellLaunch()`（行 483-499）：非 `escalated` 且系统有 `/usr/bin/sandbox-exec` 时，命令包成

```
/usr/bin/sandbox-exec -p <profile> /bin/sh -c <command>
```

seatbelt profile（`seatbeltProfile()`，行 518-540）关键规则：

```
(version 1)
(deny default)
(allow process*) (allow signal (target self)) (allow sysctl-read)
(allow file-read*)                 ← 读不受限
(allow file-write* (subpath <temp>) [(subpath <workspace>)])
(allow ipc*) (allow mach-lookup)
(allow|deny network*)              ← 仅 workspaceWriteNetwork 放行
```

> ⚠️ **边界的真相**：沙箱限制的是**写和网络**，**读不受限**（`file-read*` 全放行）—— Agent 在沙箱里仍能读到 workspace 之外的文件。真正拦住外泄的是「网络默认拒绝 + 命令输出脱敏 + 敏感环境变量剥离」。
>
> ⚠️ `escalated` 模式**完全不套 seatbelt**；系统若没有 `sandbox-exec` 也会回退到裸 `/bin/sh`（macOS 上一直存在，实际不触发）。

环境沙箱化 `sandboxedEnvironment()`（行 459-481）：删掉所有名字像 token/secret/password/api_key/credential 的变量；非 escalated 下把 `HOME` 指到临时目录、清空 `SSH_AUTH_SOCK` / `GITHUB_TOKEN` / `GH_TOKEN`。

### 3. 命令审批的三层闸门

1. **静态白名单**（[AgentSafeCommand.swift](../Xedit/AgentSafeCommand.swift)）：`ls/cat/rg/git diff` 等只读命令 → `.alwaysSafe` 直接放行；`rm/sudo/curl/dd` 等 → `.alwaysDangerous`；管道/`&&`/`;` 会拆段逐段取**最严格**结果。
2. **LLM 评委**（`.needsJudgment` 时，[AgentInjectionDefense.swift](../Xedit/AgentInjectionDefense.swift)）：把命令裹进 `<command>…</command>` 当**惰性数据**问模型「这是只读吗」，只认严格的 `<verdict>YES</verdict>`；模型不守格式一律判 NO（安全失败）。
3. **破坏性命令**（`rm`、`git push --force`、`git reset --hard`、`git clean -f` 等）→ `requiresTypedConfirmation`，用户必须**手敲 confirm**，不能一键放行。

**Always-allow**：只对 write 级生效，按命令**签名**（如 `git push`、`mcp:server:tool`）pin；文件写工具故意**不可 pin**（blast radius 依赖路径）。见 [AgentToolAuthorizationSupport.swift](../Xedit/AgentToolAuthorizationSupport.swift)。

### 4. 文件写入边界（写不出 workspace）

`apply_patch` / `edit_file` / `create_file` 三条写路径，落盘前一律过 `resolveAgentPatchURL()`（[AppStateAgentPatches.swift](../Xedit/AppStateAgentPatches.swift:337)）：

```
url = root.appendingPathComponent(path).standardizedFileURL
guard url.path == rootPath || url.path.hasPrefix(rootPath + "/") else {
    throw .pathOutsideWorkspace
}
```

`standardizedFileURL` 解析 `..`，越界即拒。写盘用 `write(atomically: true)`。补丁应用本身的鲁棒性（CRLF、模糊匹配歧义拒绝、越界行号安全失败）见 [AgentPatchApplier.swift](../Xedit/AgentPatchApplier.swift) 与 CHANGELOG rc34。

> 已知局限：`standardizedFileURL` **不解析符号链接**，workspace 内若存在指向外部的既有 symlink，理论上可绕过前缀检查（本地单用户工具，威胁模型较弱，暂未加固）。

### 5. 后台任务与前台命令

`run_in_background` 与前台 `run_command` **共用同一套沙箱**（同 `sandboxMode` + `sandboxedEnvironment`）。后台任务（[AgentBackgroundJobs.swift](../Xedit/AgentBackgroundJobs.swift)）额外带超时：到点 `terminate()`，2 秒后仍在跑则 `SIGKILL`；完成结果在 Agent 下一轮开头以 `<background-task-notification>` 注入。

### 6. 敏感信息脱敏（[AgentSecretStore.swift](../Xedit/AgentSecretStore.swift)）

用户填的密钥存 Keychain，参数里以 `${secret:uuid}` 占位，执行前解析成真值。命令的 stdout/stderr/错误在回给模型前经 `redact()` 把真值（含 URL 编码 / base64 形态）替换掉；审计日志另经 `AgentSandboxPolicy.scrub()`（正则打掉 `sk-…`/`ghp_…`/`xox…` 等常见 token 形态）。

### 7. 远端 runtime（SSH）

绑定远端 workspace 的会话，**审批逻辑（白名单 / LLM 评委 / confirm）在本地照跑**，命令通过 SSH 在远端执行（[AgentRemoteRuntime.swift](../Xedit/AgentRemoteRuntime.swift)）。区别：本地 seatbelt 管不到远端进程，远端隔离依赖远端系统自身权限；路径仍经 `RemotePathValidator` 限定在远端 workspace root 内。

### 8. 子 Agent（spawn_agent）

[AgentSubagents.swift](../Xedit/AgentSubagents.swift:257) 白名单仅 9 个**只读**工具：`search_files / grep_files / read_file / list_directory / git_status / run_command / list_skills / read_skill / web_search`。显式禁用：`spawn_agent`（不许嵌套）、`ask_user`（无人可问）、MCP 工具、后台 job、`web_fetch`（write 级需父会话审批 UI）。子 Agent 最多 12 轮。

---

## 一句话总结

- **启动**：入口 `WillDeepApp` → AppDelegate 装监听 → 每窗口一个 `AppState`，同步读几份小 JSON、会话只加载 metadata（懒物化）、空草稿清理，其余活后台化；退出前 flush 会话写队列。
- **沙箱**：四档模式 + macOS seatbelt（**限写/限网、不限读**）+ 环境剥敏；命令走「白名单 → LLM 评委 → 手敲 confirm」三层，写文件严格锁在 workspace 内，输出脱敏，子 Agent 只读且不能嵌套。
