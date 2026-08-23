/**
 * 俄罗斯方块（并行节点交付）。
 *
 * 契约遵循：
 *   - 默认导出组件，props 为 GameProps（{ seed?: string }）
 *   - 键盘经 useKeyControls（卸载自动清理、过滤连发）；触屏用 on-screen 按钮（指针事件）
 *   - 终局时调用 saveBestScore('tetris', value)，外壳徽章（game-best-score）订阅展示
 *   - 随机仅经 createPieceQueue（createRng），同一 seed 完全可复现
 *   - 用户可见文案走模块内 i18n 资源（strings.ts），不硬编码在视图
 */
import { useEffect, useMemo, useReducer, useRef } from 'react';
import type { GameProps } from '../../core/types';
import { useKeyControls } from '../../core/input';
import type { KeyBinding } from '../../core/input';
import { saveBestScore } from '../../core/bestScore';
import { useI18n } from '../../core/i18n';
import { tetrisStrings } from './strings';
import {
  BOARD_HEIGHT,
  EMPTY_CELL,
  createPieceQueue,
  createState,
  getCells,
  hardDrop,
  move,
  rotate,
  step,
  type PieceKind,
  type TetrisState,
} from './engine';
import './tetris.css';

/** 7-bag 袋数（7×16 = 112 个方块，足够完整对局）。 */
const QUEUE_BAGS = 16;
/** 重力下落间隔（毫秒）。 */
const TICK_MS = 600;

interface ViewState {
  game: TetrisState;
  cursor: number;
}

type Action =
  | { type: 'move'; dx: number }
  | { type: 'rotate' }
  | { type: 'drop' }
  | { type: 'tick' }
  | { type: 'restart' };

const initialViewState = (queue: PieceKind[]): ViewState => ({
  game: createState(queue[0] ?? 'T', queue[1] ?? 'I'),
  cursor: 2,
});

const nextKind = (queue: PieceKind[], cursor: number): PieceKind => queue[cursor % queue.length] ?? 'T';

function reduce(queue: PieceKind[], state: ViewState, action: Action): ViewState {
  switch (action.type) {
    case 'move':
      return state.game.gameOver ? state : { ...state, game: move(state.game, action.dx, 0) };
    case 'rotate':
      return state.game.gameOver ? state : { ...state, game: rotate(state.game) };
    case 'drop': {
      if (state.game.gameOver) return state;
      const result = hardDrop(state.game, nextKind(queue, state.cursor));
      return { game: result.state, cursor: state.cursor + 1 };
    }
    case 'tick': {
      if (state.game.gameOver) return state;
      const result = step(state.game, nextKind(queue, state.cursor));
      return { game: result.state, cursor: state.cursor + (result.locked ? 1 : 0) };
    }
    case 'restart':
      return initialViewState(queue);
  }
}

export default function TetrisGame({ seed }: GameProps) {
  const { locale } = useI18n();
  const strings = tetrisStrings(locale);

  const queue = useMemo(() => createPieceQueue(seed, 7 * QUEUE_BAGS), [seed]);
  const queueRef = useRef(queue);
  useEffect(() => {
    queueRef.current = queue;
  }, [queue]);

  const [view, dispatch] = useReducer(
    (state: ViewState, action: Action) => reduce(queueRef.current, state, action),
    queue,
    initialViewState,
  );

  useEffect(() => {
    if (view.game.gameOver) saveBestScore('tetris', view.game.score);
  }, [view.game.gameOver, view.game.score]);

  useEffect(() => {
    const timer = window.setInterval(() => dispatch({ type: 'tick' }), TICK_MS);
    return () => window.clearInterval(timer);
  }, []);

  const bindings = useMemo<KeyBinding[]>(
    () => [
      { key: 'ArrowLeft', onDown: () => dispatch({ type: 'move', dx: -1 }), preventDefault: true, allowRepeat: true },
      { key: 'ArrowRight', onDown: () => dispatch({ type: 'move', dx: 1 }), preventDefault: true, allowRepeat: true },
      { key: 'ArrowUp', onDown: () => dispatch({ type: 'rotate' }), preventDefault: true },
      { key: 'ArrowDown', onDown: () => dispatch({ type: 'tick' }), preventDefault: true, allowRepeat: true },
      { key: ' ', onDown: () => dispatch({ type: 'drop' }), preventDefault: true },
      { key: 'w', onDown: () => dispatch({ type: 'rotate' }) },
      { key: 'W', onDown: () => dispatch({ type: 'rotate' }) },
      { key: 'a', onDown: () => dispatch({ type: 'move', dx: -1 }), allowRepeat: true },
      { key: 'A', onDown: () => dispatch({ type: 'move', dx: -1 }), allowRepeat: true },
      { key: 'd', onDown: () => dispatch({ type: 'move', dx: 1 }), allowRepeat: true },
      { key: 'D', onDown: () => dispatch({ type: 'move', dx: 1 }), allowRepeat: true },
      { key: 's', onDown: () => dispatch({ type: 'tick' }), allowRepeat: true },
      { key: 'S', onDown: () => dispatch({ type: 'tick' }), allowRepeat: true },
      { key: 'r', onDown: () => dispatch({ type: 'restart' }) },
      { key: 'R', onDown: () => dispatch({ type: 'restart' }) },
    ],
    [],
  );
  useKeyControls(bindings);

  const display = view.game.board.map((row) => row.slice());
  for (const { x, y } of getCells(view.game.active)) {
    if (y >= 0 && y < BOARD_HEIGHT) display[y]![x] = 1;
  }

  return (
    <div className="tetris-game" data-testid="tetris-game">
      <header className="tetris-header">
        <h2>{strings.title}</h2>
        <button type="button" onClick={() => dispatch({ type: 'restart' })} data-testid="tetris-restart">
          {strings.restart}
        </button>
      </header>
      <div className="tetris-layout">
        <div className="tetris-board" role="grid" aria-label={strings.boardLabel} data-testid="tetris-board">
          {display.flatMap((row, y) =>
            row.map((cell, x) => (
              <div
                key={`${x}-${y}`}
                role="gridcell"
                className={`tetris-cell tetris-cell--${cell === EMPTY_CELL ? 'empty' : 'filled'}`}
              />
            )),
          )}
          {view.game.gameOver && (
            <div className="tetris-overlay" role="status" data-testid="tetris-game-over">
              {strings.gameOver}
            </div>
          )}
        </div>
        <aside className="tetris-stats" aria-live="polite">
          <p>
            {strings.score}: <output data-testid="tetris-score">{view.game.score}</output>
          </p>
          <p>
            {strings.lines}: <output data-testid="tetris-lines">{view.game.lines}</output>
          </p>
          <p>
            {strings.level}: <output data-testid="tetris-level">{view.game.level}</output>
          </p>
          <output
            className="tetris-active-meta"
            data-testid="tetris-active"
            data-x={view.game.active.x}
            data-y={view.game.active.y}
            data-rotation={view.game.active.rotation}
            data-kind={view.game.active.kind}
            aria-hidden="true"
          />
        </aside>
      </div>
      <div className="tetris-controls" aria-label={strings.controls}>
        <button type="button" onClick={() => dispatch({ type: 'move', dx: -1 })} data-testid="tetris-btn-left" aria-label={strings.btnLeft}>
          {strings.btnLeft}
        </button>
        <button type="button" onClick={() => dispatch({ type: 'rotate' })} data-testid="tetris-btn-rotate" aria-label={strings.btnRotate}>
          {strings.btnRotate}
        </button>
        <button type="button" onClick={() => dispatch({ type: 'move', dx: 1 })} data-testid="tetris-btn-right" aria-label={strings.btnRight}>
          {strings.btnRight}
        </button>
        <button type="button" onClick={() => dispatch({ type: 'tick' })} data-testid="tetris-btn-down" aria-label={strings.btnDown}>
          {strings.btnDown}
        </button>
        <button type="button" onClick={() => dispatch({ type: 'drop' })} data-testid="tetris-btn-drop" aria-label={strings.btnDrop}>
          {strings.btnDrop}
        </button>
      </div>
      <p className="tetris-help">{strings.controls}</p>
    </div>
  );
}
