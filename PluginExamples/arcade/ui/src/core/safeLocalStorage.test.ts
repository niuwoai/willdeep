import { describe, expect, it } from 'vitest';
import {
  STORAGE_PREFIX,
  bestScoreKey,
  isNewBestScore,
  readBestScore,
  safeLocalStorage,
  writeBestScore,
} from './safeLocalStorage';

describe('safeLocalStorage（契约）', () => {
  it('setItem/getItem 往返一致', () => {
    safeLocalStorage.setItem('k1', 'v1');
    expect(safeLocalStorage.getItem('k1')).toBe('v1');
  });

  it('不存在的 key 返回 null', () => {
    expect(safeLocalStorage.getItem('nope')).toBeNull();
  });

  it('JSON 对象读写与损坏数据回退', () => {
    safeLocalStorage.setJson('obj', { a: 1 });
    expect(safeLocalStorage.getJson<{ a: number }>('obj')).toEqual({ a: 1 });

    window.localStorage.setItem('bad', '{oops');
    expect(safeLocalStorage.getJson('bad')).toBeNull();
  });

  it('removeItem 后读取为 null', () => {
    safeLocalStorage.setItem('tmp', 'x');
    safeLocalStorage.removeItem('tmp');
    expect(safeLocalStorage.getItem('tmp')).toBeNull();
  });

  it('存储不可用时静默降级为 null / no-op（不抛异常）', () => {
    const original = window.localStorage;
    Object.defineProperty(window, 'localStorage', {
      get: () => {
        throw new Error('denied');
      },
      configurable: true,
    });
    expect(safeLocalStorage.getItem('x')).toBeNull();
    expect(() => safeLocalStorage.setItem('x', '1')).not.toThrow();
    Object.defineProperty(window, 'localStorage', {
      get: () => original,
      configurable: true,
    });
  });
});

describe('最佳成绩 key 与比较', () => {
  it('成绩 key 使用命名空间前缀 + gameId', () => {
    expect(bestScoreKey('snake')).toBe(`${STORAGE_PREFIX}.best.snake`);
  });

  it('isNewBestScore 只在更高分时通过', () => {
    writeBestScore('snake', { value: 100, achievedAt: 1 });
    expect(isNewBestScore('snake', 100)).toBe(false);
    expect(isNewBestScore('snake', 101)).toBe(true);
    expect(isNewBestScore('snake', 99)).toBe(false);
  });

  it('readBestScore 读取写入的纪录', () => {
    writeBestScore('memory', { value: 5, achievedAt: 123 });
    expect(readBestScore('memory')).toEqual({ value: 5, achievedAt: 123 });
  });
});
