import { describe, expect, it } from 'vitest';
import { createRng } from '../../core/rng';
import {
  CELL_COUNT,
  canMove,
  createInitialState,
  moveBoard,
  moveState,
  slideLine,
  targetForStage,
} from './logic';

describe('2048 合并规则', () => {
  it('一行中的每块每次只合并一次', () => {
    expect(slideLine([2, 2, 2, 2])).toEqual({ line: [4, 4, 0, 0], scoreDelta: 8 });
    expect(slideLine([4, 4, 8, 0])).toEqual({ line: [8, 8, 0, 0], scoreDelta: 8 });
    expect(slideLine([2, 2, 4, 4])).toEqual({ line: [4, 8, 0, 0], scoreDelta: 12 });
  });

  it('四个方向都按对应的行列移动', () => {
    const board = [2, 0, 2, 0, 0, 0, 0, 0, 2, 0, 0, 0, 2, 0, 0, 0];
    expect(moveBoard(board, 'left').board.slice(0, 4)).toEqual([4, 0, 0, 0]);
    expect(moveBoard(board, 'right').board.slice(0, 4)).toEqual([0, 0, 0, 4]);
    expect(moveBoard(board, 'up').board.slice(0, 4)).toEqual([4, 0, 2, 0]);
    expect(moveBoard(board, 'down').board.slice(12, 16)).toEqual([4, 0, 2, 0]);
  });
});

describe('2048 局面状态', () => {
  it('同一种子生成相同的两块开局', () => {
    const first = createInitialState(createRng('same'));
    const second = createInitialState(createRng('same'));
    expect(first.board).toEqual(second.board);
    expect(first.board).toHaveLength(CELL_COUNT);
    expect(first.board.filter(Boolean)).toHaveLength(2);
  });

  it('有效移动后只补一块，无效移动不补块', () => {
    const state = {
      board: [2, 0, 0, 0, ...Array(12).fill(0)],
      score: 0,
      moves: 0,
      target: 2048,
      status: 'idle' as const,
    };
    expect(moveState(state, 'left', createRng('no-op'))).toBe(state);
    const moved = moveState(state, 'right', createRng('move'));
    expect(moved.moves).toBe(1);
    expect(moved.board.filter(Boolean)).toHaveLength(2);
  });

  it('满盘且没有相邻同值时判负', () => {
    const board = [2, 4, 2, 4, 4, 2, 4, 2, 2, 4, 2, 4, 4, 2, 4, 2];
    expect(canMove(board)).toBe(false);
    const lost = moveState({ board, score: 0, moves: 8, target: 2048, status: 'playing' }, 'left', createRng('lost'));
    expect(lost.status).toBe('lost');
  });

  it('关卡目标从 2048 起逐关翻倍', () => {
    expect(targetForStage(1)).toBe(2048);
    expect(targetForStage(2)).toBe(4096);
    expect(targetForStage(4)).toBe(16384);
  });
});
