# 测试指南

> 适用范围：WillDeep (Xedit) 本地开发与 PR 自检。

## 测试目标在哪里

| Target | 路径 | 风格 | 覆盖 |
| --- | --- | --- | --- |
| `XeditTests` | `XeditTests/*.swift` | **Swift Testing**（`@Suite` / `@Test` / `#expect`） | 单测 + 集成（Agent 渲染、provider library、session 持久化、Markdown 解析、MCP 目录、Memory、Skill、Plan 进度等） |
| `XeditUITests` | `XeditUITests/*.swift` | XCUITest | 启动 smoke test + 个别 UI 流程 |

## 一、本地跑（Xcode）

最常用的姿势：

1. Xcode 打开 `Xedit.xcodeproj`。
2. Scheme 选 `Xedit`。
3. `Cmd+U` 跑全套（单元 + UI）。
4. 单测要单独跑：在 Test Navigator (`Cmd+6`) 里勾对应 `@Test` 函数旁的菱形。

## 二、本地跑（命令行）

不开 Xcode 也能跑。Swift Testing 跑在 `xcodebuild` 上：

```bash
# 全套单元测试
xcodebuild test \
  -project Xedit.xcodeproj \
  -scheme Xedit \
  -destination 'platform=macOS' \
  -only-testing:XeditTests \
  | xcpretty
```

只跑某一个 Suite：

```bash
xcodebuild test \
  -project Xedit.xcodeproj \
  -scheme Xedit \
  -destination 'platform=macOS' \
  -only-testing:XeditTests/AgentSessionPersistenceTests
```

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

**当前不存在。** 想要的话可以创建一个最小封装：

```bash
#!/usr/bin/env bash
# scripts/run_tests.sh — 一键跑全套单元测试
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

xcodebuild test \
  -project Xedit.xcodeproj \
  -scheme Xedit \
  -destination 'platform=macOS' \
  -only-testing:XeditTests \
  -resultBundlePath build/test-results.xcresult \
  | xcpretty --report junit --output build/test-results.xml
```

跑完会有：
- `build/test-results.xcresult` — Xcode 原生 result bundle，双击可在 Xcode 里看完整失败堆栈。
- `build/test-results.xml` — JUnit 格式，给 CI 用。

`scripts/release.sh` 在 rc42 改进后会**先调用同样的 `xcodebuild test`**，失败则停止打包（见 [scripts/release.sh](./scripts/release.sh)）。

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

**当前未配置 CI**（`.github/workflows/` 不存在）。落地后约定（见 [ROADMAP.md](./ROADMAP.md) 阶段 6）：

- workflow 名 `tests.yml`，PR 触发。
- 产物上传到 GitHub Actions artifact `test-results`：包含 `build/test-results.xcresult.zip` 与 `build/test-results.xml`。
- 失败时在 PR check tab 直接看 JUnit 摘要。

## 六、Pre-PR 自检清单

提 PR 前自己跑一遍：

```bash
xcodebuild test -project Xedit.xcodeproj -scheme Xedit -destination 'platform=macOS' -only-testing:XeditTests | xcpretty
```

期望：除了 rc41 CHANGELOG 列出的 7-8 个已知 flaky test 外，其余全绿。如果出现新的 fail，先复现确认是不是本 PR 引入。
