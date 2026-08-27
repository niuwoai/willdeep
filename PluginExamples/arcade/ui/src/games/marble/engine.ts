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

/**
 * 弹珠道具（只长在链条上的珠子身上，发射出去的弹珠永远没有道具）：
 *  - bomb    炸弹：被消掉时炸掉附近一整片，可连环引爆
 *  - reverse 闪光：被消掉时整条链往回倒退一段，把已经跑到前面的珠子拉回来
 */
export type MarblePower = 'bomb' | 'reverse';

/** 链条上的一颗弹珠：dist 为沿轨道走过的距离（0 = 入口，pathLength = 洞口）。 */
export interface MarbleBall {
  id: number;
  color: number;
  dist: number;
  power?: MarblePower;
}

/** 待入场的补给项。 */
export interface MarbleSupplyBall {
  color: number;
  power?: MarblePower;
}

/** 一次性视觉特效（渲染层按 until 与当前时间画扩散圈）。 */
export interface MarbleEffect {
  kind: 'blast' | 'reverse' | 'combo';
  x: number;
  y: number;
  radius: number;
  /** 播放到 state.time 的这个时刻为止。 */
  until: number;
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

/**
 * 'falling' 是判负前的落洞动画阶段：链条加速涌进洞口，逐颗被吞掉，
 * 全部吞完才落到 'lost'。这样用户看得见「为什么输」，而不是画面一僵。
 */
export type MarbleStatus = 'idle' | 'playing' | 'falling' | 'won' | 'lost';

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
  /** 本关炸弹珠数量。 */
  bombs: number;
  /** 本关闪光（倒流）珠数量。 */
  reverses: number;
}

export const LEVELS: readonly MarbleLevel[] = [
  { id: 'easy', colors: 4, supply: 40, opening: 12, speed: 3.2, bombs: 3, reverses: 2 },
  { id: 'medium', colors: 5, supply: 55, opening: 16, speed: 4.4, bombs: 4, reverses: 3 },
  { id: 'hard', colors: 6, supply: 70, opening: 20, speed: 5.6, bombs: 6, reverses: 4 },
];

export const DEFAULT_LEVEL = 0;

/**
 * 第 stage 关的配置：颜色、弹珠数、开局长度、速度、道具数都随关卡往上走，
 * 没有上限——这游戏可以一直打下去（颜色受配色表限制封顶 6 种）。
 */
export function levelForStage(stage: number): MarbleLevel {
  const step = Math.max(0, stage - 1);
  const colors = Math.min(6, 4 + Math.floor(step / 2));
  const id: MarbleLevel['id'] = colors >= 6 ? 'hard' : colors === 5 ? 'medium' : 'easy';
  return {
    id,
    colors,
    supply: 40 + step * 8,
    opening: Math.min(26, 12 + step * 2),
    speed: 3.2 + step * 0.45,
    bombs: 3 + Math.floor(step / 2),
    reverses: 2 + Math.floor(step / 3),
  };
}
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
/** 链条断口后方的追赶速度上限倍率（缺口会被迅速补上）。 */
const CATCH_UP = 6;
/** 每消一颗的基础分。 */
const SCORE_PER_BALL = 10;
/** 炸弹爆炸半径（沿轨道的距离，约 3 个身位前后各一片）。 */
export const BOMB_RADIUS = SPACING * 3.2;
/** 闪光珠每颗把链条往回推的距离（约 10 个身位）。 */
export const REVERSE_DISTANCE = SPACING * 10;
/** 断口合拢又凑成三连时的回退距离（比闪光珠温和些，但足够看出「被顶回去了」）。 */
export const CHAIN_PULLBACK = SPACING * 6;
/** 特效停留时长（秒），渲染层按它换算扩散进度。 */
export const EFFECT_SECONDS = 0.45;
/** 开局弹簧入场：整条链在这段时间里被「甩」上轨道，中途会过冲再回弹。 */
const ENTRY_SECONDS = 1.2;
/** 落洞阶段：基础速度与随时间的加速度（越掉越快）。 */
const FALL_BASE_SPEED = 26;
const FALL_ACCEL = 34;
/** 落洞兜底时长（秒）：再慢也要收场，不能卡在动画里。 */
const FALL_TIMEOUT = 4;
/** 闪光倒退：起步速度、加速度与上限（带一点推背感，不是瞬移）。 */
const PULLBACK_START_SPEED = 24;
const PULLBACK_ACCEL = 190;
const PULLBACK_MAX_SPEED = 150;
/** 缺口合拢：起步倍率 + 每个身位的加成，缺口越大追得越快，合拢时自然减速。 */
const CATCH_UP_BASE = 2.2;
const CATCH_UP_PER_BODY = 2.2;

export interface MarbleState {
  /** 基准种子：来自 `?seed=`，缺省时由组件生成一次性熵种子。 */
  seed: string;
  /** 局数，从 0 开始；每次重开 +1。 */
  round: number;
  /** 关卡号（1 起），同时作为旧档位表的下标回退。 */
  level: number;
  /** 本关生效的配置（关卡阶梯算出来的）。 */
  config?: MarbleLevel;
  /** 链条，按 dist 从大到小排列（队首最接近洞口）。 */
  balls: readonly MarbleBall[];
  /** 待入场的补给队列（含道具标记）。 */
  supply: readonly MarbleSupplyBall[];
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
  /** 进行中的一次性特效（爆炸圈、倒流圈）。 */
  effects: readonly MarbleEffect[];
  /** 开局弹簧入场已经过去的时间（秒）。 */
  entry: number;
  /** 入场要把链条整体推进的距离（= 开局珠子数 × 身位）。 */
  entryTarget: number;
  /** 待完成的倒退距离（闪光珠触发，按 pullbackSpeed 逐帧吃掉）。 */
  pullback: number;
  /** 当前倒退速度（世界单位/秒），从 0 加速上去。 */
  pullbackSpeed: number;
  /** 落洞阶段已经过去的时间（秒）。 */
  falling: number;
  /** 断口合拢连锁消除的累计次数：组件据此放庆祝特效。 */
  chains: number;
  /** 已推进的时间（秒），用于特效寿命与道具闪烁节拍。 */
  time: number;
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

/** 本局生效的关卡配置：优先用 state 上带的那份（关卡阶梯生成），否则回退到档位表。 */
export function configOf(state: Pick<MarbleState, 'level' | 'config'>): MarbleLevel {
  return state.config ?? levelAt(state.level);
}

/** 关卡种子：基准种子 + 局数。 */
export function levelSeed(seed: string, round: number): string {
  return `${seed}#${round}`;
}

function drawColors(rng: Rng, count: number, colors: number): number[] {
  return Array.from({ length: count }, () => Math.floor(rng() * colors) % colors);
}

/** 把道具随机撒到本关的弹珠序列上（同一颗珠子只带一种道具）。 */
function assignPowers(rng: Rng, total: number, bombs: number, reverses: number): Map<number, MarblePower> {
  const powers = new Map<number, MarblePower>();
  const place = (kind: MarblePower, count: number): void => {
    let placed = 0;
    // 有限次尝试即可：位置数远多于道具数，撞位重抽，抽不满就少放一颗
    for (let attempt = 0; placed < count && attempt < total * 4; attempt += 1) {
      const index = Math.floor(rng() * total);
      if (powers.has(index)) continue;
      powers.set(index, kind);
      placed += 1;
    }
  };
  place('bomb', bombs);
  place('reverse', reverses);
  return powers;
}

/**
 * 新局：生成补给队列与弹药序列。
 * 开局先把 opening 颗摆在入口一段轨道上（祖玛开局就有一串），其余陆续入场。
 */
export function createInitialState(
  level: number | MarbleLevel,
  seed?: string,
  round = 0,
): MarbleState {
  const config = typeof level === 'number' ? levelAt(level) : level;
  const levelIndex = typeof level === 'number' ? level : DEFAULT_LEVEL;
  const normalizedSeed = seed ?? 'marble';
  const rng = createRng(levelSeed(normalizedSeed, round));
  const colors = drawColors(rng, config.supply, config.colors);
  const ammo = drawColors(rng, config.supply * 2 + 20, config.colors);
  const powers = assignPowers(rng, colors.length, config.bombs, config.reverses);
  const opening = Math.min(config.opening, colors.length);
  // 开局这批珠子先排在入口之前（dist < 0 = 还在隧道里，渲染层不画），
  // 由 step 的弹簧入场把它们成串甩上轨道。
  const balls: MarbleBall[] = colors.slice(0, opening).map((color, index) => {
    const power = powers.get(index);
    return { id: index + 1, color, dist: -(index + 1) * SPACING, ...(power ? { power } : {}) };
  });
  const supply: MarbleSupplyBall[] = colors.slice(opening).map((color, offset) => {
    const power = powers.get(opening + offset);
    return power ? { color, power } : { color };
  });
  return {
    seed: normalizedSeed,
    round,
    level: levelIndex,
    config,
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
    effects: [],
    entry: 0,
    entryTarget: opening * SPACING,
    pullback: 0,
    pullbackSpeed: 0,
    falling: 0,
    chains: 0,
    time: 0,
    nextId: opening + 1,
  };
}

/**
 * 弹簧缓动：0 → 1 的阻尼振荡曲线，中途冲过 1 再回弹几下落定。
 * 开局入场用它把整条链甩上轨道，看起来就是「弹进来」而不是匀速爬进来。
 */
export function springEase(progress: number): number {
  if (progress <= 0) return 0;
  if (progress >= 1) return 1;
  return 1 - Math.exp(-5.5 * progress) * Math.cos(7.5 * progress);
}

/** 本帧因入场弹簧产生的整体位移（入场结束后恒为 0）。 */
export function entryShift(from: number, to: number, target: number): number {
  if (from >= ENTRY_SECONDS) return 0;
  const before = springEase(from / ENTRY_SECONDS);
  const after = springEase(Math.min(ENTRY_SECONDS, to) / ENTRY_SECONDS);
  return (after - before) * target;
}

/** 重开：局数 +1，换一套补给与弹药（关卡配置不变，同一基准种子下第 N 局仍可复现）。 */
export function restart(state: MarbleState): MarbleState {
  const next = createInitialState(configOf(state), state.seed, state.round + 1);
  return { ...next, level: state.level };
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
 * 把整条链往回推 distance：链条整体后退，但队尾不会退到入口之前，
 * 相邻两珠始终保持一个身位（从队尾往队首依次抬底，间距原样保留）。
 */
export function rollbackChain(balls: readonly MarbleBall[], distance: number): MarbleBall[] {
  const shifted = balls.map((ball) => ({ ...ball, dist: ball.dist - distance }));
  if (distance <= 0) return balls.slice();
  for (let i = shifted.length - 1; i >= 0; i -= 1) {
    const behind = shifted[i + 1];
    const floor = behind ? behind.dist + SPACING : 0;
    const current = shifted[i] as MarbleBall;
    if (current.dist < floor) shifted[i] = { ...current, dist: floor };
  }
  return shifted;
}

export interface DetonationResult {
  balls: MarbleBall[];
  gained: number;
  /** 本次一共消掉几颗（含被炸掉的）。 */
  removed: number;
  /** 断口后方那颗珠的 id，供缺口合拢的连锁判定。 */
  junction: number | null;
  effects: MarbleEffect[];
  /** 本次要往回倒退的距离（闪光珠），交给 step 逐帧加速吃掉。 */
  pullback: number;
}

const NO_DETONATION: Omit<DetonationResult, 'balls'> = {
  gained: 0,
  removed: 0,
  junction: null,
  effects: [],
  pullback: 0,
};

/**
 * 消除 [start, end] 这一段，并结算它们身上的道具：
 *  - 炸弹：把爆点前后 BOMB_RADIUS 之内的珠子一并炸掉，炸到的炸弹继续连环引爆
 *  - 闪光：每颗把整条链往回推 REVERSE_DISTANCE，已经跑到前面的珠子被拉回来
 */
function detonate(
  balls: readonly MarbleBall[],
  start: number,
  end: number,
  combo: number,
  time: number,
): DetonationResult {
  let current = balls.slice();
  let gained = 0;
  let removed = 0;
  let junction: number | null = null;
  let reverses = 0;
  const effects: MarbleEffect[] = [];
  const queue: Array<{ start: number; end: number }> = [{ start, end }];

  while (queue.length > 0) {
    const segment = queue.shift() as { start: number; end: number };
    const from = Math.max(0, segment.start);
    const to = Math.min(current.length - 1, segment.end);
    if (from > to) continue;
    const taken = current.slice(from, to + 1);
    current = [...current.slice(0, from), ...current.slice(to + 1)];
    gained += SCORE_PER_BALL * taken.length * combo;
    removed += taken.length;
    // 只认第一次断口：后续连爆产生的缺口由链条自然合拢
    if (junction === null && from > 0 && from < current.length) {
      junction = (current[from] as MarbleBall).id;
    }

    for (const ball of taken) {
      if (ball.power === 'bomb') {
        const center = pointAt(ball.dist);
        effects.push({
          kind: 'blast',
          x: center.x,
          y: center.y,
          radius: BOMB_RADIUS,
          until: time + EFFECT_SECONDS,
        });
        // 链条按 dist 降序排列，所以「距爆点一个半径以内」必然是连续的一段
        const first = current.findIndex((other) => Math.abs(other.dist - ball.dist) <= BOMB_RADIUS);
        if (first < 0) continue;
        let last = first;
        while (
          last + 1 < current.length &&
          Math.abs((current[last + 1] as MarbleBall).dist - ball.dist) <= BOMB_RADIUS
        ) {
          last += 1;
        }
        queue.push({ start: first, end: last });
      } else if (ball.power === 'reverse') {
        reverses += 1;
      }
    }
  }

  let pullback = 0;
  if (reverses > 0 && current.length > 0) {
    const head = current[0] as MarbleBall;
    const center = pointAt(head.dist);
    // 不瞬移：把距离挂账，由 step 带加速地把链条拉回去
    pullback = REVERSE_DISTANCE * reverses;
    effects.push({
      kind: 'reverse',
      x: center.x,
      y: center.y,
      radius: SPACING * 2.4,
      until: time + EFFECT_SECONDS,
    });
  }

  return { balls: current, gained, removed, junction, effects, pullback };
}

/**
 * 判定并消除以 index 为中心的同色三连以上（不足三颗不消）。
 * 命中时连同道具效果一起结算，见 detonate。
 */
function resolveMatch(
  balls: readonly MarbleBall[],
  index: number,
  combo: number,
  time: number,
): DetonationResult {
  const { start, end } = runAround(balls, index);
  if (end - start + 1 < 3) return { balls: balls.slice(), ...NO_DETONATION };
  return detonate(balls, start, end, combo, time);
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
  const result = resolveMatch(inserted, position, combo, state.time);
  const pendingJunctions = result.junction === null
    ? state.pendingJunctions
    : [...state.pendingJunctions, result.junction];
  return {
    ...state,
    balls: result.balls,
    score: state.score + result.gained,
    combo: result.removed > 0 ? state.combo + 1 : 1,
    pendingJunctions,
    effects: [...state.effects, ...result.effects],
    pullback: state.pullback + result.pullback,
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
    const gap = (balls[i - 1] as MarbleBall).dist - ball.dist - SPACING;
    const wasTouching = gap <= CONTACT_EPS;
    // 缺口越大追得越快（爆炸炸出的大缺口先猛冲），越合拢越慢，天然是个缓动
    const chase = wasTouching ? 1 : Math.min(CATCH_UP, CATCH_UP_BASE + (gap / SPACING) * CATCH_UP_PER_BODY);
    const limit = ahead.dist - SPACING;
    const moved = ball.dist + speed * chase * dt;
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
  const config = configOf(state);
  const time = state.time + dt;

  // 落洞阶段：不再接受补给与命中，整条链加速涌进洞口，逐颗被吞掉
  if (state.status === 'falling') {
    const falling = state.falling + dt;
    const speed = FALL_BASE_SPEED + FALL_ACCEL * falling;
    const balls = state.balls
      .map((ball) => ({ ...ball, dist: ball.dist + speed * dt }))
      .filter((ball) => ball.dist < PATH_LENGTH);
    const done = balls.length === 0 || falling >= FALL_TIMEOUT;
    return {
      ...state,
      balls,
      shots: [],
      time,
      falling,
      effects: state.effects.filter((effect) => effect.until > time),
      status: done ? 'lost' : 'falling',
    };
  }

  // 入场弹簧：整体位移（含过冲回弹），不改变彼此间距，插珠也不受影响
  const entry = state.entry + dt;
  const shift = entryShift(state.entry, entry, state.entryTarget);
  const entering = shift === 0 ? state.balls : state.balls.map((ball) => ({ ...ball, dist: ball.dist + shift }));
  const advanced = advance(entering, dt, config.speed);
  let balls = advanced.balls;
  let score = state.score;
  let combo = state.combo;
  let effects = state.effects.filter((effect) => effect.until > time);
  let pendingJunctions = state.pendingJunctions.filter((id) => balls.some((ball) => ball.id === id));

  // 缺口合拢：断口两侧接上时重新判定三连（连锁得分 + 回退 + 庆祝）
  let chains = state.chains;
  let chainPullback = 0;
  for (const id of advanced.joined) {
    if (!pendingJunctions.includes(id)) continue;
    const index = balls.findIndex((ball) => ball.id === id);
    if (index <= 0) continue;
    const contact = balls[index] as MarbleBall;
    const result = resolveMatch(balls, index, combo + 1, time);
    pendingJunctions = pendingJunctions.filter((pending) => pending !== id);
    if (result.removed === 0) continue;
    balls = result.balls;
    score += result.gained;
    combo += 1;
    chains += 1;
    // 撞在一起消掉的这一下，把链条往回顶一段，并在接合处放个庆祝圈
    chainPullback += CHAIN_PULLBACK;
    const center = pointAt(contact.dist);
    effects = [
      ...effects,
      ...result.effects,
      { kind: 'combo', x: center.x, y: center.y, radius: SPACING * 3, until: time + EFFECT_SECONDS * 1.6 },
    ];
    if (result.junction !== null) pendingJunctions = [...pendingJunctions, result.junction];
  }

  // 闪光倒退 / 连锁回退：带加速地把链条往回拉，而不是瞬移
  let pullback = state.pullback + chainPullback;
  let pullbackSpeed = state.pullbackSpeed;
  if (pullback > 0 && balls.length > 0) {
    pullbackSpeed = Math.min(
      PULLBACK_MAX_SPEED,
      (pullbackSpeed > 0 ? pullbackSpeed : PULLBACK_START_SPEED) + PULLBACK_ACCEL * dt,
    );
    const move = Math.min(pullback, pullbackSpeed * dt);
    balls = rollbackChain(balls, move);
    pullback -= move;
    if (pullback <= 1e-6) {
      pullback = 0;
      pullbackSpeed = 0;
    }
  } else if (pullback > 0) {
    pullback = 0;
    pullbackSpeed = 0;
  }

  // 补给入场：入口空出一个身位就放下一颗
  let supply = state.supply;
  let nextId = state.nextId;
  const tail = balls[balls.length - 1];
  if (supply.length > 0 && (!tail || tail.dist >= SPACING)) {
    const entering = supply[0] as MarbleSupplyBall;
    balls = [
      ...balls,
      { id: nextId, color: entering.color, dist: 0, ...(entering.power ? { power: entering.power } : {}) },
    ];
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
    effects,
    entry,
    pullback,
    pullbackSpeed,
    chains,
    time,
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
  // 队首碰到洞口不是立刻判负，先进落洞动画，吞完才 lost
  const falling = head !== undefined && head.dist >= PATH_LENGTH;
  const won = !falling && working.supply.length === 0 && working.balls.length === 0;
  // idle 只由「玩家开了第一枪」翻成 playing（见 shoot），链条则一直在走。
  const status: MarbleStatus = falling ? 'falling' : won ? 'won' : working.status;

  return { ...working, shots, combo, status };
}

/** 成绩即当前得分（更高分更好，适配 saveBestScore 的「只保留更高分」）。 */
export function scoreFor(state: MarbleState): number {
  return state.score;
}
