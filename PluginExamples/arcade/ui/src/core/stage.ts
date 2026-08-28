/**
 * 关卡进阶契约。
 *
 * 玩法不再让玩家手选难度：每款游戏自己维护一条关卡阶梯，通关即自动进入
 * 下一关，能一直往上加的就一直加（弹珠、贪吃蛇、俄罗斯方块是真无限；
 * 2048、打砖块、记忆翻牌、连连看、扫雷、图片拼图有各自的递进或物理上限，
 * 封顶后关卡号继续涨、分数继续累计）。
 *
 * 外壳只负责显示：游戏通过可选 prop `onStage` 上报当前关卡与本轮累计分数，
 * `GameShell` 渲染「关卡 N」「分数 X」两枚徽章。
 */
import { useEffect, useRef } from 'react';

/** 通关到自动进入下一关之间的停顿（毫秒）：留给撒花和「恭喜通关」。 */
export const STAGE_ADVANCE_MS = 1900;

export interface StageInfo {
  /** 当前关卡，从 1 开始。 */
  stage: number;
  /** 本轮累计分数（跨关累加，重开归零）。 */
  score: number;
  /** 可选的关卡描述，如「6×4 · 8 图案」。 */
  label?: string;
}

/** 关卡或分数变化时上报给外壳。 */
export function useStageReport(
  onStage: ((info: StageInfo) => void) | undefined,
  info: StageInfo,
): void {
  const { stage, score, label } = info;
  useEffect(() => {
    onStage?.({ stage, score, ...(label === undefined ? {} : { label }) });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [stage, score, label]);
}

/**
 * 通关后延迟自动进阶：active 由 false 变 true 时起一个定时器，
 * 卸载或状态回落都会清掉，不会重复触发。
 */
export function useAutoAdvance(active: boolean, advance: () => void): void {
  const advanceRef = useRef(advance);
  useEffect(() => {
    advanceRef.current = advance;
  }, [advance]);

  useEffect(() => {
    if (!active) return;
    const timer = window.setTimeout(() => advanceRef.current(), STAGE_ADVANCE_MS);
    return () => window.clearTimeout(timer);
  }, [active]);
}
