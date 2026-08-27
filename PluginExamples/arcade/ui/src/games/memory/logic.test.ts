/**
 * 记忆翻牌纯逻辑回归（并行节点交付）。
 *
 * 覆盖契约要求：确定性洗牌 / 匹配 / 不配对 / 锁定 / 胜利 /
 * 最佳成绩（效率分 + 只保留更高分）/ 重开换牌（局数推导、可复现、不重复）。
 */
import { describe, expect, it } from 'vitest';
import { saveBestScore } from '../../core/bestScore';
import { readBestScore } from '../../core/safeLocalStorage';
import {
  buildDeck,
  createInitialState,
  deckSeed,
  flipCard,
  restart,
  resolveMismatch,
  scoreFor,
} from './logic';

/** 从牌组中找出某个 pairId 的两张牌下标（恰有两个）。 */
function pairIndices(state: ReturnType<typeof createInitialState>, pairId: number): [number, number] {
  const indices: number[] = [];
  state.cards.forEach((card, index) => {
    if (card.pairId === pairId) indices.push(index);
  });
  return [indices[0] as number, indices[1] as number];
}

describe('记忆翻牌逻辑：确定性洗牌', () => {
  it('同一种子生成完全一致的牌组', () => {
    expect(buildDeck(4, 'seed-a')).toEqual(buildDeck(4, 'seed-a'));
  });

  it('不同种子生成不同布局', () => {
    expect(buildDeck(4, 'seed-a')).not.toEqual(buildDeck(4, 'seed-b'));
  });

  it('牌组长度为 2×牌对数，且每个 pairId 恰好出现两次', () => {
    for (const pairs of [2, 4, 6]) {
      const deck = buildDeck(pairs, 'layout-check');
      expect(deck).toHaveLength(pairs * 2);
      for (let pairId = 0; pairId < pairs; pairId += 1) {
        expect(deck.filter((card) => card.pairId === pairId)).toHaveLength(2);
      }
    }
  });

  it('新局初始状态：idle、零步数、无翻开无配对、未锁定', () => {
    const state = createInitialState(4, 'init');
    expect(state.status).toBe('idle');
    expect(state.moves).toBe(0);
    expect(state.flipped).toEqual([]);
    expect(state.matched).toEqual([]);
    expect(state.locked).toBe(false);
    expect(state.cards).toHaveLength(8);
  });
});

describe('记忆翻牌逻辑：匹配', () => {
  it('翻开同一对的两张牌后配对成功、步数 +1', () => {
    const state = createInitialState(4, 'match');
    const [a, b] = pairIndices(state, 0);
    const afterFirst = flipCard(state, a);
    expect(afterFirst.flipped).toEqual([a]);

    const afterSecond = flipCard(afterFirst, b);
    expect(afterSecond.matched).toContain(0);
    expect(afterSecond.flipped).toEqual([]);
    expect(afterSecond.moves).toBe(1);
    expect(afterSecond.status).toBe('playing');
  });

  it('重复翻开同一张牌是空操作', () => {
    const state = createInitialState(4, 'repeat');
    const afterFirst = flipCard(state, 2);
    expect(flipCard(afterFirst, 2)).toEqual(afterFirst);
  });

  it('越界下标是空操作', () => {
    const state = createInitialState(4, 'out-of-range');
    expect(flipCard(state, -1)).toEqual(state);
    expect(flipCard(state, 8)).toEqual(state);
  });

  it('翻开已配对的牌是空操作', () => {
    const state = createInitialState(4, 'matched-guard');
    const [a, b] = pairIndices(state, 0);
    const matched = flipCard(flipCard(state, a), b);
    expect(matched.status).toBe('playing');
    expect(flipCard(matched, a)).toEqual(matched);
  });
});

describe('记忆翻牌逻辑：不配对与锁定', () => {
  it('两张不同对的牌翻开后锁定、步数 +1、不配对', () => {
    const state = createInitialState(4, 'mismatch');
    const [a0] = pairIndices(state, 0);
    const [b1] = pairIndices(state, 1);
    const after = flipCard(flipCard(state, a0), b1);
    expect(after.locked).toBe(true);
    expect(after.flipped).toEqual([a0, b1]);
    expect(after.moves).toBe(1);
    expect(after.matched).toEqual([]);
  });

  it('锁定期间翻牌全部为空操作', () => {
    const state = createInitialState(4, 'lock');
    const [a0] = pairIndices(state, 0);
    const [b1] = pairIndices(state, 1);
    const locked = flipCard(flipCard(state, a0), b1);
    const [, c2] = pairIndices(state, 2);
    expect(flipCard(locked, c2)).toEqual(locked);
    expect(flipCard(locked, a0)).toEqual(locked);
  });

  it('resolveMismatch 复位两张牌并解锁', () => {
    const state = createInitialState(4, 'resolve');
    const [a0] = pairIndices(state, 0);
    const [b1] = pairIndices(state, 1);
    const locked = flipCard(flipCard(state, a0), b1);
    const resolved = resolveMismatch(locked);
    expect(resolved.flipped).toEqual([]);
    expect(resolved.locked).toBe(false);
    expect(resolved.moves).toBe(1);
    expect(resolved.matched).toEqual([]);
  });

  it('未锁定状态下 resolveMismatch 返回原状态', () => {
    const state = createInitialState(4, 'noop-resolve');
    expect(resolveMismatch(state)).toEqual(state);
  });
});

describe('记忆翻牌逻辑：胜利', () => {
  it('2 对牌全部配对后进入 won，步数正确', () => {
    const state = createInitialState(2, 'win-2pairs');
    const [a0, b0] = pairIndices(state, 0);
    const [a1, b1] = pairIndices(state, 1);
    const step1 = flipCard(flipCard(state, a0), b0);
    expect(step1.status).toBe('playing');
    const step2 = flipCard(flipCard(step1, a1), b1);
    expect(step2.status).toBe('won');
    expect(step2.moves).toBe(2);
    expect(step2.matched).toHaveLength(2);
  });

  it('胜利后翻牌是空操作', () => {
    const state = createInitialState(2, 'won-guard');
    const [a0, b0] = pairIndices(state, 0);
    const [a1, b1] = pairIndices(state, 1);
    const won = flipCard(flipCard(flipCard(flipCard(state, a0), b0), a1), b1);
    expect(won.status).toBe('won');
    expect(flipCard(won, a0)).toEqual(won);
  });

  it('不匹配后步数累加，随后仍可胜利', () => {
    const state = createInitialState(2, 'win-with-mistake');
    const [a0, b0] = pairIndices(state, 0);
    const [a1, b1] = pairIndices(state, 1);
    const mis = resolveMismatch(flipCard(flipCard(state, a0), a1));
    expect(mis.moves).toBe(1);
    const step1 = flipCard(flipCard(mis, b0), a0);
    expect(step1.moves).toBe(2);
    const won = flipCard(flipCard(step1, a1), b1);
    expect(won.status).toBe('won');
    expect(won.moves).toBe(3);
  });
});

describe('记忆翻牌逻辑：最佳成绩', () => {
  it('效率分与步数负相关：步数越少分越高', () => {
    expect(scoreFor(2, 2)).toBeGreaterThan(scoreFor(2, 3));
    expect(scoreFor(2, 2)).toBe(180);
    expect(scoreFor(6, 12)).toBe(480);
  });

  it('saveBestScore 只保留更高分（best:memory 持久化语义）', () => {
    saveBestScore('memory', 180);
    expect(readBestScore('memory')?.value).toBe(180);
    saveBestScore('memory', 170);
    expect(readBestScore('memory')?.value).toBe(180);
    saveBestScore('memory', 190);
    expect(readBestScore('memory')?.value).toBe(190);
  });
});

describe('记忆翻牌逻辑：重开换牌', () => {
  it('restart 清空进度、局数 +1，并换一副新洗的牌', () => {
    const state = createInitialState(6, 'restart');
    const [a0] = pairIndices(state, 0);
    const [b1] = pairIndices(state, 1);
    const progressed = resolveMismatch(flipCard(flipCard(state, a0), b1));
    expect(progressed.moves).toBe(1);

    const reset = restart(progressed);
    expect(reset.moves).toBe(0);
    expect(reset.flipped).toEqual([]);
    expect(reset.matched).toEqual([]);
    expect(reset.locked).toBe(false);
    expect(reset.status).toBe('idle');
    expect(reset.round).toBe(state.round + 1);
    // 核心诉求：玩家连按重开不该再拿到背下来的那副牌
    expect(reset.cards).not.toEqual(state.cards);
  });

  it('重开后的布局仍完全可复现：等价于同种子的第 N 局', () => {
    const state = createInitialState(4, 'reproducible');
    const second = restart(state);
    expect(second).toEqual(createInitialState(4, 'reproducible', 1));
    expect(restart(second)).toEqual(createInitialState(4, 'reproducible', 2));
    expect(deckSeed('reproducible', 2)).toBe('reproducible#2');
  });

  it('连开 8 局，6 对布局互不重复', () => {
    const layouts = new Set<string>();
    let state = createInitialState(6, 'no-repeat');
    for (let round = 0; round < 8; round += 1) {
      layouts.add(state.cards.map((card) => card.pairId).join(','));
      state = restart(state);
    }
    expect(layouts.size).toBe(8);
  });

  it('未指定种子时也走同一套局数推导（默认基准种子）', () => {
    const state = createInitialState(2);
    expect(state.round).toBe(0);
    expect(restart(state).round).toBe(1);
    expect(restart(state).cards).toEqual(createInitialState(2, 'memory', 1).cards);
  });
});
