/**
 * safeLocalStorage 契约（冻结）。
 *
 * 所有 localStorage 访问必须经由本模块：
 *  - 统一命名空间前缀（STORAGE_PREFIX）
 *  - 隐私模式 / 配额超限等异常一律吞掉并回退为 null / no-op，绝不让存储故障打断游戏
 *  - 对象读写走 JSON 序列化，损坏数据返回 null
 */
import type { BestScore } from './types';

export const STORAGE_PREFIX = 'arcade';
export const LOCALE_STORAGE_KEY = `${STORAGE_PREFIX}.locale`;

function getStore(): Storage | null {
  try {
    return typeof window === 'undefined' ? null : window.localStorage;
  } catch {
    return null;
  }
}

export const safeLocalStorage = {
  getItem(key: string): string | null {
    try {
      return getStore()?.getItem(key) ?? null;
    } catch {
      return null;
    }
  },
  setItem(key: string, value: string): void {
    try {
      getStore()?.setItem(key, value);
    } catch {
      /* 隐私模式或配额超限：静默降级 */
    }
  },
  removeItem(key: string): void {
    try {
      getStore()?.removeItem(key);
    } catch {
      /* noop */
    }
  },
  getJson<T>(key: string): T | null {
    const raw = this.getItem(key);
    if (raw === null) return null;
    try {
      return JSON.parse(raw) as T;
    } catch {
      return null;
    }
  },
  setJson<T>(key: string, value: T): void {
    try {
      this.setItem(key, JSON.stringify(value));
    } catch {
      /* noop */
    }
  },
};

export function bestScoreKey(gameId: string): string {
  return `${STORAGE_PREFIX}.best.${gameId}`;
}

export function readBestScore(gameId: string): BestScore | null {
  return safeLocalStorage.getJson<BestScore>(bestScoreKey(gameId));
}

export function writeBestScore(gameId: string, score: BestScore): void {
  safeLocalStorage.setJson(bestScoreKey(gameId), score);
}

export function clearBestScore(gameId: string): void {
  safeLocalStorage.removeItem(bestScoreKey(gameId));
}

/** 若新分数更高则返回 true（平局视为非新纪录）。 */
export function isNewBestScore(gameId: string, value: number): boolean {
  const current = readBestScore(gameId);
  return current === null || value > current.value;
}
