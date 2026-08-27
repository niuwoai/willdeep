/**
 * 连连看。
 *
 * 契约遵循：
 *   - 默认导出组件，props 为 GameProps（{ seed?: string }）
 *   - 触屏/鼠标统一走可点按钮（touch-action: manipulation 防双击缩放）
 *   - 终局时 saveBestScore('onet', scoreFor(state))，外壳徽章订阅展示
 *   - 随机仅经 createRng（见 logic.ts），同一基准种子下第 N 局完全可复现；
 *     未指定 `?seed=` 时每次进入取一次性熵种子，重开则局数 +1，牌面不会重复
 *   - 用户可见文案走模块内 i18n 资源（strings.ts），不硬编码在视图
 */
import { useEffect, useMemo, useRef, useState } from 'react';
import type { CSSProperties } from 'react';
import type { GameProps } from '../../core/types';
import { useI18n } from '../../core/i18n';
import { saveBestScore } from '../../core/bestScore';
import { entropySeed } from '../../core/rng';
import { playCue } from '../../core/audio';
import { ONET_FACES, onetStrings } from './strings';
import { useAutoAdvance, useStageReport } from '../../core/stage';
import {
  PATH_MS,
  boardForStage,
  clearHint,
  clearPath,
  createInitialState,
  findAvailableMove,
  hint,
  restart,
  scoreFor,
  selectTile,
  shuffleBoard,
} from './logic';
import type { OnetState, Point } from './logic';
import './onet.css';

/** 提示高亮停留时长（毫秒）。 */
const HINT_MS = 1600;
/** 单格上限（px）：列数越多每格越小，整体宽度始终压在 480px 以内。 */
function cellPx(cols: number): number {
  return Math.max(48, Math.min(88, Math.floor(480 / Math.max(1, cols))));
}
/** 连续自动洗牌的次数上限：万一洗不出可消对，停手交给玩家重开，避免死循环。 */
const MAX_AUTO_SHUFFLE = 3;

/** 折线 → SVG points：坐标以「格」为单位，牌心在格中央。 */
function polylinePoints(path: readonly Point[]): string {
  return path.map((point) => `${point.x + 0.5},${point.y + 0.5}`).join(' ');
}

export default function OnetGame({ seed, onWin, onStage }: GameProps) {
  const { locale } = useI18n();
  const strings = onetStrings(locale);

  // 未显式指定种子时，本次进入游戏用一次性熵种子：牌面不再是每次都一样的那副。
  const baseSeed = useMemo(() => seed ?? entropySeed('onet'), [seed]);

  // 关卡阶梯：4×4 起步一路长到 8×8 封顶，通关自动进下一关，分数跨关累计。
  const [stage, setStage] = useState(1);
  const [total, setTotal] = useState(0);
  const board = boardForStage(stage);
  const [state, setState] = useState<OnetState>(() => createInitialState(board, `${baseSeed}@1`));
  const [autoShuffled, setAutoShuffled] = useState(false);
  const autoShuffleRef = useRef(0);

  // 种子或关卡变化时重开一局。
  useEffect(() => {
    setState(createInitialState(boardForStage(stage), `${baseSeed}@${stage}`));
    setAutoShuffled(false);
  }, [stage, baseSeed]);

  useStageReport(onStage, { stage, score: total, label: `${board.cols}×${board.rows}` });
  useAutoAdvance(state.status === 'won', () => setStage((current) => current + 1));

  // 连接线展示停留后清除。
  useEffect(() => {
    if (!state.lastPath) return;
    const timer = window.setTimeout(() => setState(clearPath), PATH_MS);
    return () => window.clearTimeout(timer);
  }, [state.lastPath]);

  // 提示高亮停留后淡出。
  useEffect(() => {
    if (!state.hintPair) return;
    const timer = window.setTimeout(() => setState(clearHint), HINT_MS);
    return () => window.clearTimeout(timer);
  }, [state.hintPair]);

  // 每消掉一对就重置自动洗牌计数。
  useEffect(() => {
    autoShuffleRef.current = 0;
  }, [state.remaining]);

  // 死局自救：没有可消的对子就自动洗牌（洗牌计入扣分，并提示玩家）。
  useEffect(() => {
    if (state.status === 'won' || state.remaining === 0) return;
    if (findAvailableMove(state) !== null) return;
    if (autoShuffleRef.current >= MAX_AUTO_SHUFFLE) return;
    autoShuffleRef.current += 1;
    setState(shuffleBoard);
    setAutoShuffled(true);
  }, [state]);

  // 消掉一对给一声反馈。
  useEffect(() => {
    if (state.lastPath) playCue('clear');
  }, [state.lastPath]);

  // 洗牌（手动或死局自救）给一声反馈。
  useEffect(() => {
    if (state.shuffles > 0) playCue('shuffle');
  }, [state.shuffles]);

  // 通关：累计分数、写最佳成绩、撒花，随后自动进入下一关。
  useEffect(() => {
    if (state.status !== 'won') return;
    const gained = scoreFor(state);
    setTotal((current) => {
      const next = current + gained;
      saveBestScore('onet', next);
      return next;
    });
    playCue('win');
    onWin?.();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [state.status]);

  const statusText = state.status === 'won'
    ? strings.statusWon
    : autoShuffled
      ? strings.statusShuffled
      : state.status === 'playing'
        ? strings.statusPlaying
        : strings.statusIdle;

  const handleTileClick = (index: number): void => {
    setAutoShuffled(false);
    playCue('select');
    setState((current) => selectTile(current, index));
  };

  return (
    <section className="onet" data-testid="onet-game">
      <div className="onet__bar">
        <span className="onet__count" data-testid="onet-remaining">
          {strings.remaining}:<b data-testid="onet-remaining-value">{state.remaining}</b>
        </span>
        <span className="onet__count" data-testid="onet-moves">
          {strings.moves}:<b data-testid="onet-moves-value">{state.moves}</b>
        </span>
        <span className="onet__status" data-testid="onet-status">
          {statusText}
        </span>
      </div>

      <div className="onet__tools" data-testid="onet-tools">
        <span data-testid="onet-stage">
          {strings.stageLabel} {stage} · {board.cols}×{board.rows}
        </span>
        <span data-testid="onet-total">
          {strings.totalLabel}: {total}
        </span>
        <button
          type="button"
          className="btn"
          data-testid="onet-hint"
          onClick={() => setState(hint)}
          disabled={state.status === 'won'}
        >
          {strings.hint}
        </button>
        <button
          type="button"
          className="btn"
          data-testid="onet-shuffle"
          onClick={() => {
            setAutoShuffled(false);
            setState(shuffleBoard);
          }}
          disabled={state.status === 'won'}
        >
          {strings.shuffle}
        </button>
        <button
          type="button"
          className="btn"
          data-testid="onet-restart"
          onClick={() => {
            setAutoShuffled(false);
            setState(restart);
          }}
        >
          {strings.restart}
        </button>
        <button
          type="button"
          className="btn btn--ghost"
          data-testid="onet-restart-run"
          onClick={() => {
            playCue('select');
            setAutoShuffled(false);
            setTotal(0);
            setStage(1);
            setState(createInitialState(boardForStage(1), `${baseSeed}@1`));
          }}
        >
          {strings.restartRun}
        </button>
      </div>

      <div
        className="onet__stage"
        style={
          {
            '--onet-cols': state.cols,
            '--onet-rows': state.rows,
            '--onet-cell': `${cellPx(state.cols)}px`,
          } as CSSProperties
        }
      >
        <div
          className="onet__board"
          data-testid="onet-board"
          role="grid"
          aria-label={strings.boardLabel}
          data-columns={state.cols}
          data-rows={state.rows}
        >
          {state.tiles.map((symbol, index) => {
            const cleared = symbol === null;
            const isHinted = state.hintPair?.includes(index) ?? false;
            return (
              <button
                key={index}
                type="button"
                className={[
                  'onet__tile',
                  cleared ? 'onet__tile--empty' : '',
                  state.selected === index ? 'onet__tile--selected' : '',
                  isHinted ? 'onet__tile--hint' : '',
                ]
                  .filter(Boolean)
                  .join(' ')}
                data-testid="onet-tile"
                data-index={index}
                data-symbol={cleared ? '' : symbol}
                aria-label={strings.tileLabel.replace('{index}', String(index + 1))}
                aria-pressed={state.selected === index}
                disabled={cleared || state.status === 'won'}
                onClick={() => handleTileClick(index)}
              >
                {cleared ? '' : ONET_FACES[symbol % ONET_FACES.length]}
              </button>
            );
          })}
        </div>

        {state.lastPath && (
          <svg
            className="onet__link"
            data-testid="onet-link"
            viewBox={`0 0 ${state.cols} ${state.rows}`}
            preserveAspectRatio="none"
            aria-hidden="true"
          >
            <polyline points={polylinePoints(state.lastPath)} />
          </svg>
        )}
      </div>

      <p className="onet__help" data-testid="onet-help">
        {strings.help}
      </p>
    </section>
  );
}
