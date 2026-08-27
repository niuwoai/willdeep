/**
 * 确定性随机契约（冻结）。
 *
 * 游戏内一切随机行为（扫雷布雷、记忆洗牌、AI 决策等）必须经由
 * createRng / shuffle / pick 获取，禁止直接使用 Math.random，
 * 以保证同一种子下的可复现性（回归测试依赖此契约）。见 docs/contracts.md。
 */

/** 无状态随机函数：每次调用返回 [0, 1) 的确定性伪随机数。 */
export type Rng = () => number;

/** 将字符串种子散列为 32 位无符号整数（FNV-1a）。 */
export function hashSeed(seed: string): number {
  let h = 0x811c9dc5;
  for (let i = 0; i < seed.length; i += 1) {
    h ^= seed.charCodeAt(i);
    h = Math.imul(h, 0x01000193);
  }
  return h >>> 0;
}

/**
 * 基于 mulberry32 的确定性 PRNG。
 * 相同 seed（字符串或数字）必然产生相同序列；seed 缺失时使用 'default'。
 */
export function createRng(seed: string | number): Rng {
  let state = (typeof seed === 'number' ? seed : hashSeed(seed)) >>> 0;
  if (state === 0) state = 0x9e3779b9;
  return function mulberry32(): number {
    state = (state + 0x6d2b79f5) | 0;
    let t = state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/** 使用给定 rng 做 Fisher-Yates 洗牌，返回新数组，不改动输入。 */
export function shuffle<T>(rng: Rng, input: readonly T[]): T[] {
  const arr = input.slice();
  for (let i = arr.length - 1; i > 0; i -= 1) {
    const j = Math.floor(rng() * (i + 1));
    const tmp = arr[i] as T;
    arr[i] = arr[j] as T;
    arr[j] = tmp;
  }
  return arr;
}

/** 生成 [start, start+length) 的整数序列。 */
export function range(length: number, start = 0): number[] {
  return Array.from({ length }, (_, i) => start + i);
}

/** 从数组中按 rng 取一个元素。 */
export function pick<T>(rng: Rng, input: readonly T[]): T {
  return input[Math.floor(rng() * input.length)] as T;
}

/**
 * 一次性熵种子：仅用于「调用方未指定 seed 时，每局布局都要不一样」的场景
 * （如记忆翻牌重开、连连看洗牌的基准种子）。
 *
 * 注意：玩法内部的一切随机仍必须经 createRng / shuffle / pick——本函数只
 * 负责产出种子字符串本身，产出后的序列依旧完全确定、可复现。
 */
export function entropySeed(prefix = 'seed'): string {
  const cryptoRef = typeof globalThis !== 'undefined' ? globalThis.crypto : undefined;
  if (cryptoRef && typeof cryptoRef.getRandomValues === 'function') {
    const buffer = new Uint32Array(2);
    cryptoRef.getRandomValues(buffer);
    return `${prefix}-${(buffer[0] as number).toString(36)}${(buffer[1] as number).toString(36)}`;
  }
  return `${prefix}-${Date.now().toString(36)}${Math.floor(Math.random() * 0xffffff).toString(36)}`;
}
