# 构建分层设计：把单模块工程切出可独立编译的核心包

> Last updated: 2026-09-14 | 状态：**P1 已实现（1.370.0-rc1）**；**P3 第一刀已实现（1.373.0-rc1）**：
> 命令安全判定层 2,472 行进包，改一行的反馈从十几分钟降到 0.97 秒。L10n 那一刀因
> `String(localized:)` 的 bundle 归属未经实测，暂缓（见 P3 小节）。
> 关联版本：基于 1.368.0-rc3（develop @ 562cd5cb）
> 适用范围：Xedit（WillDeep macOS App）的构建拓扑与测试执行路径
> 关联文档：`TESTING.md`、`docs/AGENT_HARNESS_IMPROVEMENT_PRIORITIES.md`
> 一句话：把不依赖 AppState / SwiftUI 的纯逻辑抽成本地 SwiftPM 包，让这类改动和它们的测试不再需要编整个 App。

---

## 0. 需求来源

用户原话：

> 我们现在每次都是把几百个 swift 文件都编译一次，能不能分级一下，搞一些类似共享库之类的方案，不用每次都这样全量编译？

直接诱因是同一轮会话里的实测：为了跑 5 条纯函数单测，编了整个 App 十几分钟，并且因为连续撞了几个编译错，重复了四轮。

---

## 1. 现状盘点

### 1.1 规模与拓扑

| 项 | 实测值 |
| --- | --- |
| target 数 | 3（`Xedit` / `XeditTests` / `XeditUITests`），App 源码全在 `Xedit` 一个模块里 |
| App 源文件 | 678 个 `.swift`（`Xedit/*.swift`，平铺，无子目录分层） |
| 测试源文件 | 347 个（`XeditTests/*.swift`） |
| 引用 `AppState` 的文件 | 258 |
| 引用 `AgentRuntime` 的文件 | 91 |
| `import SwiftUI` 的文件 | 157 |
| **完全不碰 `AppState` / `@MainActor` / `SwiftUI` / `AppKit` 的文件** | **279（41%）** |
| 既有 SwiftPM 依赖 | 3 个远程包：Sparkle、SwiftTerm、SomeIMSharedSession |

扫描口径：`grep -qE "\bAppState\b|@MainActor|SwiftUI|AppKit"`，不命中即计入「纯逻辑」。这是粗口径，实际可抽量会因为传递依赖低于 279，见 §6 的先量后搬。

### 1.2 为什么一个小改动会级联全表

Swift 增量编译按文件追依赖，但**改一个被广泛引用的类型的存储属性，会让每个引用它的文件失效**。本轮改动往 `AgentSession`（`Xedit/AgentModels.swift:72`）和 `AgentRuntime`（`Xedit/AgentRuntime.swift:314`）加了存储属性，而这两个类型被两三百个文件引用，所以那一轮确实必须重编大半个 target。**这不是工具配置问题，是模块边界缺失的必然结果。**

单模块还丢掉了另一个本该免费的好处：模块内部非 `public` 声明的改动，本来完全不必触发下游重编。现在没有边界，拿不到。

### 1.3 仓库里已有的先例

`scripts/run_dispatch_artifact_tests.rb` 就是这套思路的一次性版本：在工作树里现生成一个无外部包依赖的 SwiftPM 测试目标（`build/dispatch-artifact-tests`），只编 8 个源文件 + 6 个测试文件，把真实 Git 集成内核编出来跑 Swift Testing 用例，**完全不建 UI**。它的头注释第一句就是「without building the entire UI」，并明确写着「This is not a replacement for XeditTests」。

`TESTING.md:146` 记录了它的定位：只缩小编译范围，不用假 Git / 假工具结果代替实际集成，也不与 Xcode 共用可写编译缓存。

**本设计不是发明新模式，是把这个一次性脚本升级成常驻的包。**

### 1.4 已有的加速手段及其上限

| 手段 | 文件:行 | 作用 | 上限 |
| --- | --- | --- | --- |
| `COMPILER_INDEX_STORE_ENABLE=NO` | `scripts/run_tests.sh:123` | 关掉索引库生成 | 只省索引，不省编译。本轮实测漏传这一项会让 `-index-system-modules` 单独吃掉 11 分钟 |
| `COMPILATION_CACHE_ENABLE_CACHING` | `scripts/run_tests.sh:121` | 复用编译缓存 | 换了 `-derivedDataPath` 就冷 |
| `scripts/build_fast.rb` | — | Release 预热，复用 DerivedData 与 SwiftPM 缓存 | 服务发布，不缩小编译范围 |
| `project_build_guard.rb` | `scripts/run_tests.sh:92` | 排队、指纹、去重 | 避免重复跑，不让单次变快 |

结论：能在配置层榨的已经榨过了，剩下的只有拆模块。

---

## 2. 收益边界（先把话说准）

抽出核心包之后：

**会变快的**
- 纯算法改动（解析器、判据、策略、台账）落在包内，不再触发 App 模块重编。
- **测试，这是大头。** 包内逻辑的测试用 `swift test` 跑，秒级，不建 App。本轮为跑 5 条纯函数测试编整个 App 十几分钟，就是这一项的代价。

**不会变快的**
- **改 `AgentSession` / `AgentRuntime` 的存储属性仍然级联全表。** 它们是模型层，包和 App 都依赖。本轮那种改动不会因为这次拆分而变快。
- SwiftUI 视图层改动（157 个文件）仍在 App 模块里。

把这两条写在这里，是因为「拆了模块就不用全量编译了」这个期待会落空，而落空之后容易得出「拆分没用」的错误结论。真实收益是**把最高频的两类改动从十几分钟降到秒级**，不是消灭全量编译。

---

## 3. 总体架构

```
WillDeepCore（本地 SwiftPM 包，无 SwiftUI / AppKit / AppState 依赖）
  ├─ Sources/WillDeepCore/      纯值类型、判据、解析器、策略
  └─ Tests/WillDeepCoreTests/   对应测试，swift test 秒级
        ▲
        │ import
Xedit（App target，678 → 约 400 个文件）
  └─ AppState / SwiftUI 视图 / 工具执行 / 宿主桥
XeditTests（保留，仍跑需要 App 的那部分）
```

包放在仓库内 `Packages/WillDeepCore`，用 `XCLocalSwiftPackageReference` 引入——工程已经在用 SwiftPM 接远程包，本地包是同一套机制。

### 3.1 边界规则

1. **包内不得出现 `import SwiftUI` / `import AppKit`**，也不得引用 `AppState`、`AgentRuntime` 这类宿主类型。这条用 CI 守卫钉住（见 §5）。
2. 包对外暴露的符号显式标 `public`；没标的就是包内私有，改它不触发 App 重编——这正是要买的东西。
3. **不为了拆而拆**：一个文件如果为了进包需要把宿主类型也拖进去，就不进包。

---

## 4. 分期（先量后搬）

| 阶段 | 内容 | 验收 |
| --- | --- | --- |
| P0 | 量真实可抽集：对 279 个候选做传递依赖闭包，去掉会把宿主类型拖进来的，得到真实清单与文件数 | 一份清单落进本文档 §6 |
| P1 | 建包，搬 20–30 个**零传递依赖**的纯判据与解析器，连带搬它们的测试 | `swift test` 在包内秒级跑通；App 仍编得过 |
| P2 | 加 CI 守卫（禁 SwiftUI/AppKit/AppState 进包）；把 `run_tests.sh` 改成先跑包测试再跑 App 测试 | 守卫反验：往包里塞一个 `import SwiftUI` 即红 |
| P3 | 按 P0 清单分批搬剩余部分，每批独立提交、独立验证 | 每批 App 编译与全量测试仍绿 |

**P1 是收益验证阶段，不是交付阶段。** 如果 P1 之后 `swift test` 的实测收益不明显，就停在这里，不往 P3 推。

P1 的现成候选（本轮新写的纯逻辑，以及既有的同形状文件）：
`Xedit/AgentFileObservationLedger.swift`、`Xedit/AgentGitCommitAttribution.swift`、`Xedit/AgentPluginMCPToolCatalog.swift`、`Xedit/AgentModelPickerSupport.swift`、`Xedit/AgentExecutionProfile.swift`。

---

## 5. 不可让渡的不变量

1. **不得用假实现换编译速度。** 这是 `run_dispatch_artifact_tests.rb` 头注释里已经写明的底线：只缩小编译范围，不用假 Git / 假工具结果代替实际集成。
2. **包不得反向依赖 App。** 出现这种依赖时整个分层就白做了，靠 CI 守卫拦，而不是靠约定。
3. **`XeditTests` 不被替代。** 需要 AppState、需要真实 UI 生命周期的用例留在原处。包测试是增量，不是替换。
4. **一批一提交。** 搬文件的提交不夹带行为改动，否则出问题时分不清是搬坏了还是改坏了。

---

## 6. 已确认决策（2026-09-12）

1. **P1 搬那批零传递依赖的纯逻辑文件**（清单见 §6.1，由 P0 实测确定）。
2. **包名 `WillDeepCore`**，放在仓库内 `Packages/WillDeepCore`。
3. **不一次做到 P3。** 先在 P1 验证 `swift test` 的实测收益，不明显就停。
4. **包测试放在 ruby 守卫之后、xcodebuild 之前**——它最快，失败也最该早暴露。
5. **P0 用 grep 粗算给量级**，不引入新工具链。

## 6.1 P0 实测清单

脚本口径：去掉注释后，取文件里所有 `Agent|App|WillDeep|Editor|Xedit` 前缀的标识符，
减去该文件自己声明的类型，剩下的若都不属于别的文件即算「零项目内依赖」。

| 口径 | 数量 |
| --- | --- |
| App 源文件总数 | 678 |
| 零项目内依赖 | 138 |
| 且无 SwiftUI / AppKit / MainActor | 111（合计 17293 行） |
| 且有配对测试文件 | 28 |

**脚本有一个判定缺陷，值得记下来**：第一版把 `extension X` 也算作「本文件定义了 X」，
于是 `AgentStructuredSchema.swift` 因为带一个 `extension AgentJSONValue: Codable`
被误判成零依赖，搬进包里才被编译器拆穿。已修正为只认 `struct/enum/class/actor/
protocol/typealias`。

**第二个缺陷是只量了源文件，没量测试文件。** `AgentDelegatedAcceptancePolicy`、
`AgentGoalContinuationBudget`、`AgentTimeContext` 三个源文件确实零依赖，但它们的
测试依赖 `AgentDelegatedTaskContract` / `AgentGoal` / `AgentContextBuilder`，
搬过去编不过，只能退回。**「可抽」的判据是源码与测试都零依赖**，这一点在 P1 里
才浮出来。

### P1 实际落地的 6 对

`AgentContextRunwayPolicy`、`AgentDaemonEventCursor`、`AgentFileObservationLedger`、
`AgentGitCommitAttribution`、`AgentLeakedToolCallText`、`AgentMarkdownTableFormatter`。


## P3 第一刀：命令安全判定层（2026-09-14，1.373.0-rc1）

### 搬了什么

`AgentShellCommandParser`(299) / `AgentSafeCommand`(1,636) /
`AgentPackageCommandPolicy`(138) / `AgentMaliciousCommandDenylist`(399)，
共 **2,472 行**，外加从 `AgentToolAuthorizationSupport` 里拆出的
`shellTokens` / `sshHostIndex` / `sshRemoteCommand` 三个纯字符串函数（97 行）。

这四个文件是一个完整功能单元：命令怎么切段、切出来的段危不危险、是不是
确定性恶意。它们零 UI、零 AppState、**零本地化调用**——最后一条是能搬的
关键，见下文。

### 实测收益

| | 搬之前 | 搬之后 |
|---|---|---|
| 改一行后拿到反馈 | 十几分钟（建 App） | **0.97 秒**（`swift build`） |
| 跑这批判据的测试 | 十几分钟 + 156 秒 | **0.61 秒**（62 用例 / 7 suite） |

### 搬迁实际撞了几次

**3 轮，2,472 行。** 远好于 P1 记的「每 100 行撞一次」——原因是这批文件
本来就是纯函数集合，公开面窄。三轮分别是：

1. 包内 `AgentSafeCommand` 还在调 App 侧的 `AgentCommandAuthorization`
   （所以那三个函数必须跟着进包）。
2. `Match` / `SafeShellExpansionResolution` 这类**嵌套类型和实例属性**没标
   public——批量脚本只覆盖了顶层声明和 static 成员。
3. `cleaned` 这个私有辅助被一起搬走，App 侧还有 5 处在用。**修法是在 App
   侧补一份副本，而不是从包里 public 出来**：包的公开面越小，改包内实现
   越不触发 App 重编，那正是这件事要买的东西。

### L10n 那一刀为什么没动

原计划 L10n 是第一刀（churn 密度 2.24 全仓最高，52 个文件全部只
`import Foundation`）。查下来卡在一个硬约束上：

**3,633 处 `String(localized:)`，无一指定 bundle**，而
`Localizable.xcstrings` 在 App target 里。`String(localized:)` 的 `bundle`
参数默认走 `Bundle.main`，理论上搬进包仍然读得到 App bundle——但这个结论
**没有实测支撑**，而且已有的 WillDeepCore 包里一处本地化调用都没有，这条
路没人走过。

赌错的代价是所有非英文文案静默退回英文，**不会有任何编译错误**，也很难被
测试发现。所以 L10n 必须先做一次真机验证（搬 1-2 个文件进包，跑起来看中文
是否正常），验证通过再谈剩下 50 个。这一步没做，就不搬。

### 下一刀的候选与已知阻碍

`AgentToolAuthorization`(2,408) 和 `AgentToolAuthorizationSupport`(867) 是
Authz 的核心，但它们依赖 `AgentToolModels`（`AgentJSONValue` /
`AgentToolRisk` / `AgentToolCall`），而 `AgentToolModels` 带 UI/AppState。
按边界规则第 3 条「不为了拆而拆」，它们**现在搬不动**——除非先把
`AgentToolModels` 里的纯模型部分拆出来。那是独立的一刀，不要和这次混在
一起评估。

## 原待确认问题（已按默认执行）

1. **P1 先搬哪一批？** 默认假设：上面列的 5 个纯逻辑文件加它们的测试。理由是这批零传递依赖、且其中三个是本轮刚写的，我清楚它们的边界。
2. **包名叫什么？** 默认假设 `WillDeepCore`。
3. **要不要一次做到 P3？** 默认假设**不要**，先在 P1 验证收益。
4. **`run_tests.sh` 里包测试放在哪一步？** 默认假设放在 ruby 守卫之后、xcodebuild 之前——它最快，失败也最该早暴露。
5. **P0 的传递依赖闭包用什么量？** 默认假设先用 grep 粗算给出量级，不引入新工具链。

---

### 落地后补记的实现要点

**收益是实测出来的，比预期好。**

| 路径 | 实测 |
| --- | --- |
| 包：`swift build` | 0.2–1.9 秒 |
| 包：`swift test`（53 条，连编带跑） | 4.9 秒；测试本身 0.007 秒 |
| App：`build-for-testing` + 全量测试 | 十几分钟编译 + 156 秒测试 |

也就是说，改这 6 个文件里的判据并验证，从「十几分钟」变成「5 秒」。

**跨模块访问控制是主要的搬迁成本，不是编译配置。** 一共撞了 7 轮编译错，全是
access level：`public struct` 的成员初始化器默认 internal、`private(set)` 跨模块
读不到、`nonisolated final class` 合成的 init 是 internal、嵌套类型的成员没跟着
标 public。批量加 `public` 的脚本还把函数体里的局部 `let` 也标了，触发
「attribute 'public' can only be used in a non-local scope」。**结论：别指望脚本
一把标对，靠包的 2 秒编译迭代收敛。**

**`swiftLanguageMode(.v5)` 必须钉住。** 主工程是 Swift 5 模式加
`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`；包若切到 v6 严格并发，同一份源码
在两处的编译结论不一样，这个包就不再是「主工程代码换个地方编」。

**pbxproj 要手工加三处**：`packageReferences` 里的 `XCLocalSwiftPackageReference`、
新建的 `XCLocalSwiftPackageReference` 段、以及 App target 的
`packageProductDependencies`。App 源文件走文件系统同步组，所以文件搬出 `Xedit/`
就自动离开 target，这半边是免费的。

**边界靠守卫不靠约定。** `scripts/willdeep_core_boundary_test.rb` 禁止包内出现
SwiftUI / AppKit / AppState / `@MainActor`，并要求包测试 import `WillDeepCore`。
它接在 `run_tests.sh` 的 xcodebuild 之前，和包测试一起跑。反验过：往包里塞一个
`import SwiftUI` 即红。

**下一步（P3）的判据已经清楚**：剩余候选要按「源码与测试都零依赖」重新量，且
access level 的改造成本按本轮经验约等于每 100 行源码撞一次编译错。
