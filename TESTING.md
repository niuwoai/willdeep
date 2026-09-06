# 测试指南

> 适用范围：WillDeep 本地开发与 PR 自检。

## 测试目标在哪里

| Target | 路径 | 风格 | 覆盖 |
| --- | --- | --- | --- |
| `XeditTests` | `XeditTests/*.swift` | **Swift Testing**（`@Suite` / `@Test` / `#expect`） | 单测 + 集成（Agent 渲染、provider library、session 持久化、Markdown 解析、MCP 目录、Memory、Skill、Plan 进度等） |
| `XeditUITests` | `XeditUITests/*.swift` | XCUITest | 启动 smoke test + 个别 UI 流程 |

## 一、本地跑（Xcode）

最常用的姿势：

1. Xcode 打开 `Xedit.xcodeproj`。
2. 普通开发 Scheme 选 `XeditUnitTests`。
3. `Cmd+U` 跑单元测试；需要 UI 测试时再切回 `Xedit`。
4. 单测要单独跑：在 Test Navigator (`Cmd+6`) 里勾对应 `@Test` 函数旁的菱形。

## 二、本地跑（命令行）

不开 Xcode 也能跑。开发阶段统一使用快速入口，不要直接启动裸 `xcodebuild`，否则多个 Agent/worktree 无法共享构建锁：

```bash
# 全套单元测试
ruby scripts/run_tests_fast.rb
```

只跑某一个 Suite：

```bash
ruby scripts/run_tests_fast.rb \
  -only-testing:XeditTests/AgentSessionPersistenceTests

# 源码和构建输入完全未变时，跳过构建步骤快速复跑
ruby scripts/run_tests_fast.rb \
  --without-building \
  -only-testing:XeditTests/AgentSessionPersistenceTests
```

`--without-building` 会校验 tracked diff、未跟踪文件内容、Xcode 工程、`Package.resolved`、Scheme 和 Xcode 版本。任一输入变化都会拒绝旧测试二进制，改为不带该参数重跑即可。

UI 测试：

```bash
xcodebuild test \
  -project Xedit.xcodeproj \
  -scheme Xedit \
  -destination 'platform=macOS' \
  -only-testing:XeditUITests
```

> 提示：UI 测试会真正启动 WillDeep，会在屏幕上看到窗口闪。跑之前关掉自己手动打开的 WillDeep 实例，否则状态会乱。

## 三、scripts/run_tests.sh

完整本地门禁执行：

```bash
scripts/run_tests.sh
```

跑完会有：
- `build/ci/XeditTests.xcresult` — Xcode 原生 result bundle。
- `build/ci/report.md` / `report.json` — 人读与机读测试报告。
- `build/ci/project_build_guard_report.md` / `.json` — 排队、缓存与耗时记录。

### 怎么读测试报告（别被绿勾骗了）

**判定规则：退出码 + 原始日志 + `report.json` 三者一致才算数。** 任何一个说失败就是失败，任何一个对不上就不许当通过。别只看 `report.json` 的 `status`——它读的是 result bundle，而 bundle 可能是陈旧的、也可能是被中途掐死时只写了一半的（见下）。

`report.json` 里 `status` 三种取值：

| status | 含义 | 退出码 |
| --- | --- | --- |
| `passed` | 退出码、日志、bundle 三者一致确认通过 | 0 |
| `failed` | 确认有失败用例（bundle 或日志任一发现失败即算） | 1 |
| `unknown` | **没能确认**——读不出结论，或几个证据互相打架 | 2 |

`source` 说明结论是从哪来的：`xcresult`（正常解析）、`xcodebuild-log`（bundle 坏了，从原始日志兜底捞的，计数为近似值）、`none`（什么都没捞到，此时必然是 `unknown`）。`unknown` 时 `reasons` 数组会写清楚为什么。

报告里另外三个字段专门用来戳穿假绿：

- `log_stats` — 从 `xcodebuild.log` 独立数出来的一份统计，跟 `stats` 对照看。
- `total_mismatch` — `stats.total` 与日志对不上时为 `true`，`reasons` 里会写明差额。此时 `status` 一定不是 `passed`。
- `test_exit` — 调用方透传的 xcodebuild 退出码。非 0 一律不许出 `passed`。

为什么要有 `unknown`：

1. xcodebuild 在 macOS 上跑完测试后有概率不退出，`scripts/xcodebuild_ci.rb` 的看门狗会把它杀掉，被杀的 bundle 缺 `Info.plist`，`xcresulttool` 全线失败。
2. **bundle 能读出来也不等于可信。** 2026-08-14 实测过一次假绿：日志写着 `Test run with 2355 tests in 201 suites failed`、三个 `✘`、xcodebuild 退出 65，`report.json` 却是 `"status": "passed"`、`total` 只有 2340——bundle 少了 22 个用例，而三个失败恰好落在少掉的那批里。复用的旧 bundle、以及跑到一半没收尾的 bundle，都会这样"干干净净"地少报。

所以这种情况下报告绝不允许写出 `ok:true`——尤其是 `scripts/run_tests_fast.rb | tail -60` 这类写法本来就吞退出码，一个绿勾就足以让跑崩的构建冒充跑通的构建。`scripts/run_tests.sh` 现在还会在开跑前先删掉上一轮的 `report.{json,md}`：中途任何一步被 `set -e` 掐断，宁可没有报告，也不能留一个旧绿勾在那儿冒充本次结论。

这套契约由 `scripts/xcresult_report_contract_test.rb` 守着（`run_tests.sh` 与 CI 都会跑），改报告器前先看它。

快速入口与完整入口会复用稳定的 DerivedData、SwiftPM checkout/package cache，并通过 Git common dir 派生的仓库级锁协调所有 linked worktree。完整 DerivedData 仍按工作树隔离，不允许多个工作树并发写入同一目录。

## 四、写新测试（Swift Testing 风格）

`XeditTests` 已经全部迁到 Swift Testing。新写测试一律用这个风格：

```swift
import Testing
import Foundation
@testable import WillDeep

@Suite("我的功能行为")
struct MyFeatureTests {

    /// 每个 @Test 跑时 Swift Testing 都会 new 一个 instance，
    /// 所以 init() 就是 setUp，没有专门 tearDown — 在 init 里
    /// 清干净 UserDefaults / 临时目录 / 单例缓存。
    init() {
        UserDefaults.standard.removeObject(forKey: "com.willdeep.my.feature")
    }

    @Test("空输入返回 nil")
    func emptyInputYieldsNil() {
        let result = MyFeature.parse("")
        #expect(result == nil)
    }

    @Test("中文 + emoji 不截断", arguments: ["你好🌏", "Swift测试"])
    func handlesUnicode(input: String) {
        #expect(MyFeature.parse(input)?.isEmpty == false)
    }
}
```

约定：
- 文件名 `XxxTests.swift`，`@Suite` 标题用中文短句描述行为，不是函数名复读。
- 涉及 `AppState` 的测试用 `@Suite(.serialized)`（参考 `XeditTests.swift`），因为 AppState init 会触摸磁盘，并发会污染。
- 涉及主线程的代码在 `@Test` 上加 `@MainActor`。
- 已知 flaky 的几个测试（rc41 CHANGELOG 列出）正在独立任务追踪，新增测试时**不要**依赖 AppState 的初始磁盘状态。

## 五、CI 报告位置

GitHub Actions `Tests` workflow 会运行复杂度、版本一致性、Go agent 与 XeditTests 门禁，并上传 Xcode、Markdown 和 JSON 报告。

## 六、Pre-PR 自检清单

### 调度产物组件快速回归

`ruby scripts/run_dispatch_artifact_tests.rb` 在工作树独立的 `build/dispatch-artifact-tests` 生成一个无外部包依赖的 SwiftPM 测试目标，编译真实集成内核及子进程源码，并执行原 Swift Testing fixture。它只缩小编译范围，不用假 Git/假工具结果代替实际集成；不会与 Xcode 共用可写编译缓存。

入口保留增量缓存，并用自身锁避免同一工作树并发改写。`--check` 仅验证生产源码提取边界，不能当作测试通过。正常运行输出 `report.json`、`report.md` 与 `swift-test.log`，源码在运行中变化时不得报绿。新入口不能替代下面的完整 Pre-PR 门禁；目前不宣称整条 App 构建已获得任何固定倍数提速。

提 PR 前自己跑一遍：

```bash
scripts/run_tests.sh
```

期望：完整门禁全绿。如果出现新的失败，先用 `run_tests_fast.rb -only-testing:...` 针对性复现。
