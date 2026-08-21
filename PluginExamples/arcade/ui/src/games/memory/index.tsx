/**
 * 记忆翻牌（并行节点交付）。
 *
 * 契约遵循：
 *   - 默认导出组件，props 为 GameProps（{ seed?: string }）
 *   - 触屏/键盘均通过可点按钮触发（onClick，touch-action: manipulation 防双击缩放）
 *   - 不匹配时锁定棋盘 MISMATCH_MS 后自动复位；胜利时 saveBestScore('memory', score)
 *   - 随机仅经 createRng（见 logic.ts buildDeck），同一种子布局完全可复现
 *   - 用户可见文案走模块内 i18n 资源（strings.ts），不硬编码在视图
 */
import { useEffect, useState } from 'react';
import type { GameProps } from '../../core/types';
import { useI18n } from '../../core/i18n';
import { saveBestScore } from '../../core/bestScore';
import { memoryStrings } from './strings';
import type { MemoryStrings } from './strings';
import {
  DEFAULT_PAIRS,
  MISMATCH_MS,
  PAIR_OPTIONS,
  createInitialState,
  flipCard,
  resolveMismatch,
  restart,
  scoreFor,
} from './logic';
import type { MemoryState } from './logic';
import './memory.css';

const PAIR_LABEL_KEY: Record<number, keyof MemoryStrings> = {
  2: 'pairsEasy',
  4: 'pairsMedium',
  6: 'pairsHard',
};

function pairLabelKey(option: number): keyof MemoryStrings {
  return (PAIR_LABEL_KEY[option] ?? 'pairsEasy') as keyof MemoryStrings;
}

export default function MemoryGame({ seed }: GameProps) {
  const { locale } = useI18n();
  const strings = memoryStrings(locale);

  const [pairs, setPairs] = useState<number>(DEFAULT_PAIRS);
  const [state, setState] = useState<MemoryState>(() => createInitialState(DEFAULT_PAIRS, seed));

  // 种子或牌对数变化时重建一局（确定性布局，进度清零）。
  useEffect(() => {
    setState(createInitialState(pairs, seed));
  }, [pairs, seed]);

  // 不匹配展示停留后自动复位两张牌。
  useEffect(() => {
    if (!state.locked) return;
    const timer = window.setTimeout(() => setState(resolveMismatch), MISMATCH_MS);
    return () => window.clearTimeout(timer);
  }, [state.locked]);

  // 胜利时写入最佳成绩（saveBestScore 幂等，只保留更高分）。
  useEffect(() => {
    if (state.status === 'won') {
      saveBestScore('memory', scoreFor(state.pairs, state.moves));
    }
  }, [state.status, state.pairs, state.moves]);

  const handleCardClick = (index: number): void => {
    setState((s) => flipCard(s, index));
  };

  const handleRestart = (): void => {
    setState((s) => restart(s));
  };

  const statusText: Record<MemoryState['status'], string> = {
    idle: strings.statusIdle,
    playing: strings.statusPlaying,
    won: strings.statusWon,
  };

  const gridColumns = Math.min(pairs, 4);

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
        <span>{strings.pairsLabel}:</span>
        {PAIR_OPTIONS.map((option) => (
          <button
            key={option}
            type="button"
            className="btn btn--ghost btn--pairs"
            data-testid={`memory-pairs-${option}`}
            aria-pressed={pairs === option}
            onClick={() => setPairs(option)}
          >
            {strings[pairLabelKey(option)]}
          </button>
        ))}
      </div>

      <div
        className="memory__board"
        data-testid="memory-board"
        role="grid"
        aria-label={strings.boardLabel}
        style={{ gridTemplateColumns: `repeat(${gridColumns}, 1fr)` }}
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
