<a id="willdeep-中文版"></a>

<div align="center">

<img src="appicons/icon_256x256.png" width="128" height="128" alt="WillDeep" />

# WillDeep（中文版）

**一个打开就能用的 macOS 原生编辑器，自带一个真的会改代码的 Agent。**

[![macOS](https://img.shields.io/badge/macOS-13.7%2B-black?logo=apple)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-SwiftUI-orange?logo=swift)](https://developer.apple.com/swift/)
[![Version](https://img.shields.io/badge/version-1.109.0--rc496-blue)](CHANGELOG.md)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue)](LICENSE)

*不靠 Electron。没有 800MB 的 Helper 子进程。没有那种让你怀疑人生的 "loading workspace…"。*

[willdeep.com](https://willdeep.com)

[English](#willdeep) · **简体中文** · [日本語](#willdeep-日本語版)

</div>

---

## 为什么还要再做一个编辑器？

因为你现在用的那些，都在偷偷糊弄你。

VS Code 嘴上说自己是文本编辑器，结果开五个 Node 进程来画一个 tab。Cursor 在它外面再裹一层 JS，然后每个月收你 20 美元。Xcode 启动慢到地质纪元。`vim` 当然好用，但同事看你的 dotfile 像看天书。Sublime 还活着，但靠呼吸机。

**WillDeep 是这样一个东西：把 90% 你日常真的在用的编辑功能，老老实实写成一个原生 macOS 应用；剩下那 10% 你嫌烦的部分，挂一个真能跑工具、真能写补丁的 Agent。**

- 纯原生 AppKit + SwiftUI。整个 App 比一个 VS Code 插件还小。
- 打开文件耗时 **= 你松开鼠标的瞬间**。没有 "正在索引工作区"。
- 10MB 的文件也照样打开，边滚边高亮，不哭。
- Agent 能 **跑 shell 命令、用 unified diff 改文件、做危险操作之前问你一声**。接你自己的 OpenAI / DashScope / DeepSeek / Claude / 月之暗面 Key。账单你出，数据你管。

如果你曾经一边用 `nano` 一边幻想"要是它有侧边栏、语法高亮、tab、还有个 LLM，并且良心还在该多好" —— 就是它。

---

## 它实际上能干嘛

### 一个不糟蹋你 CPU 的编辑器
- 文件打开 **立刻** 显示纯文本，语法高亮在主线程之外一边走一边叠上来。
- 文件 ≥ ~100 KB 时只高亮当前可见区域，滚到哪高亮到哪。打开一个 5MB 的 JSON 不再心慌。
- 切 tab 会恢复光标和滚动位置。Cmd+1 之后不用再问"我刚才看到哪了"。
- 代码折叠（从行号槽点开收起）、脏行标记、括号配对、Minimap + 结构 inspector、跨 tab / 跨文件夹查找替换、Markdown / HTML 实时预览、分屏、Focus 模式，全都有。
- 25 种以上语言的真高亮：Swift、Ruby、PHP、Java、JS/TS、Go、Python、Rust、C / C++ / C#、SQL、YAML、TOML、Dockerfile、Makefile、shell……

### 一个"你让它出现它才出现"的文件树
大部分编辑器只要你双击一个 `.txt`，就立刻把它所在的目录整个吞下去扫一遍。WillDeep 不会。**打开文件就只是打开文件**。只有你显式点 **Open Folder…**（⇧⌘O）的时候，左边的文件树才会出来。再也不会因为你点开 `~/Downloads` 里的一个文件，整个 App 卡住几秒钟。

### 一个值得养着的 Agent 模式
按 **⌘⇧A**，整个窗口翻到 Agent 模式 —— 左边是按项目分组的会话侧栏，右边是宽敞的对话区，回到编辑器只需一个快捷键。

- **自带 Key。** OpenAI、DashScope（qwen / qwq）、DeepSeek、Kimi、月之暗面、Claude，或者任何 OpenAI 兼容端点都能接。Key 存在 Keychain 里。
- **双档路由。** 配一个便宜的 **Flash** 模型 + 一个强力的 **Pro** 模型。Auto 模式按成本走 Flash，复杂回合强制走 Pro。
- **不是聊天，是真的会动手。** Agent 能调 `search_files`、`grep_files`（真正的正则）、`read_file`、`list_directory`、`git_status`、`run_command`、`ask_user`，也能列出并调用你配置的 **Codex skills** 和 **MCP servers**。
- **远端 runtime。** 在 Settings → Runtimes 配置 SSH 主机，把 Agent 会话绑定到远端 workspace 后，文件读取、grep/search、Git 状态、shell 命令、编译、测试和 CLI Agent 委派都会在远端执行，本地只负责界面和审批。
- **安全命令自动放行。** 只读的（`ls`、`cat`、`git diff`、`rg` 之类）走静态白名单立即执行。模棱两可的命令落到一个小的 LLM 评委手里（"YES/NO，这个命令是只读吗？"）。带破坏性的命令仍然要你手敲 `confirm`。
- **补丁式编辑，不盲写。** Agent 改文件以 unified diff 的形式给你看 —— **你点 Apply 才会写**。只能改 workspace 里已存在的文件。打开的 tab 和 git 状态会自动同步。
- **能塞图。** 在 composer 里粘贴 / 拖拽 / 添加截图。文字模型走不通的时候，自动让另一个图像理解 provider 先描述，再拼回主对话。
- **真实 token 计算。** 头部的上下文使用率是按下一次实际请求体算出来的（含 system / 历史 / 工具结果 / 图片 / tool schemas），不是拍脑袋估的。超过 50% 出现 **Compress** 按钮，让 Flash 把老对话压成一条总结；超过 75% 自动压。
- **消息可排队。** Agent 还在出字你就能继续打下一条，自动排队按顺序发。Stop 不会清掉队列，Clear Queue 才会。

### 一些细节
- Settings 里可以一键把 `willdeep` CLI 装到 `~/.local/bin`。`willdeep foo.go` 打开文件，`willdeep .` 打开当前目录。
- 跟 Finder 集成得很好。Open With… 就能选它。把文件夹拖到 Dock 上，开一个新窗口。
- 会话以人类可读的 JSON 存在 `~/Library/Application Support/WillDeep/`。想 grep 你自己的聊天记录？随便。
- Quick Open 列表跨会话缓存，按项目根路径的 SHA-256 做 key，最多缓存 50 个项目。重新打开项目时 **Cmd+P 立即可用**。
- 多窗口、多 tab、Cmd+1..9 切换、Cmd+Shift+T 恢复。
- 想给编辑器加个自定义背景图（带透明度调节）？可以。我们也加了。

---

## 安装

### 从源码编译

```bash
git clone https://github.com/xurenlu/willdeep.git
cd willdeep
open Xedit.xcodeproj
# ⌘R
```

需要 Xcode 和 macOS 13.7+。产物叫 **WillDeep.app**。公开产品域名是 [willdeep.com](https://willdeep.com)。

### 用起来

1. 打开 App。
2. **⌘O** 开文件，**⇧⌘O** 开文件夹。
3. **⌘⇧A** 切到 Agent 模式。Settings → Agent 填上你的 API Key。
4. 想要 `willdeep` 命令行的话，Settings → Command Line Tool → **Install**。

---

## 键盘映射

| 快捷键 | 动作 |
| --- | --- |
| ⌘O / ⇧⌘O | 打开文件 / 打开文件夹 |
| ⌘P | Quick Open |
| ⌘⇧P | 命令面板 |
| ⌘⇧A | 切换 Agent 模式 |
| ⌥⌘A | 切换 Agent 侧栏 |
| ⌘F / ⌘G | 查找 / 查找下一个 |
| ⌘L | 跳到行 |
| ⌘⇧O | 跳到符号（当前文件） |
| ⌘D | 复制当前行 |
| ⌥↑ / ⌥↓ | 上 / 下移当前行 |
| ⌘⇧Z | Focus 模式 |
| ⌘⌥R | 切换 Preview（Markdown / HTML） |
| ⌘⌥\ | 打开分屏文件 |
| ⌘⌥I | 切换 Inspector |
| ⌘1..9 / ⌘[ ] | Tab 切换 |
| ⌘⇧T | 恢复刚关掉的 tab |
| ⌘W | 关闭 tab |

---

## 设计哲学

> 软件该让你觉得机器在帮你赢，而不是在拖你。

- **冷启动延迟是个功能。** 不快就是 bug。
- **主线程是神圣的。** 任何会摸磁盘或网络的操作都滚去后台。
- **危险动作要问一声。** 工具默认要审批；破坏性命令要手敲确认。
- **Key 是你自己的。** 没有遥测、没有上游模型代理、没有被限流的"免费 plus 升级"漏斗。
- **Agent 是同事，不是合伙人。** 它给你 diff，你点 merge。

---

## 项目状态

WillDeep 当前在 `1.60.x` 上活跃迭代。编辑器主体已经很稳，可以日常用；Agent 部分是改动最频繁的地方。每次发布的具体变化看 [CHANGELOG.md](CHANGELOG.md)，完整的能力矩阵和未决问题看 [product-overview.md](product-overview.md)。

只要一个 fix 落地我们就发一个 release candidate。Tag 格式：`vMAJOR.MINOR.PATCH-rcN`。

---

## 参与贡献

欢迎 Issue 和 PR。代码量小到 [AppState.swift](Xedit/AppState.swift)、[ContentView.swift](Xedit/ContentView.swift) 加上 Agent 那一摞文件，一个下午能看完。从那儿开始最快。

提 PR 时请：
1. 按仓库规则升版本号（bugfix 升 `-rcN`，新功能才升 minor）。
2. 在 CHANGELOG 加一条，说清楚 **为什么** 这么改，不只是"改了啥"。
3. 不要让冷启动延迟变差。改到 open 路径上的代码请先 profile。

---

## 许可与 Open Core

WillDeep 采用 [Apache License 2.0](LICENSE) + [Open Core](OPEN_CORE.md) 模式。

除非具体文件另有说明，本仓库代码按 Apache 2.0 开源。你可以自由使用、修改、再分发本项目（包括商用），前提是遵守许可证条款。

WillDeep 名称、Logo、官方签名构建、托管服务、云同步、受管 runtime、团队功能、marketplace 能力与企业支持可能作为独立商业产品或服务提供。本仓库中已经按 Apache 2.0 发布的代码，会继续保持 Apache 2.0。

---

<div align="center">

**写给那些宁愿改代码也不愿等代码加载的人。**

⭐ 如果你也曾对着一个 loading 转圈骂出过声，请给我们点个星。

</div>

---

<div align="center">

<img src="appicons/icon_256x256.png" width="128" height="128" alt="WillDeep" />

# WillDeep

**A native macOS editor that opens fast, stays out of your way, and ships an agent that actually edits your code.**

[![macOS](https://img.shields.io/badge/macOS-13.7%2B-black?logo=apple)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-SwiftUI-orange?logo=swift)](https://developer.apple.com/swift/)
[![Version](https://img.shields.io/badge/version-1.109.0--rc496-blue)](CHANGELOG.md)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue)](LICENSE)

*No Electron. No 800MB Helper processes. No "loading workspace…" spinner that eats your afternoon.*

[willdeep.com](https://willdeep.com)

**English** · [简体中文](#willdeep-中文版) · [日本語](#willdeep-日本語版)

</div>

---

## Why another editor?

Because the ones you have are lying to you.

VS Code says it's a text editor and then forks five Node processes to render a tab. Cursor wraps that with another layer of JS and asks $20/month. Xcode launches in geological time. `vim` is wonderful and your coworkers don't read your config. Sublime is alive on a respirator.

**WillDeep is what happens when you write a real macOS app for the 90% of editing you actually do, and bolt a real coding agent onto it for the 10% you don't want to.**

- Native AppKit + SwiftUI. The whole app is smaller than one VS Code extension.
- Opens a file in **the time it takes to release the mouse button**. No "indexing workspace."
- Opens a 10MB file without crying. Highlights it incrementally as you scroll.
- An agent that **runs shell commands, edits files via unified diff, and asks you before it does anything scary** — wired into your own OpenAI / DashScope / DeepSeek / Claude / Moonshot key. You own the bill. You own the data.

If you've ever wished `nano` had a sidebar, syntax highlighting, tabs, an LLM, and a clear conscience — this is the one.

---

## What it actually does

### Editor that respects your CPU
- Plain text shows up **immediately** on open. Syntax highlighting streams in off the main thread.
- Files ≥ ~100 KB highlight only what's on screen, then extend on scroll. Open a 5MB JSON without dread.
- Tab switching restores caret + scroll position. No "where was I?" after Cmd+1.
- Code folding from the gutter, dirty-line marks, matching brackets, minimap + structure inspector, find/replace across tabs or folder, Markdown/HTML live preview, split editor, focus mode.
- 25+ languages with real grammars: Swift, Ruby, PHP, Java, JS/TS, Go, Python, Rust, C / C++ / C#, SQL, YAML, TOML, Dockerfile, Makefile, shell, and the rest.

### A file tree that loads when you tell it to
Most editors slam through your folder the moment you double-click a `.txt`. WillDeep doesn't. **Opening a file opens *the file*** — the sidebar only appears when you explicitly choose **Open Folder…** (⇧⌘O). No more locking up because you opened something inside `~/Downloads`.

### Agent mode that earns its keep
Hit **⌘⇧A** and the window flips into a dedicated chat surface — project-grouped session sidebar, wide transcript, your editor still one keystroke away.

- **Bring your own key.** OpenAI, DashScope (qwen / qwq), DeepSeek, Kimi, Moonshot, Claude, or any OpenAI-compatible endpoint. Keys live in Keychain.
- **Two-tier routing.** Configure a cheap **Flash** model and a strong **Pro** model. Auto-route cost-first or force Pro for hard turns.
- **Tools, not just chat.** The agent can `search_files`, `grep_files` (real regex), `read_file`, `list_directory`, `git_status`, `run_command`, `ask_user`. It can also list & call **Codex skills** and **MCP servers** you've configured.
- **Remote runtimes.** Configure SSH hosts in Settings → Runtimes, bind an Agent session to a remote workspace, and the Agent's file reads, grep/search, Git status, shell commands, builds, tests, and delegated CLI agents execute there while the UI stays local.
- **Remote daemon MVP.** The `willdeep-agent/` Go module ships a remote daemon with HTTP, SSE job events, and WebSocket control events. Run it on a remote Linux/macOS host behind an SSH tunnel: `willdeep-agent serve --workspace /path/to/project --token-file ~/.willdeep-agent-token`.
- **Auto-approve safe commands.** Read-only stuff (`ls`, `cat`, `git diff`, `rg`, …) runs immediately via a static allowlist. Borderline commands fall through to a tiny LLM judge ("YES/NO — is this read-only?"). Destructive patterns still demand you type `confirm`.
- **Diff proposals, not blind writes.** Agent edits arrive as unified diffs you can read, **apply, or reject**. Only files inside your workspace. Open tabs + git status update automatically.
- **Image-in.** Paste, drag, or attach screenshots in the composer. Text-only providers transparently route through a separately configured image-describing provider.
- **Real context accounting.** Header shows actual remaining tokens against the model's window — computed from the exact request payload, not a guess. A **Compress** button summarises older turns through Flash when usage crosses 50%; above 75% it runs automatically.
- **Queued sends.** Type the next message while the current turn is still streaming. Stop the response without dropping the queue.

### The little things
- `willdeep` CLI installable from Settings into `~/.local/bin`. `willdeep foo.go` opens the file. `willdeep .` opens the folder.
- Native Finder integration. Open With… just works. Drop a folder on the Dock, get a new window.
- Sessions persist as readable JSON under `~/Library/Application Support/WillDeep/`. Grep your own chat history.
- Cross-session Quick Open cache, keyed by SHA-256 of project root, capped at 50 projects. **Cmd+P** is instant on re-open.
- Multi-window, multi-tab, Cmd+1..9 to switch, Cmd+Shift+T to reopen.
- Choose a custom editor background image with opacity if that's your thing. (It's our thing.)

---

## Install

### Build from source

```bash
git clone https://github.com/xurenlu/willdeep.git
cd willdeep
open Xedit.xcodeproj
# ⌘R
```

Requires Xcode and macOS 13.7+. The app builds as **WillDeep.app**. The public product domain is [willdeep.com](https://willdeep.com).

### Use it

1. Open the app.
2. **⌘O** for a file, **⇧⌘O** for a folder.
3. **⌘⇧A** to flip into Agent mode. Settings → Agent to drop in an API key.
4. Settings → Command Line Tool → **Install** if you want `willdeep` on your `$PATH`.

---

## The keyboard map

| Shortcut | Action |
| --- | --- |
| ⌘O / ⇧⌘O | Open File / Open Folder |
| ⌘P | Quick Open |
| ⌘⇧P | Command Palette |
| ⌘⇧A | Toggle Agent mode |
| ⌥⌘A | Toggle Agent side panel |
| ⌘F / ⌘G | Find / Find Next |
| ⌘L | Go to Line |
| ⌘⇧O | Go to Symbol (in active file) |
| ⌘D | Duplicate line |
| ⌥↑ / ⌥↓ | Move line up / down |
| ⌘⇧Z | Focus Mode |
| ⌘⌥R | Toggle Preview (Markdown / HTML) |
| ⌘⌥\ | Open Split File |
| ⌘⌥I | Toggle Inspector |
| ⌘1..9 / ⌘[ ] | Tabs |
| ⌘⇧T | Reopen closed tab |
| ⌘W | Close tab |

---

## Philosophy

> Software should feel like the machine wants you to win.

- **Cold-start latency is a feature.** If it's not snappy, it's broken.
- **The main thread is sacred.** Anything that can hit disk or network goes off it.
- **Ask before risky.** Tools default to approval. Destructive commands need typed confirmation.
- **You own the keys.** No telemetry, no upstream model proxy, no rate-limited freemium funnel.
- **The agent is a colleague, not a co-founder.** It proposes diffs. You merge.

---

## Status

WillDeep is in active `1.60.x` development. The editor surface is solid for daily use; the agent stack is the area moving fastest. See [CHANGELOG.md](CHANGELOG.md) for what each release changed and [product-overview.md](product-overview.md) for the full capability matrix and open questions.

We ship a release candidate the moment a fix lands. Tags follow `vMAJOR.MINOR.PATCH-rcN`.

---

## Contributing

Issues and PRs welcome. The codebase is small enough that you can read all of [AppState.swift](Xedit/AppState.swift), [ContentView.swift](Xedit/ContentView.swift), and the Agent stack in one afternoon. Start there.

When you open a PR, please:
1. Bump the version following the rules in the repo (`-rcN` for bugfixes, minor bump for features).
2. Add a CHANGELOG entry that says **why**, not just what.
3. Don't regress cold-start latency. Profile if you're touching the open path.

---

## License And Open Core

WillDeep uses an [Apache License 2.0](LICENSE) + [Open Core](OPEN_CORE.md) model.

The code in this repository is open source under Apache 2.0 unless a file says otherwise. You are free to use, modify, and redistribute it — including for commercial purposes — provided you comply with the license terms.

The WillDeep name, logo, official signed builds, hosted services, cloud sync, managed runtimes, team features, marketplace offerings, and enterprise support may be provided separately as commercial products or services. Code already released in this repository under Apache 2.0 remains Apache 2.0.

---

<div align="center">

**Built for people who'd rather edit code than wait for it to load.**

⭐ Star the repo if you've ever sworn at a loading spinner.

</div>

---

---

<a id="willdeep-日本語版"></a>

<div align="center">

<img src="appicons/icon_256x256.png" width="128" height="128" alt="WillDeep" />

# WillDeep（日本語版）

**軽快に起動し、邪魔をせず、コードを実際に編集するエージェントを搭載した、macOS ネイティブエディター。**

[English](#willdeep) · [简体中文](#willdeep-中文版) · **日本語**

</div>

---

*日本語版の README は準備中です。暫くお待ちください。*
