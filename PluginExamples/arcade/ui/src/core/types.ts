/**
 * 共享契约：核心类型定义（冻结于 rc1，禁止破坏性修改）。
 *
 * 本文件是所有并行游戏模块与大厅之间的唯一类型契约来源。
 * 契约冻结规则见 docs/contracts.md。
 */
import type { ComponentType } from 'react';

/** 平台内置的五款游戏（最终上线集合）。 */
export type GameId = 'snake' | 'tetris' | 'pong' | 'minesweeper' | 'memory';

/** 游戏渲染组件：由各游戏模块提供默认导出组件。 */
export type GameComponent = ComponentType<GameProps>;

/** 传给游戏组件的固定 props（冻结）。 */
export interface GameProps {
  /** 确定性随机种子（来自 hash 查询串 `?seed=`），可为空。 */
  seed?: string;
}

/** 游戏清单条目（冻结）。 */
export interface GameManifestEntry {
  /** 唯一 id，同时用于路由 `/game/<id>`、localStorage 命名空间与 data-testid。 */
  id: GameId;
  /** i18n 文案 key（大厅标题）。 */
  nameKey: string;
  /** i18n 文案 key（一句话描述）。 */
  descriptionKey: string;
  /** i18n 文案 key（操作说明，显示在 GameShell 帮助区）。 */
  controlsKey: string;
  /** 最佳成绩 localStorage key 前缀，最终 key 为 `<prefix>.<id>`。 */
  bestScoreKeyPrefix: string;
  /** 游戏组件（各模块提供默认导出组件）。 */
  component: GameComponent;
}

/** 最佳成绩数值接口（冻结）。 */
export interface BestScore {
  /** 分数（越高越好）。 */
  value: number;
  /** 达成时间，Unix 毫秒。 */
  achievedAt: number;
}

/** 语言代码（冻结）。 */
export type Locale = 'zh-Hans' | 'en';
