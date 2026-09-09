---
name: swiftui-hang-diagnose
description: 诊断并修复 macOS/iOS 原生 Swift App（SwiftUI / AppKit / UIKit）的主线程卡死、转圈、Beachball（彩虹圈）、CPU 跑满空转、界面无响应、"进程像死了一样"。当用户说 App 卡住了 / 卡死 / 转圈 / 没响应 / 假死 / 风火轮 / beachball / spinning / CPU 100% / 占用很高 / 进程死掉了 / 帮我采样一下 / sample 一下 / 为什么这么卡 / SwiftUI 列表卡顿 / 滚动卡 等，且目标是一个本机正在运行（或刚崩溃）的原生 Swift/Objective-C App 时使用。用 macOS 的 sample / spindump 采样定位热点，按"SwiftUI 卡死模式库"判读调用栈给出根因与修复，最后善后（kill）。不负责：网页/Electron/JVM 应用调优、远程服务器进程、纯算法性能优化（这类不走本 skill）。
effects: host-control
---

# Swift App 主线程卡死诊断手册

适用对象：本机正在运行（或刚卡死/崩溃）的 **原生 Swift / Objective-C App**（SwiftUI、AppKit、UIKit、Catalyst）。核心症状是 **界面转圈 / Beachball / CPU 跑满 / 点啥都没反应**。

核心思路：**先用 `sample` 抓主线程在干什么，再按"模式库"对号入座**。99% 的"卡死"不是死锁就是主线程被某段代码（常见是 SwiftUI 布局/重渲染）占满，`sample` 一抓一个准。

---

## 第 0 步 · 先判断是不是本 skill 的场景

- ✅ 原生 App、界面卡住或 CPU 异常高、进程还在（或刚没）→ 继续。
- ❌ 是 Web/Electron/Java/Python/Node 进程 → 不走本 skill。
- ❌ 用户要的是"为什么算得慢"这类纯算法优化、没有界面卡死 → 不走本 skill。

**关键认知**：用户常说"进程死掉了 / app 死了"，但大多数情况进程**还活着，只是主线程卡死**（Beachball）。务必先核实，别急着下"崩溃"结论。

---

## 第 1 步 · 定位进程，区分"卡死"还是"真崩溃"

```bash
# 按名字找进程，重点看第 3 列 %CPU
ps aux | grep -i -E "你的App名|进程名" | grep -v grep
```

判读：
- **进程在 + %CPU 很高（>80%，甚至单核 100%）** → 典型 **主线程死循环/重计算卡死**。这是 `sample` 的主场，进第 2 步。
- **进程在 + %CPU ≈ 0** → 多半是 **死锁 / 在等锁或等 IO**。也用 `sample`，会看到主线程停在 `__psynch_mutexwait` / `mach_msg` / `read` 等。
- **进程已经没了** → 才是真崩溃，去翻崩溃日志：
  ```bash
  ls -lt ~/Library/Logs/DiagnosticReports/ | grep -i 你的App名 | head
  ```
  读最新的 `.ips`（JSON 格式）里的 `Exception Type` 与 `Thread 0` 栈。

记下：**PID、版本号**（`sample` 报告头部会显示 `Version:`，便于和源码对齐）。

---

## 第 2 步 · 用 sample 采样（首选）

```bash
# 语法：sample <pid> <采样秒数> -mayDie
sample <PID> 5 -mayDie
```

- 采 3~5 秒足够定位稳定的死循环热点；卡死是持续的，不必采太久。
- `-mayDie` 允许对疑似要崩的进程采样。
- 报告同时打到终端并存到 `/tmp/<名>.sample.txt`，**保留这个路径**给用户。
- 同用户进程一般无需 sudo；若提示权限不足再加 `sudo`。

**只关心一件事：`com.apple.main-thread`（Thread 标注 `DispatchQueue_1: com.apple.main-thread`）这一条栈，看它最深、占样本最多的帧停在哪。** 其他 worker 线程若停在 `__workq_kernreturn` / `mach_msg` 就是 idle，忽略。

辅助工具（按需）：
- `spindump <PID> 5 -o /tmp/x.spindump.txt` —— 系统级、含所有线程与"无响应"标注，死锁排查更全。
- `leaks <PID>` —— 查内存泄漏（CPU 不高但内存暴涨时）。
- `sample` 抓不到符号时：进程是 Release 且 strip 过，但系统库（SwiftUI/AppKit）符号仍在，足够判读。

---

## 第 3 步 · 判读主线程栈（决策表）

看主线程最热的帧落在哪个库：

| 主线程热点 | 含义 | 去第 4 步看 |
|---|---|---|
| `SwiftUICore` 布局相关：`GraphHost.flushTransactions` / `AttributeGraph` / `placeSubviews` / `ForEachList.applyNodes` / `LazyHVStack.lengthAndSpacing` / `sizeThatFits` / `lengthThatFits` 反复递归 | **SwiftUI 布局不收敛 / 全量测量** | 模式 A、B、C |
| 出现大量 **App 自己的 `.body` getter / ViewModel 方法** 帧 | **重渲染（invalidation）循环**：state 在 body 求值里被改 | 模式 D |
| `__psynch_mutexwait` / `_dispatch_...wait` / `os_unfair_lock` | **死锁 / 主线程等锁** | 模式 E |
| `mach_msg` + 自己的同步网络/文件调用（`CFReadStream`、`read`、`SQLite`、`URLSession ...syncly`） | **主线程同步 IO 阻塞** | 模式 F |
| `WebKit` / `WebCore` + 上面的布局帧同时出现 | **WKWebView 动态测高回环** | 模式 C |

**核心判别**：栈里**有没有 App 自己的代码帧**？
- **几乎全是系统库（SwiftUI/AttributeGraph）、没有自己的帧** → 是**纯布局不收敛**（模式 A/B/C），不是重渲染。
- **反复出现自己的 `View.body` / `ViewModel`** → 是**重渲染循环**（模式 D）。

---

## 第 4 步 · SwiftUI / AppKit 卡死模式库（根因 → 修复）

### 模式 A：`ForEach` 里直接读"无缓存的计算属性"（最高频元凶）⭐
**特征**：栈在 `ForEachList.applyNodes → sizeThatFits` 反复递归，全是系统帧；列表数据上千。
**根因**：`ForEach(viewModel.someComputedList)` 里 `someComputedList` 是 `var x: [T] { ...filter/sort/group... }` 计算属性。SwiftUI 在**一次**布局 pass 里会多次向 ForEach 索要数据（测量、放置、协商各一遍），每取一次就把全量数据 `filter+sort+group` 重算一遍 → 永不收敛 → CPU 100%。返回的还是全新实例，SwiftUI 无法 diff，雪上加霜。
**修复**：
- 把计算属性改成 **`@Published private(set) var`，只在源数据变化时重算一次并缓存**；**绝不让 `ForEach` / `body` 直接读计算属性**。
- 让元素 `Equatable` 且 `id` 稳定（基于内容指纹如 `latestId+unreadCount`），帮助 diff。
- body 里现算的 `let filtered = xs.filter{...}` 也要警惕：每次 body 求值算一次，量大时挪进 ViewModel 缓存。

### 模式 B：`LazyVStack/LazyHStack` 被"无界容器"撑破，退化成全量测量
**特征**：lazy 列表却把上千行全测了一遍。
**根因**：`LazyVStack` 外层是高度/宽度不受约束的容器（如再套一层 `ScrollView`，或放进 `sizeThatFits` 无界的自定义布局），lazy 失效，被迫一次性测量全部子视图。
**修复**：保证 LazyStack 所在的滚动方向有明确边界（唯一一层 `ScrollView`，外层用固定 `.frame(width:)/.frame(height:)` 或 split view 限定）。避免 ScrollView 套 ScrollView 同向嵌套。

### 模式 C：WKWebView 动态测高 ↔ SwiftUI 布局回环
**特征**：栈里 `WebKit/WebCore` + 布局帧同时持续出现；采样里有 `WebCore: Scrolling` 线程。
**根因**：`NSViewRepresentable` 包 WKWebView，用 `onHeightChange → @State height → .frame(height: height)` 自适应高度，且外层在 ScrollView 里。webView 回报高度→改 state→重新布局→webView 再回报，含图片/异步字体的邮件高度在两值间横跳，永不稳定。
**修复**：测高加去抖（`abs(new-old) < 2` 直接忽略）；高度只增不减或加阈值；超长内容别让 webView 完全靠外层 ScrollView 撑开，给 webView 自身可滚动 + 固定/上限高度。

### 模式 D：重渲染（invalidation）循环
**特征**：栈里反复出现自己的 `SomeView.body` / `@Published` setter。
**根因**：在 `body` 求值过程中（或 `onAppear`/`onChange` 无条件地）修改了被本视图依赖的 `@State/@Published` → 改了就重渲染 → 重渲染又改 → 死循环。常见：body 里 `self.x = ...`、`GeometryReader` 里回写 state 不设阈值、`onChange` 互相触发。
**修复**：状态修改移出 body；回写 state 前做"值变了才写"判断；用 `task`/`onReceive` 而非在 body 内副作用。

### 模式 E：主线程死锁 / 等锁
**特征**：%CPU≈0，主线程停在 `__psynch_mutexwait` / `os_unfair_lock_lock` / `dispatch_*wait`。
**根因**：主线程 `DispatchQueue.main.sync { }`（自己等自己，必死锁）；或主线程等一个被后台线程长期持有的锁；A/B 锁顺序相反互等。
**修复**：杜绝在主线程 `DispatchQueue.main.sync`；锁内不做重活/不发起会回到主线程的调用；统一加锁顺序；优先用 actor/串行队列替代裸锁。

### 模式 F：主线程同步 IO 阻塞
**特征**：主线程停在 `read`/`recv`/`CFReadStream`/SQLite/`URLSession ...sync`/大文件 `Data(contentsOf:)`。
**根因**：网络请求、数据库大查询、磁盘大文件读写跑在主线程。
**修复**：挪到后台（`Task.detached` / 后台队列 / `async`），结果切回 `@MainActor` 更新 UI。

### 其它高频点
- 主线程跑重 CPU 活：JSON 解析、正则、图片解码、加密、`String` 大量拼接 → 移后台。
- `List`/`Table` 行内放未约束尺寸的图片或 `Text` 超长无 `lineLimit` → 给约束。
- `.animation()` 作用域过大导致每帧重排 → 收窄到具体值的隐式动画或 `withAnimation`。

---

## 第 5 步 · 善后

确认根因后，卡死进程不会自愈（主线程忙，连退出事件都处理不了），需强杀：
```bash
kill -9 <PID>          # 主线程卡死时 SIGTERM 往往无效，直接 -9
ps -p <PID> >/dev/null 2>&1 && echo "仍在运行" || echo "已终止"
```
原生邮件/编辑类 App 数据一般已落库，强杀通常安全；但先口头确认用户没有未保存的内存态数据。

---

## 产出规范（给用户的结论）

一次诊断至少给出：
1. **结论**：是"主线程卡死"还是"真崩溃"，一句话定性（别被"进程死了"带偏）。
2. **根因**：命中模式库哪一条，**带 `文件:行号` 证据**（必要时派只读 agent 通读相关 View/ViewModel 锁定具体视图）。
3. **修复建议**：按优先级排序，最小改动优先；指出"改哪一条就能根除"。
4. **采样报告路径**：`/tmp/*.sample.txt` 留档。
5. **善后**：是否已 `kill`。

> 记住本仓库规则：真要动手改代码时，bugfix 走 `rcN` 递增、前后端版本一致、更新 CHANGELOG，不要擅自提交。
