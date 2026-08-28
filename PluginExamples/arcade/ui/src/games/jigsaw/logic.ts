/** 拼图纯逻辑：确定性洗牌、选块交换、通关与计分。 */
import { createRng, range, shuffle } from '../../core/rng';

export type JigsawStatus = 'idle' | 'playing' | 'won';

export interface JigsawState {
  seed: string;
  round: number;
  grid: number;
  /** 当前每个棋盘位置放着哪一块；piece id 等于它在完整图片中的正确位置。 */
  order: readonly number[];
  selected: number | null;
  moves: number;
  status: JigsawStatus;
}

export const MIN_GRID = 3;
export const MAX_GRID = 6;

/** 3×3 起步，逐关升到 6×6；封顶后关卡号与累计分继续增长。 */
export function gridForStage(stage: number): number {
  return Math.min(MAX_GRID, MIN_GRID + Math.max(0, stage - 1));
}

export function puzzleSeed(seed: string, round: number): string {
  return `${seed}#${round}`;
}

export function isSolved(order: readonly number[]): boolean {
  return order.every((piece, position) => piece === position);
}

/** 洗牌若意外回到原图，就轮转一格，确保用户不会一开局直接通关。 */
export function shuffledOrder(grid: number, seed: string): number[] {
  const pieces = range(grid * grid);
  const shuffled = shuffle(createRng(seed), pieces);
  if (!isSolved(shuffled)) return shuffled;
  return [...shuffled.slice(1), shuffled[0] as number];
}

export function createInitialState(grid: number, seed?: string, round = 0): JigsawState {
  const normalizedSeed = seed ?? 'jigsaw';
  return {
    seed: normalizedSeed,
    round,
    grid,
    order: shuffledOrder(grid, puzzleSeed(normalizedSeed, round)),
    selected: null,
    moves: 0,
    status: 'idle',
  };
}

export function restart(state: JigsawState): JigsawState {
  return createInitialState(state.grid, state.seed, state.round + 1);
}

/** 交换两个位置；鼠标拖放与两次点按共用这一条规则。 */
export function swapPositions(state: JigsawState, from: number, to: number): JigsawState {
  if (state.status === 'won' || from === to) return { ...state, selected: null };
  if (!state.order[from] && state.order[from] !== 0) return state;
  if (!state.order[to] && state.order[to] !== 0) return state;
  const order = state.order.slice();
  const held = order[from] as number;
  order[from] = order[to] as number;
  order[to] = held;
  return {
    ...state,
    order,
    selected: null,
    moves: state.moves + 1,
    status: isSolved(order) ? 'won' : 'playing',
  };
}

/** 点按操作：第一次选块，第二次与目标位置交换；重复点同一块则取消。 */
export function selectPosition(state: JigsawState, position: number): JigsawState {
  if (state.status === 'won' || position < 0 || position >= state.order.length) return state;
  if (state.selected === null) {
    return { ...state, selected: position, status: 'playing' };
  }
  if (state.selected === position) return { ...state, selected: null };
  return swapPositions(state, state.selected, position);
}

/** 棋盘越大基础分越高，每次交换扣 12 分，至少保留 100 分通关奖励。 */
export function scoreFor(grid: number, moves: number): number {
  return Math.max(100, grid * grid * 120 - moves * 12);
}
