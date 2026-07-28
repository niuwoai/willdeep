# 贡献指南

> 适用范围：VeilWriter (Xedit) 仓库的代码、文档、release 流程贡献。

中文为主，技术术语保留英文。提交信息和分支名用英文，正文（PR 描述、注释）按现状跟随项目语言（目前 CHANGELOG 是中文）。

---

## 一、Fork & Clone

仓库：`git@github.com:xurenlu/veilwriter.git`

```bash
# 1) 在 GitHub 上 fork 到自己账号
# 2) 本地 clone fork
git clone git@github.com:<你的用户名>/veilwriter.git Xedit
cd Xedit

# 3) 加上游 remote，后面同步 main 用
git remote add upstream git@github.com:xurenlu/veilwriter.git
git fetch upstream

# 4) 同步 main 到 fork
git checkout main
git merge upstream/main
git push origin main
```

打开 `Xedit.xcodeproj`，scheme 选 `Xedit`，`Cmd+R` 跑得起来就算环境 OK。如果是 macOS 第一次跑，可能需要在 System Settings → Privacy & Security 里允许未签名运行。

## 二、分支命名

从 `main`（或当前 release 分支，比如 `codex/agent-tool-call-ui-rc23`）切新分支：

```bash
git checkout -b <类型>/<短描述>
```

类型用以下之一，跟 commit prefix 对齐：

| 前缀 | 用途 | 例 |
| --- | --- | --- |
| `feat/` | 新功能 | `feat/agent-image-paste` |
| `fix/` | bug 修复 | `fix/composer-freeze-on-attach` |
| `refactor/` | 不改变行为的内部结构调整 | `refactor/split-appstate` |
| `perf/` | 性能优化 | `perf/viewport-highlight-cache` |
| `docs/` | 仅文档变更 | `docs/contributing-guide` |
| `chore/` | 杂项（依赖、release 流程） | `chore/release-script-test-gate` |

短描述用连字符 kebab-case，全小写，不超过 5 个词。

## 三、Commit 信息风格

跟 `git log` 现有风格保持一致：[Conventional Commits](https://www.conventionalcommits.org) + 中文正文。

格式：

```
<type>(<scope>): <短主题>

<可选正文，中文，解释 why，不是 what>

Co-Authored-By: ...  (可选)
```

实际仓库统计（近 30 commit）：

| 前缀 | 出现次数 | 示例 |
| --- | --- | --- |
| `fix(agent):` | 17 | `fix(agent): protect live runtimes from empty-session pruning` |
| `feat(agent):` | 8 | `feat(agent): add routines and concurrent runtimes` |
| `fix(settings):` | 1 | `fix(settings): make Settings window resizable like a normal mac window` |
| `refactor:` | 1 | `refactor: code health pass rc37→rc41` |
| `chore(license):` | 1 | `chore(license): add Apache License 2.0 + refresh README license sections` |

约定：

- **type**：`feat` / `fix` / `refactor` / `perf` / `docs` / `chore` / `test`，与分支前缀对齐。
- **scope**（括号内，可省略）：模块名，常见 `agent` / `editor` / `settings` / `sidebar` / `chrome`。重构跨模块时可省 scope，例如 `refactor: code health pass rc37→rc41`。
- **主题**：英文短句，祈使式（"add" / "fix" / "tone down"），首字母小写，结尾不加句号。
- **正文**：可选；中文，分段写"做了什么 + 为什么"。CHANGELOG 自动从近似的中文段落抓取，所以正文写得清晰，CHANGELOG 几乎不需要二次编辑。
- 如果是与 Claude 协作完成的提交，末尾加 `Co-Authored-By: Claude <模型说明> <noreply@anthropic.com>`，沿用现有 commit 风格。

## 四、版本号约定

详见 [product-overview.md → 版本号约定](./product-overview.md#版本号约定)。要点：

- 格式 `MAJOR.MINOR.PATCH-rcN`，例 `1.52.1-rc42`。
- **bugfix / 文档 / release 流程改进** → 只递增 `rcN`。
- **feature 新增** → 提升 `PATCH` 或 `MINOR`，`rc` 归位 `rc1`。
- 版本同步位点以 [product-overview.md → 版本号约定](./product-overview.md#版本号约定) 的清单为准，至少包含：
  - `Xedit.xcodeproj/project.pbxproj` 里全部 `MARKETING_VERSION` 与 `CURRENT_PROJECT_VERSION`（debug + release × target）
  - `willdeep-agent/internal/agent/version.go`
  - `Help/WillDeep.help/Contents/Info.plist` 与 `ComputerUseHelper/Info.plist`
  - 根 README、Chrome 扩展 manifest / README、Mobile Gateway 与 Agent Harness 版本文档
  - `product-overview.md` 头部的 `Current version` 字段
  - `CHANGELOG.md` 顶部新增一节
- 版本号一定要前后一致：`AgentClient` 出站请求带的 `X-App-Version` 取自 `Bundle.main.CFBundleShortVersionString`，必须等于 pbxproj 里的 `MARKETING_VERSION`。

一键校验使用仓库脚本（CI 与本地共用）：

```bash
ruby scripts/version_consistency.rb
```

## 五、提 PR 前的自检

```bash
# 1) 单元测试（用 xcpretty 收掉 xcodebuild 的噪声）
xcodebuild test \
  -project Xedit.xcodeproj \
  -scheme Xedit \
  -destination 'platform=macOS' \
  -only-testing:XeditTests | xcpretty

# 2) 版本号一致性（见上节脚本）

# 3) git diff 自查：有没有 print()/dump() debug 痕迹、有没有 .env / *.key 误入
git diff --stat
git diff --name-only | xargs grep -nE '(print|dump)\(' 2>/dev/null
```

提 PR 时：

- 标题用英文、跟 commit 主题同风格（祈使式）。
- 描述里至少写：(a) **为什么**做这次改动，(b) **做了什么**（具体到关键文件 / 函数），(c) **怎么测**（手动步骤或测试覆盖说明），(d) **影响范围**（哪些用户路径会变）。
- 如果触发版本号变化，描述里贴出 `pbxproj` / `product-overview.md` / `CHANGELOG.md` 三处对齐的版本。
- 涉及 UI 改动尽量贴 before/after 截图。

PR 合入约定：

- bugfix PR → squash merge，commit 主题用 `fix(<scope>):` 开头。
- feature PR → 可以保留多个 commit，但每个 commit 都要自洽过 build。
- 文档单独 PR → `docs:` prefix。
