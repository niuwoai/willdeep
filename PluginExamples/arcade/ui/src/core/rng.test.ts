import { describe, expect, it } from 'vitest';
import { createRng, hashSeed, pick, range, shuffle } from './rng';

describe('createRng（确定性种子契约）', () => {
  it('相同种子产生完全相同的序列', () => {
    const a = createRng('seed-42');
    const b = createRng('seed-42');
    const seqA = Array.from({ length: 20 }, () => a());
    const seqB = Array.from({ length: 20 }, () => b());
    expect(seqA).toEqual(seqB);
  });

  it('不同种子产生不同序列', () => {
    const a = createRng('seed-1');
    const b = createRng('seed-2');
    expect(Array.from({ length: 8 }, () => a())).not.toEqual(
      Array.from({ length: 8 }, () => b()),
    );
  });

  it('数字种子与字符串散列种子均确定性', () => {
    const a = createRng(42);
    const b = createRng(42);
    expect(a()).toBe(b());
  });

  it('输出落在 [0, 1) 区间', () => {
    const rng = createRng('any');
    for (let i = 0; i < 100; i += 1) {
      const v = rng();
      expect(v).toBeGreaterThanOrEqual(0);
      expect(v).toBeLessThan(1);
    }
  });

  it('hashSeed 稳定且对输入敏感', () => {
    expect(hashSeed('abc')).toBe(hashSeed('abc'));
    expect(hashSeed('abc')).not.toBe(hashSeed('abd'));
  });
});

describe('shuffle / pick / range', () => {
  it('shuffle 保持元素集合不变（确定性种子下可复现）', () => {
    const input = range(12);
    const a = shuffle(createRng('shuffle'), input);
    const b = shuffle(createRng('shuffle'), input);
    expect(a).toEqual(b);
    expect([...a].sort((x, y) => x - y)).toEqual(input);
    expect(input).toEqual(range(12));
  });

  it('pick 返回输入内的元素', () => {
    const rng = createRng('pick');
    for (let i = 0; i < 50; i += 1) {
      expect(range(4)).toContain(pick(rng, range(4)));
    }
  });

  it('range 生成半开区间序列', () => {
    expect(range(3)).toEqual([0, 1, 2]);
    expect(range(3, 5)).toEqual([5, 6, 7]);
  });
});
