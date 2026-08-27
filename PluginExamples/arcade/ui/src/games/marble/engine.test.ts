/**
 * 印加弹珠引擎回归。
 *
 * 覆盖：轨道采样、链条前进与补给入场、发射与换色、三连消除与连锁、
 * 失败/通关判定、计分，以及「重开换补给但同种子可复现」。
 */
import { describe, expect, it } from 'vitest';
import {
  BALL_RADIUS,
  BOMB_RADIUS,
  DEFAULT_LEVEL,
  FIELD,
  LEVELS,
  MAX_SHOTS,
  PATH_LENGTH,
  REVERSE_DISTANCE,
  SHOOTER,
  SPACING,
  aimAt,
  applyHit,
  createInitialState,
  levelAt,
  levelSeed,
  pointAt,
  restart,
  rollbackChain,
  springEase,
  scoreFor,
  shoot,
  step,
  swapAmmo,
  tangentAt,
  trackPoints,
} from './engine';
import type { MarbleBall, MarblePower, MarbleState } from './engine';

/** 直接摆一条链条，绕开逐帧入场，方便测消除规则；powers 按下标挂道具。 */
function withChain(
  colors: readonly number[],
  headDist = 200,
  powers: Readonly<Record<number, MarblePower>> = {},
): MarbleState {
  const base = createInitialState(0, 'chain');
  const balls: MarbleBall[] = colors.map((color, index) => {
    const power = powers[index];
    return {
      id: index + 1,
      color,
      dist: headDist - index * SPACING,
      ...(power ? { power } : {}),
    };
  });
  // 入场弹簧当作已经演完（entry 超过窗口、位移目标清零），免得测消除时链条还在被甩
  return {
    ...base,
    balls,
    supply: [],
    status: 'playing',
    entry: 10,
    entryTarget: 0,
    nextId: colors.length + 1,
  };
}

describe('印加弹珠：轨道', () => {
  it('轨道有长度，采样点都落在场地内', () => {
    expect(PATH_LENGTH).toBeGreaterThan(100);
    for (const point of trackPoints()) {
      expect(point.x).toBeGreaterThanOrEqual(0);
      expect(point.x).toBeLessThanOrEqual(FIELD);
      expect(point.y).toBeGreaterThanOrEqual(0);
      expect(point.y).toBeLessThanOrEqual(FIELD);
    }
  });

  it('pointAt 单调推进且越界夹紧到端点', () => {
    const start = pointAt(0);
    const end = pointAt(PATH_LENGTH);
    expect(pointAt(-50)).toEqual(start);
    expect(pointAt(PATH_LENGTH + 50)).toEqual(end);
    // 终点在内圈（更靠近发射器），起点在外圈
    const radius = (point: { x: number; y: number }) =>
      Math.hypot(point.x - SHOOTER.x, point.y - SHOOTER.y);
    expect(radius(end)).toBeLessThan(radius(start));
  });

  it('tangentAt 返回单位向量', () => {
    for (const dist of [0, PATH_LENGTH / 3, PATH_LENGTH]) {
      const tangent = tangentAt(dist);
      expect(Math.hypot(tangent.x, tangent.y)).toBeCloseTo(1, 5);
    }
  });
});

describe('印加弹珠：链条前进与补给', () => {
  it('开局的一串弹珠排在隧道里，被弹簧甩上轨道后补给才陆续入场', () => {
    const easy = LEVELS[0] as { supply: number; opening: number };
    let state = createInitialState(0, 'supply');
    expect(state.balls).toHaveLength(easy.opening);
    expect(state.supply).toHaveLength(easy.supply - easy.opening);
    // 开局全部在入口之前（dist < 0），渲染层不画
    expect(state.balls.every((ball) => ball.dist < 0)).toBe(true);

    // 入场结束（约 1.2 秒）后整条链已经在轨道上
    for (let frame = 0; frame < 45; frame += 1) state = step(state, 1 / 30);
    expect(state.balls.slice(0, easy.opening).every((ball) => ball.dist >= 0)).toBe(true);

    for (let frame = 0; frame < 90; frame += 1) state = step(state, 1 / 30);
    expect(state.supply.length).toBeLessThan(easy.supply - easy.opening);
    expect(state.balls.length).toBeGreaterThan(easy.opening);
  });

  it('弹簧缓动会过冲再落定', () => {
    expect(springEase(0)).toBe(0);
    expect(springEase(1)).toBe(1);
    // 中途冲过目标位置（>1），这就是「弹一下」的观感
    const overshoot = Math.max(...[0.2, 0.25, 0.3, 0.35].map((p) => springEase(p)));
    expect(overshoot).toBeGreaterThan(1);
  });

  it('链条不会自我穿插：相邻两珠间距不小于一个身位', () => {
    let state = createInitialState(2, 'packing');
    for (let frame = 0; frame < 200; frame += 1) state = step(state, 1 / 60);
    for (let i = 1; i < state.balls.length; i += 1) {
      const ahead = state.balls[i - 1] as MarbleBall;
      const current = state.balls[i] as MarbleBall;
      expect(ahead.dist - current.dist).toBeGreaterThanOrEqual(SPACING - 1e-6);
    }
  });

  it('队首碰到洞口先进落洞动画，弹珠被逐颗吞掉后才判负', () => {
    let falling = withChain([0, 1, 2], PATH_LENGTH - 0.1);
    for (let frame = 0; frame < 10 && falling.status !== 'falling'; frame += 1) {
      falling = step(falling, 1 / 60);
    }
    expect(falling.status).toBe('falling');
    expect(falling.balls.length).toBeGreaterThan(0);

    // 越掉越快：盯住同一颗（队尾）看它每帧走多远，后一帧一定比前一帧远
    const tailId = (falling.balls[falling.balls.length - 1] as MarbleBall).id;
    const distOf = (state: MarbleState): number =>
      (state.balls.find((ball) => ball.id === tailId) as MarbleBall).dist;
    const frame1 = step(falling, 1 / 60);
    const frame2 = step(frame1, 1 / 60);
    expect(distOf(frame1) - distOf(falling)).toBeGreaterThan(0);
    expect(distOf(frame2) - distOf(frame1)).toBeGreaterThan(distOf(frame1) - distOf(falling));

    for (let frame = 0; frame < 240 && falling.status === 'falling'; frame += 1) {
      falling = step(falling, 1 / 60);
    }
    expect(falling.status).toBe('lost');
    expect(falling.balls).toHaveLength(0);
  });

  it('补给放完且链条清空即通关', () => {
    const state: MarbleState = { ...withChain([0]), balls: [], supply: [] };
    expect(step(state, 1 / 60).status).toBe('won');
  });

  it('已分出胜负后 step 不再改变状态', () => {
    let lost = withChain([0, 1, 2], PATH_LENGTH - 0.1);
    for (let frame = 0; frame < 300 && lost.status !== 'lost'; frame += 1) lost = step(lost, 1 / 60);
    expect(lost.status).toBe('lost');
    expect(step(lost, 1)).toEqual(lost);
  });
});

describe('印加弹珠：发射与换色', () => {
  it('发射产生一颗朝瞄准方向飞行的弹珠，并换上下一发', () => {
    const aimed = aimAt(createInitialState(0, 'shooting'), SHOOTER.x + 10, SHOOTER.y);
    const fired = shoot(aimed);
    expect(fired.shots).toHaveLength(1);
    const shot = fired.shots[0] as { x: number; y: number; vx: number; vy: number; color: number };
    expect(shot.x).toBeCloseTo(SHOOTER.x, 5);
    expect(shot.vx).toBeGreaterThan(0);
    expect(Math.abs(shot.vy)).toBeLessThan(1e-6);
    expect(shot.color).toBe(aimed.loaded);
    expect(fired.loaded).toBe(aimed.next);
    expect(fired.status).toBe('playing');
  });

  it('同时在飞的弹珠有上限', () => {
    let state = createInitialState(0, 'limit');
    for (let i = 0; i < MAX_SHOTS + 3; i += 1) state = shoot(state);
    expect(state.shots).toHaveLength(MAX_SHOTS);
  });

  it('换色交换当前与下一发', () => {
    const state = createInitialState(0, 'swap');
    const swapped = swapAmmo(state);
    expect(swapped.loaded).toBe(state.next);
    expect(swapped.next).toBe(state.loaded);
  });

  it('飞出场地的弹珠会被丢弃并打断连锁', () => {
    const aimed = aimAt({ ...createInitialState(0, 'miss'), combo: 3 }, SHOOTER.x, SHOOTER.y - 10);
    let state = shoot(aimed);
    for (let frame = 0; frame < 60 && state.shots.length > 0; frame += 1) {
      state = step(state, 1 / 60);
    }
    expect(state.shots).toHaveLength(0);
    expect(state.combo).toBe(1);
  });
});

describe('印加弹珠：消除与连锁', () => {
  it('补进第三颗同色即消除三颗并得分', () => {
    const state = withChain([0, 0, 1, 2]);
    const after = applyHit(state, 1, 0, false);
    expect(after.balls.map((ball) => ball.color)).toEqual([1, 2]);
    expect(after.score).toBe(30);
    expect(after.combo).toBe(2);
  });

  it('凑不满三颗只是插进链条，连锁倍率复位', () => {
    const state = { ...withChain([0, 1, 2]), combo: 4 };
    const after = applyHit(state, 0, 1, false);
    expect(after.balls).toHaveLength(4);
    expect(after.score).toBe(0);
    expect(after.combo).toBe(1);
  });

  it('插入后方的珠被顶开，保持一个身位', () => {
    const state = withChain([0, 1, 2, 3]);
    const after = applyHit(state, 1, 5, false);
    for (let i = 1; i < after.balls.length; i += 1) {
      const ahead = after.balls[i - 1] as MarbleBall;
      const current = after.balls[i] as MarbleBall;
      expect(ahead.dist - current.dist).toBeGreaterThanOrEqual(SPACING - 1e-6);
    }
  });

  it('断口合拢后同色再成三，按更高倍率连锁得分', () => {
    // 断口前后各留同色：消掉中间三颗后，两侧合拢又凑成三颗
    const chain = withChain([7, 7, 3, 3, 3, 7]);
    const afterFirst = applyHit(chain, 4, 3, false);
    expect(afterFirst.score).toBeGreaterThan(0);
    expect(afterFirst.pendingJunctions.length).toBeGreaterThan(0);

    let state = afterFirst;
    for (let frame = 0; frame < 600 && state.balls.length > 0; frame += 1) {
      state = step(state, 1 / 60);
    }
    expect(state.balls).toHaveLength(0);
    expect(state.score).toBeGreaterThan(afterFirst.score);
  });

  it('命中检测把飞行弹珠并入链条', () => {
    const chain = withChain([0, 0, 1], 40);
    const head = pointAt((chain.balls[0] as MarbleBall).dist);
    const aimed = aimAt(chain, head.x, head.y);
    let state = shoot({ ...aimed, loaded: 0, next: 0 });
    for (let frame = 0; frame < 120 && state.shots.length > 0; frame += 1) {
      state = step(state, 1 / 120);
    }
    // 打中了就消掉三颗同色，只剩下那颗 1（补给已清空，不会再进新珠）
    expect(state.shots).toHaveLength(0);
    expect(state.score).toBeGreaterThan(0);
    expect(state.balls.map((ball) => ball.color)).toEqual([1]);
  });
});

describe('印加弹珠：关卡与重开', () => {
  it('同一种子同一局完全可复现，重开则换一套补给', () => {
    const first = createInitialState(1, 'replay');
    expect(createInitialState(1, 'replay')).toEqual(first);
    const second = restart(first);
    expect(second.round).toBe(1);
    expect(second.supply).not.toEqual(first.supply);
    expect(second).toEqual(createInitialState(1, 'replay', 1));
    expect(levelSeed('replay', 1)).toBe('replay#1');
  });

  it('开局链条 + 补给合计就是本关弹珠总数，颜色都在范围内', () => {
    LEVELS.forEach((level, index) => {
      const state = createInitialState(index, 'colors');
      expect(state.balls.length + state.supply.length).toBe(level.supply);
      expect(state.balls).toHaveLength(level.opening);
      const colors = [
        ...state.supply.map((item) => item.color),
        ...state.balls.map((ball) => ball.color),
      ];
      for (const color of colors) {
        expect(color).toBeGreaterThanOrEqual(0);
        expect(color).toBeLessThan(level.colors);
      }
    });
  });

  it('每关按配置撒下炸弹珠与闪光珠', () => {
    LEVELS.forEach((level, index) => {
      const state = createInitialState(index, 'powers');
      const all = [
        ...state.balls.map((ball) => ball.power),
        ...state.supply.map((item) => item.power),
      ];
      expect(all.filter((power) => power === 'bomb')).toHaveLength(level.bombs);
      expect(all.filter((power) => power === 'reverse')).toHaveLength(level.reverses);
    });
  });

  it('levelAt 对越界下标回退到默认档位', () => {
    expect(levelAt(99)).toEqual(LEVELS[DEFAULT_LEVEL]);
  });

  it('成绩即当前得分', () => {
    const state = withChain([0, 0, 1]);
    expect(scoreFor({ ...state, score: 250 })).toBe(250);
    expect(BALL_RADIUS).toBeGreaterThan(0);
  });
});

describe('印加弹珠：道具珠', () => {
  it('炸弹珠被消掉时炸掉附近一整片', () => {
    // 队首三颗同色（其中一颗是炸弹），后面紧跟一串异色，爆炸半径内的都得没
    const chain = withChain([0, 0, 1, 2, 3, 4, 5, 6, 7], 200, { 1: 'bomb' });
    const before = chain.balls.length;
    const after = applyHit(chain, 1, 0, false);

    // 三连本身 3 颗 + 爆炸半径（3.2 个身位）内的邻居
    const removed = before + 1 - after.balls.length;
    expect(removed).toBeGreaterThan(3);
    expect(after.score).toBe(removed * 10);
    expect(after.effects.some((effect) => effect.kind === 'blast')).toBe(true);
    // 幸存的珠子都在爆炸半径之外
    const bombDist = (chain.balls[1] as MarbleBall).dist;
    for (const ball of after.balls) {
      expect(Math.abs(ball.dist - bombDist)).toBeGreaterThan(BOMB_RADIUS);
    }
  });

  it('炸弹连环引爆：炸到的另一颗炸弹继续炸', () => {
    // 第二颗炸弹落在第一颗的爆炸半径内，被炸到后接力再炸一片
    const colors = [0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9];
    const single = applyHit(withChain(colors, 200, { 1: 'bomb' }), 1, 0, false);
    const chained = applyHit(withChain(colors, 200, { 1: 'bomb', 3: 'bomb' }), 1, 0, false);

    expect(chained.balls.length).toBeLessThan(single.balls.length);
    expect(chained.score).toBeGreaterThan(single.score);
    expect(chained.effects.filter((effect) => effect.kind === 'blast')).toHaveLength(2);
  });

  it('闪光珠把倒退挂账，随后带加速地把链条拉回去', () => {
    // 同一手消除，只差队首那颗带不带闪光
    let plain = applyHit(withChain([0, 0, 1, 2, 3, 4], 300), 1, 0, false);
    let flashy = applyHit(withChain([0, 0, 1, 2, 3, 4], 300, { 1: 'reverse' }), 1, 0, false);

    // 不是瞬移：命中当帧只记账，位置还没动
    expect(flashy.pullback).toBeCloseTo(REVERSE_DISTANCE, 5);
    expect(plain.pullback).toBe(0);
    expect(flashy.balls[0]?.dist).toBeCloseTo(plain.balls[0]?.dist as number, 5);

    // 倒退是加速的：第二帧退得比第一帧多
    const before = flashy.balls[0]?.dist as number;
    const frame1 = step(flashy, 1 / 60);
    const frame2 = step(frame1, 1 / 60);
    const delta1 = before - (frame1.balls[0]?.dist as number);
    const delta2 = (frame1.balls[0]?.dist as number) - (frame2.balls[0]?.dist as number);
    expect(delta2).toBeGreaterThan(delta1);

    // 退完之后与不带闪光的那局刚好差一个 REVERSE_DISTANCE
    for (let frame = 0; frame < 240; frame += 1) {
      plain = step(plain, 1 / 60);
      flashy = step(flashy, 1 / 60);
    }
    expect(flashy.pullback).toBe(0);
    expect(flashy.balls[0]?.dist as number).toBeCloseTo(
      (plain.balls[0]?.dist as number) - REVERSE_DISTANCE,
      1,
    );
    expect(flashy.effects.some((effect) => effect.kind === 'reverse')).toBe(false);
  });

  it('倒退不会把队尾推到入口之前，且保持一个身位的间距', () => {
    const chain = withChain([0, 1, 2, 3], 3 * SPACING + 1);
    const rolled = rollbackChain(chain.balls, 999);
    expect((rolled[rolled.length - 1] as MarbleBall).dist).toBe(0);
    for (let i = 1; i < rolled.length; i += 1) {
      const ahead = rolled[i - 1] as MarbleBall;
      const current = rolled[i] as MarbleBall;
      expect(ahead.dist - current.dist).toBeCloseTo(SPACING, 5);
    }
    expect(rollbackChain(chain.balls, 0)).toEqual(chain.balls);
  });

  it('特效有寿命，过期后被 step 清掉', () => {
    const chain = withChain([0, 0, 1, 2, 3], 200, { 1: 'bomb' });
    let state = applyHit(chain, 1, 0, false);
    expect(state.effects.length).toBeGreaterThan(0);
    for (let frame = 0; frame < 60; frame += 1) state = step(state, 1 / 60);
    expect(state.effects).toHaveLength(0);
  });

  it('发射出去的弹珠永远不带道具', () => {
    const chain = withChain([0, 1, 2], 200, { 0: 'bomb' });
    const after = applyHit(chain, 1, 5, false);
    expect(after.balls.filter((ball) => ball.power === 'bomb')).toHaveLength(1);
    expect(after.balls.find((ball) => ball.color === 5)?.power).toBeUndefined();
  });
});
