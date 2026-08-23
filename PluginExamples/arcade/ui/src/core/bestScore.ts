/**
 * 最佳成绩契约（冻结）。
 *
 * 成绩持久化统一走 safeLocalStorage，key 为 `arcade.best.<gameId>`；
 * 游戏模块在游戏结束时调用 saveBestScore(gameId, value)（内部只保留更高分）。
 * 展示一律用 useBestScore(gameId) 订阅，外部写入会触发所有订阅者刷新。
 */
import { useSyncExternalStore } from 'react';
import type { BestScore } from './types';
import { readBestScore, writeBestScore, clearBestScore } from './safeLocalStorage';

const listeners = new Set<() => void>();

function notifyListeners(): void {
  for (const listener of listeners) listener();
}

export function subscribeBestScore(onChange: () => void): () => void {
  listeners.add(onChange);
  return () => {
    listeners.delete(onChange);
  };
}

/** 稳定引用快照：内容不变时返回同一对象，避免 useSyncExternalStore 死循环。 */
const snapshots = new Map<string, BestScore | null>();

export function bestScoreSnapshot(gameId: string): BestScore | null {
  const current = readBestScore(gameId);
  const previous = snapshots.get(gameId);
  if (current === null) {
    snapshots.set(gameId, null);
    return null;
  }
  if (previous && previous.value === current.value && previous.achievedAt === current.achievedAt) {
    return previous;
  }
  snapshots.set(gameId, current);
  return current;
}

export function useBestScore(gameId: string): BestScore | null {
  return useSyncExternalStore(
    subscribeBestScore,
    () => bestScoreSnapshot(gameId),
    () => null,
  );
}

/** 保存最佳成绩：仅当高于既有纪录时更新并广播。返回最终生效的纪录。 */
export function saveBestScore(gameId: string, value: number): BestScore {
  const existing = readBestScore(gameId);
  const record: BestScore =
    existing !== null && existing.value >= value
      ? existing
      : { value, achievedAt: Date.now() };
  writeBestScore(gameId, record);
  notifyListeners();
  return record;
}

export function resetBestScore(gameId: string): void {
  clearBestScore(gameId);
  notifyListeners();
}
