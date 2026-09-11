# 文件改动归属台账设计

> Last updated: 2026-09-11 | 状态：**已确认，实施中**（2026-09-11 用户说「再完成台帐」，七项待确认全部按默认假设执行）
> 关联版本：基于 1.368.0-rc3（develop @ 562cd5cb）
> 适用范围：Xedit（WillDeep macOS App）Agent 模式的文件读写与 Git 提交路径
> 关联文档：`docs/AGENT_HARNESS_IMPROVEMENT_PRIORITIES.md`
> 一句话：给会话加一份「我看过/写过哪些文件、当时是什么样」的台账，让 Agent 说得出哪处改动是自己的、哪处是外部的，并在写入陈旧内容前先告知模型。

---

## 0. 需求来源

用户看到 Claude Code 的一段输出后提出的：

> 提交时我发现 `deploy/k8s/overlays/production/03-tokenhub.yaml` 有一处改动，不是我做的，文件时间戳是 20:29，就在我跑测试前后。它和 trace 这件事无关，所以我没有把它带进提交，现在还留在工作区未暂存。

随后明确：「我们 willdeep 要能记得哪些是自己改的，哪些是外部改的。」

拆开是三个能力，缺一不可：

1. **记得自己动过什么**（写集）——已有，但会误记。
2. **记得自己看过什么、当时什么样**（读账）——没有。
3. **在提交和写入时把两者用出来**——提交侧刚做了一半，写入侧没有。

---

## 1. 现状盘点

### 1.1 已经有的

| 文件:行 | 它现在干什么 | 对本需求够不够 |
| --- | --- | --- |
| `Xedit/AgentRuntime.swift:314` | `agentEditedPaths: Set<String>` 写集，随会话持久化 | 路径级够用，但只记「动过」不记「动成什么样」 |
| `Xedit/AgentGitCommitAttribution.swift`（1.368.0-rc3 新增） | 按写集把评审里的改动切成本会话/非本会话两堆 | 已落地，但证据只有「在不在写集里」 |
| `Xedit/AppStateAgentPatches.swift:702` / `:734` | `apply_patch` 的字节级 CAS：预检读一次 `originalData`，落盘前重读比对 | 真·读写一致校验，但窗口只有单次工具调用内部 |
| `Xedit/AgentWorkspaceMutationGuard.swift:386` | 回合级工作区修订（HEAD、staged digest、逐文件 `git hash-object`），写前在锁内重抓比对 | 只覆盖 `run_command` 里的 git 变更命令，`edit_file` / `apply_patch` 完全不过它 |
| `Xedit/AppStateGitStatus.swift:863` | `fileSignatureMetadata`：一次 `lstat(2)` 拿 size+mtime。注释写明刻意不用 `attributesOfItem`，后者的 xattr 流量在繁忙工作区里压倒一切 | **最便宜的探针，本设计直接复用** |
| `Xedit/AgentWorkspaceMutationGuard.swift:512` | `batchedFileDigests`：`git hash-object` 批量，每批 256 路径 | 需要内容 hash 时复用它，不要再写 CryptoKit 循环 |
| `Xedit/AgentAttachmentModels.swift:202-203` | 知识库附件已经持久化 `sourceFileSize` / `sourceModifiedAt` | **台账条目的现成范式**，字段形状照它抄 |

### 1.2 缺口

**缺口一：读取完全不留凭据。** 所有读入口拿到内容时手上都没有 mtime。

| 读入口 | 文件:行 | 手上有什么 |
| --- | --- | --- |
| `read_file` 本地 | `Xedit/AgentFileTools.swift:245` | 绝对 URL + size；**无 mtime**。且内容可能来自打开的 tab buffer 而非磁盘（`:311-317`） |
| `read_file` 远程 SSH / daemon | `Xedit/AgentRemoteRuntime.swift:167` / `:569` | 只有相对路径，连 size 都没有 |
| `search_files` / `grep_files` | `Xedit/AgentFileTools.swift:27` / `:118` | ripgrep 路径只回 path |
| `edit_file` 的读前读 | `Xedit/AgentToolsFileEditing.swift:104` | 有 URL，无 mtime |
| 上下文自动带入的当前文件 | `Xedit/AgentContextBuilder.swift:515` | 内容来自内存 tab，不是磁盘 |

**缺口二：`edit_file` 不做新旧校验。** 它拿 `old_string` 去匹配**写入那一刻**的内容（`Xedit/AgentToolsFileEditing.swift:76-140`）。文件被别人改过、但那段字符串还在，它照改不误，模型和用户都不会被告知。

**缺口三：写集会把外部改动记到自己名下。** `Xedit/AppStateGitStatus.swift:768` 把 `agentEditedPaths` 和 `changedPaths` 取并集，而 `changedPaths` 来自工具执行窗口内的快照对比（`:909`）。工具跑的那几秒里用户手改了文件，这笔会被算成 Agent 的。

**缺口四：`knownModificationDates` 是另一套，不能借。** `Xedit/AppState.swift:645` 只服务编辑器单个 tab 的「文件已被外部修改」横幅（`:2007-2012`、`Xedit/ContentViewEditorChrome.swift:80`），不带 hash、不记 Agent 读过什么、不参与任何工具门禁，且只看 `openedFileURL` 一个文件。

---

## 2. 总体架构

一份台账，两种登记来源，三个消费点。

```
登记                        台账                        消费
read_file  ─┐                                       ┌─ 写入前：内容陈旧 → 告知模型
grep/search ├─→ AgentFileObservationLedger ─────────┤
edit_file  ─┤   path → { size, mtime, source,       ├─ 提交时：非本会话改动 + 时间戳证据
apply_patch─┘            observedAt, kind }         │
                                                     └─ 归属修正：外部改动不再并进写集
```

**登记点只有一个**：`Xedit/AgentTools.swift:733`，`AgentToolRunner.run` 的成功返回处。这是唯一一个所有工具（含远程后端、含子代理的 `Xedit/AgentSubagents.swift:2034`）都必过、且同时手握工具名、参数和根目录的位置，旁边已经排了三个同类收尾 hook，加第四个是同构改动。

**探针用 `lstat`，不用 hash。** `read_file` 在 `Xedit/AgentFileTools.swift:275` 本来就调了一次 `attributesOfItem` 拿 size，换成 `fileSignatureMetadata` 一次拿齐 size+mtime，净开销约等于零。内容 hash 只在下面 §3.3 说的升级路径里按需引入。

### 2.1 为什么不搭在 `AgentWorktreeSnapshot` 上

考虑过把读取路径并进 `Xedit/AppStateGitStatus.swift:823` 的回合级快照，复用它的对比与归因。不选，三个代价：

- **域不相交**。`fileSignatures` 只覆盖 `git status` 报出来的 dirty 文件（`:884`），而 Agent 读的绝大多数文件是干净的，根本不在里面。
- **粒度对不上**。快照是 per-round，per-tool 基线明确复用回合基线不重抓（`Xedit/AppStateAgentLoop.swift:2349`），刷新还被推迟到轮末（`:2493`）。而「写前告知」要的是写那一刻的即时值。为此重抓就要多一次 `git status` 加一次 `git diff --numstat` 子进程，那正是当初特意省掉的开销。
- **语义污染**。该快照现在的契约是「git 视角的变更」，塞进干净的只读路径会让 `changes` 和 artifact 归因那套既有判断变脆。

零件仍然借：`fileSignatureMetadata`、`batchedFileDigests`、`fileDigest` 的大文件采样策略。

---

## 3. 数据结构与关键流程

### 3.1 台账条目

照 `Xedit/AgentAttachmentModels.swift:202-203` 的既有形状：

```swift
nonisolated struct AgentFileObservation: Codable, Equatable {
    var sizeBytes: Int64
    var modifiedAt: Date
    /// 内容是从磁盘读的还是从打开的 tab buffer 读的。
    var source: Source      // disk | buffer
    /// 本会话最后一次观察到它是这个样子的时刻。
    var observedAt: Date
    /// 观察是「读」还是「我写成这样」。
    var kind: Kind          // read | write
    /// 仅在需要强证据时填（见 §3.3）。
    var contentDigest: String?
}
```

`source` 必须记。`read_file` 优先读 tab buffer（`Xedit/AgentFileTools.swift:311-317`），不记来源的话「从 buffer 读、磁盘没变」会被误报成漂移。

### 3.2 写入前的告知

**不新建拦截点。** `apply_patch` 已经在 `Xedit/AppStateAgentPatches.swift:702` 读了 `originalData`、`:734` 做字节级比对，失败抛 `hunkDidNotMatch`。改动是在 `:702` 之后加一道查账：该路径在台账里、且当前 `(size, mtime)` 与登记值不符时，结果里附一条说明——「你读到的是 `<observedAt>` 那一刻的版本，磁盘已在 `<modifiedAt>` 被改过」。`edit_file` 在 `Xedit/AgentToolsFileEditing.swift:104` 同理。

这是**告知，不是阻断**。理由见 §5。

### 3.3 证据强度分档

| 档 | 探针 | 能证明 | 代价 |
| --- | --- | --- | --- |
| 默认 | `lstat` 的 size+mtime | 「文件在你读之后被动过」 | 一次系统调用 |
| 升级 | 加 `git hash-object` 内容 hash | 「内容确实不同」，能排除 touch 和同内容重写 | 每 256 路径一次子进程 |

默认档足以支撑用户原话里那句「文件时间戳是 20:29」。同一秒内的同尺寸改写测不出来——这是已知取舍，写在这里而不是假装没有。

### 3.4 归属修正

`Xedit/AppStateGitStatus.swift:768` 那个并集，改成：`changedPaths` 里的路径，若台账记着它在工具执行窗口开始之后被外部改过（`modifiedAt` 晚于本次登记且 `kind == .read`），就不并进写集。

### 3.5 持久化

- `AgentSession` 加 `var fileObservations: [String: AgentFileObservation]?`，走 `Xedit/AgentModels.swift:497` 的 `decodeIfPresent ?? [:]` 惯例。会话存档**没有版本号机制**，这样加即可，不需要迁移。
- `Xedit/AgentRuntime.swift:711` 的 `persist()` 是逐字段手写刷回，必须加一行，否则永远写不出去。
- **必须在 `Xedit/AgentSessionStore.swift:1099` 的 `metadataSession(from:)` 里清空。** 那个函数给侧边栏目录侧车用，任何新加的 session 字段默认原样进侧车，每次 persist 都多写一份无人读的字节——会话侧车 70% 废字节就是这么来的。
- 台账要有上限。见「待确认问题」第 3 条。

---

## 4. 失败路径与边缘

| 场景 | 行为 |
| --- | --- |
| 文件被删 | 登记为 `missing`，写入时按「已不存在」告知，不当成漂移 |
| 远程 / SSH 工作区 | 远程读没有 stat（`Xedit/AgentRemoteRuntime.swift:167`），首版**不登记**，不为此多一次 SSH 往返。台账缺条目时一律按「无从判断」处理，不报漂移 |
| ripgrep 命中 | 只回 path 不回 stat，为命中文件补一次 `lstat`（命中数通常个位到几十） |
| 台账无此路径 | 不告知、不阻断。缺凭据不等于「没变过」 |
| 会话恢复后台账为空 | 同上。这与 `AgentGitCommitAttribution.split` 在写集为空时返回 nil 的取舍一致：说不出口的时候就别说 |
| 同一文件 Agent 和用户都改过 | 归属仍算本会话的（路径级归属撑不起行级证据）。UI 文案说「不是本会话的改动」，不说「Agent 没碰过」 |

---

## 5. 不可让渡的不变量

1. **台账只增加信息，不新增阻断。** 写入是否成功仍由既有的 `old_string` 匹配和 `apply_patch` 的 CAS 决定。台账误报时最坏结果是模型多看一句话，不是用户改不了文件。
2. **「无从判断」必须区别于「没变过」。** 缺条目、远程工作区、会话恢复后空台账，一律走无从判断，不得默认成「未变更」。
3. **不得因为台账而跳过 `apply_patch` 现有的字节级 CAS。** 台账是软证据，那个是硬校验，`Xedit/AppStateAgentPatches.swift:734` 不动。
4. **拦截与告知发生在执行路径，不在 UI。** 消费点在工具执行内部，不依赖任何面板是否打开。

---

## 6. 验收标准与测试计划

| 编号 | 验收 | 怎么测 |
| --- | --- | --- |
| A1 | 读过的文件被外部改动后，写入结果里带漂移说明 | 单测：登记 → 改 mtime → 走 `edit_file`，断言结果含说明 |
| A2 | 从 tab buffer 读的内容不因磁盘未变而误报 | 单测：`source == .buffer` 时不报漂移 |
| A3 | 台账无条目时不报漂移 | 单测：空台账 + 已改文件 → 无说明 |
| A4 | 工具窗口内的外部改动不并进写集 | 单测：伪造 `changedPaths` 与台账，断言归属 |
| A5 | 新字段不进目录侧车 | 单测：`metadataSession` 后 `fileObservations` 为 nil/空 |
| A6 | 旧会话存档能干净加载 | 单测：不含该字段的 JSON 解码后台账为空 |
| A7 | 提交回执里带得出时间戳证据 | 单测：归属结果携带 `modifiedAt` |

全部可落成 Swift Testing 用例，不需要真实 git 仓库，除 A4 外不需要子进程。

---

## 7. 分期

| 阶段 | 内容 | 依赖 |
| --- | --- | --- |
| P1 | 台账数据结构 + 登记点 + 持久化 + 侧车清理（A5、A6） | 无 |
| P2 | 写入前告知（A1、A2、A3） | P1 |
| P3 | 归属修正 + 提交回执带证据（A4、A7） | P1、P2 |

P1 单独可交付且无行为变化，适合先合。

---

## 已确认决策（2026-09-11）

用户原话是「再完成台帐」，没有逐条回答，按流程显式列出采用的默认假设：

1. **首版不做内容 hash**，只用 `lstat` 的 size+mtime。代价：同一秒内的同尺寸改写测不出来。
2. **漂移只告知，不阻断。** 台账误报时最坏结果是模型多看一句话。
3. **台账每会话保留最近 500 条**，按 `observedAt` 淘汰。
4. **远程 / SSH 工作区首版不登记**，不为此多一次 `stat` 往返。
5. **搜索类工具登记**，`grep_files` / `search_files` 命中的文件按读处理。
6. **上下文自动带入的当前文件不登记**，它的内容来自内存 tab 而非磁盘。
7. **首版不做专门 UI**，只在提交面板已有那行文案里补时间戳。

原「待确认问题」一节的展开理由保留在下方，供后来人还原当初为什么这么定。

## 原待确认问题（已按默认执行）

1. **首版要不要内容 hash？** 默认假设：**不要**，只用 size+mtime。理由是足以支撑「时间戳是 20:29」这类说明，且开销约等于零；代价是同秒同尺寸改写测不出来。要强证据就加 `git hash-object`，每 256 路径一次子进程。
2. **漂移时告知还是阻断？** 默认假设：**只告知，不阻断**（见 §5 第 1 条）。阻断的风险是台账误报直接堵住用户的正常编辑。
3. **台账上限怎么定？** 默认假设：每会话保留最近 **500** 条，按 `observedAt` 淘汰。一次长任务读几百个文件是常态，不设上限会把会话存档撑大。这个数字是拍的，需要你认。
4. **远程 / SSH 工作区首版是否登记？** 默认假设：**不登记**，因为要多一次 `stat` 往返。代价是远程会话完全没有这个能力。
5. **搜索类工具要不要登记？** 默认假设：**要**，`grep_files` / `search_files` 命中的文件按读处理。理由是模型确实据此下判断。代价是 ripgrep 路径要为命中文件补 `lstat`。
6. **上下文自动带入的当前文件要不要登记？** 默认假设：**不登记**。它的内容来自内存 tab 而不是磁盘（`Xedit/AgentContextBuilder.swift:515`），登记进去语义混乱。
7. **要不要给用户看？** 默认假设：首版**不做专门 UI**，只在提交面板已有的那行文案里补上时间戳。依据是你此前定过的「边缘场景靠文案不靠 UI」。
