/**
 * 印加弹珠（Zuma 玩法）纯引擎，不依赖 React / canvas。
 *
 * 世界坐标固定为 100×100 的方形场地，渲染层只负责等比缩放。
 * 弹珠沿一条向内收拢的螺旋轨道前进，走到轨道尽头（骷髅洞）即失败；
 * 中央发射器把弹珠打进链条，凑够三颗同色即消除并触发连锁。
 *
 * 契约约束：
 *  - 一切随机只经 createRng（src/core/rng.ts）；补给与弹药在开局一次性生成，
 *    所以「同一基准种子的第 N 局」完全可复现
 *  - step(state, dt) 是纯函数：给定状态与时间步长返回新状态，便于单测
 */
import { createRng } from '../../core/rng';
import type { Rng } from '../../core/rng';

export interface Vec {
  x: number;
  y: number;
}

/** 链条上的一颗弹珠：dist 为沿轨道走过的距离（0 = 入口，pathLength = 洞口）。 */
export interface MarbleBall {
  id: number;
  color: number;
  dist: number;
}

/** 飞行中的弹珠。 */
export interface MarbleShot {
  id: number;
  color: number;
  x: number;
  y: number;
  vx: number;
  vy: number;
}

export type MarbleStatus = 'idle' | 'playing' | 'won' | 'lost';

export interface MarbleLevel {
  id: 'easy' | 'medium' | 'hard';
  /** 颜色种类数。 */
  colors: number;
  /** 本关总共要放出的弹珠数。 */
  supply: number;
  /** 开局就摆在轨道上的弹珠数（其余从入口陆续入场）。 */
  opening: number;
  /** 链条基础前进速度（世界单位/秒）。 */
  speed: number;
}

export const LEVELS: readonly MarbleLevel[] = [
  { id: 'easy', colors: 4, supply: 40, opening: 12, speed: 3.2 },
  { id: 'medium', colors: 5, supply: 55, opening: 16, speed: 4.4 },
  { id: 'hard', colors: 6, supply: 70, opening: 20, speed: 5.6 },
];

export const DEFAULT_LEVEL = 0;
/** 场地边长（世界单位）。 */
export const FIELD = 100;
/** 弹珠半径。 */
export const BALL_RADIUS = 2.6;
/** 链条上相邻两珠的中心间距。 */
export const SPACING = BALL_RADIUS * 2;
/** 判定「已经贴上」的间距容差。 */
const CONTACT_EPS = 0.35;
/** 发射器位置（场地中心）。 */
export const SHOOTER: Vec = { x: FIELD / 2, y: FIELD / 2 };
/** 飞行速度（世界单位/秒）。 */
export const SHOT_SPEED = 78;
/** 同时在飞的弹珠上限。 */
export const MAX_SHOTS = 3;
/** 链条断口后方的追赶速度倍率（缺口会被迅速补上）。 */
const CATCH_UP = 4.5;
/** 每消一颗的基础分。 */
const SCORE_PER_BALL = 10;

export interface MarbleState {
  /** 基准种子：来自 `?seed=`，缺省时由组件生成一次性熵种子。 */
  seed: string;
  /** 局数，从 0 开始；每次重开 +1。 */
  round: number;
  level: number;
  /** 链条，按 dist 从大到小排列（队首最接近洞口）。 */
  balls: readonly MarbleBall[];
  /** 待入场的补给颜色队列。 */
  supply: readonly number[];
  /** 飞行中的弹珠。 */
  shots: readonly MarbleShot[];
  /** 预生成的弹药颜色序列与游标（确定性）。 */
  ammo: readonly number[];
  ammoCursor: number;
  /** 当前待发射与下一颗的颜色。 */
  loaded: number;
  next: number;
  /** 瞄准角（弧度，0 指向右）。 */
  angle: number;
  score: number;
  /** 当前连锁倍率（一次发射内连续消除会叠加）。 */
  combo: number;
  status: MarbleStatus;
  /** 断口处等待合拢的弹珠 id：合拢瞬间要重新判定是否成三。 */
  pendingJunctions: readonly number[];
  nextId: number;
}

/** 轨道采样点与累计弧长（模块级常量，全局共享一份）。 */
interface Track {
  points: readonly Vec[];
  cumulative: readonly number[];
  length: number;
}

const TRACK_TURNS = 2.6;
const TRACK_OUTER = 45;
const TRACK_INNER = 15;
const TRACK_STEPS = 720;
const TRACK_START_ANGLE = -Math.PI / 2;

function buildTrack(): Track {
  const points: Vec[] = [];
  for (let i = 0; i <= TRACK_STEPS; i += 1) {
    const t = i / TRACK_STEPS;
    const angle = TRACK_START_ANGLE + t * TRACK_TURNS * Math.PI * 2;
    const radius = TRACK_OUTER - (TRACK_OUTER - TRACK_INNER) * t;
    points.push({
      x: FIELD / 2 + radius * Math.cos(angle),
      y: FIELD / 2 + radius * Math.sin(angle),
    });
  }
  const cumulative: number[] = [0];
  for (let i = 1; i < points.length; i += 1) {
    const previous = points[i - 1] as Vec;
    const current = points[i] as Vec;
    const segment = Math.hypot(current.x - previous.x, current.y - previous.y);
    cumulative.push((cumulative[i - 1] as number) + segment);
  }
  return { points, cumulative, length: cumulative[cumulative.length - 1] as number };
}

const TRACK = buildTrack();

/** 轨道总长（世界单位）。 */
export const PATH_LENGTH = TRACK.length;

/** 轨道折线（渲染层画轨道用）。 */
export function trackPoints(): readonly Vec[] {
  return TRACK.points;
}

/** 轨道上距离 dist 处的坐标（越界按端点夹紧）。 */
export function pointAt(dist: number): Vec {
  const clamped = Math.max(0, Math.min(TRACK.length, dist));
  let low = 0;
  let high = TRACK.cumulative.length - 1;
  while (low < high - 1) {
    const mid = (low + high) >> 1;
    if ((TRACK.cumulative[mid] as number) <= clamped) low = mid;
    else high = mid;
  }
  const start = TRACK.points[low] as Vec;
  const end = TRACK.points[high] as Vec;
  const startDist = TRACK.cumulative[low] as number;
  const endDist = TRACK.cumulative[high] as number;
  const ratio = endDist === startDist ? 0 : (clamped - startDist) / (endDist - startDist);
  return { x: start.x + (end.x - start.x) * ratio, y: start.y + (end.y - start.y) * ratio };
}

/** 轨道上距离 dist 处的单位切向（指向前进方向）。 */
export function tangentAt(dist: number): Vec {
  const back = pointAt(Math.max(0, dist - 0.5));
  const front = pointAt(Math.min(TRACK.length, dist + 0.5));
  const dx = front.x - back.x;
  const dy = front.y - back.y;
  const size = Math.hypot(dx, dy) || 1;
  return { x: dx / size, y: dy / size };
}

export function levelAt(level: number): MarbleLevel {
  return (LEVELS[level] ?? LEVELS[DEFAULT_LEVEL]) as MarbleLevel;
}

/** 关卡种子：基准种子 + 局数。 */
export function levelSeed(seed: string, round: number): string {
  return `${seed}#${round}`;
}

function drawColors(rng: Rng, count: number, colors: number): number[] {
  return Array.from({ length: count }, () => Math.floor(rng() * colors) % colors);
}

/**
 * 新局：生成补给队列与弹药序列。
 * 开局先把 opening 颗摆在入口一段轨道上（祖玛开局就有一串），其余陆续入场。
 */
export function createInitialState(level: number, seed?: string, round = 0): MarbleState {
  const config = levelAt(level);
  const normalizedSeed = seed ?? 'marble';
  const rng = createRng(levelSeed(normalizedSeed, round));
  const colors = drawColors(rng, config.supply, config.colors);
  const ammo = drawColors(rng, config.supply * 2 + 20, config.colors);
  const opening = Math.min(config.opening, colors.length);
  const balls: MarbleBall[] = colors.slice(0, opening).map((color, index) => ({
    id: index + 1,
    color,
    dist: (opening - 1 - index) * SPACING,
  }));
  const supply = colors.slice(opening);
  return {
    seed: normalizedSeed,
    round,
    level,
    balls,
    supply,
    shots: [],
    ammo,
    ammoCursor: 2,
    loaded: ammo[0] as number,
    next: ammo[1] as number,
    angle: -Math.PI / 2,
    score: 0,
    combo: 1,
    status: 'idle',
    pendingJunctions: [],
    nextId: opening + 1,
  };
}

/** 重开：局数 +1，换一套补给与弹药（同一基准种子下第 N 局仍可复现）。 */
export function restart(state: MarbleState): MarbleState {
  return createInitialState(state.level, state.seed, state.round + 1);
}

/** 设置瞄准角。 */
export function aim(state: MarbleState, angle: number): MarbleState {
  return { ...state, angle };
}

/** 朝世界坐标 (x, y) 瞄准。 */
export function aimAt(state: MarbleState, x: number, y: number): MarbleState {
  return aim(state, Math.atan2(y - SHOOTER.y, x - SHOOTER.x));
}

/** 交换当前弹珠与下一颗（经典祖玛的换色）。 */
export function swapAmmo(state: MarbleState): MarbleState {
  if (state.status === 'won' || state.status === 'lost') return state;
  return { ...state, loaded: state.next, next: state.loaded };
}

/** 取下一发弹药；抽到场上已经没有的颜色时改用队首弹珠的颜色，避免死子。 */
function reload(state: MarbleState, balls: readonly MarbleBall[]): {
  loaded: number;
  next: number;
  ammoCursor: number;
} {
  const cursor = state.ammoCursor % state.ammo.length;
  let candidate = state.ammo[cursor] as number;
  if (balls.length > 0 && !balls.some((ball) => ball.color === candidate)) {
    candidate = (balls[0] as MarbleBall).color;
  }
  return { loaded: state.next, next: candidate, ammoCursor: state.ammoCursor + 1 };
}

/** 发射一颗弹珠。 */
export function shoot(state: MarbleState): MarbleState {
  if (state.status === 'won' || state.status === 'lost') return state;
  if (state.shots.length >= MAX_SHOTS) return state;
  const shot: MarbleShot = {
    id: state.nextId,
    color: state.loaded,
    x: SHOOTER.x,
    y: SHOOTER.y,
    vx: Math.cos(state.angle) * SHOT_SPEED,
    vy: Math.sin(state.angle) * SHOT_SPEED,
  };
  const { loaded, next, ammoCursor } = reload(state, state.balls);
  return {
    ...state,
    shots: [...state.shots, shot],
    loaded,
    next,
    ammoCursor,
    nextId: state.nextId + 1,
    status: state.status === 'idle' ? 'playing' : state.status,
  };
}

/** 以 index 为中心、只在「已贴上」的相邻珠之间扩展的同色连续段。 */
function runAround(balls: readonly MarbleBall[], index: number): { start: number; end: number } {
  const color = (balls[index] as MarbleBall).color;
  let start = index;
  let end = index;
  while (start > 0) {
    const ahead = balls[start - 1] as MarbleBall;
    const current = balls[start] as MarbleBall;
    if (ahead.color !== color) break;
    if (ahead.dist - current.dist > SPACING + CONTACT_EPS) break;
    start -= 1;
  }
  while (end < balls.length - 1) {
    const behind = balls[end + 1] as MarbleBall;
    const current = balls[end] as MarbleBall;
    if (behind.color !== color) break;
    if (current.dist - behind.dist > SPACING + CONTACT_EPS) break;
    end += 1;
  }
  return { start, end };
}

/**
 * 判定并消除以 index 为中心的同色三连以上。
 * 返回新链条、得分与断口后方那颗珠的 id（供连锁判定）。
 */
function resolveMatch(
  balls: readonly MarbleBall[],
  index: number,
  combo: number,
): { balls: MarbleBall[]; gained: number; removed: number; junction: number | null } {
  const { start, end } = runAround(balls, index);
  const removed = end - start + 1;
  if (removed < 3) return { balls: balls.slice(), gained: 0, removed: 0, junction: null };
  const rest = [...balls.slice(0, start), ...balls.slice(end + 1)];
  const junction = start > 0 && start < rest.length ? (rest[start] as MarbleBall).id : null;
  return { balls: rest, gained: SCORE_PER_BALL * removed * combo, removed, junction };
}

/** 插入一颗弹珠：position 为插入后的数组下标，随后把后方的珠依次顶开。 */
function insertBall(
  balls: readonly MarbleBall[],
  position: number,
  ball: MarbleBall,
): MarbleBall[] {
  const next = [...balls.slice(0, position), ball, ...balls.slice(position)];
  for (let i = position + 1; i < next.length; i += 1) {
    const ahead = next[i - 1] as MarbleBall;
    const current = next[i] as MarbleBall;
    if (ahead.dist - current.dist < SPACING) {
      next[i] = { ...current, dist: ahead.dist - SPACING };
    }
  }
  return next;
}

/**
 * 把一颗飞行弹珠并入链条：命中第 hitIndex 颗，ahead 表示落在它前方（更靠近洞口）。
 * 供碰撞检测与单测直接调用。
 */
export function applyHit(
  state: MarbleState,
  hitIndex: number,
  color: number,
  ahead: boolean,
  ballId?: number,
): MarbleState {
  const target = state.balls[hitIndex];
  if (!target) return state;
  const position = ahead ? hitIndex : hitIndex + 1;
  const dist = ahead ? target.dist + SPACING : target.dist - SPACING;
  const id = ballId ?? state.nextId;
  const inserted = insertBall(state.balls, position, { id, color, dist });
  const combo = 1;
  const result = resolveMatch(inserted, position, combo);
  const pendingJunctions = result.junction === null
    ? state.pendingJunctions
    : [...state.pendingJunctions, result.junction];
  return {
    ...state,
    balls: result.balls,
    score: state.score + result.gained,
    combo: result.removed > 0 ? state.combo + 1 : 1,
    pendingJunctions,
    nextId: Math.max(state.nextId, id) + 1,
    status: state.status === 'idle' ? 'playing' : state.status,
  };
}

/** 链条前进 + 缺口合拢；返回新链条与本帧刚刚合拢的珠 id。 */
function advance(
  balls: readonly MarbleBall[],
  dt: number,
  speed: number,
): { balls: MarbleBall[]; joined: number[] } {
  const next: MarbleBall[] = [];
  const joined: number[] = [];
  for (let i = 0; i < balls.length; i += 1) {
    const ball = balls[i] as MarbleBall;
    if (i === 0) {
      next.push({ ...ball, dist: ball.dist + speed * dt });
      continue;
    }
    const ahead = next[i - 1] as MarbleBall;
    const wasTouching = (balls[i - 1] as MarbleBall).dist - ball.dist <= SPACING + CONTACT_EPS;
    const limit = ahead.dist - SPACING;
    const moved = ball.dist + speed * (wasTouching ? 1 : CATCH_UP) * dt;
    const dist = Math.min(moved, limit);
    if (!wasTouching && dist >= limit - CONTACT_EPS) joined.push(ball.id);
    next.push({ ...ball, dist });
  }
  return { balls: next, joined };
}

/** 命中检测：飞行弹珠与链条相交时返回命中下标与前后方向。 */
function hitTest(
  balls: readonly MarbleBall[],
  shot: MarbleShot,
): { index: number; ahead: boolean } | null {
  for (let i = 0; i < balls.length; i += 1) {
    const ball = balls[i] as MarbleBall;
    const center = pointAt(ball.dist);
    if (Math.hypot(center.x - shot.x, center.y - shot.y) > SPACING) continue;
    const tangent = tangentAt(ball.dist);
    const ahead = (shot.x - center.x) * tangent.x + (shot.y - center.y) * tangent.y > 0;
    return { index: i, ahead };
  }
  return null;
}

/**
 * 推进一帧。dt 单位为秒，调用方需按帧间隔传入（并自行夹紧过大的 dt）。
 * 顺序：链条前进 → 缺口合拢连锁 → 补给入场 → 飞行弹珠移动与命中 → 胜负判定。
 */
export function step(state: MarbleState, dt: number): MarbleState {
  if (state.status === 'won' || state.status === 'lost') return state;
  const config = levelAt(state.level);

  const advanced = advance(state.balls, dt, config.speed);
  let balls = advanced.balls;
  let score = state.score;
  let combo = state.combo;
  let pendingJunctions = state.pendingJunctions.filter((id) => balls.some((ball) => ball.id === id));

  // 缺口合拢：断口两侧接上时重新判定三连（连锁得分）
  for (const id of advanced.joined) {
    if (!pendingJunctions.includes(id)) continue;
    const index = balls.findIndex((ball) => ball.id === id);
    if (index <= 0) continue;
    const result = resolveMatch(balls, index, combo + 1);
    pendingJunctions = pendingJunctions.filter((pending) => pending !== id);
    if (result.removed === 0) continue;
    balls = result.balls;
    score += result.gained;
    combo += 1;
    if (result.junction !== null) pendingJunctions = [...pendingJunctions, result.junction];
  }

  // 补给入场：入口空出一个身位就放下一颗
  let supply = state.supply;
  let nextId = state.nextId;
  const tail = balls[balls.length - 1];
  if (supply.length > 0 && (!tail || tail.dist >= SPACING)) {
    balls = [...balls, { id: nextId, color: supply[0] as number, dist: 0 }];
    supply = supply.slice(1);
    nextId += 1;
  }

  // 飞行弹珠：移动、命中并入链条、飞出场地则丢弃
  const shots: MarbleShot[] = [];
  let working: MarbleState = {
    ...state,
    balls,
    supply,
    score,
    combo,
    pendingJunctions,
    nextId,
    shots: [],
  };
  for (const shot of state.shots) {
    const moved: MarbleShot = { ...shot, x: shot.x + shot.vx * dt, y: shot.y + shot.vy * dt };
    const margin = BALL_RADIUS * 2;
    if (
      moved.x < -margin ||
      moved.y < -margin ||
      moved.x > FIELD + margin ||
      moved.y > FIELD + margin
    ) {
      combo = 1;
      working = { ...working, combo };
      continue;
    }
    const hit = hitTest(working.balls, moved);
    if (!hit) {
      shots.push(moved);
      continue;
    }
    working = applyHit(working, hit.index, moved.color, hit.ahead, moved.id);
    combo = working.combo;
  }

  const head = working.balls[0];
  const lost = head !== undefined && head.dist >= PATH_LENGTH;
  const won = !lost && working.supply.length === 0 && working.balls.length === 0;
  // idle 只由「玩家开了第一枪」翻成 playing（见 shoot），链条则一直在走。
  const status: MarbleStatus = lost ? 'lost' : won ? 'won' : working.status;

  return { ...working, shots, combo, status };
}

/** 成绩即当前得分（更高分更好，适配 saveBestScore 的「只保留更高分」）。 */
export function scoreFor(state: MarbleState): number {
  return state.score;
}
