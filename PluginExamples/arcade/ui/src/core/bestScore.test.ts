import { act, renderHook } from '@testing-library/react';
import { describe, expect, it } from 'vitest';
import { resetBestScore, saveBestScore, useBestScore } from './bestScore';

describe('bestScore（最佳成绩契约）', () => {
  it('saveBestScore 只保留更高分并广播', () => {
    const { result } = renderHook(() => useBestScore('snake'));
    expect(result.current).toBeNull();

    act(() => saveBestScore('snake', 50));
    expect(result.current?.value).toBe(50);

    act(() => saveBestScore('snake', 30));
    expect(result.current?.value).toBe(50);

    act(() => saveBestScore('snake', 80));
    expect(result.current?.value).toBe(80);
  });

  it('不同游戏成绩相互隔离', () => {
    const snake = renderHook(() => useBestScore('snake'));
    const memory = renderHook(() => useBestScore('memory'));

    act(() => saveBestScore('snake', 10));
    expect(snake.result.current?.value).toBe(10);
    expect(memory.result.current).toBeNull();
  });

  it('resetBestScore 清空纪录', () => {
    const { result } = renderHook(() => useBestScore('pong'));
    act(() => saveBestScore('pong', 7));
    expect(result.current?.value).toBe(7);
    act(() => resetBestScore('pong'));
    expect(result.current).toBeNull();
  });

  it('纪录写入 localStorage（arcade.best.<id>）', () => {
    act(() => saveBestScore('tetris', 120));
    const stored = JSON.parse(
      window.localStorage.getItem('arcade.best.tetris') as string,
    ) as { value: number };
    expect(stored.value).toBe(120);
  });
});
