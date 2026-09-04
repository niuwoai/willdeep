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
import { playCue } from '../../core/audio';
import { MARBLE_COLORS, marbleStrings } from './strings';
import { useAutoAdvance, useStageReport } from '../../core/stage';
import {
  BALL_RADIUS,
  EFFECT_SECONDS,
  FIELD,
  SHOOTER,
  SPACING,
  aimAt,
  configOf,
  createInitialState,
  levelForStage,
  pathLength,
  pointAt,
  restart,
  scoreFor,
  shoot,
  step,
  swapAmmo,
  tangentAt,
  trackPoints,
} from './engine';
import type { MarbleState, MarbleStatus, Vec } from './engine';
import './marble.css';

/** 单帧最大时间步长（秒）：切后台回来时不要一次性把链条推很远。 */
const MAX_DT = 1 / 20;
/** 键盘每次瞄准的角度增量（弧度）。 */
const AIM_STEP = 0.09;

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

/** 光从左上方 45° 打过来：高光偏左上，阴影落右下。 */
const LIGHT = { x: -0.42, y: -0.45 };
/** 弹珠精灵的贴图边长（像素）：一次画好、之后只做缩放贴图，省掉逐帧渐变。 */
const SPRITE_SIZE = 96;

const spriteCache = new Map<number, HTMLCanvasElement>();

/** 取（或生成）某个颜色的球体精灵：底色 + 高光 + 暗边，自带立体感。 */
function marbleSprite(color: number): HTMLCanvasElement | null {
  const cached = spriteCache.get(color);
  if (cached) return cached;
  if (typeof document === 'undefined') return null;
  const canvas = document.createElement('canvas');
  canvas.width = SPRITE_SIZE;
  canvas.height = SPRITE_SIZE;
  let context: CanvasRenderingContext2D | null = null;
  try {
    context = canvas.getContext('2d');
  } catch {
    context = null;
  }
  if (!context) return null;

  const radius = SPRITE_SIZE / 2;
  const base = colorOf(color);
  const gradient = context.createRadialGradient(
    radius + LIGHT.x * radius * 0.9,
    radius + LIGHT.y * radius * 0.9,
    radius * 0.08,
    radius,
    radius,
    radius,
  );
  gradient.addColorStop(0, '#ffffff');
  gradient.addColorStop(0.18, base);
  gradient.addColorStop(0.82, base);
  gradient.addColorStop(1, 'rgba(0, 0, 0, 0.55)');
  context.beginPath();
  context.arc(radius, radius, radius * 0.98, 0, Math.PI * 2);
  context.fillStyle = gradient;
  context.fill();

  // 迎光面的小高光点，让球看起来是「亮面材质」
  context.beginPath();
  context.ellipse(
    radius + LIGHT.x * radius * 1.05,
    radius + LIGHT.y * radius * 1.05,
    radius * 0.26,
    radius * 0.18,
    -Math.PI / 4,
    0,
    Math.PI * 2,
  );
  context.fillStyle = 'rgba(255, 255, 255, 0.75)';
  context.fill();

  // 背光侧的暗环，压住轮廓
  context.beginPath();
  context.arc(radius, radius, radius * 0.96, 0, Math.PI * 2);
  context.strokeStyle = 'rgba(0, 0, 0, 0.28)';
  context.lineWidth = radius * 0.08;
  context.stroke();

  spriteCache.set(color, canvas);
  return canvas;
}

/** 画一颗球：先落地阴影（背光方向），再贴球体精灵。 */
function drawMarble(
  context: CanvasRenderingContext2D,
  center: Vec,
  color: number,
  scale = 1,
): void {
  const radius = BALL_RADIUS * scale;
  context.beginPath();
  context.ellipse(
    center.x - LIGHT.x * radius * 0.75,
    center.y - LIGHT.y * radius * 0.75,
    radius * 0.95,
    radius * 0.72,
    0,
    0,
    Math.PI * 2,
  );
  context.fillStyle = 'rgba(0, 0, 0, 0.38)';
  context.fill();

  const sprite = marbleSprite(color);
  if (sprite) {
    context.drawImage(sprite, center.x - radius, center.y - radius, radius * 2, radius * 2);
    return;
  }
  context.beginPath();
  context.arc(center.x, center.y, radius, 0, Math.PI * 2);
  context.fillStyle = colorOf(color);
  context.fill();
}

/** 洞口金环：平时的呼吸节拍与幅度（弧度/秒、相对洞口半径）。 */
const RING_CALM_RATE = 2.1;
const RING_CALM_SWELL = 0.14;
/** 危险冲刺时：呼吸更急、张得更大。 */
const RING_DANGER_RATE = 9.5;
const RING_DANGER_SWELL = 0.24;
/** 金环基准半径（相对洞口半径）：涨到最大也要留在场地里，轨迹端点据此收边。 */
const RING_BASE = 1.52;

/** 洞口金环这一刻的呼吸相位（0 → 1）。 */
function ringBreath(time: number, danger: boolean): number {
  return 0.5 + 0.5 * Math.sin(time * (danger ? RING_DANGER_RATE : RING_CALM_RATE));
}

/**
 * 洞口金环这一刻的半径：纯函数，单测据此核对呼吸幅度与「涨到最大也不出界」。
 * radius 传洞口半径，返回值是金环半径。
 */
export function holeRingRadius(radius: number, time: number, danger: boolean): number {
  const swell = danger ? RING_DANGER_SWELL : RING_CALM_SWELL;
  return radius * (RING_BASE + swell * ringBreath(time, danger));
}

/** 金环涨到最大时的半径（危险冲刺那一档），轨迹端点要按它留边。 */
export const HOLE_RING_MAX = RING_BASE + RING_DANGER_SWELL;

/**
 * 洞口外的金环：半径随时间一涨一缩地呼吸，像洞口在喘气。
 * 队首弹珠冲进危险区时呼吸骤然加快、张得更大，配合警报音提示「要掉了」。
 */
function drawHoleRing(
  context: CanvasRenderingContext2D,
  center: Vec,
  radius: number,
  time: number,
  danger: boolean,
): void {
  const breath = ringBreath(time, danger);
  const ring = holeRingRadius(radius, time, danger);

  // 外圈晕光：跟着一起胀缩，让金环看起来在发热而不是一条硬线
  const halo = context.createRadialGradient(center.x, center.y, ring * 0.72, center.x, center.y, ring * 1.32);
  halo.addColorStop(0, 'rgba(255, 214, 118, 0)');
  halo.addColorStop(0.55, `rgba(255, 214, 118, ${(danger ? 0.34 : 0.2) * (0.45 + 0.55 * breath)})`);
  halo.addColorStop(1, 'rgba(255, 214, 118, 0)');
  context.beginPath();
  context.arc(center.x, center.y, ring * 1.32, 0, Math.PI * 2);
  context.fillStyle = halo;
  context.fill();

  const gold = context.createLinearGradient(
    center.x - ring,
    center.y - ring,
    center.x + ring,
    center.y + ring,
  );
  gold.addColorStop(0, '#fff2c4');
  gold.addColorStop(0.45, '#e8b84a');
  gold.addColorStop(1, '#8a5d16');
  context.beginPath();
  context.arc(center.x, center.y, ring, 0, Math.PI * 2);
  context.lineWidth = radius * (danger ? 0.3 : 0.2) * (0.8 + 0.4 * breath);
  context.strokeStyle = gold;
  context.stroke();
}

/** 洞口的黄金浮雕骷髅：一眼就知道珠子滚到这儿就结束了。 */
function drawSkull(context: CanvasRenderingContext2D, center: Vec, radius: number): void {
  const gold = context.createLinearGradient(
    center.x - radius,
    center.y - radius,
    center.x + radius,
    center.y + radius,
  );
  gold.addColorStop(0, '#ffe9a8');
  gold.addColorStop(0.35, '#e8b84a');
  gold.addColorStop(0.7, '#a9761f');
  gold.addColorStop(1, '#6d4711');

  // 洞：先挖一圈黑，再镶金环
  context.beginPath();
  context.arc(center.x, center.y, radius * 1.28, 0, Math.PI * 2);
  context.fillStyle = '#05070d';
  context.fill();
  context.lineWidth = radius * 0.26;
  context.strokeStyle = gold;
  context.stroke();

  // 头骨轮廓
  context.save();
  context.translate(center.x, center.y);
  context.beginPath();
  context.moveTo(-radius * 0.72, -radius * 0.1);
  context.bezierCurveTo(-radius * 0.78, -radius * 0.95, radius * 0.78, -radius * 0.95, radius * 0.72, -radius * 0.1);
  context.bezierCurveTo(radius * 0.7, radius * 0.42, radius * 0.42, radius * 0.5, radius * 0.34, radius * 0.52);
  context.lineTo(-radius * 0.34, radius * 0.52);
  context.bezierCurveTo(-radius * 0.42, radius * 0.5, -radius * 0.7, radius * 0.42, -radius * 0.72, -radius * 0.1);
  context.closePath();
  context.fillStyle = gold;
  context.fill();
  // 浮雕感：迎光面提亮描边
  context.strokeStyle = 'rgba(255, 245, 210, 0.65)';
  context.lineWidth = radius * 0.07;
  context.stroke();

  // 眼窝与鼻腔（凹陷用黑 + 内侧一点反光）
  context.fillStyle = '#0a0c12';
  for (const sign of [-1, 1]) {
    context.beginPath();
    context.ellipse(sign * radius * 0.32, -radius * 0.24, radius * 0.24, radius * 0.27, 0, 0, Math.PI * 2);
    context.fill();
  }
  context.beginPath();
  context.moveTo(0, radius * 0.02);
  context.lineTo(radius * 0.13, radius * 0.26);
  context.lineTo(-radius * 0.13, radius * 0.26);
  context.closePath();
  context.fill();

  // 牙
  context.fillStyle = 'rgba(10, 12, 18, 0.85)';
  for (let i = -2; i <= 2; i += 1) {
    context.fillRect(i * radius * 0.16 - radius * 0.05, radius * 0.34, radius * 0.1, radius * 0.18);
  }
  context.restore();
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
  const track = configOf(state).track;
  const currentPathLength = pathLength(track);
  const points = trackPoints(track);
  context.beginPath();
  points.forEach((point, index) => {
    if (index === 0) context.moveTo(point.x, point.y);
    else context.lineTo(point.x, point.y);
  });
  context.lineCap = 'round';
  context.lineJoin = 'round';
  // 槽壁：先画一圈偏亮的外沿，再压上暗色槽底，形成凹槽的立体感
  context.strokeStyle = '#2b3650';
  context.lineWidth = SPACING + 3.4;
  context.stroke();
  context.strokeStyle = '#141b2b';
  context.lineWidth = SPACING + 1.2;
  context.stroke();

  // 洞口：黄金浮雕骷髅，珠子滚到这儿就是终局
  const hole = pointAt(currentPathLength, track);
  drawHoleRing(context, hole, BALL_RADIUS * 1.75, state.time, state.danger);
  drawSkull(context, hole, BALL_RADIUS * 1.75);

  // 链条（带道具的珠子额外画标记：炸弹是深色芯 + 引信，闪光是脉动白环 + 回退箭头）
  const pulse = 0.55 + 0.45 * Math.sin(state.time * 7);
  for (const ball of state.balls) {
    if (ball.dist < 0) continue; // 还在入口隧道里，尚未露头
    const center = pointAt(ball.dist, track);
    // 快到洞口的珠子按距离缩小，看起来是被骷髅一口口吞下去
    const remain = currentPathLength - ball.dist;
    const scale = remain < SPACING * 1.6 ? Math.max(0.15, remain / (SPACING * 1.6)) : 1;
    drawMarble(context, center, ball.color, scale);
    if (scale > 0.7) {
      if (ball.power === 'bomb') drawBomb(context, center, pulse);
      else if (ball.power === 'reverse') drawFlash(context, center, pulse, tangentAt(ball.dist, track));
    }
  }

  // 飞行中的弹珠
  for (const shot of state.shots) {
    drawMarble(context, { x: shot.x, y: shot.y }, shot.color);
  }

  // 一次性特效：爆炸是橙色扩散圈，倒流是白色收缩圈
  for (const effect of state.effects) {
    const remain = Math.max(0, Math.min(1, (effect.until - state.time) / EFFECT_SECONDS));
    const progress = 1 - remain;
    const radius = effect.kind === 'reverse'
      ? effect.radius * (1 - progress * 0.6)
      : BALL_RADIUS + (effect.radius - BALL_RADIUS) * progress;
    context.beginPath();
    context.arc(effect.x, effect.y, radius, 0, Math.PI * 2);
    context.strokeStyle = effect.kind === 'blast'
      ? `rgba(255, 168, 76, ${remain.toFixed(3)})`
      : effect.kind === 'combo'
        ? `rgba(255, 226, 128, ${remain.toFixed(3)})`
        : `rgba(226, 240, 255, ${remain.toFixed(3)})`;
    context.lineWidth = effect.kind === 'blast' ? 1.4 : effect.kind === 'combo' ? 1.1 : 1;
    context.stroke();
    if (effect.kind === 'combo') {
      // 星芒：四道向外甩的金色短线，表示「连锁成了」
      context.strokeStyle = `rgba(255, 244, 200, ${(remain * 0.9).toFixed(3)})`;
      context.lineWidth = 0.7;
      for (let spoke = 0; spoke < 8; spoke += 1) {
        const angle = (spoke / 8) * Math.PI * 2 + progress * 1.2;
        context.beginPath();
        context.moveTo(effect.x + Math.cos(angle) * radius * 0.75, effect.y + Math.sin(angle) * radius * 0.75);
        context.lineTo(effect.x + Math.cos(angle) * radius * 1.25, effect.y + Math.sin(angle) * radius * 1.25);
        context.stroke();
      }
    }
    if (effect.kind === 'blast') {
      context.beginPath();
      context.arc(effect.x, effect.y, radius * 0.55, 0, Math.PI * 2);
      context.fillStyle = `rgba(255, 214, 148, ${(remain * 0.35).toFixed(3)})`;
      context.fill();
    }
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
  drawMarble(context, SHOOTER, state.loaded);
  drawMarble(
    context,
    { x: SHOOTER.x + BALL_RADIUS * 2.6, y: SHOOTER.y + BALL_RADIUS * 2.6 },
    state.next,
    0.62,
  );
}

/** 炸弹标记：深色芯 + 顶上一点引信火花。 */
function drawBomb(context: CanvasRenderingContext2D, center: Vec, pulse: number): void {
  context.beginPath();
  context.arc(center.x, center.y, BALL_RADIUS * 0.58, 0, Math.PI * 2);
  context.fillStyle = '#12151f';
  context.fill();
  context.strokeStyle = `rgba(255, 214, 148, ${(0.5 + 0.5 * pulse).toFixed(3)})`;
  context.lineWidth = 0.45;
  context.stroke();
  context.beginPath();
  context.arc(center.x + BALL_RADIUS * 0.45, center.y - BALL_RADIUS * 0.45, BALL_RADIUS * 0.22, 0, Math.PI * 2);
  context.fillStyle = `rgba(255, 196, 92, ${(0.45 + 0.55 * pulse).toFixed(3)})`;
  context.fill();
}

/** 闪光标记：脉动白环 + 指向入口方向的回退箭头。 */
function drawFlash(
  context: CanvasRenderingContext2D,
  center: Vec,
  pulse: number,
  tangent: Vec,
): void {
  context.beginPath();
  context.arc(center.x, center.y, BALL_RADIUS * 0.92, 0, Math.PI * 2);
  context.strokeStyle = `rgba(255, 255, 255, ${(0.35 + 0.65 * pulse).toFixed(3)})`;
  context.lineWidth = 0.7;
  context.stroke();
  // 箭头朝链条前进方向的反向（也就是往回退的方向）
  const back = { x: -tangent.x, y: -tangent.y };
  const side = { x: -back.y, y: back.x };
  const tip = { x: center.x + back.x * BALL_RADIUS * 0.62, y: center.y + back.y * BALL_RADIUS * 0.62 };
  const baseX = center.x - back.x * BALL_RADIUS * 0.28;
  const baseY = center.y - back.y * BALL_RADIUS * 0.28;
  context.beginPath();
  context.moveTo(tip.x, tip.y);
  context.lineTo(baseX + side.x * BALL_RADIUS * 0.42, baseY + side.y * BALL_RADIUS * 0.42);
  context.lineTo(baseX - side.x * BALL_RADIUS * 0.42, baseY - side.y * BALL_RADIUS * 0.42);
  context.closePath();
  context.fillStyle = `rgba(255, 255, 255, ${(0.6 + 0.4 * pulse).toFixed(3)})`;
  context.fill();
}

export default function MarbleGame({ seed, onWin, onStage }: GameProps) {
  const { locale } = useI18n();
  const strings = marbleStrings(locale);

  // 未显式指定种子时，本次进入游戏用一次性熵种子。
  const baseSeed = useMemo(() => seed ?? entropySeed('marble'), [seed]);

  // 关卡阶梯：颜色/弹珠数/速度/道具数随关卡一路往上，没有上限。
  const [stage, setStage] = useState(1);
  const [total, setTotal] = useState(0);
  const stateRef = useRef<MarbleState>(createInitialState(levelForStage(1), `${baseSeed}@1`));
  const canvasRef = useRef<HTMLCanvasElement | null>(null);
  // 2D 上下文只取一次：取不到（如 jsdom）就此关掉绘制，主循环照跑不误。
  const contextRef = useRef<CanvasRenderingContext2D | null | undefined>(undefined);
  const scoredRef = useRef(false);
  const effectsRef = useRef(0);
  const chainsRef = useRef(0);
  // 危险冲刺的上一帧状态：只在「刚进危险区」那一下报警，不是每帧都叫
  const dangerRef = useRef(false);
  const [hud, setHud] = useState<Hud>(() => toHud(stateRef.current));
  // 主循环只建一次，回调用 ref 取最新的，避免把循环重挂
  const onWinRef = useRef(onWin);
  useEffect(() => {
    onWinRef.current = onWin;
  }, [onWin]);
  // 主循环里要读到最新的累计分（写最佳成绩用），走 ref 免得重挂循环
  const totalRef = useRef(0);
  useEffect(() => {
    totalRef.current = total;
  }, [total]);

  const reset = useCallback(
    (nextStage: number) => {
      stateRef.current = createInitialState(levelForStage(nextStage), `${baseSeed}@${nextStage}`);
      scoredRef.current = false;
      effectsRef.current = 0;
      chainsRef.current = 0;
      dangerRef.current = false;
      setHud(toHud(stateRef.current));
    },
    [baseSeed],
  );

  // 关卡或种子变化时重开一局。
  useEffect(() => {
    reset(stage);
  }, [stage, reset]);

  const config = levelForStage(stage);
  useStageReport(onStage, {
    stage,
    score: total + hud.score,
    label: `${config.colors} ${strings.colorsUnit} · ${strings.trackNames[config.track]}`,
  });
  // 通关后自动进入下一关；失败则停在原地等玩家按「重开」
  useAutoAdvance(hud.status === 'won', () => {
    setTotal((current) => current + stateRef.current.score);
    setStage((current) => current + 1);
  });

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
      // 新冒出来的特效各配一声（爆炸 / 倒流 / 连锁）
      if (next.effects.length > effectsRef.current) {
        const fresh = next.effects.slice(effectsRef.current);
        if (fresh.some((effect) => effect.kind === 'blast')) playCue('blast');
        if (fresh.some((effect) => effect.kind === 'reverse')) playCue('reverse');
      }
      effectsRef.current = next.effects.length;

      // 队首弹珠冲进危险区：报一次警，链条同时提速（见引擎 DANGER_SPEED）
      if (next.danger && !dangerRef.current) playCue('alarm');
      dangerRef.current = next.danger;

      // 断口撞在一起又消掉：庆祝一下（音效 + 外壳撒花）
      if (next.chains > chainsRef.current) {
        chainsRef.current = next.chains;
        playCue('match');
        onWinRef.current?.();
      }

      const snapshot = toHud(next);
      setHud((previous) => (sameHud(previous, snapshot) ? previous : snapshot));
      if ((next.status === 'won' || next.status === 'lost') && !scoredRef.current) {
        scoredRef.current = true;
        saveBestScore('marble', totalRef.current + scoreFor(next));
        if (next.status === 'won') {
          playCue('win');
          onWinRef.current?.();
        } else {
          playCue('lose');
        }
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
    const before = stateRef.current.shots.length;
    stateRef.current = shoot(stateRef.current);
    if (stateRef.current.shots.length > before) playCue('shoot');
    setHud(toHud(stateRef.current));
  }, []);

  const swap = useCallback(() => {
    stateRef.current = swapAmmo(stateRef.current);
    playCue('select');
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
    falling: strings.statusFalling,
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
        <span data-testid="marble-stage">
          {strings.stageLabel} {stage} · {config.colors} {strings.colorsUnit} · {strings.trackNames[config.track]}
        </span>
        <span data-testid="marble-total">
          {strings.totalLabel}: {total + hud.score}
        </span>
        <button type="button" className="btn" data-testid="marble-restart" onClick={() => {
          stateRef.current = restart(stateRef.current);
          scoredRef.current = false;
          effectsRef.current = 0;
          chainsRef.current = 0;
          dangerRef.current = false;
          playCue('select');
          setHud(toHud(stateRef.current));
        }}>
          {strings.restart}
        </button>
        <button
          type="button"
          className="btn btn--ghost"
          data-testid="marble-restart-run"
          onClick={() => {
            playCue('select');
            setTotal(0);
            if (stage === 1) reset(1);
            else setStage(1);
          }}
        >
          {strings.restartRun}
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

      <ul className="marble__legend" data-testid="marble-legend">
        <li>
          <i className="marble__mark marble__mark--bomb" aria-hidden="true" />
          {strings.legendBomb}
        </li>
        <li>
          <i className="marble__mark marble__mark--flash" aria-hidden="true" />
          {strings.legendReverse}
        </li>
      </ul>

      <p className="marble__help" data-testid="marble-help">
        {strings.help}
      </p>
    </section>
  );
}
