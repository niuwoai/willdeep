# 共享契约规范（冻结）

> 本文档由“冻结共享契约”节点产出，是并行游戏节点与集成节点的唯一契约事实来源。
> 冻结后任何破坏性修改（重命名、改签名、改 key）都需要升级契约版本并同步本文档。

## 1. GameManifest（游戏注册表）

位置：`src/games/manifest.ts`；类型：`src/core/types.ts`。

```ts
type GameId = 'snake' | 'tetris' | 'pong' | 'minesweeper' | 'memory';
interface GameManifestEntry {
  id: GameId;
  nameKey: string;        // i18n 标题 key
  descriptionKey: string; // i18n 描述 key
  controlsKey: string;    // i18n 操作说明 key
  bestScoreKeyPrefix: string; // 成绩 key 前缀，最终 key = `${prefix}.${id}`
  component: GameComponent;   // 默认导出组件
}
interface GameProps { seed?: string }
```

- 清单条目（id / key）由冻结节点与集成节点维护，游戏节点**不得修改**。
- 新增游戏 = 扩展 `GameId` 联合类型 + manifest 条目 + 对应 i18n key。

## 2. HashRouter（路由）

位置：`src/core/hashRouter.tsx`。

- 路由形态：`#/game/<id>?seed=<value>`；空 hash 归一为 `/`。
- 游戏模块通过 `GameProps.seed` 接收种子；**不得**直接读写 `location.hash`，
  必须使用 `useRoute()` / `navigate(to)` / `<Link to>`。
- 未知路径由 `App` 渲染 404（`data-testid="not-found"`）。

## 3. safeLocalStorage（存储）

位置：`src/core/safeLocalStorage.ts`。

- 所有 localStorage 访问必须经过本模块（隐私模式/配额异常静默降级）。
- 命名空间前缀 `arcade`；成绩 key = `arcade.best.<gameId>`（`bestScoreKey()`）。
- 对象读写走 JSON；损坏数据返回 `null`。

## 4. i18n

位置：`src/core/i18n.tsx`；字典 `src/core/i18n/{zh-Hans,en}.ts`。

- 默认语言 `zh-Hans`；fallback：当前语言 → zh-Hans → 原样返回 key。
- 支持 `{param}` 插值（如 `t('common.seedValue', { seed })`）。
- 语言选择持久化在 `arcade.locale`。
- en 字典必须与 zh-Hans **key 完全同构**（有测试强制）。
- 决策背景见 docs/i18n.md。

## 5. data-testid

位置：`src/core/testid.ts`（`makeTestId` / `TEST_IDS`）。

- 规则：`<scope>-<name>`，如 `lobby-card-snake`、`game-shell-tetris`。
- 游戏模块新增可交互元素沿用此规则；大厅/外壳/占位元素的 testid 已冻结。
- E2E 与集成验收依赖这些 id 定位元素。

## 6. 确定性种子

位置：`src/core/rng.ts`。

- `createRng(seed)`（mulberry32 + FNV-1a 散列）：同一种子序列完全一致。
- `shuffle(rng, arr)` / `pick(rng, arr)` / `range(n)`。
- **规则：游戏内一切随机必须经由上述 API，禁止 `Math.random()`。**
  扫雷布雷、记忆洗牌等以此保证 `?seed=` 可复现，回归测试依赖此性质。

## 7. 输入清理

位置：`src/core/input.ts`。

- 键盘全局监听必须经 `useKeyControls(bindings, deps)`：卸载时强制移除监听；
  默认过滤 `e.repeat`；需要防滚动/防默认行为时声明 `preventDefault`。
- 触屏/指针：使用 React 合成事件（`onPointerDown` 等），组件卸载不得残留全局监听。
- 最小可点目标 44px（styles.css 已约定 `touch-action: manipulation`）。

## 8. 最佳成绩

位置：`src/core/bestScore.ts`。

- 写入：游戏结束时 `saveBestScore('<id>', value)`，内部仅保留更高分。
- 读取：`useBestScore('<id>')` 订阅式刷新（写后所有订阅者自动更新）。
- 存储 key = `arcade.best.<id>`（与第 3 条一致）。

## 9. 游戏模块形状（并行节点交付接口）

- 路径：`src/games/<id>/index.tsx`，**默认导出**组件。
- Props：`GameProps`（`{ seed?: string }`）。
- 外壳已由 `GameShell` 提供（标题/返回/成绩徽章/操作说明），游戏只渲染玩法区。
- 完成约束：单元测试放 `src/games/<id>/*.test.tsx`（vitest include 已覆盖）。

## 10. 冻结边界（谁可以改什么）

| 文件/区域 | 冻结节点 | 游戏节点 | 集成节点 |
| --- | --- | --- | --- |
| `src/core/*` | 冻结 | 只读 | 校验 |
| `src/games/manifest.ts` | 冻结 | 只读 | 校验/微调 import |
| `src/core/i18n/*` key | 冻结 | 只读 | 校验 |
| `src/ui/*` | 冻结 | 只读 | 按需微调 |
| `src/games/<id>/*` | 占位 | **实现** | 合并 |
| `tests/e2e/*` | 冻结骨架 | 可扩展本游戏 | 汇总 |
