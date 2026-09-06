# CLAUDE.md（Xedit / WillDeep 项目级规则）

> 本文件是 Xedit 项目专属的 AI 协作规则，优先级高于全局 `~/.claude/CLAUDE.md`。
> 全局通用规范（代码风格、错误处理、版本号、CHANGELOG 等）仍然适用，本文件只补充项目特有约束。

同时遵守根目录 [AGENTS.md](AGENTS.md)。其中的 Git 历史保留规则适用于 Claude Code、Codex 及其他协作 Agent。

## Git 工作流（硬约束）

- **MUST**：每次开发都从 `develop` 分支拉新分支再动手，**不得**直接在 `develop` 或 `main` 上开发。
  - 先检查工作树占用与未提交改动，再从已核对的 develop 基线创建工作分支；不要在并发工作树中直接切换共享分支。
  - 分支命名沿用现有习惯（`fix/...`、`feat/...`、`claude/...` 等）。
- **MUST**：开发完成后，**先跑完单元测试**，测试通过后**先提交（commit）**，再把分支合回 `develop`。
  - 顺序固定：**跑单测 → 提交 → 合回 develop**。三步缺一不可，不得跳过测试直接合。
  - 单测失败时，禁止提交、禁止合并；先修复到全绿再走后续步骤。
- **MUST**：如实报告单测结果——失败就说失败并附输出，不把未验证的改动说成"已完成/已合并"。
- **MUST NOT**：跳过单元测试直接 commit 或直接 merge 回 `develop`。
- **MUST NOT**：`git push --force` 到 `develop` / `main` 等共享分支。
- **MUST**：默认保留工作分支的逐条有效提交，不使用 squash 合并。优先在工作分支 rebase 到目标分支后 fast-forward，或通过 Rebase and merge 集成。
- **MUST NOT**：为增加 main 的提交数量制造空提交、重复提交、无意义拆分，或改写已共享的主分支历史。
- **MUST**：develop → main 发布同样保留提交明细；若历史分叉，在临时发布分支上对齐 main 并复验，不 rebase/强推共享 develop 或 main。普通 merge 可作为保留真实历史的安全备选。

### 标准流程

```bash
# 1. 核对现场并更新目标引用；以下仅为流程示例
git status
git worktree list
git fetch origin
git switch -c feat/xxx origin/develop

# 2. 开发……

# 3. 跑完单元测试（全绿才继续）
#    本地单测参考 TESTING.md / scripts 下的测试脚本

# 4. 先提交
git add <精确改动的文件>   # 并发会话仓库，勿用 git add -A
git commit -m "feat(xxx): ..."

# 5. 获准集成后，在工作分支对齐最新 develop
git fetch origin
git rebase origin/develop

# 6. 重新验证，再通过 PR 的 Rebase and merge 集成
#    本地集成则在 develop 所属且干净的工作树执行：
git merge --ff-only feat/xxx
#    不使用 squash；main 集成遵循同样的历史保留规则
```
