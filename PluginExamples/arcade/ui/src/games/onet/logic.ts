/**
 * 连连看纯逻辑（不依赖 React）。
 *
 * 契约约束：
 *  - 一切随机只经 createRng / shuffle（src/core/rng.ts）；
 *    发牌种子 = `<基准种子>#<局数>`，洗牌种子再叠 `!<洗牌次数>`，
 *    所以「同一基准种子的第 N 局第 M 次洗牌」完全可复现，而玩家每次重开都是新牌面
 *  - 连接规则（经典连连看）：两张图案相同的牌，若存在一条不超过两次拐弯、
 *    且沿途只经过空格的折线路径即可消除；棋盘外围一圈视作空格，可以绕行
 *  - 最佳成绩 = scoreFor(state)：更高分更好，与 saveBestScore「只保留更高分」一致
 */
import { createRng, shuffle } from '../../core/rng';
import type { Rng } from '../../core/rng';

/** 棋盘坐标：x 为列、y 为行；允许取到 -1 与 cols/rows（外围一圈）。 */
export interface Point {
  x: number;
  y: number;
}

export type OnetStatus = 'idle' | 'playing' | 'won';

/** 难度档位。 */
export interface OnetLevel {
  id: 'easy' | 'medium' | 'hard';
  rows: number;
  cols: number;
  /** 图案种类数（牌面数必须是它的整数倍的两倍，构造时按需循环取用）。 */
  symbols: number;
}

export const LEVELS: readonly OnetLevel[] = [
  { id: 'easy', rows: 4, cols: 4, symbols: 6 },
  { id: 'medium', rows: 4, cols: 6, symbols: 8 },
  { id: 'hard', rows: 6, cols: 8, symbols: 12 },
];

export const DEFAULT_LEVEL = 1;
/** 连接线展示时长（毫秒），由组件在此后清除路径。 */
export const PATH_MS = 420;
/** 最多允许的拐弯次数（经典规则：两次）。 */
export const MAX_TURNS = 2;

/** 计分系数：每消一对 100 分，失败尝试 −10，提示 −50，洗牌 −30。 */
const SCORE_PER_PAIR = 100;
const SCORE_PER_MISS = 10;
const SCORE_PER_HINT = 50;
const SCORE_PER_SHUFFLE = 30;

export interface OnetState {
  /** 基准种子：来自 `?seed=`，缺省时由组件生成一次性熵种子。 */
  seed: string;
  /** 局数，从 0 开始；每次重开 +1。 */
  round: number;
  /** 难度档位下标（LEVELS 的下标）。 */
  level: number;
  rows: number;
  cols: number;
  /** 牌面：图案 id，已消除的位置为 null；下标 = y * cols + x。 */
  tiles: readonly (number | null)[];
  /** 当前选中的牌下标。 */
  selected: number | null;
  /** 最近一次成功连接的折线（含首尾牌），供组件画线后清除。 */
  lastPath: readonly Point[] | null;
  /** 提示高亮的一对牌下标。 */
  hintPair: readonly [number, number] | null;
  /** 剩余未消除的牌数。 */
  remaining: number;
  /** 尝试次数（选中两张不同的牌算一次）。 */
  moves: number;
  hints: number;
  shuffles: number;
  status: OnetStatus;
}

const DIRECTIONS: readonly Point[] = [
  { x: 1, y: 0 },
  { x: -1, y: 0 },
  { x: 0, y: 1 },
  { x: 0, y: -1 },
];

/** 发牌种子：基准种子 + 局数 + 洗牌次数，三者共同决定牌面。 */
export function dealSeed(seed: string, round: number, shuffles = 0): string {
  return shuffles > 0 ? `${seed}#${round}!${shuffles}` : `${seed}#${round}`;
}

export function levelAt(level: number): OnetLevel {
  return (LEVELS[level] ?? LEVELS[DEFAULT_LEVEL]) as OnetLevel;
}

export function indexOf(cols: number, point: Point): number {
  return point.y * cols + point.x;
}

export function pointOf(cols: number, index: number): Point {
  return { x: index % cols, y: Math.floor(index / cols) };
}

/** 构造成对牌面：图案循环取用，保证每种图案出现偶数次。 */
export function buildTiles(rows: number, cols: number, symbols: number, rng: Rng): (number | null)[] {
  const total = rows * cols;
  const deck: number[] = [];
  for (let pair = 0; pair < Math.floor(total / 2); pair += 1) {
    const symbol = pair % symbols;
    deck.push(symbol, symbol);
  }
  return shuffle(rng, deck);
}

/**
 * 该点是否可以「穿过」：外围一圈永远可通行，棋盘内只有空位可通行；
 * 终点牌本身允许作为落点（由调用方以 target 传入）。
 */
function walkable(
  tiles: readonly (number | null)[],
  rows: number,
  cols: number,
  x: number,
  y: number,
  target: Point,
): boolean {
  if (x === target.x && y === target.y) return true;
  if (x < -1 || y < -1 || x > cols || y > rows) return false;
  if (x < 0 || y < 0 || x >= cols || y >= rows) return true;
  return tiles[y * cols + x] === null;
}

/** 把折线上共线的中间点压掉，只留起点、拐点与终点。 */
function compress(points: readonly Point[]): Point[] {
  const result: Point[] = [];
  for (let i = 0; i < points.length; i += 1) {
    const previous = result[result.length - 1];
    const current = points[i] as Point;
    const next = points[i + 1];
    if (previous && next) {
      const collinearX = previous.x === current.x && current.x === next.x;
      const collinearY = previous.y === current.y && current.y === next.y;
      if (collinearX || collinearY) continue;
    }
    result.push(current);
  }
  return result;
}

/**
 * 求 from → to 的可行连接折线（拐弯不超过 MAX_TURNS 次）。
 * 命中返回折线（含首尾牌坐标，已压缩共线点），不可达返回 null。
 *
 * 实现：在「棋盘 + 外围一圈」的扩展网格上做 0-1 BFS，
 * 状态为 (x, y, 进入方向)，同方向前进代价 0（队首入队），换向代价 1（队尾入队）。
 */
export function findPath(
  tiles: readonly (number | null)[],
  rows: number,
  cols: number,
  from: Point,
  to: Point,
): Point[] | null {
  if (from.x === to.x && from.y === to.y) return null;

  const width = cols + 2;
  const height = rows + 2;
  const stateCount = width * height * DIRECTIONS.length;
  const stateKey = (x: number, y: number, dir: number): number =>
    ((y + 1) * width + (x + 1)) * DIRECTIONS.length + dir;

  const UNVISITED = MAX_TURNS + 1;
  const turnsAt = new Int16Array(stateCount).fill(UNVISITED);
  const parentOf = new Int32Array(stateCount).fill(-1);
  const deque: number[] = [];

  DIRECTIONS.forEach((direction, dir) => {
    const x = from.x + direction.x;
    const y = from.y + direction.y;
    if (!walkable(tiles, rows, cols, x, y, to)) return;
    const key = stateKey(x, y, dir);
    turnsAt[key] = 0;
    parentOf[key] = -1;
    deque.push(key);
  });

  const decode = (key: number): { x: number; y: number; dir: number } => {
    const dir = key % DIRECTIONS.length;
    const cell = (key - dir) / DIRECTIONS.length;
    return { x: (cell % width) - 1, y: Math.floor(cell / width) - 1, dir };
  };

  const rebuild = (key: number): Point[] => {
    const points: Point[] = [];
    let cursor = key;
    while (cursor >= 0) {
      const { x, y } = decode(cursor);
      points.unshift({ x, y });
      cursor = parentOf[cursor] as number;
    }
    points.unshift({ x: from.x, y: from.y });
    return compress(points);
  };

  while (deque.length > 0) {
    const key = deque.shift() as number;
    const { x, y, dir } = decode(key);
    if (x === to.x && y === to.y) return rebuild(key);

    const turns = turnsAt[key] as number;
    for (let nextDir = 0; nextDir < DIRECTIONS.length; nextDir += 1) {
      const direction = DIRECTIONS[nextDir] as Point;
      // 不允许原地掉头（等价于回退，永远不会更优）
      if ((nextDir ^ 1) === dir) continue;
      const nextTurns = turns + (nextDir === dir ? 0 : 1);
      if (nextTurns > MAX_TURNS) continue;
      const nx = x + direction.x;
      const ny = y + direction.y;
      if (!walkable(tiles, rows, cols, nx, ny, to)) continue;
      const nextKey = stateKey(nx, ny, nextDir);
      if ((turnsAt[nextKey] as number) <= nextTurns) continue;
      turnsAt[nextKey] = nextTurns;
      parentOf[nextKey] = key;
      if (nextDir === dir) deque.unshift(nextKey);
      else deque.push(nextKey);
    }
  }
  return null;
}

/** 两张牌是否可连（图案相同且存在合法路径）。 */
export function canConnect(state: OnetState, a: number, b: number): boolean {
  return connectionPath(state, a, b) !== null;
}

/** 两张牌之间的连接折线；不可连返回 null。 */
export function connectionPath(state: OnetState, a: number, b: number): Point[] | null {
  if (a === b) return null;
  const first = state.tiles[a];
  const second = state.tiles[b];
  if (first === null || first === undefined || second === null || second === undefined) return null;
  if (first !== second) return null;
  return findPath(state.tiles, state.rows, state.cols, pointOf(state.cols, a), pointOf(state.cols, b));
}

/** 找出当前棋盘上任意一对可消的牌；没有则返回 null（死局）。 */
export function findAvailableMove(state: OnetState): [number, number] | null {
  const buckets = new Map<number, number[]>();
  state.tiles.forEach((symbol, index) => {
    if (symbol === null) return;
    const bucket = buckets.get(symbol);
    if (bucket) bucket.push(index);
    else buckets.set(symbol, [index]);
  });
  for (const indices of buckets.values()) {
    for (let i = 0; i < indices.length; i += 1) {
      for (let j = i + 1; j < indices.length; j += 1) {
        const a = indices[i] as number;
        const b = indices[j] as number;
        if (connectionPath(state, a, b)) return [a, b];
      }
    }
  }
  return null;
}

/** 用指定种子重新发牌（保留剩余牌的图案多重集合）。 */
function redeal(state: OnetState, symbols: readonly number[], seed: string): (number | null)[] {
  const slots: number[] = [];
  state.tiles.forEach((symbol, index) => {
    if (symbol !== null) slots.push(index);
  });
  const shuffled = shuffle(createRng(seed), symbols);
  const tiles: (number | null)[] = state.tiles.map(() => null);
  slots.forEach((slot, i) => {
    tiles[slot] = shuffled[i] as number;
  });
  return tiles;
}

/**
 * 新局：按难度发牌，并保证开局至少有一对可消
 * （极小概率的死局牌面直接换下一个子种子重发，最多尝试 8 次）。
 */
export function createInitialState(level: number, seed?: string, round = 0): OnetState {
  const config = levelAt(level);
  const normalizedSeed = seed ?? 'onet';
  let tiles = buildTiles(config.rows, config.cols, config.symbols, createRng(dealSeed(normalizedSeed, round)));
  let state: OnetState = {
    seed: normalizedSeed,
    round,
    level,
    rows: config.rows,
    cols: config.cols,
    tiles,
    selected: null,
    lastPath: null,
    hintPair: null,
    remaining: config.rows * config.cols,
    moves: 0,
    hints: 0,
    shuffles: 0,
    status: 'idle',
  };
  for (let attempt = 1; attempt <= 8 && findAvailableMove(state) === null; attempt += 1) {
    tiles = buildTiles(
      config.rows,
      config.cols,
      config.symbols,
      createRng(dealSeed(normalizedSeed, round, attempt)),
    );
    state = { ...state, tiles };
  }
  return state;
}

/** 重开：局数 +1，换一副新牌面（同一基准种子下第 N 局仍可复现）。 */
export function restart(state: OnetState): OnetState {
  return createInitialState(state.level, state.seed, state.round + 1);
}

/**
 * 洗牌：把剩余的牌重新打散（死局自救）。洗完仍是死局就继续换子种子，
 * 最多 8 次；棋面只剩一对且互不可连的极端情况保持原样，交给玩家重开。
 */
export function shuffleBoard(state: OnetState): OnetState {
  const symbols = state.tiles.filter((tile): tile is number => tile !== null);
  if (symbols.length === 0) return state;
  const shuffles = state.shuffles + 1;
  let next: OnetState = {
    ...state,
    tiles: redeal(state, symbols, dealSeed(state.seed, state.round, shuffles)),
    selected: null,
    lastPath: null,
    hintPair: null,
    shuffles,
  };
  for (let attempt = 1; attempt <= 8 && findAvailableMove(next) === null; attempt += 1) {
    next = {
      ...next,
      tiles: redeal(state, symbols, dealSeed(state.seed, state.round, shuffles * 100 + attempt)),
    };
  }
  return next;
}

/** 死局自救：无可消对时自动洗牌；有可消对时原样返回。 */
export function ensurePlayable(state: OnetState): OnetState {
  if (state.status === 'won' || state.remaining === 0) return state;
  if (findAvailableMove(state) !== null) return state;
  return shuffleBoard(state);
}

/**
 * 点选一张牌：
 *  - 未选中任何牌 → 选中它
 *  - 再次点同一张 → 取消选中
 *  - 点另一张牌 → 记一次尝试；可连则双双消除并记录折线，否则改选新点的这张
 */
export function selectTile(state: OnetState, index: number): OnetState {
  if (state.status === 'won') return state;
  const tile = state.tiles[index];
  if (tile === null || tile === undefined) return state;
  if (state.selected === null) {
    return { ...state, selected: index, hintPair: null, status: 'playing' };
  }
  if (state.selected === index) {
    return { ...state, selected: null };
  }

  const path = connectionPath(state, state.selected, index);
  const moves = state.moves + 1;
  if (!path) {
    return { ...state, selected: index, moves, hintPair: null, status: 'playing' };
  }

  const tiles = state.tiles.slice();
  tiles[state.selected] = null;
  tiles[index] = null;
  const remaining = state.remaining - 2;
  return {
    ...state,
    tiles,
    selected: null,
    hintPair: null,
    lastPath: path,
    remaining,
    moves,
    status: remaining === 0 ? 'won' : 'playing',
  };
}

/** 连接线展示结束后清除折线（组件在 PATH_MS 后调用）。 */
export function clearPath(state: OnetState): OnetState {
  if (!state.lastPath) return state;
  return { ...state, lastPath: null };
}

/** 提示：高亮一对可消的牌并计入扣分；死局时先洗牌再提示。 */
export function hint(state: OnetState): OnetState {
  if (state.status === 'won') return state;
  const playable = ensurePlayable(state);
  const pair = findAvailableMove(playable);
  if (!pair) return playable;
  return { ...playable, hintPair: pair, hints: playable.hints + 1, status: 'playing' };
}

/** 清除提示高亮。 */
export function clearHint(state: OnetState): OnetState {
  if (!state.hintPair) return state;
  return { ...state, hintPair: null };
}

/** 成绩：消对得分，失败尝试、提示、洗牌扣分（更高分更好）。 */
export function scoreFor(state: OnetState): number {
  const total = state.rows * state.cols;
  const matchedPairs = (total - state.remaining) / 2;
  const misses = Math.max(0, state.moves - matchedPairs);
  return Math.max(
    0,
    matchedPairs * SCORE_PER_PAIR -
      misses * SCORE_PER_MISS -
      state.hints * SCORE_PER_HINT -
      state.shuffles * SCORE_PER_SHUFFLE,
  );
}
