/**
 * 乒乓球（canvas 重制版）。
 *
 * 契约遵循：
 *   - 默认导出组件，props 为 GameProps（seed / onWin / onStage）
 *   - 键盘经 useKeyControls；触屏用指针事件与屏幕按钮
 *   - 赢一局 saveBestScore('pong', 累计分) 并由外壳撒花；关卡自动进阶
 *   - 用户可见文案走模块内 i18n 资源（strings.ts）
 *
 * 渲染：逐帧状态放在 ref 里由 requestAnimationFrame 驱动 canvas（与印加弹珠同一套路），
 * React 只在比分/关卡/状态变化时重渲染。球桌、球拍、球都按左上 45° 打光并投影；
 * 丢球之后停 1 秒再发球，给玩家一个回位的呼吸。
 */
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import type { PointerEvent as ReactPointerEvent } from 'react';
import type { GameProps } from '../../core/types';
import { useKeyControls } from '../../core/input';
import { saveBestScore } from '../../core/bestScore';
import { playCue } from '../../core/audio';
import { useAutoAdvance, useStageReport } from '../../core/stage';
import { useI18n } from '../../core/i18n';
import { pongStrings } from './strings';
import './pong.css';

/** 球桌逻辑尺寸（世界单位），渲染层等比缩放。 */
export const TABLE_W = 100;
export const TABLE_H = 58;
const PADDLE_W = 2.4;
const PADDLE_H = 13;
/** 两侧球拍中心线到桌边的距离。 */
const PADDLE_X = 6;
const BALL_R = 1.6;
/** 先得几分算赢一局。 */
export const WIN_SCORE = 5;
/** 丢球后重新发球的等待（秒）。 */
export const SERVE_DELAY = 1;
/** 光照方向（左上 45°）：高光偏左上，投影落右下。 */
const LIGHT = { x: -0.4, y: -0.45 };

/** 第 stage 关的球速与 CPU 跟球速度（世界单位/秒）。 */
export function ballSpeedForStage(stage: number): number {
  return 42 + Math.max(0, stage - 1) * 5;
}
export function cpuSpeedForStage(stage: number): number {
  return Math.min(78, 34 + Math.max(0, stage - 1) * 6);
}

export interface PongState {
  playerY: number;
  cpuY: number;
  ballX: number;
  ballY: number;
  vx: number;
  vy: number;
  player: number;
  cpu: number;
  won: boolean;
  /** 发球倒计时（秒），大于 0 时球停在中线不动。 */
  serveIn: number;
  /** 发球方向：-1 发向玩家、1 发向 CPU。 */
  serveDir: number;
}

export function createState(stage: number, serveDir = -1): PongState {
  return {
    playerY: TABLE_H / 2 - PADDLE_H / 2,
    cpuY: TABLE_H / 2 - PADDLE_H / 2,
    ballX: TABLE_W / 2,
    ballY: TABLE_H / 2,
    vx: ballSpeedForStage(stage) * serveDir,
    vy: 0,
    player: 0,
    cpu: 0,
    won: false,
    serveIn: SERVE_DELAY,
    serveDir,
  };
}

/** 球拍与球的碰撞：命中点越靠边，回球角度越大。 */
function bounceOffPaddle(
  state: PongState,
  paddleY: number,
  direction: number,
  speed: number,
): PongState {
  const hit = (state.ballY - (paddleY + PADDLE_H / 2)) / (PADDLE_H / 2);
  const angle = Math.max(-0.8, Math.min(0.8, hit)) * 0.9;
  return {
    ...state,
    vx: Math.cos(angle) * speed * direction,
    vy: Math.sin(angle) * speed,
  };
}

/** 推进一帧（纯函数，便于推理与单测）。 */
export function stepPong(state: PongState, dt: number, stage: number): PongState {
  if (state.won) return state;
  const speed = ballSpeedForStage(stage);

  // CPU 追球（发球等待期间回中位）
  const cpuTarget = state.serveIn > 0 ? TABLE_H / 2 - PADDLE_H / 2 : state.ballY - PADDLE_H / 2;
  const cpuStep = cpuSpeedForStage(stage) * dt;
  const cpuDelta = Math.max(-cpuStep, Math.min(cpuStep, cpuTarget - state.cpuY));
  const cpuY = Math.max(0, Math.min(TABLE_H - PADDLE_H, state.cpuY + cpuDelta));

  if (state.serveIn > 0) {
    const serveIn = state.serveIn - dt;
    if (serveIn > 0) return { ...state, cpuY, serveIn };
    // 发球：从中线朝上一次丢球的一方推出去
    return {
      ...state,
      cpuY,
      serveIn: 0,
      ballX: TABLE_W / 2,
      ballY: TABLE_H / 2,
      vx: speed * state.serveDir,
      vy: (state.serveDir > 0 ? 1 : -1) * speed * 0.22,
    };
  }

  let ballX = state.ballX + state.vx * dt;
  let ballY = state.ballY + state.vy * dt;
  let vy = state.vy;
  const previousX = state.ballX;

  // 上下边框反弹
  if (ballY < BALL_R) {
    ballY = BALL_R;
    vy = Math.abs(vy);
  } else if (ballY > TABLE_H - BALL_R) {
    ballY = TABLE_H - BALL_R;
    vy = -Math.abs(vy);
  }

  let next: PongState = { ...state, cpuY, ballX, ballY, vy };

  // 球拍：只在越过拍面那一帧判定，避免高速穿透
  const playerPlane = PADDLE_X + PADDLE_W / 2 + BALL_R;
  if (previousX > playerPlane && ballX <= playerPlane) {
    if (ballY >= state.playerY - BALL_R && ballY <= state.playerY + PADDLE_H + BALL_R) {
      next = bounceOffPaddle({ ...next, ballX: playerPlane }, state.playerY, 1, speed);
      playCue('bounce');
    }
  }
  const cpuPlane = TABLE_W - PADDLE_X - PADDLE_W / 2 - BALL_R;
  if (previousX < cpuPlane && ballX >= cpuPlane) {
    if (ballY >= cpuY - BALL_R && ballY <= cpuY + PADDLE_H + BALL_R) {
      next = bounceOffPaddle({ ...next, ballX: cpuPlane }, cpuY, -1, speed);
      playCue('bounce');
    }
  }

  // 出界：记分，停 SERVE_DELAY 秒再发球
  if (next.ballX < -BALL_R || next.ballX > TABLE_W + BALL_R) {
    const conceded = next.ballX < 0;
    const player = conceded ? state.player : state.player + 1;
    const cpu = conceded ? state.cpu + 1 : state.cpu;
    playCue(conceded ? 'miss' : 'point');
    const won = player >= WIN_SCORE || cpu >= WIN_SCORE;
    return {
      ...next,
      player,
      cpu,
      won,
      ballX: TABLE_W / 2,
      ballY: TABLE_H / 2,
      vx: 0,
      vy: 0,
      serveIn: won ? 0 : SERVE_DELAY,
      serveDir: conceded ? -1 : 1,
    };
  }

  return next;
}

/** 画一帧：球桌 → 球网 → 影子 → 球拍与球。 */
function draw(
  canvas: HTMLCanvasElement,
  context: CanvasRenderingContext2D,
  state: PongState,
): void {
  const ratio = window.devicePixelRatio || 1;
  const width = canvas.clientWidth || TABLE_W;
  const height = (width * TABLE_H) / TABLE_W;
  const pixelW = Math.max(1, Math.round(width * ratio));
  const pixelH = Math.max(1, Math.round(height * ratio));
  if (canvas.width !== pixelW || canvas.height !== pixelH) {
    canvas.width = pixelW;
    canvas.height = pixelH;
  }
  const scale = pixelW / TABLE_W;
  context.setTransform(scale, 0, 0, scale, 0, 0);
  context.clearRect(0, 0, TABLE_W, TABLE_H);

  // 桌面：深绿毛毡，左上偏亮、右下压暗
  const felt = context.createLinearGradient(0, 0, TABLE_W, TABLE_H);
  felt.addColorStop(0, '#1f7a51');
  felt.addColorStop(0.55, '#17603f');
  felt.addColorStop(1, '#0f4a30');
  context.fillStyle = felt;
  context.fillRect(0, 0, TABLE_W, TABLE_H);

  // 白色边线与中线
  context.strokeStyle = 'rgba(255, 255, 255, 0.85)';
  context.lineWidth = 0.7;
  context.strokeRect(1.6, 1.6, TABLE_W - 3.2, TABLE_H - 3.2);
  context.beginPath();
  context.moveTo(1.6, TABLE_H / 2);
  context.lineTo(TABLE_W - 1.6, TABLE_H / 2);
  context.strokeStyle = 'rgba(255, 255, 255, 0.32)';
  context.lineWidth = 0.4;
  context.stroke();

  // 球网：中线上一排竖栏 + 顶边高光
  const netX = TABLE_W / 2;
  context.fillStyle = 'rgba(8, 20, 15, 0.35)';
  context.fillRect(netX - 0.9, 0, 1.8, TABLE_H);
  context.strokeStyle = 'rgba(236, 245, 240, 0.5)';
  context.lineWidth = 0.2;
  for (let y = 1; y < TABLE_H; y += 2.2) {
    context.beginPath();
    context.moveTo(netX - 0.9, y);
    context.lineTo(netX + 0.9, y);
    context.stroke();
  }
  context.fillStyle = 'rgba(255, 255, 255, 0.9)';
  context.fillRect(netX - 1.1, 0, 2.2, 0.7);

  const paddle = (x: number, y: number, from: string, to: string): void => {
    // 影子落在背光侧
    context.fillStyle = 'rgba(0, 0, 0, 0.3)';
    context.beginPath();
    context.roundRect(x - LIGHT.x * 1.5, y - LIGHT.y * 1.5, PADDLE_W, PADDLE_H, PADDLE_W / 2);
    context.fill();

    const gradient = context.createLinearGradient(x, y, x + PADDLE_W, y + PADDLE_H);
    gradient.addColorStop(0, from);
    gradient.addColorStop(1, to);
    context.fillStyle = gradient;
    context.beginPath();
    context.roundRect(x, y, PADDLE_W, PADDLE_H, PADDLE_W / 2);
    context.fill();
    context.strokeStyle = 'rgba(255, 255, 255, 0.5)';
    context.lineWidth = 0.22;
    context.stroke();
  };

  paddle(PADDLE_X - PADDLE_W / 2, state.playerY, '#ffd9dd', '#d63b52');
  paddle(TABLE_W - PADDLE_X - PADDLE_W / 2, state.cpuY, '#d8e6ff', '#3559c7');

  // 球：发球等待期间在中线呼吸，提示马上要来
  const pulse = state.serveIn > 0 ? 0.55 + 0.45 * Math.sin(state.serveIn * 14) : 1;
  const radius = BALL_R * pulse;
  context.fillStyle = 'rgba(0, 0, 0, 0.32)';
  context.beginPath();
  context.ellipse(
    state.ballX - LIGHT.x * 1.9,
    state.ballY - LIGHT.y * 1.9,
    radius * 1.05,
    radius * 0.72,
    0,
    0,
    Math.PI * 2,
  );
  context.fill();

  const ball = context.createRadialGradient(
    state.ballX + LIGHT.x * radius * 0.9,
    state.ballY + LIGHT.y * radius * 0.9,
    radius * 0.1,
    state.ballX,
    state.ballY,
    radius,
  );
  ball.addColorStop(0, '#ffffff');
  ball.addColorStop(0.45, '#ffd98a');
  ball.addColorStop(1, '#e2952a');
  context.beginPath();
  context.arc(state.ballX, state.ballY, radius, 0, Math.PI * 2);
  context.fillStyle = ball;
  context.fill();
}

export default function PongGame({ seed, onWin, onStage }: GameProps) {
  const { locale } = useI18n();
  const strings = pongStrings(locale);
  // 种子只决定首发方向，玩法本身不依赖随机
  const startDir = useMemo(() => (seed !== undefined && seed.length % 2 === 1 ? 1 : -1), [seed]);

  const [stage, setStage] = useState(1);
  const [total, setTotal] = useState(0);
  const stateRef = useRef<PongState>(createState(1, startDir));
  const canvasRef = useRef<HTMLCanvasElement | null>(null);
  const contextRef = useRef<CanvasRenderingContext2D | null | undefined>(undefined);
  const stageRef = useRef(stage);
  const [view, setView] = useState({ player: 0, cpu: 0, won: false, serving: true });

  useEffect(() => {
    stageRef.current = stage;
  }, [stage]);

  useStageReport(onStage, {
    stage,
    score: total + view.player,
    label: `${view.player} : ${view.cpu}`,
  });
  useAutoAdvance(view.won && view.player > view.cpu, () => {
    setTotal((current) => current + view.player);
    setStage((current) => {
      const next = current + 1;
      stateRef.current = createState(next, -1);
      setView({ player: 0, cpu: 0, won: false, serving: true });
      return next;
    });
  });

  // 终局：赢了写累计分并撒花，输了给一声。
  useEffect(() => {
    if (!view.won) return;
    if (view.player > view.cpu) {
      saveBestScore('pong', total + view.player);
      playCue('win');
      onWin?.();
    } else {
      playCue('lose');
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [view.won]);

  // 主循环
  useEffect(() => {
    let frame = 0;
    let last = 0;
    const loop = (now: number): void => {
      const dt = last === 0 ? 0 : Math.min(1 / 20, (now - last) / 1000);
      last = now;
      const next = stepPong(stateRef.current, dt, stageRef.current);
      stateRef.current = next;
      const canvas = canvasRef.current;
      if (canvas) {
        if (contextRef.current === undefined) {
          try {
            contextRef.current = canvas.getContext('2d');
          } catch {
            contextRef.current = null;
          }
        }
        if (contextRef.current) draw(canvas, contextRef.current, next);
        // 位置也挂到 data-* 上：e2e 不用去猜 canvas 像素
        canvas.dataset.playerY = next.playerY.toFixed(2);
        canvas.dataset.ballX = next.ballX.toFixed(2);
        canvas.dataset.ballY = next.ballY.toFixed(2);
        canvas.dataset.serving = next.serveIn > 0 ? 'true' : 'false';
      }
      setView((previous) =>
        previous.player === next.player &&
        previous.cpu === next.cpu &&
        previous.won === next.won &&
        previous.serving === next.serveIn > 0
          ? previous
          : { player: next.player, cpu: next.cpu, won: next.won, serving: next.serveIn > 0 },
      );
      frame = window.requestAnimationFrame(loop);
    };
    frame = window.requestAnimationFrame(loop);
    return () => window.cancelAnimationFrame(frame);
  }, []);

  const move = useCallback((delta: number) => {
    const current = stateRef.current;
    stateRef.current = {
      ...current,
      playerY: Math.max(0, Math.min(TABLE_H - PADDLE_H, current.playerY + delta)),
    };
  }, []);

  useKeyControls(
    [
      { key: 'ArrowUp', onDown: () => move(-4), preventDefault: true, allowRepeat: true },
      { key: 'ArrowDown', onDown: () => move(4), preventDefault: true, allowRepeat: true },
      { key: 'w', onDown: () => move(-4), allowRepeat: true },
      { key: 's', onDown: () => move(4), allowRepeat: true },
    ],
    [move],
  );

  const handlePointer = (event: ReactPointerEvent<HTMLCanvasElement>): void => {
    const rect = event.currentTarget.getBoundingClientRect();
    if (rect.height === 0) return;
    const y = ((event.clientY - rect.top) / rect.height) * TABLE_H - PADDLE_H / 2;
    const current = stateRef.current;
    stateRef.current = { ...current, playerY: Math.max(0, Math.min(TABLE_H - PADDLE_H, y)) };
  };

  const restartMatch = (): void => {
    playCue('select');
    stateRef.current = createState(stageRef.current, -1);
    setView({ player: 0, cpu: 0, won: false, serving: true });
  };

  const restartRun = (): void => {
    playCue('select');
    setTotal(0);
    setStage(1);
    stateRef.current = createState(1, -1);
    setView({ player: 0, cpu: 0, won: false, serving: true });
  };

  const status = view.won
    ? view.player > view.cpu
      ? strings.statusWon
      : strings.statusLost
    : view.serving
      ? strings.statusServing
      : strings.status;

  return (
    <section className="pong" data-testid="pong-game">
      <div className="pong__bar">
        <strong data-testid="pong-score">
          {strings.score}: {view.player} – {view.cpu}
        </strong>
        <span data-testid="pong-stage">
          {strings.stageLabel} {stage}
        </span>
        <span data-testid="pong-total">
          {strings.totalLabel}: {total + view.player}
        </span>
        <span className="pong__status" data-testid="pong-status">
          {status}
        </span>
      </div>

      <canvas
        ref={canvasRef}
        className="pong__court"
        data-testid="pong-court"
        role="img"
        aria-label={strings.courtLabel}
        onPointerMove={handlePointer}
        onPointerDown={handlePointer}
      />

      <div className="pong__controls">
        <button type="button" className="btn" onClick={() => move(-6)}>
          {strings.up}
        </button>
        <button type="button" className="btn" onClick={() => move(6)}>
          {strings.down}
        </button>
        <button
          type="button"
          className="btn btn--ghost"
          data-testid="pong-restart"
          onClick={restartMatch}
        >
          {strings.restart}
        </button>
        <button
          type="button"
          className="btn btn--ghost"
          data-testid="pong-restart-run"
          onClick={restartRun}
        >
          {strings.restartRun}
        </button>
      </div>
      <p className="pong__hint">{strings.controls}</p>
    </section>
  );
}
