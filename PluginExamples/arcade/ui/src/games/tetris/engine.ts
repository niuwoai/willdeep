/**
 * 俄罗斯方块纯逻辑（并行节点交付，不依赖 React）。
 *
 * 契约约束：
 *  - 随机仅经 createRng（src/core/rng.ts），同一 seed 完全可复现
 *  - 不触碰共享契约文件（src/core/*、src/games/manifest.ts、i18n 字典）
 *  - 计分：消行 [0,100,300,500,800] × level；硬降每格 +2
 *  - 顶出（top-out）：锁定方块若仍有单元悬在棋盘上方（y < 0）即终局
 */
import { createRng } from '../../core/rng';

export const BOARD_WIDTH = 10;
export const BOARD_HEIGHT = 20;
export const EMPTY_CELL = 0;
/** 缺省随机种子（GameProps.seed 缺省时的确定性来源）。 */
export const DEFAULT_SEED = 'tetris';
/** 7-bag 随机化器使用的全部方块种类。 */
export const PIECE_KINDS: readonly PieceKind[] = ['I', 'J', 'L', 'O', 'S', 'T', 'Z'];

export type Cell = number;
export type Board = Cell[][];
export type PieceKind = 'I' | 'J' | 'L' | 'O' | 'S' | 'T' | 'Z';
export type Rotation = 0 | 1 | 2 | 3;

export interface Point {
  x: number;
  y: number;
}

export interface ActivePiece {
  kind: PieceKind;
  rotation: Rotation;
  x: number;
  y: number;
}

export interface TetrisState {
  board: Board;
  active: ActivePiece;
  next: PieceKind;
  score: number;
  lines: number;
  level: number;
  gameOver: boolean;
}

const SHAPES: Record<PieceKind, ReadonlyArray<ReadonlyArray<Point>>> = {
  I: [
    [{ x: 0, y: 1 }, { x: 1, y: 1 }, { x: 2, y: 1 }, { x: 3, y: 1 }],
    [{ x: 2, y: 0 }, { x: 2, y: 1 }, { x: 2, y: 2 }, { x: 2, y: 3 }],
    [{ x: 0, y: 2 }, { x: 1, y: 2 }, { x: 2, y: 2 }, { x: 3, y: 2 }],
    [{ x: 1, y: 0 }, { x: 1, y: 1 }, { x: 1, y: 2 }, { x: 1, y: 3 }],
  ],
  J: [
    [{ x: 0, y: 0 }, { x: 0, y: 1 }, { x: 1, y: 1 }, { x: 2, y: 1 }],
    [{ x: 1, y: 0 }, { x: 2, y: 0 }, { x: 1, y: 1 }, { x: 1, y: 2 }],
    [{ x: 0, y: 1 }, { x: 1, y: 1 }, { x: 2, y: 1 }, { x: 2, y: 2 }],
    [{ x: 1, y: 0 }, { x: 1, y: 1 }, { x: 0, y: 2 }, { x: 1, y: 2 }],
  ],
  L: [
    [{ x: 2, y: 0 }, { x: 0, y: 1 }, { x: 1, y: 1 }, { x: 2, y: 1 }],
    [{ x: 1, y: 0 }, { x: 1, y: 1 }, { x: 1, y: 2 }, { x: 2, y: 2 }],
    [{ x: 0, y: 1 }, { x: 1, y: 1 }, { x: 2, y: 1 }, { x: 0, y: 2 }],
    [{ x: 0, y: 0 }, { x: 1, y: 0 }, { x: 1, y: 1 }, { x: 1, y: 2 }],
  ],
  O: [
    [{ x: 1, y: 0 }, { x: 2, y: 0 }, { x: 1, y: 1 }, { x: 2, y: 1 }],
    [{ x: 1, y: 0 }, { x: 2, y: 0 }, { x: 1, y: 1 }, { x: 2, y: 1 }],
    [{ x: 1, y: 0 }, { x: 2, y: 0 }, { x: 1, y: 1 }, { x: 2, y: 1 }],
    [{ x: 1, y: 0 }, { x: 2, y: 0 }, { x: 1, y: 1 }, { x: 2, y: 1 }],
  ],
  S: [
    [{ x: 1, y: 0 }, { x: 2, y: 0 }, { x: 0, y: 1 }, { x: 1, y: 1 }],
    [{ x: 1, y: 0 }, { x: 1, y: 1 }, { x: 2, y: 1 }, { x: 2, y: 2 }],
    [{ x: 1, y: 1 }, { x: 2, y: 1 }, { x: 0, y: 2 }, { x: 1, y: 2 }],
    [{ x: 0, y: 0 }, { x: 0, y: 1 }, { x: 1, y: 1 }, { x: 1, y: 2 }],
  ],
  T: [
    [{ x: 1, y: 0 }, { x: 0, y: 1 }, { x: 1, y: 1 }, { x: 2, y: 1 }],
    [{ x: 1, y: 0 }, { x: 1, y: 1 }, { x: 2, y: 1 }, { x: 1, y: 2 }],
    [{ x: 0, y: 1 }, { x: 1, y: 1 }, { x: 2, y: 1 }, { x: 1, y: 2 }],
    [{ x: 1, y: 0 }, { x: 0, y: 1 }, { x: 1, y: 1 }, { x: 1, y: 2 }],
  ],
  Z: [
    [{ x: 0, y: 0 }, { x: 1, y: 0 }, { x: 1, y: 1 }, { x: 2, y: 1 }],
    [{ x: 2, y: 0 }, { x: 1, y: 1 }, { x: 2, y: 1 }, { x: 1, y: 2 }],
    [{ x: 0, y: 1 }, { x: 1, y: 1 }, { x: 1, y: 2 }, { x: 2, y: 2 }],
    [{ x: 1, y: 0 }, { x: 0, y: 1 }, { x: 1, y: 1 }, { x: 0, y: 2 }],
  ],
};

export const createBoard = (): Board =>
  Array.from({ length: BOARD_HEIGHT }, () => Array<Cell>(BOARD_WIDTH).fill(EMPTY_CELL));

const shapeFor = (piece: ActivePiece): ReadonlyArray<Point> => SHAPES[piece.kind][piece.rotation]!;

export const getCells = (piece: ActivePiece): Point[] =>
  shapeFor(piece).map(({ x, y }) => ({ x: piece.x + x, y: piece.y + y }));

export const canPlace = (board: Board, piece: ActivePiece): boolean =>
  getCells(piece).every(
    ({ x, y }) => x >= 0 && x < BOARD_WIDTH && y < BOARD_HEIGHT && (y < 0 || board[y]![x] === EMPTY_CELL),
  );

export const createState = (first: PieceKind = 'T', next: PieceKind = 'I'): TetrisState => ({
  board: createBoard(),
  active: { kind: first, rotation: 0, x: 3, y: -1 },
  next,
  score: 0,
  lines: 0,
  level: 1,
  gameOver: false,
});

export const move = (state: TetrisState, dx: number, dy: number): TetrisState => {
  if (state.gameOver) return state;
  const active = { ...state.active, x: state.active.x + dx, y: state.active.y + dy };
  return canPlace(state.board, active) ? { ...state, active } : state;
};

/** SRS 简化踢墙表：旋转后依次尝试水平偏移，首个可放位置生效。 */
const KICKS: ReadonlyArray<ReadonlyArray<Point>> = [
  [{ x: 0, y: 0 }, { x: -1, y: 0 }, { x: 1, y: 0 }, { x: -2, y: 0 }, { x: 2, y: 0 }],
  [{ x: 0, y: 0 }, { x: 1, y: 0 }, { x: -1, y: 0 }, { x: 2, y: 0 }, { x: -2, y: 0 }],
  [{ x: 0, y: 0 }, { x: 1, y: 0 }, { x: -1, y: 0 }],
  [{ x: 0, y: 0 }, { x: -1, y: 0 }, { x: 1, y: 0 }],
];

export const rotate = (state: TetrisState): TetrisState => {
  if (state.gameOver) return state;
  const rotation = ((state.active.rotation + 1) % 4) as Rotation;
  const kicks = KICKS[state.active.rotation]!;
  for (const kick of kicks) {
    const active = { ...state.active, rotation, x: state.active.x + kick.x, y: state.active.y + kick.y };
    if (canPlace(state.board, active)) return { ...state, active };
  }
  return state;
};

export const clearLines = (board: Board): { board: Board; count: number } => {
  const remaining = board.filter((row) => row.some((cell) => cell === EMPTY_CELL));
  const count = BOARD_HEIGHT - remaining.length;
  return {
    board: [...Array.from({ length: count }, () => Array<Cell>(BOARD_WIDTH).fill(EMPTY_CELL)), ...remaining],
    count,
  };
};

const LINE_SCORES = [0, 100, 300, 500, 800] as const;

export const scoreForLines = (count: number, level: number): number => LINE_SCORES[count]! * level;

export const lock = (state: TetrisState, nextKind: PieceKind = state.next): TetrisState => {
  const cells = getCells(state.active);
  if (cells.some(({ y }) => y < 0)) return { ...state, gameOver: true };
  const board = state.board.map((row) => row.slice());
  cells.forEach(({ x, y }) => {
    board[y]![x] = 1;
  });
  const cleared = clearLines(board);
  const lines = state.lines + cleared.count;
  const level = Math.floor(lines / 10) + 1;
  const active: ActivePiece = { kind: nextKind, rotation: 0, x: 3, y: -1 };
  return {
    ...state,
    board: cleared.board,
    active,
    next: state.active.kind,
    score: state.score + scoreForLines(cleared.count, state.level),
    lines,
    level,
    gameOver: !canPlace(cleared.board, active),
  };
};

export interface StepResult {
  state: TetrisState;
  /** 本步是否完成锁定（新方块入盘，消耗一个序列位）。 */
  locked: boolean;
}

export const step = (state: TetrisState, nextKind?: PieceKind): StepResult => {
  if (state.gameOver) return { state, locked: false };
  const moved = move(state, 0, 1);
  if (moved !== state) return { state: moved, locked: false };
  return { state: lock(state, nextKind), locked: true };
};

export const hardDrop = (state: TetrisState, nextKind?: PieceKind): StepResult => {
  if (state.gameOver) return { state, locked: false };
  let falling = state;
  let distance = 0;
  while (true) {
    const moved = move(falling, 0, 1);
    if (moved === falling) break;
    falling = moved;
    distance += 1;
  }
  return { state: lock({ ...falling, score: falling.score + distance * 2 }, nextKind), locked: true };
};

/**
 * 7-bag 随机序列（确定性）：每袋 7 种方块各出现一次，袋内洗牌经 createRng。
 * 组件用同一 seed 生成队列，保证同一 seed 对局完全可复现（回归依赖此契约）。
 */
export function createPieceQueue(seed: string | undefined, length: number): PieceKind[] {
  const rng = createRng(seed || DEFAULT_SEED);
  const queue: PieceKind[] = [];
  while (queue.length < length) {
    const bag = PIECE_KINDS.slice();
    for (let i = bag.length - 1; i > 0; i -= 1) {
      const j = Math.floor(rng() * (i + 1));
      const tmp = bag[i]!;
      bag[i] = bag[j]!;
      bag[j] = tmp;
    }
    queue.push(...bag);
  }
  return queue;
}
