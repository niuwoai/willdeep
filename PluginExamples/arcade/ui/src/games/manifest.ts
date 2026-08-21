/**
 * GameManifest 契约（冻结）：平台唯一游戏注册表。
 *
 * 并行节点只替换各游戏模块文件；清单条目本身（id/文案 key/成绩 key）
 * 不允许并行节点修改，集成节点统一校验。
 * 新增游戏 = 扩展 GameId 联合类型 + 本清单 + 对应 i18n 文案。
 */
import type { GameId, GameManifestEntry } from '../core/types';
import MemoryGame from './memory';
import MinesweeperGame from './minesweeper';
import PongGame from './pong';
import SnakeGame from './snake';
import TetrisGame from './tetris';

export const GAME_MANIFEST: readonly GameManifestEntry[] = [
  {
    id: 'memory',
    nameKey: 'games.memory.name',
    descriptionKey: 'games.memory.description',
    controlsKey: 'games.memory.controls',
    bestScoreKeyPrefix: 'arcade.best',
    component: MemoryGame,
  },
  {
    id: 'minesweeper',
    nameKey: 'games.minesweeper.name',
    descriptionKey: 'games.minesweeper.description',
    controlsKey: 'games.minesweeper.controls',
    bestScoreKeyPrefix: 'arcade.best',
    component: MinesweeperGame,
  },
  {
    id: 'pong',
    nameKey: 'games.pong.name',
    descriptionKey: 'games.pong.description',
    controlsKey: 'games.pong.controls',
    bestScoreKeyPrefix: 'arcade.best',
    component: PongGame,
  },
  {
    id: 'snake',
    nameKey: 'games.snake.name',
    descriptionKey: 'games.snake.description',
    controlsKey: 'games.snake.controls',
    bestScoreKeyPrefix: 'arcade.best',
    component: SnakeGame,
  },
  {
    id: 'tetris',
    nameKey: 'games.tetris.name',
    descriptionKey: 'games.tetris.description',
    controlsKey: 'games.tetris.controls',
    bestScoreKeyPrefix: 'arcade.best',
    component: TetrisGame,
  },
];

export function getGameEntry(id: string): GameManifestEntry | undefined {
  return GAME_MANIFEST.find((entry) => entry.id === (id as GameId));
}

/** 冻结断言：清单必须恰好覆盖全部 GameId，且成绩 key 前缀唯一约定。 */
export const GAME_IDS: readonly GameId[] = GAME_MANIFEST.map((entry) => entry.id);
