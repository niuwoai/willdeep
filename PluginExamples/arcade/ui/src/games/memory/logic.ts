/**
 * 记忆翻牌纯逻辑（并行节点交付，不依赖 React）。
 *
 * 契约约束：
 *  - 一切随机只经 createRng / shuffle（src/core/rng.ts），同一种子完全可复现
 *  - 每次重开换一副牌：牌组种子 = `<基准种子>#<局数>`，所以「同一基准种子下的
 *    第 N 局」依旧完全确定可复现，但玩家连按重开不会再拿到同一张布局表
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
  /** 基准种子：来自 `?seed=`，缺省时由组件生成一次性熵种子。 */
  seed: string;
  /** 局数，从 0 开始；每次重开 +1，参与牌组种子推导。 */
  round: number;
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

export const DEFAULT_PAIRS = 2;
export const MIN_PAIRS = 2;
/** 牌对数上限：再多就塞不进面板了，封顶后关卡号继续涨。 */
export const MAX_PAIRS = 12;

/** 第 stage 关的牌对数：2 对起步，每关 +1，到 12 对封顶。 */
export function pairsForStage(stage: number): number {
  return Math.min(MAX_PAIRS, MIN_PAIRS + Math.max(0, stage - 1));
}

/** 棋盘列数：让牌面尽量接近方阵，最多 6 列。 */
export function columnsForPairs(pairs: number): number {
  const cards = pairs * 2;
  return Math.max(2, Math.min(6, Math.ceil(Math.sqrt(cards))));
}
/** 不匹配展示停留时长（毫秒），由组件在锁定期间调度翻转复位。 */
export const MISMATCH_MS = 600;
/** 效率分系数：每对 100 分，每多一次尝试扣 10 分。 */
const SCORE_PER_PAIR = 100;
const SCORE_PER_MOVE = 10;

/** 牌组种子：基准种子 + 局数，保证「重开换布局」与「可复现」同时成立。 */
export function deckSeed(seed: string, round: number): string {
  return `${seed}#${round}`;
}

/** 构造确定性的成对牌组并洗牌：每个 pairId 恰好出现两次。 */
export function buildDeck(pairs: number, seed: string): MemoryCard[] {
  const deck: MemoryCard[] = [];
  for (let pairId = 0; pairId < pairs; pairId += 1) {
    deck.push({ pairId }, { pairId });
  }
  return shuffle(createRng(seed), deck);
}

/** 新局初始状态：全部牌面朝下、零步数、idle。 */
export function createInitialState(pairs: number, seed?: string, round = 0): MemoryState {
  const normalizedSeed = seed ?? 'memory';
  return {
    seed: normalizedSeed,
    round,
    pairs,
    cards: buildDeck(pairs, deckSeed(normalizedSeed, round)),
    flipped: [],
    matched: [],
    moves: 0,
    locked: false,
    status: 'idle',
  };
}

/**
 * 重开：局数 +1 重建一局——牌对数与基准种子不变，但换一副新洗的牌。
 * 玩家反复重开不会再撞上同一张布局；同一基准种子下第 N 局仍完全可复现。
 */
export function restart(state: MemoryState): MemoryState {
  return createInitialState(state.pairs, state.seed, state.round + 1);
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
