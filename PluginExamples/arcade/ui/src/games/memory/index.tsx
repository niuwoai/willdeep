/**
 * 记忆翻牌（并行节点交付）。
 *
 * 契约遵循：
 *   - 默认导出组件，props 为 GameProps（{ seed?: string }）
 *   - 触屏/键盘均通过可点按钮触发（onClick，touch-action: manipulation 防双击缩放）
 *   - 不匹配时锁定棋盘 MISMATCH_MS 后自动复位；胜利时 saveBestScore('memory', score)
 *   - 随机仅经 createRng（见 logic.ts buildDeck），同一基准种子下第 N 局完全可复现
 *   - 未通过 `?seed=` 指定种子时，每次进入游戏取一次性熵种子；每次重开局数 +1，
 *     所以布局不会重复（玩家背下来的那副牌不再翻回来）
 *   - 用户可见文案走模块内 i18n 资源（strings.ts），不硬编码在视图
 */
import { useEffect, useMemo, useState } from 'react';
import type { CSSProperties } from 'react';
import type { GameProps } from '../../core/types';
import { useI18n } from '../../core/i18n';
import { saveBestScore } from '../../core/bestScore';
import { entropySeed } from '../../core/rng';
import { playCue } from '../../core/audio';
import { memoryStrings } from './strings';
import { useAutoAdvance, useStageReport } from '../../core/stage';
import {
  MISMATCH_MS,
  columnsForPairs,
  createInitialState,
  flipCard,
  pairsForStage,
  resolveMismatch,
  restart,
  scoreFor,
} from './logic';
import type { MemoryState } from './logic';
import './memory.css';

export default function MemoryGame({ seed, onWin, onStage }: GameProps) {
  const { locale } = useI18n();
  const strings = memoryStrings(locale);

  // 未显式指定种子时，本次进入游戏用一次性熵种子：布局不再是每次都一样的那副牌。
  const baseSeed = useMemo(() => seed ?? entropySeed('memory'), [seed]);

  // 关卡阶梯：第 1 关 2 对，每通一关自动 +1 对（12 对封顶），分数跨关累计。
  const [stage, setStage] = useState(1);
  const [total, setTotal] = useState(0);
  const pairs = pairsForStage(stage);
  const [state, setState] = useState<MemoryState>(() => createInitialState(pairs, `${baseSeed}@1`));

  // 种子或关卡变化时重建一局（确定性布局，进度清零）。
  useEffect(() => {
    setState(createInitialState(pairsForStage(stage), `${baseSeed}@${stage}`));
  }, [stage, baseSeed]);

  useStageReport(onStage, { stage, score: total, label: `${pairs} 对` });
  useAutoAdvance(state.status === 'won', () => setStage((current) => current + 1));

  // 不匹配展示停留后自动复位两张牌。
  useEffect(() => {
    if (!state.locked) return;
    const timer = window.setTimeout(() => setState(resolveMismatch), MISMATCH_MS);
    return () => window.clearTimeout(timer);
  }, [state.locked]);

  // 配对成功/失败各给一声反馈。
  useEffect(() => {
    if (state.matched.length > 0) playCue('match');
  }, [state.matched.length]);
  useEffect(() => {
    if (state.locked) playCue('miss');
  }, [state.locked]);

  // 通关：累计分数、写入最佳成绩（只保留更高分）、撒花，随后自动进入下一关。
  useEffect(() => {
    if (state.status !== 'won') return;
    const gained = scoreFor(state.pairs, state.moves);
    setTotal((current) => {
      const next = current + gained;
      saveBestScore('memory', next);
      return next;
    });
    playCue('win');
    onWin?.();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [state.status]);

  const handleCardClick = (index: number): void => {
    playCue('flip');
    setState((s) => flipCard(s, index));
  };

  /** 换一副牌重打本关（关卡与累计分数不变）。 */
  const handleRestart = (): void => {
    playCue('select');
    setState((s) => restart(s));
  };

  /** 从第 1 关重新开始，累计分数归零。 */
  const handleRestartRun = (): void => {
    playCue('select');
    setTotal(0);
    setStage(1);
    setState(createInitialState(pairsForStage(1), `${baseSeed}@1`));
  };

  const statusText: Record<MemoryState['status'], string> = {
    idle: strings.statusIdle,
    playing: strings.statusPlaying,
    won: strings.statusWon,
  };

  // 列数随牌数走（尽量方阵），宽度交给 CSS：容器相对 + 每张牌绝对上限
  // （见 memory.css），不用视口单位，免得面板宽度与布局视口不一致时被撑出可视区。
  const gridColumns = columnsForPairs(pairs);

  return (
    <div className="memory" data-testid="memory-game">
      <div className="memory__bar">
        <span className="memory__moves" data-testid="memory-moves">
          {strings.moves}:
          <span data-testid="memory-moves-value">{state.moves}</span>
        </span>
        <span className="memory__status" data-testid="memory-status">
          {statusText[state.status]}
        </span>
        <button
          type="button"
          className="btn memory__restart"
          data-testid="memory-restart"
          onClick={handleRestart}
        >
          {strings.restart}
        </button>
      </div>

      <div className="memory__pairs" data-testid="memory-pairs">
        <span data-testid="memory-stage">
          {strings.stageLabel} {stage} · {pairs} {strings.pairsUnit}
        </span>
        <span data-testid="memory-total">
          {strings.totalLabel}: {total}
        </span>
        <button
          type="button"
          className="btn btn--ghost"
          data-testid="memory-restart-run"
          onClick={handleRestartRun}
        >
          {strings.restartRun}
        </button>
      </div>

      <div
        className="memory__board"
        data-testid="memory-board"
        role="grid"
        aria-label={strings.boardLabel}
        data-columns={gridColumns}
        style={{ '--memory-cols': gridColumns } as CSSProperties}
      >
        {state.cards.map((card, index) => {
          const faceUp = state.flipped.includes(index) || state.matched.includes(card.pairId);
          return (
            <button
              key={index}
              type="button"
              className={[
                'memory__card',
                faceUp ? `memory__card--up memory__card--pair-${card.pairId}` : '',
              ]
                .filter(Boolean)
                .join(' ')}
              data-testid="memory-card"
              data-index={index}
              data-pair={card.pairId}
              aria-pressed={faceUp}
              onClick={() => handleCardClick(index)}
              disabled={state.status === 'won' || (faceUp && state.matched.includes(card.pairId))}
            />
          );
        })}
      </div>

      <p className="memory__hint" data-testid="memory-hint">
        {strings.hint}
      </p>
    </div>
  );
}
