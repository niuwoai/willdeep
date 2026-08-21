/**
 * 贪吃蛇纯逻辑（并行节点交付，不依赖 React）。
 *
 * 契约约束：
 *  - 一切随机只经 createRng（src/core/rng.ts），保证同一种子完全可复现
 *  - 不触碰共享契约文件（src/core/*、src/games/manifest.ts、i18n 字典）
 *  - 分数 = 吃到的食物数；吃满 MILESTONE_FOOD 个食物触发里程碑胜利
 */
import { createRng } from '../../core/rng';

export interface Point {
  row: number;
  col: number;
}

export type Direction = 'up' | 'down' | 'left' | 'right';

export type GameStatus = 'idle' | 'playing' | 'gameover' | 'won';

export const GRID_ROWS = 20;
export const GRID_COLS = 20;
export const INITIAL_LENGTH = 3;
/** 里程碑：累计吃满该数量的食物即通关（won）。 */
export const MILESTONE_FOOD = 5;
/** 自动行进间隔（毫秒）。 */
export const TICK_MS = 220;
export const DEFAULT_SEED = 'snake';

export interface SnakeState {
  /** 蛇身，索引 0 为头。 */
  snake: Point[];
  direction: Direction;
  food: Point;
  status: GameStatus;
  /** 分数 = 已吃食物数。 */
  score: number;
  foodsEaten: number;
  seed: string;
}

const DIRECTION_DELTA: Record<Direction, Point> = {
  up: { row: -1, col: 0 },
  down: { row: 1, col: 0 },
  left: { row: 0, col: -1 },
  right: { row: 0, col: 1 },
};

const OPPOSITE: Record<Direction, Direction> = {
  up: 'down',
  down: 'up',
  left: 'right',
  right: 'left',
};

export function isOpposite(a: Direction, b: Direction): boolean {
  return OPPOSITE[a] === b;
}

/** 方向是否可切换：不允许原地不变，也不允许 180° 掉头。 */
export function canTurn(current: Direction, next: Direction): boolean {
  return next !== current && !isOpposite(current, next);
}

function pointKey(p: Point): string {
  return `${p.row},${p.col}`;
}

function isInside(p: Point): boolean {
  return p.row >= 0 && p.row < GRID_ROWS && p.col >= 0 && p.col < GRID_COLS;
}

function initialSnake(): Point[] {
  const head: Point = { row: Math.floor(GRID_ROWS / 2), col: 5 };
  return [head, { row: head.row, col: head.col - 1 }, { row: head.row, col: head.col - 2 }];
}

/** 用确定性 rng 在空闲格放置食物（避开蛇身）；step 为已吃食物数（新食物序号）。 */
export function placeFood(snake: readonly Point[], seed: string, step: number): Point {
  const rng = createRng(`${seed}:food:${step}`);
  const occupied = new Set(snake.map(pointKey));
  const free: Point[] = [];
  for (let row = 0; row < GRID_ROWS; row += 1) {
    for (let col = 0; col < GRID_COLS; col += 1) {
      const p = { row, col };
      if (!occupied.has(pointKey(p))) free.push(p);
    }
  }
  const picked = free[Math.floor(rng() * free.length)];
  return picked ?? { row: 0, col: 0 };
}

/** 初始状态：idle，蛇身 3 格，初始方向向右，食物由种子决定。 */
export function initialState(seed?: string): SnakeState {
  const normalized = seed !== undefined && seed.length > 0 ? seed : DEFAULT_SEED;
  const snake = initialSnake();
  return {
    snake,
    direction: 'right',
    food: placeFood(snake, normalized, 0),
    status: 'idle',
    score: 0,
    foodsEaten: 0,
    seed: normalized,
  };
}

/** 重开复位：回到初始状态（保留原种子）。 */
export function resetState(state: Pick<SnakeState, 'seed'>): SnakeState {
  return initialState(state.seed);
}

/**
 * 推进一帧。
 * nextDirection 可选：仅在非 180° 时生效（防止快速连按掉头自杀）。
 * 撞墙/自咬 → gameover；吃满 MILESTONE_FOOD → won；均返回不可变新状态。
 */
export function step(state: SnakeState, nextDirection?: Direction): SnakeState {
  if (state.status === 'gameover' || state.status === 'won') return state;

  const direction =
    nextDirection !== undefined && canTurn(state.direction, nextDirection)
      ? nextDirection
      : state.direction;

  const delta = DIRECTION_DELTA[direction];
  const nextHead: Point = {
    row: state.snake[0]!.row + delta.row,
    col: state.snake[0]!.col + delta.col,
  };

  if (!isInside(nextHead)) {
    return { ...state, direction, status: 'gameover' };
  }

  const eating = pointKey(state.food) === pointKey(nextHead);
  // 不吃食物时尾巴让位，允许头部走入原尾格；吃食物则整体保留（增长）。
  const body = eating ? state.snake : state.snake.slice(0, -1);
  if (body.some((p) => pointKey(p) === pointKey(nextHead))) {
    return { ...state, direction, status: 'gameover' };
  }

  const snake = [nextHead, ...body];
  if (!eating) return { ...state, snake, direction };

  const foodsEaten = state.foodsEaten + 1;
  const won = foodsEaten >= MILESTONE_FOOD;
  return {
    ...state,
    snake,
    direction,
    foodsEaten,
    score: foodsEaten,
    food: won ? state.food : placeFood(snake, state.seed, foodsEaten),
    status: won ? 'won' : 'playing',
  };
}
