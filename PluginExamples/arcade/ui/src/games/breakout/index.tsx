import { useCallback, useEffect, useRef, useState } from 'react';
import type { PointerEvent as ReactPointerEvent } from 'react';
import { playCue } from '../../core/audio';
import { saveBestScore } from '../../core/bestScore';
import { useI18n } from '../../core/i18n';
import { useKeyControls } from '../../core/input';
import { useAutoAdvance, useStageReport } from '../../core/stage';
import type { GameProps } from '../../core/types';
import {
  BALL_RADIUS,
  FIELD_HEIGHT,
  FIELD_WIDTH,
  PADDLE_HEIGHT,
  PADDLE_Y,
  brickRowsForStage,
  createInitialState,
  movePaddle,
  paddleWidthForStage,
  stepBreakout,
  togglePlay,
} from './engine';
import type { BreakoutState } from './engine';
import { breakoutStrings } from './strings';
import './breakout.css';

const BRICK_COLORS = ['#ff6b6b', '#ff9f43', '#ffd166', '#56d89c', '#4dabf7', '#9b7bff'] as const;
const KEYBOARD_STEP = 6;

function draw(canvas: HTMLCanvasElement, state: BreakoutState, stage: number): void {
  if (typeof navigator !== 'undefined' && navigator.userAgent.includes('jsdom')) return;
  const context = canvas.getContext('2d');
  if (!context) return;
  const ratio = window.devicePixelRatio || 1;
  const width = canvas.clientWidth || FIELD_WIDTH;
  const height = (width * FIELD_HEIGHT) / FIELD_WIDTH;
  const pixelWidth = Math.max(1, Math.round(width * ratio));
  const pixelHeight = Math.max(1, Math.round(height * ratio));
  if (canvas.width !== pixelWidth || canvas.height !== pixelHeight) {
    canvas.width = pixelWidth;
    canvas.height = pixelHeight;
  }
  const scale = pixelWidth / FIELD_WIDTH;
  context.setTransform(scale, 0, 0, scale, 0, 0);
  context.clearRect(0, 0, FIELD_WIDTH, FIELD_HEIGHT);

  const background = context.createLinearGradient(0, 0, 0, FIELD_HEIGHT);
  background.addColorStop(0, '#11182b');
  background.addColorStop(1, '#080b13');
  context.fillStyle = background;
  context.fillRect(0, 0, FIELD_WIDTH, FIELD_HEIGHT);

  for (const brick of state.bricks) {
    context.fillStyle = 'rgba(0, 0, 0, 0.35)';
    context.beginPath();
    context.roundRect(brick.x + 0.35, brick.y + 0.45, brick.width, brick.height, 0.7);
    context.fill();
    const gradient = context.createLinearGradient(brick.x, brick.y, brick.x, brick.y + brick.height);
    gradient.addColorStop(0, '#ffffff');
    gradient.addColorStop(0.12, BRICK_COLORS[brick.color] as string);
    gradient.addColorStop(1, BRICK_COLORS[brick.color] as string);
    context.fillStyle = gradient;
    context.beginPath();
    context.roundRect(brick.x, brick.y, brick.width, brick.height, 0.7);
    context.fill();
  }

  const paddleWidth = paddleWidthForStage(stage);
  const paddleGradient = context.createLinearGradient(
    state.paddleX - paddleWidth / 2,
    PADDLE_Y,
    state.paddleX + paddleWidth / 2,
    PADDLE_Y + PADDLE_HEIGHT,
  );
  paddleGradient.addColorStop(0, '#f7f8fb');
  paddleGradient.addColorStop(1, '#8d98ae');
  context.fillStyle = 'rgba(0, 0, 0, 0.4)';
  context.beginPath();
  context.roundRect(state.paddleX - paddleWidth / 2 + 0.7, PADDLE_Y + 0.8, paddleWidth, PADDLE_HEIGHT, 1.2);
  context.fill();
  context.fillStyle = paddleGradient;
  context.beginPath();
  context.roundRect(state.paddleX - paddleWidth / 2, PADDLE_Y, paddleWidth, PADDLE_HEIGHT, 1.2);
  context.fill();

  const ball = context.createRadialGradient(
    state.ballX - BALL_RADIUS * 0.35,
    state.ballY - BALL_RADIUS * 0.4,
    BALL_RADIUS * 0.1,
    state.ballX,
    state.ballY,
    BALL_RADIUS,
  );
  ball.addColorStop(0, '#ffffff');
  ball.addColorStop(0.5, '#dbe7ff');
  ball.addColorStop(1, '#7394d8');
  context.fillStyle = ball;
  context.beginPath();
  context.arc(state.ballX, state.ballY, BALL_RADIUS, 0, Math.PI * 2);
  context.fill();
}

export default function BreakoutGame({ onWin, onStage }: GameProps) {
  const { locale } = useI18n();
  const strings = breakoutStrings(locale);
  const [stage, setStage] = useState(1);
  const [total, setTotal] = useState(0);
  const [state, setState] = useState<BreakoutState>(() => createInitialState(1));
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const terminalHandled = useRef(false);
  const previousFeedback = useRef({ score: 0, lives: state.lives });

  const resetStage = useCallback((nextStage: number) => {
    terminalHandled.current = false;
    const next = createInitialState(nextStage);
    previousFeedback.current = { score: 0, lives: next.lives };
    setState(next);
  }, []);

  useEffect(() => resetStage(stage), [resetStage, stage]);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (canvas) draw(canvas, state, stage);
    if (state.score > previousFeedback.current.score) playCue('blast');
    if (state.lives < previousFeedback.current.lives) playCue('miss');
    previousFeedback.current = { score: state.score, lives: state.lives };
  }, [stage, state]);

  useEffect(() => {
    if (state.status !== 'playing') return;
    let frame = 0;
    let previous = performance.now();
    const tick = (now: number): void => {
      const dt = Math.min(0.04, Math.max(0, (now - previous) / 1000));
      previous = now;
      setState((current) => stepBreakout(current, dt, stage));
      frame = window.requestAnimationFrame(tick);
    };
    frame = window.requestAnimationFrame(tick);
    return () => window.cancelAnimationFrame(frame);
  }, [stage, state.status]);

  useStageReport(onStage, {
    stage,
    score: total + state.score,
    label: `${brickRowsForStage(stage)} ${strings.stageLabel}`,
  });
  useAutoAdvance(state.status === 'won', () => {
    setTotal((current) => current + state.score);
    setStage((current) => current + 1);
  });

  useEffect(() => {
    if ((state.status !== 'won' && state.status !== 'lost') || terminalHandled.current) return;
    terminalHandled.current = true;
    const finalScore = total + state.score;
    saveBestScore('breakout', finalScore);
    if (state.status === 'won') {
      playCue('win');
      onWin?.();
    } else {
      playCue('lose');
    }
  }, [onWin, state.score, state.status, total]);

  const moveBy = useCallback((amount: number) => {
    setState((current) => movePaddle(current, current.paddleX + amount, stage));
  }, [stage]);
  const toggle = useCallback(() => setState(togglePlay), []);

  useKeyControls([
    { key: 'ArrowLeft', onDown: () => moveBy(-KEYBOARD_STEP), preventDefault: true, allowRepeat: true },
    { key: 'a', onDown: () => moveBy(-KEYBOARD_STEP), preventDefault: true, allowRepeat: true },
    { key: 'A', onDown: () => moveBy(-KEYBOARD_STEP), preventDefault: true, allowRepeat: true },
    { key: 'ArrowRight', onDown: () => moveBy(KEYBOARD_STEP), preventDefault: true, allowRepeat: true },
    { key: 'd', onDown: () => moveBy(KEYBOARD_STEP), preventDefault: true, allowRepeat: true },
    { key: 'D', onDown: () => moveBy(KEYBOARD_STEP), preventDefault: true, allowRepeat: true },
    { key: ' ', onDown: toggle, preventDefault: true },
    { key: 'p', onDown: toggle, preventDefault: true },
    { key: 'P', onDown: toggle, preventDefault: true },
  ], [moveBy, toggle]);

  const handlePointer = (event: ReactPointerEvent<HTMLCanvasElement>): void => {
    const rect = event.currentTarget.getBoundingClientRect();
    const x = ((event.clientX - rect.left) / Math.max(1, rect.width)) * FIELD_WIDTH;
    setState((current) => movePaddle(current, x, stage));
  };

  const statusText: Record<BreakoutState['status'], string> = {
    idle: strings.statusIdle,
    playing: strings.statusPlaying,
    paused: strings.statusPaused,
    won: strings.statusWon,
    lost: strings.statusLost,
  };
  const toggleText = state.status === 'playing'
    ? strings.pause
    : state.status === 'paused'
      ? strings.resume
      : strings.launch;

  return (
    <section className="breakout" data-testid="breakout-game">
      <div className="breakout__bar">
        <span>{strings.score}: <strong data-testid="breakout-score">{state.score}</strong></span>
        <span>{strings.total}: <strong>{total}</strong></span>
        <span>{strings.lives}: <strong data-testid="breakout-lives">{state.lives}</strong></span>
        <span>{strings.bricks}: <strong data-testid="breakout-bricks">{state.bricks.length}</strong></span>
        <span className="breakout__status" data-testid="breakout-status">{statusText[state.status]}</span>
      </div>
      <canvas
        ref={canvasRef}
        className="breakout__field"
        data-testid="breakout-field"
        aria-label={strings.fieldLabel}
        onPointerMove={handlePointer}
        onPointerDown={(event) => {
          handlePointer(event);
          event.currentTarget.setPointerCapture(event.pointerId);
          setState((current) => current.status === 'idle' ? togglePlay(current) : current);
        }}
      />
      <div className="breakout__controls">
        <button type="button" className="btn" aria-label={strings.moveLeft} onClick={() => moveBy(-KEYBOARD_STEP)}>←</button>
        <button type="button" className="btn" data-testid="breakout-toggle" onClick={toggle}>{toggleText}</button>
        <button type="button" className="btn" aria-label={strings.moveRight} onClick={() => moveBy(KEYBOARD_STEP)}>→</button>
        <button type="button" className="btn btn--ghost" data-testid="breakout-restart" onClick={() => resetStage(stage)}>
          {strings.restart}
        </button>
        <button
          type="button"
          className="btn btn--ghost"
          data-testid="breakout-restart-run"
          onClick={() => {
            setTotal(0);
            setStage(1);
            resetStage(1);
          }}
        >
          {strings.restartRun}
        </button>
      </div>
      <p className="breakout__hint">{strings.hint}</p>
    </section>
  );
}
