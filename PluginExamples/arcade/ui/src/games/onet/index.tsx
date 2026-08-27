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
import type { OnetStrings } from './strings';
import {
  DEFAULT_LEVEL,
  LEVELS,
  PATH_MS,
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
/** 各难度的单格上限（px）：列数越多每格越小，整体宽度都压在 480px 以内。 */
const CELL_PX: readonly number[] = [88, 72, 60];
/** 连续自动洗牌的次数上限：万一洗不出可消对，停手交给玩家重开，避免死循环。 */
const MAX_AUTO_SHUFFLE = 3;

const LEVEL_LABEL_KEY: readonly (keyof OnetStrings)[] = ['levelEasy', 'levelMedium', 'levelHard'];

/** 折线 → SVG points：坐标以「格」为单位，牌心在格中央。 */
function polylinePoints(path: readonly Point[]): string {
  return path.map((point) => `${point.x + 0.5},${point.y + 0.5}`).join(' ');
}

export default function OnetGame({ seed, onWin }: GameProps) {
  const { locale } = useI18n();
  const strings = onetStrings(locale);

  // 未显式指定种子时，本次进入游戏用一次性熵种子：牌面不再是每次都一样的那副。
  const baseSeed = useMemo(() => seed ?? entropySeed('onet'), [seed]);

  const [level, setLevel] = useState<number>(DEFAULT_LEVEL);
  const [state, setState] = useState<OnetState>(() => createInitialState(DEFAULT_LEVEL, baseSeed));
  const [autoShuffled, setAutoShuffled] = useState(false);
  const autoShuffleRef = useRef(0);

  // 种子或难度变化时重开一局。
  useEffect(() => {
    setState(createInitialState(level, baseSeed));
    setAutoShuffled(false);
  }, [level, baseSeed]);

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

  // 胜利时写入最佳成绩（saveBestScore 只保留更高分）并撒花。
  useEffect(() => {
    if (state.status !== 'won') return;
    saveBestScore('onet', scoreFor(state));
    playCue('win');
    onWin?.();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [state.status]);

  const config = LEVELS[state.level] ?? LEVELS[DEFAULT_LEVEL];
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
        <span>{strings.levelLabel}:</span>
        {LEVELS.map((option, index) => (
          <button
            key={option.id}
            type="button"
            className="btn btn--ghost"
            data-testid={`onet-level-${option.id}`}
            aria-pressed={level === index}
            onClick={() => setLevel(index)}
          >
            {strings[LEVEL_LABEL_KEY[index] ?? 'levelEasy']}
          </button>
        ))}
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
      </div>

      <div
        className="onet__stage"
        style={
          {
            '--onet-cols': config?.cols ?? state.cols,
            '--onet-rows': config?.rows ?? state.rows,
            '--onet-cell': `${CELL_PX[state.level] ?? 60}px`,
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
