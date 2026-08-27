/**
 * 印加弹珠（Zuma 玩法）。
 *
 * 契约遵循：
 *   - 默认导出组件，props 为 GameProps（{ seed?: string }）
 *   - 键盘经 useKeyControls（卸载自动清理）；触屏/鼠标用指针事件 + 屏幕按钮
 *   - 终局时 saveBestScore('marble', score)，外壳徽章订阅展示
 *   - 随机仅经 createRng（见 engine.ts），同一基准种子下第 N 局完全可复现；
 *     未指定 `?seed=` 时每次进入取一次性熵种子，重开则局数 +1
 *   - 用户可见文案走模块内 i18n 资源（strings.ts），不硬编码在视图
 *
 * 渲染策略：逐帧状态放在 ref 里由 requestAnimationFrame 驱动 canvas，
 * React 只在 HUD 数值（得分/连锁/剩余/弹药/状态）变化时重渲染，避免每帧 setState。
 */
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import type { CSSProperties, PointerEvent as ReactPointerEvent } from 'react';
import type { GameProps } from '../../core/types';
import { useI18n } from '../../core/i18n';
import { useKeyControls } from '../../core/input';
import { saveBestScore } from '../../core/bestScore';
import { entropySeed } from '../../core/rng';
import { MARBLE_COLORS, marbleStrings } from './strings';
import type { MarbleStrings } from './strings';
import {
  BALL_RADIUS,
  DEFAULT_LEVEL,
  FIELD,
  LEVELS,
  PATH_LENGTH,
  SHOOTER,
  SPACING,
  aimAt,
  createInitialState,
  pointAt,
  restart,
  scoreFor,
  shoot,
  step,
  swapAmmo,
  trackPoints,
} from './engine';
import type { MarbleState, MarbleStatus } from './engine';
import './marble.css';

/** 单帧最大时间步长（秒）：切后台回来时不要一次性把链条推很远。 */
const MAX_DT = 1 / 20;
/** 键盘每次瞄准的角度增量（弧度）。 */
const AIM_STEP = 0.09;

const LEVEL_LABEL_KEY: readonly (keyof MarbleStrings)[] = ['levelEasy', 'levelMedium', 'levelHard'];

interface Hud {
  score: number;
  combo: number;
  remaining: number;
  loaded: number;
  next: number;
  status: MarbleStatus;
}

function toHud(state: MarbleState): Hud {
  return {
    score: state.score,
    combo: state.combo,
    remaining: state.supply.length + state.balls.length,
    loaded: state.loaded,
    next: state.next,
    status: state.status,
  };
}

function sameHud(a: Hud, b: Hud): boolean {
  return (
    a.score === b.score &&
    a.combo === b.combo &&
    a.remaining === b.remaining &&
    a.loaded === b.loaded &&
    a.next === b.next &&
    a.status === b.status
  );
}

function colorOf(color: number): string {
  return MARBLE_COLORS[color % MARBLE_COLORS.length] as string;
}

/** 画一帧：轨道 → 洞口 → 链条 → 飞行弹珠 → 发射器与准星。 */
function draw(
  canvas: HTMLCanvasElement,
  context: CanvasRenderingContext2D,
  state: MarbleState,
): void {
  const ratio = window.devicePixelRatio || 1;
  const size = canvas.clientWidth || FIELD;
  const pixels = Math.max(1, Math.round(size * ratio));
  if (canvas.width !== pixels || canvas.height !== pixels) {
    canvas.width = pixels;
    canvas.height = pixels;
  }
  const scale = pixels / FIELD;
  context.setTransform(scale, 0, 0, scale, 0, 0);
  context.clearRect(0, 0, FIELD, FIELD);

  // 轨道
  const points = trackPoints();
  context.beginPath();
  points.forEach((point, index) => {
    if (index === 0) context.moveTo(point.x, point.y);
    else context.lineTo(point.x, point.y);
  });
  context.strokeStyle = '#1b2437';
  context.lineWidth = SPACING + 1.6;
  context.lineCap = 'round';
  context.lineJoin = 'round';
  context.stroke();

  // 洞口
  const hole = pointAt(PATH_LENGTH);
  context.beginPath();
  context.arc(hole.x, hole.y, BALL_RADIUS * 1.6, 0, Math.PI * 2);
  context.fillStyle = '#05070d';
  context.fill();
  context.strokeStyle = '#39435c';
  context.lineWidth = 0.8;
  context.stroke();

  // 链条
  for (const ball of state.balls) {
    const center = pointAt(ball.dist);
    context.beginPath();
    context.arc(center.x, center.y, BALL_RADIUS, 0, Math.PI * 2);
    context.fillStyle = colorOf(ball.color);
    context.fill();
    context.beginPath();
    context.arc(center.x - BALL_RADIUS * 0.3, center.y - BALL_RADIUS * 0.3, BALL_RADIUS * 0.35, 0, Math.PI * 2);
    context.fillStyle = 'rgba(255, 255, 255, 0.45)';
    context.fill();
  }

  // 飞行中的弹珠
  for (const shot of state.shots) {
    context.beginPath();
    context.arc(shot.x, shot.y, BALL_RADIUS, 0, Math.PI * 2);
    context.fillStyle = colorOf(shot.color);
    context.fill();
  }

  // 准星
  context.beginPath();
  context.moveTo(SHOOTER.x, SHOOTER.y);
  context.lineTo(
    SHOOTER.x + Math.cos(state.angle) * FIELD,
    SHOOTER.y + Math.sin(state.angle) * FIELD,
  );
  context.strokeStyle = 'rgba(238, 241, 246, 0.22)';
  context.lineWidth = 0.6;
  context.setLineDash([2, 3]);
  context.stroke();
  context.setLineDash([]);

  // 发射器：外圈 + 当前弹珠 + 下一颗
  context.beginPath();
  context.arc(SHOOTER.x, SHOOTER.y, BALL_RADIUS * 2.1, 0, Math.PI * 2);
  context.fillStyle = '#171d2e';
  context.fill();
  context.strokeStyle = '#39435c';
  context.lineWidth = 0.8;
  context.stroke();
  context.beginPath();
  context.arc(SHOOTER.x, SHOOTER.y, BALL_RADIUS, 0, Math.PI * 2);
  context.fillStyle = colorOf(state.loaded);
  context.fill();
  context.beginPath();
  context.arc(SHOOTER.x + BALL_RADIUS * 2.6, SHOOTER.y + BALL_RADIUS * 2.6, BALL_RADIUS * 0.7, 0, Math.PI * 2);
  context.fillStyle = colorOf(state.next);
  context.fill();
}

export default function MarbleGame({ seed }: GameProps) {
  const { locale } = useI18n();
  const strings = marbleStrings(locale);

  // 未显式指定种子时，本次进入游戏用一次性熵种子。
  const baseSeed = useMemo(() => seed ?? entropySeed('marble'), [seed]);

  const [level, setLevel] = useState<number>(DEFAULT_LEVEL);
  const stateRef = useRef<MarbleState>(createInitialState(DEFAULT_LEVEL, baseSeed));
  const canvasRef = useRef<HTMLCanvasElement | null>(null);
  // 2D 上下文只取一次：取不到（如 jsdom）就此关掉绘制，主循环照跑不误。
  const contextRef = useRef<CanvasRenderingContext2D | null | undefined>(undefined);
  const scoredRef = useRef(false);
  const [hud, setHud] = useState<Hud>(() => toHud(stateRef.current));

  const reset = useCallback(
    (nextLevel: number) => {
      stateRef.current = createInitialState(nextLevel, baseSeed);
      scoredRef.current = false;
      setHud(toHud(stateRef.current));
    },
    [baseSeed],
  );

  // 关卡或种子变化时重开一局。
  useEffect(() => {
    reset(level);
  }, [level, reset]);

  // 主循环：推进引擎 → 画帧 → HUD 变化才触发 React 重渲染。
  useEffect(() => {
    let frame = 0;
    let last = 0;
    const loop = (now: number): void => {
      const dt = last === 0 ? 0 : Math.min(MAX_DT, (now - last) / 1000);
      last = now;
      const next = step(stateRef.current, dt);
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
      }
      const snapshot = toHud(next);
      setHud((previous) => (sameHud(previous, snapshot) ? previous : snapshot));
      if ((next.status === 'won' || next.status === 'lost') && !scoredRef.current) {
        scoredRef.current = true;
        saveBestScore('marble', scoreFor(next));
      }
      frame = window.requestAnimationFrame(loop);
    };
    frame = window.requestAnimationFrame(loop);
    return () => window.cancelAnimationFrame(frame);
  }, []);

  const aimBy = useCallback((delta: number) => {
    const current = stateRef.current;
    const angle = current.angle + delta;
    stateRef.current = { ...current, angle };
  }, []);

  const fire = useCallback(() => {
    stateRef.current = shoot(stateRef.current);
    setHud(toHud(stateRef.current));
  }, []);

  const swap = useCallback(() => {
    stateRef.current = swapAmmo(stateRef.current);
    setHud(toHud(stateRef.current));
  }, []);

  useKeyControls(
    [
      { key: 'ArrowLeft', onDown: () => aimBy(-AIM_STEP), preventDefault: true, allowRepeat: true },
      { key: 'ArrowRight', onDown: () => aimBy(AIM_STEP), preventDefault: true, allowRepeat: true },
      { key: ' ', onDown: () => fire(), preventDefault: true },
      { key: 's', onDown: () => swap() },
      { key: 'S', onDown: () => swap() },
    ],
    [aimBy, fire, swap],
  );

  const handlePointer = (event: ReactPointerEvent<HTMLCanvasElement>): void => {
    const rect = event.currentTarget.getBoundingClientRect();
    if (rect.width === 0 || rect.height === 0) return;
    const x = ((event.clientX - rect.left) / rect.width) * FIELD;
    const y = ((event.clientY - rect.top) / rect.height) * FIELD;
    stateRef.current = aimAt(stateRef.current, x, y);
  };

  const statusText: Record<MarbleStatus, string> = {
    idle: strings.statusIdle,
    playing: strings.statusPlaying,
    won: strings.statusWon,
    lost: strings.statusLost,
  };

  return (
    <section className="marble" data-testid="marble-game">
      <div className="marble__bar">
        <span className="marble__stat" data-testid="marble-score">
          {strings.score}:<b data-testid="marble-score-value">{hud.score}</b>
        </span>
        <span className="marble__stat" data-testid="marble-combo">
          {strings.combo}:<b>×{hud.combo}</b>
        </span>
        <span className="marble__stat" data-testid="marble-remaining">
          {strings.remaining}:<b>{hud.remaining}</b>
        </span>
        <span className="marble__ammo" data-testid="marble-ammo" aria-hidden="true">
          <i className="marble__chip" style={{ background: colorOf(hud.loaded) } as CSSProperties} />
          <i
            className="marble__chip marble__chip--next"
            style={{ background: colorOf(hud.next) } as CSSProperties}
          />
        </span>
        <span className="marble__status" data-testid="marble-status">
          {statusText[hud.status]}
        </span>
      </div>

      <div className="marble__tools" data-testid="marble-tools">
        <span>{strings.levelLabel}:</span>
        {LEVELS.map((option, index) => (
          <button
            key={option.id}
            type="button"
            className="btn btn--ghost"
            data-testid={`marble-level-${option.id}`}
            aria-pressed={level === index}
            onClick={() => setLevel(index)}
          >
            {strings[LEVEL_LABEL_KEY[index] ?? 'levelEasy']}
          </button>
        ))}
        <button type="button" className="btn" data-testid="marble-restart" onClick={() => {
          stateRef.current = restart(stateRef.current);
          scoredRef.current = false;
          setHud(toHud(stateRef.current));
        }}>
          {strings.restart}
        </button>
      </div>

      <canvas
        ref={canvasRef}
        className="marble__field"
        data-testid="marble-field"
        aria-label={strings.fieldLabel}
        role="img"
        onPointerMove={handlePointer}
        onPointerDown={(event) => {
          handlePointer(event);
          fire();
        }}
      />

      <div className="marble__pad" data-testid="marble-pad">
        <button type="button" className="btn" data-testid="marble-aim-left" onClick={() => aimBy(-AIM_STEP * 3)}>
          {strings.aimLeft}
        </button>
        <button type="button" className="btn" data-testid="marble-shoot" onClick={fire}>
          {strings.shoot}
        </button>
        <button type="button" className="btn" data-testid="marble-swap" onClick={swap}>
          {strings.swap}
        </button>
        <button type="button" className="btn" data-testid="marble-aim-right" onClick={() => aimBy(AIM_STEP * 3)}>
          {strings.aimRight}
        </button>
      </div>

      <p className="marble__help" data-testid="marble-help">
        {strings.help}
      </p>
    </section>
  );
}
