# 多文件夹项目（Projects）设计

> 状态：**已确认，实施中**。三个关键决策见 §3；决策 2 与 3 的冲突按 §6 的「只删独占会话」方案处理（已确认）。
> 关联版本：基于 1.232.0-rc1。
> 对标：Codex 的「编辑项目」——项目有独立名称，可挂多个源文件夹，可重命名，可移除。

## 1. 动机

今天一个「项目」等同于**一个文件夹路径**：侧栏按 `workspaceSidebarGroupKey` 分组，组名硬取路径最后一段。这带来三个具体问题：

1. **同一个项目的多个目录被拆散**。前后端分离仓库（`tokenhub` + `tokenhub-web`）、主仓库 + 独立文档仓库，在侧栏是彼此无关的两组。
2. **组名不可改**。目录叫 `xedit`，产品叫 WillDeep，侧栏只能显示 `xedit`。
3. **调度板与侧栏各叫各的**。调度板有自己的 `AgentDispatchLogicalProject.displayName`，同样从路径派生，两处命名无法统一。

## 2. 现有地基（比预期完整）

**关键事实：展示归属与执行路径早已分离。**

- `AgentSession.sidebarWorkspaceRootPath`（`AgentModels.swift:83`）——注释原文：「会话在 Git worktree 里执行时的侧栏分组根。工具用 `workspaceLocation`，侧栏仍把会话归在原项目下。」这已经是「一个项目、多个文件夹」的雏形，只是仅由 worktree 流程自动写入，用户无法管理。
- `AgentSession.workspaceSidebarGroupKey`（`AgentModels.swift:340`）——分组 key 已经有优先级链：`sidebarWorkspaceRootPath` → `workspaceLocation` → `workspaceRootPath`。**加一层 projectID 只需在链首插入一环。**
- `AgentDispatchLogicalProject`（`AgentDispatchModels.swift:139`）——已有 `id / displayName / primaryWorkspacePath / localRepositoryIdentity`，由 `AgentDispatchLogicalProjectResolver` 从路径派生。
- 工具执行侧读 `workspaceLocation`，**与分组完全无关**——引入项目层不需要改动任何一个工具。

## 3. 已拍板的决策

| # | 决策 | 推论 |
| --- | --- | --- |
| 1 | 项目与调度板 `logicalProject` **统一** | `AgentDispatchLogicalProject` 退化为 `AgentProject` 的投影，displayName 单一来源；调度板与侧栏永远同名 |
| 2 | 一个文件夹**可以属于多个项目** | 归属是多对多，不能在文件夹上存 projectID；会话的项目归属需要显式字段 + 可解析回退 |
| 3 | 移除项目时**会话跟着删** | 不可逆，必须确认；且与决策 2 冲突，见 §6 |

## 4. 数据模型

```swift
/// 用户可命名的项目：一个名字 + 多个源文件夹。
/// 纯展示与归组概念——工具执行始终使用会话自己的 workspaceLocation。
nonisolated struct AgentProject: Codable, Equatable, Identifiable {
    let id: UUID
    var displayName: String
    /// 归属本项目的文件夹，规范化后的绝对路径。顺序即 UI 顺序，
    /// 第一个作为「主文件夹」（新建会话的默认落点、调度板的 primary path）。
    var folderPaths: [String]
    /// 本地仓库指纹，沿用 logicalProject 的既有解析，用于 Finder 移动后恢复。
    var repositoryIdentities: [String]
    var createdAt: Date
    var updatedAt: Date
}
```

存储：`AgentProjectStore`，单文件 `projects.json`，与会话目录同级（对齐 `AgentSubagentTranscriptStore` 的做法，天然继承测试沙箱重定向）。项目数量是个位数量级，不需要分片。

会话侧新增一个字段：

```swift
/// 显式项目归属。nil 表示按路径回退到隐式项目（旧会话与未纳入管理的文件夹）。
var projectID: UUID?
```

分组 key 变为：

```
projectID → sidebarWorkspaceRootPath → workspaceLocation → workspaceRootPath
```

**旧会话零迁移**：`projectID == nil` 时行为与今天逐字节一致。

## 5. 归属解析

新建会话时按顺序解析：

1. 会话已有 `projectID` → 用它
2. 会话路径命中某个项目的 `folderPaths` → 绑定该项目
3. **命中多个项目**（决策 2 允许）→ 取 `folderPaths` 中路径最长的一条所属项目（最具体者胜）；仍并列则取 `updatedAt` 最新的项目，并在会话上落 `projectID` 固化，避免每次解析结果漂移
4. 都不命中 → `projectID = nil`，走今天的路径分组

第 3 条是决策 2 的直接代价：多对多归属必须有确定性裁决，且**裁决结果要固化**，否则用户新增一个项目就可能让老会话悄悄换组。

## 6. 决策 2 与 3 的冲突（已确认解法）

**冲突**：文件夹 `F` 同时属于项目 A 和 B，会话 `S` 位于 `F` 内。按决策 3，移除项目 A 时 `S` 被删除——但 `S` 同样是项目 B 的内容，B 的使用者会莫名其妙少了一段历史，且不可恢复。

**已确认解法：删除只作用于「独占」会话。**

移除项目 A 时：

- `projectID == A` 且其路径**不属于任何其他项目** → 随项目删除
- `projectID == A` 但路径同时属于项目 B → **保留**，`projectID` 改绑 B（按 §5 规则重解析）
- `projectID == nil` 的会话完全不受影响

确认弹窗必须把两个数字都说清楚，例如：

> 移除项目「tokenhub」
> 将永久删除 12 个会话及其全部内容。另有 3 个会话同时属于「tokenhub-web」，将保留并移入该项目。
> 此操作无法恢复。

理由：决策 3 的本意是「项目没了，它的东西也没必要留着」，而共享会话并非「它的东西」独有。让 A 的删除破坏 B 的数据，是用户在做这个决定时不会预期到的后果。

若不接受此解法，替代方案是**禁止删除仍被共享的会话**（弹窗直接拒绝并提示先解除共享），但那会让删除操作在常见情况下失败，体验更差。

## 7. 删除的安全要求

- 走与删除会话、删除定时任务同款的 `NSAlert` 确认（1.230.0-rc6 已统一该模式）
- 弹窗列出：将删除的会话数、将保留并改绑的会话数、项目名
- 删除按 `hasDestructiveAction` 标红
- 会话删除复用既有 `deleteAgentSession`，不新写删除路径——那条路径已处理运行中会话、异步写队列与 sidecar 清理
- **正在响应中的会话**：先停止其回合再删除，避免写队列在文件删除后回写

## 8. UI

「编辑项目」弹窗（对标截图）：

- 项目名输入框
- 源文件夹列表，每行可移除；「添加文件夹」走系统选目录面板
- 底部：`移除项目`（左，红色）/ `取消` / `保存`
- 入口：侧栏工作区分组行的 `…` 菜单

新增约束：

- 项目名去空白后不得为空；为空时回退为主文件夹名（不接受空名，否则侧栏出现无名分组）
- 至少保留一个文件夹；移除最后一个文件夹等价于移除项目，需给出同样的确认
- 文案全部走 L10n

## 9. 调度板统一（决策 1）

- `AgentDispatchLogicalProject.displayName` 改为读取 `AgentProject.displayName`（有 projectID 时），否则维持现有路径派生
- `primaryWorkspacePath` 取项目的第一个文件夹
- `AgentDispatchLogicalProjectResolver.representsSameProject` 增加一条前置判定：两侧 projectID 相同即同项目，无需再比路径与仓库指纹
- 既有 `goalsRepresentSameProject` 的去重逻辑保持不变，只是判定更准

## 10. 兼容与迁移

- 无 `projects.json` → 全部会话 `projectID == nil` → 侧栏与今天完全一致
- `AgentSession.projectID` 为 optional，旧会话 JSON 直接解码为 nil
- worktree 的 `sidebarWorkspaceRootPath` 行为不变：它在优先级链中位于 projectID 之后，仅在未纳入项目时生效
- 项目引用了已被删除/移动的文件夹：不清理，UI 灰显并提示「文件夹不存在」，由用户决定移除——自动清理会在外接硬盘未挂载时误删配置

## 11. 分期

**一期（模型 + 分组）**
1. `AgentProject` / `AgentProjectStore` / `AgentSession.projectID`
2. 分组 key 插入 projectID 环节；归属解析与固化（§5）
3. 单测：优先级链、多项目归属裁决与固化、旧会话零变化

**二期（UI + 生命周期）**
4. 编辑项目弹窗（增删文件夹、重命名）
5. 移除项目：独占/共享判定、确认文案含双数字、复用既有删除路径
6. 单测：空名回退、末个文件夹等价移除、共享会话不被误删

**三期（调度板统一）**
7. §9 全部
8. 单测：同名一致、同项目判定优先走 projectID

每期照常：全量单测绿 → bump 版本 + CHANGELOG → 合回 develop。

## 12. 风险

| 风险 | 缓解 |
| --- | --- |
| 删除项目误删共享会话 | §6 独占判定 + 弹窗双数字；不接受则改为拒绝删除 |
| 多项目归属导致老会话漂移换组 | 解析结果固化到 `projectID`（§5 第 3 条） |
| 分组 key 改动影响侧栏可见性 | 已有「侧栏与看板严格互补」的分区不变量测试，扩展它覆盖 projectID |
| 外接盘未挂载被误判为文件夹丢失 | 不自动清理，仅灰显提示 |
