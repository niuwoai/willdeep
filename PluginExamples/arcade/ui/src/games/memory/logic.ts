/**
 * 记忆翻牌纯逻辑（并行节点交付，不依赖 React）。
 *
 * 契约约束：
 *  - 一切随机只经 createRng / shuffle（src/core/rng.ts），同一种子完全可复现
 *  - 不触碰共享契约文件（src/core/*、src/games/manifest.ts、i18n 字典）
 *  - 步数（moves）= 翻开第二张牌的次数（每次“尝试”计 1）；全部配对后胜利
 *  - 最佳成绩 = 效率分 scoreFor(pairs, moves)：更高分更好，
 *    与冻结契约 saveBestScore 的“只保留更高分”语义一致
 */
import { createRng, shuffle } from '../../core/rng';

/** 单张卡：pairId 相同的两张卡互为配对；位置即数组下标。 */
export interface MemoryCard {
  pairId: number;
}

export type MemoryStatus = 'idle' | 'playing' | 'won';

export interface MemoryState {
  seed: string;
  /** 牌对数（牌面数 = pairs * 2）。 */
  pairs: number;
  /** 洗牌后的牌组（确定性，取决于 pairs 与 seed）。 */
  cards: readonly MemoryCard[];
  /** 当前翻开（待处理）的牌下标，最多 2 个。 */
  flipped: readonly number[];
  /** 已配对的 pairId 集合。 */
  matched: readonly number[];
  /** 尝试次数（翻开第二张牌计 1）。 */
  moves: number;
  /** 锁定：不匹配的两张牌停留展示期间禁止翻牌。 */
  locked: boolean;
  status: MemoryStatus;
}

export const DEFAULT_PAIRS = 6;
export const MIN_PAIRS = 2;
export const MAX_PAIRS = 6;
/** 可选牌对数（难度档位）。 */
export const PAIR_OPTIONS: readonly number[] = [2, 4, 6];
/** 不匹配展示停留时长（毫秒），由组件在锁定期间调度翻转复位。 */
export const MISMATCH_MS = 600;
/** 效率分系数：每对 100 分，每多一次尝试扣 10 分。 */
const SCORE_PER_PAIR = 100;
const SCORE_PER_MOVE = 10;

/** 构造确定性的成对牌组并洗牌：每个 pairId 恰好出现两次。 */
export function buildDeck(pairs: number, seed: string): MemoryCard[] {
  const deck: MemoryCard[] = [];
  for (let pairId = 0; pairId < pairs; pairId += 1) {
    deck.push({ pairId }, { pairId });
  }
  return shuffle(createRng(seed), deck);
}

/** 新局初始状态：全部牌面朝下、零步数、idle。 */
export function createInitialState(pairs: number, seed?: string): MemoryState {
  const normalizedSeed = seed ?? 'memory';
  return {
    seed: normalizedSeed,
    pairs,
    cards: buildDeck(pairs, normalizedSeed),
    flipped: [],
    matched: [],
    moves: 0,
    locked: false,
    status: 'idle',
  };
}

/** 重开复位：同牌对数、同种子重建一局（确定性布局不变，进度清零）。 */
export function restart(state: MemoryState): MemoryState {
  return createInitialState(state.pairs, state.seed);
}

/** 翻开下标为 index 的牌。返回新状态；非法/已处理的操作返回原状态。 */
export function flipCard(state: MemoryState, index: number): MemoryState {
  if (state.status === 'won' || state.locked) return state;
  const card = state.cards[index];
  if (!card || state.flipped.includes(index) || state.matched.includes(card.pairId)) {
    return state;
  }
  if (state.flipped.length === 0) {
    return { ...state, flipped: [index], status: 'playing' };
  }
  const firstIndex = state.flipped[0] as number;
  const first = state.cards[firstIndex] as MemoryCard;
  const moves = state.moves + 1;
  if (first.pairId === card.pairId) {
    const matched = [...state.matched, card.pairId];
    const won = matched.length >= state.pairs;
    return { ...state, flipped: [], matched, moves, status: won ? 'won' : 'playing' };
  }
  return { ...state, flipped: [firstIndex, index], moves, locked: true };
}

/** 解锁并复位不匹配的两张牌（组件在不匹配展示停留后调用）。 */
export function resolveMismatch(state: MemoryState): MemoryState {
  if (!state.locked) return state;
  return { ...state, flipped: [], locked: false };
}

/** 效率分：步数越少分越高（更高分更好，适配“只保留更高分”的成绩契约）。 */
export function scoreFor(pairs: number, moves: number): number {
  return Math.max(0, pairs * SCORE_PER_PAIR - moves * SCORE_PER_MOVE);
}
