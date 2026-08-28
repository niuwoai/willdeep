import { describe, expect, it } from 'vitest';
import {
  createInitialState,
  gridForStage,
  isSolved,
  restart,
  scoreFor,
  selectPosition,
  swapPositions,
} from './logic';

describe('图片拼图逻辑', () => {
  it('关卡从 3×3 递增到 6×6 后封顶', () => {
    expect([1, 2, 3, 4, 20].map(gridForStage)).toEqual([3, 4, 5, 6, 6]);
  });

  it('同一种子可复现，开局不会已经完成', () => {
    const first = createInitialState(3, 'same');
    expect(createInitialState(3, 'same')).toEqual(first);
    expect(first.order).toHaveLength(9);
    expect(isSolved(first.order)).toBe(false);
    expect(new Set(first.order).size).toBe(9);
  });

  it('重开轮次递增并换一套布局', () => {
    const first = createInitialState(4, 'restart');
    const second = restart(first);
    expect(second.round).toBe(1);
    expect(second.order).not.toEqual(first.order);
    expect(second).toEqual(createInitialState(4, 'restart', 1));
  });

  it('两次点选交换位置并累计一步', () => {
    const initial = createInitialState(3, 'select');
    const selected = selectPosition(initial, 0);
    const swapped = selectPosition(selected, 1);
    expect(selected.selected).toBe(0);
    expect(swapped.order[0]).toBe(initial.order[1]);
    expect(swapped.order[1]).toBe(initial.order[0]);
    expect(swapped.moves).toBe(1);
    expect(swapped.selected).toBeNull();
  });

  it('最后一次交换回正确位置后判定通关', () => {
    const base = createInitialState(3, 'win');
    const almost = { ...base, order: [1, 0, 2, 3, 4, 5, 6, 7, 8], status: 'playing' as const };
    const won = swapPositions(almost, 0, 1);
    expect(won.status).toBe('won');
    expect(isSolved(won.order)).toBe(true);
  });

  it('交换越少得分越高且保留最低通关分', () => {
    expect(scoreFor(3, 8)).toBeGreaterThan(scoreFor(3, 20));
    expect(scoreFor(3, 9999)).toBe(100);
  });
});
