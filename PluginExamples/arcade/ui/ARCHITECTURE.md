# 架构（ARCHITECTURE）

> 版本：0.1.0 · 冻结范围见 docs/locked-scope.md。本文件随架构变更同步更新。

## 1. 目标

构建一个最小但完整的经典网页小游戏平台：统一游戏大厅 + 多款独立可游玩的游戏
（贪吃蛇、俄罗斯方块、Pong、扫雷、记忆翻牌），支持响应式布局、键盘与触屏操作、
localStorage 最佳成绩，并配套 Vitest 单元测试与 Playwright 端到端回归。

## 2. 技术栈

| 层 | 选型 | 理由 |
| --- | --- | --- |
| 框架 | React 18 + TypeScript（strict 全开） | 组件化、类型安全、生态成熟 |
| 构建 | Vite 5 | 快速 dev/build，统一 Vitest/Playwright 配置 |
| 包管理 | yarn 1（packageManager 锁定 1.22.22） | 项目既有约定 |
| 单元测试 | Vitest + jsdom + Testing Library | 与 Vite 同构、速度快 |
| E2E | Playwright（chromium） | 真实浏览器回归 |
| 路由 | 自研 HashRouter | 静态托管/file 协议零配置 |
| i18n | 自研轻量字典 + `{param}` 插值 | 需求简单，避免引入重型依赖 |

## 3. 模块边界与数据流

```
main.tsx
  └─ HashRouter（hash → {path, query, seed}）
       └─ I18nProvider（locale → t(key, params)）
            └─ App（按 path 分发）
                 ├─ Lobby ──→ GameManifest 卡片 ×5（i18n 标题 + 最佳成绩）
                 └─ GameShell(gameId) ──→ <entry.component seed={seed}/>
                      ├─ 返回大厅 / 标题 / 最佳成绩徽章 / 种子徽章 / 操作说明
                      └─ 游戏模块（默认导出，GameProps）
```

数据流方向：

- **路由**：`location.hash` → `HashRouter`（useSyncExternalStore）→ `App` 分发 → 游戏模块。
- **成绩**：游戏模块 `saveBestScore(id, value)` → `safeLocalStorage`（`arcade.best.<id>`）→
  广播 → `useBestScore` 订阅刷新徽章与大厅卡片。
- **语言**：`setLocale` → 内存状态 + `arcade.locale` 持久化 → `t()` 重渲染。
- **随机**：路由 `?seed=` → `GameProps.seed` → `createRng(seed)`，全链路可复现。

## 4. 冻结契约（核心交付）

见 [docs/contracts.md](docs/contracts.md)。要点：

1. `GameManifest`（`src/games/manifest.ts`）是平台唯一游戏注册表。
2. 路由为 hash 形态 `#/game/<id>?seed=`；游戏模块不得直接操作 location.hash。
3. 存储一律经 `safeLocalStorage`，成绩 key = `arcade.best.<gameId>`。
4. 所有可见文案走 i18n（默认 zh-Hans），视图代码零硬编码文案。
5. 交互元素带稳定 `data-testid`（命名 `<scope>-<name>`）。
6. 随机一律经 `createRng`/`shuffle`，同一种子输出完全一致。
7. 键盘监听经 `useKeyControls`，卸载强制清理；触屏用 React 合成事件。
8. 游戏模块形状：`src/games/<id>/index.tsx` 默认导出 `(props: GameProps) => JSX`。

## 5. 并行开发与集成

- 各游戏模块相互独立，仅触碰 `src/games/<id>/`；新增游戏 = 扩展 `GameId` + `manifest.ts` + i18n 文案。
- 通关反馈是平台级能力：游戏调用可选的 `GameProps.onWin`，由 `App` 的 `GameRoute` 记数、`GameShell` 渲染
  `Confetti`；音效统一走 `src/core/audio.ts`（Web Audio 合成，无素材文件），开关在 `GameShell` 上。
- 集成节点合并后替换占位实现，并校验 manifest import、i18n key 与 data-testid。
- 验收节点执行 `yarn build`、`yarn test`、`yarn test:e2e` 全量回归。

## 6. 部署与运行形态

- 纯静态产物（`dist/`），任意静态服务器或 file 协议可用（hash 路由无需 rewrite）。
- 无后端、无凭据、无外部服务依赖；localStorage 为唯一持久化。
