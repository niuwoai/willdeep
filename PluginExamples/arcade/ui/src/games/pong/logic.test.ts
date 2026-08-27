/**
 * 乒乓球物理回归（canvas 重制版的纯函数部分）。
 *
 * 覆盖：发球等待、上下边框反弹、球拍回球角度、丢球记分与重新发球、
 * 先得 5 分赢下这一关，以及关卡越高球越快。
 */
import { describe, expect, it } from 'vitest';
import {
  SERVE_DELAY,
  TABLE_H,
  TABLE_W,
  WIN_SCORE,
  ballSpeedForStage,
  cpuSpeedForStage,
  createState,
  stepPong,
} from './index';
import type { PongState } from './index';

/** 跑若干帧（默认 1/60 秒一帧）。 */
function run(state: PongState, frames: number, stage = 1, dt = 1 / 60): PongState {
  let current = state;
  for (let i = 0; i < frames; i += 1) current = stepPong(current, dt, stage);
  return current;
}

describe('乒乓球：发球', () => {
  it('开局先等 1 秒再发球，等待期间球停在中线', () => {
    const state = createState(1);
    expect(state.serveIn).toBe(SERVE_DELAY);

    const waiting = run(state, 30); // 0.5 秒
    expect(waiting.serveIn).toBeGreaterThan(0);
    expect(waiting.ballX).toBe(TABLE_W / 2);
    expect(waiting.ballY).toBe(TABLE_H / 2);

    const served = run(waiting, 45); // 再 0.75 秒，早过了发球点
    expect(served.serveIn).toBe(0);
    expect(served.ballX).not.toBe(TABLE_W / 2);
  });

  it('发球方向朝上一次丢球的一方', () => {
    const toPlayer = run(createState(1, -1), 70);
    expect(toPlayer.ballX).toBeLessThan(TABLE_W / 2);
    const toCpu = run(createState(1, 1), 70);
    expect(toCpu.ballX).toBeGreaterThan(TABLE_W / 2);
  });
});

describe('乒乓球：球的物理', () => {
  it('撞上下边框反弹，不会跑出桌面', () => {
    const state: PongState = { ...createState(1), serveIn: 0, ballY: 3, vx: 0, vy: -40 };
    const bounced = run(state, 20);
    expect(bounced.ballY).toBeGreaterThanOrEqual(0);
    expect(bounced.vy).toBeGreaterThan(0);
  });

  it('球拍接到球会把球打回去，命中点越靠边角度越大', () => {
    const base: PongState = {
      ...createState(1),
      serveIn: 0,
      ballX: 12,
      ballY: 29,
      vx: -ballSpeedForStage(1),
      vy: 0,
      playerY: 29 - 6.5,
    };
    const center = run(base, 8);
    expect(center.vx).toBeGreaterThan(0);

    // 打在球拍上缘：回球明显带向上的分量
    const edge = run({ ...base, playerY: 29 - 1 }, 8);
    expect(edge.vx).toBeGreaterThan(0);
    expect(Math.abs(edge.vy)).toBeGreaterThan(Math.abs(center.vy));
  });

  it('球从玩家侧出界：CPU 得分，并重新进入发球等待', () => {
    const state: PongState = {
      ...createState(1),
      serveIn: 0,
      ballX: 2,
      ballY: 5,
      vx: -ballSpeedForStage(1),
      vy: 0,
      playerY: 40,
    };
    const scored = run(state, 10);
    expect(scored.cpu).toBe(1);
    expect(scored.player).toBe(0);
    // 出界那一帧起算，随后几帧继续倒数，所以只断言「还在等发球」
    expect(scored.serveIn).toBeGreaterThan(SERVE_DELAY * 0.8);
    expect(scored.serveIn).toBeLessThanOrEqual(SERVE_DELAY);
    expect(scored.serveDir).toBe(-1);
    expect(scored.ballX).toBe(TABLE_W / 2);
  });
});

describe('乒乓球：胜负与关卡', () => {
  it('先得 5 分赢下这一关，赢了之后不再推进', () => {
    const matchPoint: PongState = {
      ...createState(1),
      serveIn: 0,
      player: WIN_SCORE - 1,
      ballX: TABLE_W - 1,
      ballY: 5,
      vx: ballSpeedForStage(1),
      vy: 0,
      cpuY: 40,
    };
    const won = run(matchPoint, 10);
    expect(won.player).toBe(WIN_SCORE);
    expect(won.won).toBe(true);
    expect(stepPong(won, 1, 1)).toEqual(won);
  });

  it('关卡越高，球速与 CPU 跟球速度越快（CPU 有上限）', () => {
    expect(ballSpeedForStage(3)).toBeGreaterThan(ballSpeedForStage(1));
    expect(cpuSpeedForStage(3)).toBeGreaterThan(cpuSpeedForStage(1));
    expect(cpuSpeedForStage(99)).toBeLessThanOrEqual(78);
  });
});
