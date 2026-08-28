/**
 * GameManifest 契约（冻结）：平台唯一游戏注册表。
 *
 * 并行节点只替换各游戏模块文件；清单条目本身（id/文案 key/成绩 key）
 * 不允许并行节点修改，集成节点统一校验。
 * 新增游戏 = 扩展 GameId 联合类型 + 本清单 + 对应 i18n 文案。
 */
import type { GameId, GameManifestEntry } from '../core/types';
import Twenty48Game from './twenty48';
import BreakoutGame from './breakout';
import JigsawGame from './jigsaw';
import MarbleGame from './marble';
import MemoryGame from './memory';
import MinesweeperGame from './minesweeper';
import OnetGame from './onet';
import PongGame from './pong';
import SnakeGame from './snake';
import TetrisGame from './tetris';

export const GAME_MANIFEST: readonly GameManifestEntry[] = [
  {
    id: '2048',
    nameKey: 'games.2048.name',
    descriptionKey: 'games.2048.description',
    controlsKey: 'games.2048.controls',
    bestScoreKeyPrefix: 'arcade.best',
    component: Twenty48Game,
  },
  {
    id: 'breakout',
    nameKey: 'games.breakout.name',
    descriptionKey: 'games.breakout.description',
    controlsKey: 'games.breakout.controls',
    bestScoreKeyPrefix: 'arcade.best',
    component: BreakoutGame,
  },
  {
    id: 'jigsaw',
    nameKey: 'games.jigsaw.name',
    descriptionKey: 'games.jigsaw.description',
    controlsKey: 'games.jigsaw.controls',
    bestScoreKeyPrefix: 'arcade.best',
    component: JigsawGame,
  },
  {
    id: 'memory',
    nameKey: 'games.memory.name',
    descriptionKey: 'games.memory.description',
    controlsKey: 'games.memory.controls',
    bestScoreKeyPrefix: 'arcade.best',
    component: MemoryGame,
  },
  {
    id: 'onet',
    nameKey: 'games.onet.name',
    descriptionKey: 'games.onet.description',
    controlsKey: 'games.onet.controls',
    bestScoreKeyPrefix: 'arcade.best',
    component: OnetGame,
  },
  {
    id: 'marble',
    nameKey: 'games.marble.name',
    descriptionKey: 'games.marble.description',
    controlsKey: 'games.marble.controls',
    bestScoreKeyPrefix: 'arcade.best',
    component: MarbleGame,
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
