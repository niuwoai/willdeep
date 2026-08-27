# 经典网页小游戏平台（Classic Arcade Platform）

统一游戏大厅 + 七款经典小游戏：贪吃蛇、俄罗斯方块、Pong、扫雷、记忆翻牌、连连看、印加弹珠。

技术栈：React 18 + TypeScript（strict）+ Vite 5 + yarn 1 + Vitest + Playwright + 轻量自研 i18n/HashRouter。

通关会撒花（`src/ui/Confetti.tsx`，自绘 canvas，无第三方依赖），音效由 Web Audio 现场合成
（`src/core/audio.ts`，不打包任何音频素材，外壳右上角可静音）。

## 快速开始

```bash
yarn install        # 安装依赖（受限沙箱环境见下文“沙箱安装”）
yarn dev            # 开发服务器 http://localhost:5173
yarn build          # tsc --noEmit && vite build
yarn test           # Vitest 单元测试
yarn test:e2e       # Playwright 端到端测试（需先 yarn playwright install chromium）
```

访问 `http://localhost:5173/#/game/minesweeper?seed=42` 可带确定性种子进入指定游戏。

## 沙箱安装（受限网络环境）

本仓库附带开发辅助脚本，仅在 shell 被沙箱限制（node 进程 DNS 被拦截、
网络间歇可用、HOME/TMPDIR 只读）时使用：

```bash
./scripts/retry-install.sh    # 等待网络窗口并带重试地执行 yarn install
./scripts/run-yarn.sh build   # 重定向 TMPDIR/缓存后运行任意 yarn 命令（build/test 等）
```

- `scripts/dns-shim.cjs`：通过 `NODE_OPTIONS=--require` 预加载，把 `dns.lookup`
  重定向到 curl 的解析结果（node 进程无法 getaddrinfo 时使用）。
- `scripts/retry-install.sh`：轮询等待网络窗口，再调用 dns-shim + yarn，整轮重试。
- `scripts/run-yarn.sh`：把 yarn 1 的临时/缓存/全局目录重定向到工作区 `.cache/`
  （已 gitignore），避免只读 HOME/TMPDIR 导致的 EPERM。

普通环境下直接 `yarn install` / `yarn build` / `yarn test` 即可，
以上脚本均为开发工具，不参与运行时。

## 共享契约（冻结）

本仓库的核心交付是**冻结的共享契约**，各游戏模块独立开发、按清单注册：

- `src/core/types.ts` — `GameId` / `GameManifestEntry` / `GameProps` / `BestScore` / `Locale`
- `src/games/manifest.ts` — GameManifest：注册全部正式游戏（`memory`、`onet`、`marble`、`minesweeper`、`pong`、`snake`、`tetris`）
- `src/core/hashRouter.tsx` — Hash 路由（`#/game/<id>?seed=`），无需服务端 rewrite
- `src/core/safeLocalStorage.ts` — 存储安全封装 + 成绩 key 约定（`arcade.best.<id>`）
- `src/core/i18n.tsx` — i18n（默认 zh-Hans，fallback en→zh-Hans→key，`{param}` 插值）
- `src/core/testid.ts` — data-testid 命名契约
- `src/core/rng.ts` — 确定性种子（mulberry32）/ shuffle，游戏内禁止 Math.random
- `src/core/input.ts` — 键盘输入清理契约（useKeyControls）
- `src/core/bestScore.ts` — 最佳成绩（useBestScore / saveBestScore）

完整契约规范见 [docs/contracts.md](docs/contracts.md)。

## 目录结构

```
src/
  core/         # 冻结契约：types/manifest 无关的通用能力（rng、storage、i18n、router、input、bestScore、testid）
  ui/           # Lobby、GameShell
  games/        # 各游戏模块（src/games/<id>/index.tsx，默认导出 GameProps 组件）+ manifest
tests/e2e/      # Playwright 回归
scripts/        # 沙箱安装辅助脚本
docs/           # contracts / design / i18n / locked-scope
```

## 并行开发约定

- 每个游戏节点只修改 `src/games/<id>/index.tsx`（或其同目录实现文件），
  保持默认导出组件、props 为 `GameProps`（`{ seed?: string }`）。
- 不得修改 `src/core/*`、`src/games/manifest.ts`、i18n key、data-testid 契约。
- 游戏结束调用 `saveBestScore('<id>', value)`；随机一律用 `createRng`/`shuffle`。
- 合并冲突集中在 `manifest.ts` 的 import 区域，由集成节点统一解决。
