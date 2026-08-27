# Changelog

本项目遵循语义化版本。构建号未单独管理（纯静态前端，无发布产物号）。

## [0.2.0] - 2026-08-27

### 新增

- **连连看**（`src/games/onet/`）：4×4 / 6×4 / 8×6 三档难度，经典「连线拐弯不超过两次、可绕棋盘外围一圈」规则；
  纯逻辑 `findPath` 用扩展网格上的 0-1 BFS 求解，成功连接会在棋盘上画出折线；提示、洗牌、死局自动洗牌各自计入扣分。
- **印加弹珠**（`src/games/marble/`，Zuma 玩法）：弹珠沿螺旋轨道滚向洞口，中央发射器打进同色三连即消除，
  断口合拢可触发连锁倍率；引擎 `step(state, dt)` 为纯函数，canvas 只负责渲染，逐帧状态不进 React state。

### 变更

- **记忆翻牌每次重开都换一副牌**：牌组种子改为 `<基准种子>#<局数>`，重开即局数 +1；
  未通过 `?seed=` 指定种子时，每次进入游戏取一次性熵种子（`core/rng.ts` 新增 `entropySeed`）。
  「同一基准种子的第 N 局」依旧完全可复现，回归测试不受影响。
- **棋盘尺寸一律容器相对**：记忆翻牌 / 贪吃蛇 / 俄罗斯方块的棋盘从 `width: min(NNvw, …)` 改为
  `width: 100%` + 每格绝对上限。视口单位在插件面板里并不等于可视宽度，旧写法会让「挑战 · 6 对」
  这类布局被撑大并出现横向滚动条。`tests/e2e/layout.spec.ts` 增加棋盘 ≤ 容器、单张牌 ≤ 96px 的回归断言。

## [0.1.1] - 2026-08-19

### 变更（验收最终化）

- 独立验收节点完成干净环境完整回归：`yarn install --frozen-lockfile`、`yarn build`、`yarn test`、`yarn test:e2e` 在干净克隆上全部 exit 0；Playwright 22/22 通过（键盘 + CDP 真实触屏双通道、360×640 无横向溢出、best 持久化/跨游戏隔离/损坏 JSON 与 storage 异常降级）。
- 受限沙箱适配（仅回归工具，不参与业务逻辑）：e2e 改用 `chrome-headless-shell --no-zygote` 规避 crashpad mach bootstrap 拒绝；门禁探测与套件同路径。
- 修复 Pong 高速球可穿透球拍碰撞线导致的可获胜性缺陷；重开复位断言改为有界窗口消除读取竞态。
- 归档：`docs/acceptance-report.md`（验收报告）、`docs/verification-topology.md`（分支拓扑/合并提交/worktree 记录）。

## [0.1.0] - 2026-08-03

### 新增（五游戏集成）

- 按字母序合并 `memory`、`minesweeper`、`pong`、`snake`、`tetris` 五项 GameManifest 注册；大厅由注册表生成五个导航入口。
- 移除大厅路由对 `DummyGame` 的依赖，五个独立游戏模块均接入键盘或触屏操作与 localStorage 最佳成绩。
- 更新 README、锁定范围和大厅回归用例以反映正式集成状态。

### 新增（冻结共享契约与可运行大厅骨架）

- 工程骨架：React 18 + TypeScript(strict) + Vite 5 + Vitest + Playwright + yarn 1，
  提供 `dev` / `build` / `test` / `test:e2e` / `typecheck` / `preview` 脚本。
- 冻结共享契约（`src/core/*`）：
  - `types.ts`：`GameId` / `GameManifestEntry` / `GameProps` / `BestScore` / `Locale`。
  - `games/manifest.ts`：GameManifest 五款游戏注册表（贪吃蛇/俄罗斯方块/Pong/扫雷/记忆翻牌）。
  - `hashRouter.tsx`：Hash 路由（`#/game/<id>?seed=`），`useRoute` / `navigate` / `Link`。
  - `safeLocalStorage.ts`：存储安全封装，成绩 key `arcade.best.<id>`。
  - `i18n.tsx` + `i18n/{zh-Hans,en}.ts`：默认 zh-Hans，`{param}` 插值，语言持久化。
  - `testid.ts`：data-testid 命名契约（`<scope>-<name>`）。
  - `rng.ts`：确定性种子（mulberry32 + FNV-1a）、`shuffle` / `pick` / `range`。
  - `input.ts`：`useKeyControls` 键盘输入清理契约。
  - `bestScore.ts`：`useBestScore` / `saveBestScore` 最佳成绩订阅。
- 可运行骨架：`ui/Lobby`（卡片大厅 + 语言切换）、`ui/GameShell`（外壳 +
  成绩/种子徽章）、`games/dummy/DummyGame`（占位演示游戏）、五个游戏模块占位。
- 回归：Vitest 单元测试（rng / safeLocalStorage / i18n / hashRouter / input /
  bestScore / App 路由与 dummy），Playwright e2e（大厅导航、语言切换）。
- 文档：README、ARCHITECTURE、docs/contracts.md、docs/design.md、docs/i18n.md、
  docs/locked-scope.md。
- 开发辅助：`scripts/dns-shim.cjs`、`scripts/retry-install.sh`（受限沙箱网络
  环境下安装依赖用）。

### 已知事项

- 五款游戏均为占位实现，由并行游戏节点开发、集成节点合入。
