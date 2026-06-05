# Roadmap

> 截至 v1.52.1-rc42。本文记录代码体检多阶段重构的进度、文件拆分前后对比、后续 TODO。

## 代码体检完成总结（rc37 → rc42）

由 **5 维度并行扫描 + 对抗式验证** 报告驱动的多阶段重构：

| 阶段 | 范围 | 状态 | 落地 rc |
| --- | --- | --- | --- |
| 1 | 性能与正确性机械修复 | ✅ | rc37–rc39 |
| 2 | 拆 `ContentView.swift` | ✅ | rc40 |
| 3 | 拆 `AppState.swift`（extension 分文件） | ✅ | rc42 |
| 4 | 拆其它 >2000 行大文件（AgentModeView 等） | ⏳ TODO | — |
| 5 | i18n 落地（`Localizable.xcstrings` + L10n） | ⏳ TODO | — |
| 6 | CI（PR 触发 xcodebuild test + 版本号校验） | ⏳ TODO | — |
| 7 | 文档与 release 流程收尾 | ✅ | rc42 |

### 阶段 1 — 性能与正确性（rc37–rc39）

- 表格渲染列宽对齐：抽 `AgentMarkdownTableFormatter.swift`，TextKit 历史与 SwiftUI 流式两条路径共用，CJK 双宽算列。
- `.gitignore` 补齐 `.env*` / `*.key` / macOS 杂项等敏感与噪声项。
- 工具调用 `argumentsJSON` 解析失败不再静默落空 dict——失败 tool call 标 `.failed` 并把坏 JSON 通过 tool message 反馈给模型自纠。
- 复制按钮 3s 还原由 `asyncAfter` 改 `DispatchWorkItem`，连续点击不再 label 错乱。
- `AgentClient` 所有出站请求加 `X-App-Version` + `User-Agent: Xedit/<version> (macOS)` header。
- `SyntaxHighlighter` 已编译的 `NSRegularExpression` 进 NSLock 保护的静态缓存。viewport 高亮的 O(N × 规则数) 编译降到 O(规则数) 一次。
- `AppState.findMatchRanges` / `changedLineNumbers` 加内容哈希双键缓存。SwiftUI body 多次读不再每次重扫全文。
- `AgentChatHistoryRenderer` avatar NSImage 进 (label, fill) 缓存。
- `awaitToolDecision` 用 `withTaskCancellationHandler` 兜底 cancel，杜绝工具决策悬挂泄漏。

### 阶段 2 — 拆 ContentView.swift（rc40）

```
ContentView.swift   3287 → 1798 行   (-1489, -45%)
+ ContentViewBackgrounds.swift  ~201   背景 / 视觉效果 / resize handle
+ EmptyStateViews.swift         ~308   空工作区 / 空 tab hero + recent
+ MainWindowChrome.swift        ~423   键盘快捷键 / 窗口 chrome / palette
+ MarkdownPreview.swift         ~727   Markdown / HTML / 代码块 / 表格
```

`ContentView.swift` 收敛回 CLAUDE.md §10 软上限 2000 行以下。

### 阶段 3 — 拆 AppState.swift（rc42）

```
AppState.swift    4946 → 1364 行   (-3582, -72%)
+ AppStateAgentLoop.swift              ~1382   dispatch/runAgentLoop/awaitToolDecision/工具决策/context 压缩/patch
+ AppStateAgentSessions.swift          ~1052   sendAgentMessage / sessions+routines 生命周期 / Plan & Goal / library / 附件
+ AppStateFileOperations.swift          ~540   NSOpenPanel / file load+save / session restore / 安全 bookmark
+ AppStateGitStatus.swift                ~488   git porcelain 解析 / worktree snapshot / diff preview
+ AppStateEditorTextUtilities.swift      ~180   nonisolated 文本工具：find / changedLines / 行操作 / 目录枚举
+ AppStatePersistenceStores.swift        ~111   RecentItemsStore / SessionStore / CompressionSummaryCollector
```

主类瘦身到 1364 行；所有伴生文件 < 1400 行。门面 + callsite 不动，零行为变更。

### 阶段 7 — 文档与 release 流程（rc42）

- `product-overview.md` 重写架构 / 目录结构 / 关键概念 / 版本号 / i18n / 测试 CI 章节，与代码实际结构对齐。
- 新增 [TESTING.md](./TESTING.md) — 本地 / 命令行跑 XeditTests + XeditUITests，Swift Testing 新风格示例，pre-PR 自检清单。
- 新增 [CONTRIBUTING.md](./CONTRIBUTING.md) — fork-clone / 分支命名 / commit 风格（与现有 `fix(agent):` / `refactor:` 对齐）/ rc 版本号约定 / PR 自检。共 5 章节。
- 改进 `scripts/release.sh`：
  - **build 前先跑 `xcodebuild test`**，失败 → 整个 release 停。
  - 新增 `--dry-run` 演练模式：跑测试 + Release build，不签名 / 不公证 / 不打 tag（适合签名证书不可用时验证脚本本身）。
  - 公证 + staple 完成后，**交互确认是否打 `v{版本号}` tag**；用户确认后再问是否 push origin。不直接自动 push（破坏性操作要确认，CLAUDE.md §5 + 体检报告点名要求）。
  - 输出 release 摘要：DMG 路径 + tag + HEAD + 上次 tag 到 HEAD 的 commit 范围。
- 新增本文件 `ROADMAP.md`。

## 后续 TODO

### 阶段 4 — 拆其它 >2000 行大文件

仍超 CLAUDE.md §10 软上限 2000 行的文件，按优先级：

| 文件 | 行数 | 拆分思路 |
| --- | --- | --- |
| `AgentModeView.swift` | ~2585 | 抽 `AgentSidebarView`（左侧会话/Routines 侧栏）/ `AgentChatPaneView`（右侧聊天）/ `AgentEmptyDashboard`（无会话时 stats + heatmap） |
| `AgentTools.swift` | ~2126 | 按工具家族拆：`AgentTools+Search`（search/grep）/ `AgentTools+File`（read/list）/ `AgentTools+RunCommand`（含 allowlist + LLM judge）/ `AgentTools+MCP` / `AgentTools+Skill` |
| `AgentModeComposerView.swift` | ~1910 | 抽 `AgentComposerInputBar` / `AgentComposerAttachments` / `AgentComposerPickers`（@file/@workspace/@skill 选择器）/ `AgentComposerWorkspacePill` |
| `AgentChatHistoryTextView.swift` | ~1852 | 抽 `AgentChatHistoryRenderer`（已有，但仍内嵌）/ `AgentChatBubbleDrawing` / `AgentChatToolGroupRendering` |

每次只动一个文件、保留 callsite 完全不变，测试套绿即可合入。

### 阶段 5 — i18n 落地

前提：先决定首发语言矩阵（建议 zh-Hans + en），然后：

1. `Resources/Localizable.xcstrings`（Xcode 15+ String Catalog 格式）建表。
2. 写一个 `L10n.swift` enum，每个 case 对应一个 string key，body 调 `String(localized:)`。
3. 把现有写死文案分批迁过去：先 Settings → Agent 主面板 → Editor 菜单 → 错误信息。
4. 加 lint：禁止 SwiftUI 视图里直接出现 `Text("中文字符")` —— 强制走 `L10n.foo` 或 `L10n.foo(args)`。
5. 文档：在 `CONTRIBUTING.md` 加一节"i18n 规范"。

### 阶段 6 — CI

GitHub Actions `tests.yml`：

```yaml
name: tests
on: [pull_request, push]
jobs:
  unit-tests:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4
      - name: Select Xcode
        run: sudo xcode-select -s /Applications/Xcode_15.4.app
      - name: Run XeditTests
        run: |
          xcodebuild test \
            -project Xedit.xcodeproj \
            -scheme Xedit \
            -destination 'platform=macOS' \
            -only-testing:XeditTests \
            -resultBundlePath build/test-results.xcresult
      - name: Upload result bundle
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: test-results
          path: build/test-results.xcresult
      - name: Version consistency check
        run: ./scripts/check_versions.sh   # 还要再加这个脚本
```

附加：lint workflow（swift-format / swiftlint）、版本号一致性脚本 `scripts/check_versions.sh`（CONTRIBUTING.md 第四节已经给出 inline 版本）。

### 阶段 5 / 6 之外的零散 TODO

继承自 `product-overview.md` 的 Open Questions：

- Quick Open 文件列表缓存是否应该尊重 `.gitignore`。
- Go to Symbol outline 加跨 session 磁盘缓存。
- Agent edit proposals 支持多步 patch review / 新建文件 / 更丰富的 before/after diff。
- 非 OpenAI 兼容的 model catalog endpoint 走 provider-specific fallback。
- Agent memory 用 embedding retrieval + LLM 辅助去重合并。
- 自动抽取 skill：把工具调用密集的对话变成用户可审阅的 skill 草稿。
- 默认编辑路径之外，超大文件改为 read-only 预览模式。

### 已知 flaky tests

CHANGELOG rc41 提到的 7-8 个测试由 `AppState.init` 中的磁盘 IO 在测试间相互污染引起。已 spawn 独立任务追踪。阶段 4 拆 AppState 后部分根因应该自然消失，剩余的需要补 testFixture/隔离。

## 不在此次重构范围

- 编辑器内核（`EditorView` / `SyntaxHighlighter`）：已经在 rc37 之前完成多轮 perf pass，当前规模可控。
- Settings UI：rc35 / rc36 已做完 multi-provider library 重写。
- README.md / docs/RELEASE.md：内容已较稳定，本轮只在涉及版本号约定的地方补链接。
