/**
 * 贪吃蛇（并行节点交付）。
 *
 * 契约遵循：
 *   - 默认导出组件，props 为 GameProps（{ seed?: string }）
 *   - 键盘经 useKeyControls（卸载自动清理、过滤连发）；触屏用 React 指针事件滑动
 *   - 终局/胜利时调用 saveBestScore('snake', value)
 *   - 随机仅经 createRng（见 logic.ts placeFood）
 *   - 用户可见文案走模块内 i18n 资源（strings.ts），不硬编码在视图
 */
import { useCallback, useEffect, useRef, useState } from 'react';
import type { PointerEvent as ReactPointerEvent, ReactNode } from 'react';
import type { GameProps } from '../../core/types';
import { useKeyControls } from '../../core/input';
import type { KeyBinding } from '../../core/input';
import { saveBestScore } from '../../core/bestScore';
import { playCue } from '../../core/audio';
import { useI18n } from '../../core/i18n';
import { snakeStrings } from './strings';
import {
  GRID_COLS,
  GRID_ROWS,
  isOpposite,
  initialState,
  milestoneForStage,
  resetState,
  step,
  tickForStage,
} from './logic';
import { useAutoAdvance, useStageReport } from '../../core/stage';
import type { Direction, GameStatus, SnakeState } from './logic';
import './snake.css';

/** 触屏滑动判定阈值（px）。 */
const SWIPE_THRESHOLD = 24;

const DIRECTION_KEYS: Record<string, Direction> = {
  ArrowUp: 'up',
  ArrowDown: 'down',
  ArrowLeft: 'left',
  ArrowRight: 'right',
  w: 'up',
  s: 'down',
  a: 'left',
  d: 'right',
  W: 'up',
  S: 'down',
  A: 'left',
  D: 'right',
};

export default function SnakeGame({ seed, onWin, onStage }: GameProps) {
  const { locale } = useI18n();
  const strings = snakeStrings(locale);

  // 关卡阶梯：目标食物数 5 起步每关 +2，节拍越来越快，一直往上加
  const [stage, setStage] = useState(1);
  const [total, setTotal] = useState(0);
  const [state, setState] = useState<SnakeState>(() => initialState(seed, milestoneForStage(1)));
  const stateRef = useRef(state);
  useEffect(() => {
    stateRef.current = state;
  }, [state]);

  /** 输入请求的转向，在下一 tick 消费（每次 tick 最多允许一次转向）。 */
  const pendingDirection = useRef<Direction | null>(null);
  /** 触屏滑动的起点。 */
  const swipeStart = useRef<{ x: number; y: number } | null>(null);

  const requestDirection = useCallback((dir: Direction) => {
    const current = stateRef.current;
    if (current.status === 'gameover' || current.status === 'won') return;
    const base = pendingDirection.current ?? current.direction;
    // 同向按键：不改变方向，但 idle 状态视为“起步”指令
    if (dir === base) {
      setState((s) => (s.status === 'idle' ? { ...s, status: 'playing' } : s));
      return;
    }
    if (isOpposite(base, dir)) return;
    pendingDirection.current = dir;
    setState((s) => (s.status === 'idle' ? { ...s, status: 'playing' } : s));
  }, []);

  const bindings: KeyBinding[] = Object.entries(DIRECTION_KEYS).map(([key, dir]) => ({
    key,
    onDown: () => requestDirection(dir),
    preventDefault: true,
  }));
  useKeyControls(bindings, []);

  // 自动行进：仅 playing 时注册 interval，切换状态时清理。
  useEffect(() => {
    if (state.status !== 'playing') return;
    const timer = window.setInterval(() => {
      const dir = pendingDirection.current;
      pendingDirection.current = null;
      setState(step(stateRef.current, dir ?? undefined));
    }, tickForStage(stage));
    return () => window.clearInterval(timer);
  }, [state.status, stage]);

  useStageReport(onStage, { stage, score: total + state.score, label: `${state.milestone} 食物` });
  useAutoAdvance(state.status === 'won', () => {
    setTotal((current) => current + stateRef.current.score);
    setStage((current) => {
      const next = current + 1;
      setState(initialState(seed, milestoneForStage(next)));
      return next;
    });
  });

  // 吃到食物给一声反馈。
  useEffect(() => {
    if (state.score > 0) playCue('eat');
  }, [state.score]);

  // 终局/胜利时写入最佳成绩（saveBestScore 幂等，只保留更高分）；通关撒花。
  useEffect(() => {
    if (state.status !== 'gameover' && state.status !== 'won') return;
    saveBestScore('snake', total + state.score);
    if (state.status === 'won') {
      playCue('win');
      onWin?.();
    } else {
      playCue('lose');
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [state.status]);

  const handleRestart = useCallback(() => {
    pendingDirection.current = null;
    setState(resetState(stateRef.current));
  }, []);

  /** 从第 1 关重来，累计分数归零。 */
  const handleRestartRun = useCallback(() => {
    pendingDirection.current = null;
    setTotal(0);
    setStage(1);
    setState(initialState(seed, milestoneForStage(1)));
  }, [seed]);

  const handlePointerDown = useCallback((event: ReactPointerEvent<HTMLDivElement>) => {
    if (event.pointerType === 'mouse') return;
    swipeStart.current = { x: event.clientX, y: event.clientY };
  }, []);

  const handlePointerEnd = useCallback((event: ReactPointerEvent<HTMLDivElement>) => {
    const start = swipeStart.current;
    swipeStart.current = null;
    if (start === null || event.pointerType === 'mouse') return;
    const dx = event.clientX - start.x;
    const dy = event.clientY - start.y;
    if (Math.abs(dx) < SWIPE_THRESHOLD && Math.abs(dy) < SWIPE_THRESHOLD) return;
    if (Math.abs(dx) > Math.abs(dy)) requestDirection(dx > 0 ? 'right' : 'left');
    else requestDirection(dy > 0 ? 'down' : 'up');
  }, [requestDirection]);

  const statusText: Record<GameStatus, string> = {
    idle: strings.statusIdle,
    playing: strings.statusPlaying,
    gameover: strings.statusGameover,
    won: strings.statusWon,
  };

  const cells: ReactNode[] = [];
  const head = state.snake[0]!;
  for (let row = 0; row < GRID_ROWS; row += 1) {
    for (let col = 0; col < GRID_COLS; col += 1) {
      const isHead = head.row === row && head.col === col;
      const isBody = state.snake.some((p) => p.row === row && p.col === col);
      const isFood = state.food.row === row && state.food.col === col;
      const className = ['snake__cell'];
      if (isHead) className.push('snake__cell--head');
      else if (isBody) className.push('snake__cell--body');
      if (isFood) className.push('snake__cell--food');
      cells.push(
        <div
          key={`${row}-${col}`}
          className={className.join(' ')}
          data-testid={isHead ? 'snake-head' : isFood ? 'snake-food' : undefined}
          data-row={isHead || isFood ? row : undefined}
          data-col={isHead || isFood ? col : undefined}
        />,
      );
    }
  }

  return (
    <div className="snake" data-testid="snake-game">
      <div className="snake__bar">
        <span className="snake__score" data-testid="snake-score">
          {strings.score}:
          <span data-testid="snake-score-value">{state.score}</span>
        </span>
        <span className="snake__status" data-testid="snake-status">
          {statusText[state.status]}
        </span>
        <button
          type="button"
          className="btn snake__restart"
          data-testid="snake-restart"
          onClick={handleRestart}
        >
          {strings.restart}
        </button>
        <button
          type="button"
          className="btn btn--ghost"
          data-testid="snake-restart-run"
          onClick={handleRestartRun}
        >
          {strings.restartRun}
        </button>
      </div>
      <div
        className="snake__board"
        data-testid="snake-board"
        role="grid"
        aria-label={strings.boardLabel}
        onPointerDown={handlePointerDown}
        onPointerUp={handlePointerEnd}
        onPointerCancel={handlePointerEnd}
      >
        {cells}
      </div>
      <p className="snake__milestone" data-testid="snake-milestone">
        {strings.milestone
          .replace('{eaten}', String(state.foodsEaten))
          .replace('{total}', String(state.milestone))}
      </p>
      <p className="snake__hint" data-testid="snake-hint">
        {strings.hint}
      </p>
    </div>
  );
}
