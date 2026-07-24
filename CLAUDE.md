# CLAUDE.md（Xedit / WillDeep 项目级规则）

> 本文件是 Xedit 项目专属的 AI 协作规则，优先级高于全局 `~/.claude/CLAUDE.md`。
> 全局通用规范（代码风格、错误处理、版本号、CHANGELOG 等）仍然适用，本文件只补充项目特有约束。

## Git 工作流（硬约束）

- **MUST**：每次开发都从 `develop` 分支拉新分支再动手，**不得**直接在 `develop` 或 `main` 上开发。
  - 起手：`git checkout develop && git pull && git checkout -b <feature-branch>`
  - 分支命名沿用现有习惯（`fix/...`、`feat/...`、`claude/...` 等）。
- **MUST**：开发完成后，**先跑完单元测试**，测试通过后**先提交（commit）**，再把分支合回 `develop`。
  - 顺序固定：**跑单测 → 提交 → 合回 develop**。三步缺一不可，不得跳过测试直接合。
  - 单测失败时，禁止提交、禁止合并；先修复到全绿再走后续步骤。
- **MUST**：如实报告单测结果——失败就说失败并附输出，不把未验证的改动说成"已完成/已合并"。
- **MUST NOT**：跳过单元测试直接 commit 或直接 merge 回 `develop`。
- **MUST NOT**：`git push --force` 到 `develop` / `main` 等共享分支。

### 标准流程

```bash
# 1. 从 develop 拉新分支
git checkout develop
git pull
git checkout -b feat/xxx

# 2. 开发……

# 3. 跑完单元测试（全绿才继续）
#    本地单测参考 TESTING.md / scripts 下的测试脚本

# 4. 先提交
git add <精确改动的文件>   # 并发会话仓库，勿用 git add -A
git commit -m "feat(xxx): ..."

# 5. 再合回 develop
git checkout develop
git merge feat/xxx
```
