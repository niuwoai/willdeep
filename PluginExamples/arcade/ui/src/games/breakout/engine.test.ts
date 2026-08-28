import { describe, expect, it } from 'vitest';
import {
  BALL_RADIUS,
  BRICK_COLUMNS,
  FIELD_HEIGHT,
  INITIAL_LIVES,
  PADDLE_Y,
  ballSpeedForStage,
  brickRowsForStage,
  createInitialState,
  movePaddle,
  paddleWidthForStage,
  stepBreakout,
  togglePlay,
} from './engine';

describe('打砖块关卡', () => {
  it('第 1 关有 4 排砖和 3 条命，后续增加排数并加速', () => {
    const state = createInitialState(1);
    expect(state.bricks).toHaveLength(BRICK_COLUMNS * 4);
    expect(state.lives).toBe(INITIAL_LIVES);
    expect(brickRowsForStage(99)).toBe(8);
    expect(ballSpeedForStage(4)).toBeGreaterThan(ballSpeedForStage(1));
    expect(paddleWidthForStage(4)).toBeLessThan(paddleWidthForStage(1));
  });

  it('待发球时挡板与球一起移动，发球后可以暂停和继续', () => {
    const state = createInitialState(1);
    const moved = movePaddle(state, 80, 1);
    expect(moved.paddleX).toBe(80);
    expect(moved.ballX).toBe(80);
    expect(togglePlay(state).status).toBe('playing');
    expect(togglePlay(togglePlay(state)).status).toBe('paused');
  });
});

describe('打砖块碰撞', () => {
  it('撞到顶边会向下反弹', () => {
    const state = {
      ...createInitialState(1),
      status: 'playing' as const,
      ballY: BALL_RADIUS + 0.1,
      vy: -ballSpeedForStage(1),
      vx: 0,
    };
    const next = stepBreakout(state, 0.05, 1);
    expect(next.ballY).toBeGreaterThanOrEqual(BALL_RADIUS);
    expect(next.vy).toBeGreaterThan(0);
  });

  it('命中砖块后移除一块并计分', () => {
    const state = createInitialState(1);
    const brick = state.bricks[0]!;
    const next = stepBreakout({
      ...state,
      status: 'playing',
      ballX: brick.x + brick.width / 2,
      ballY: brick.y + brick.height + BALL_RADIUS + 0.1,
      vx: 0,
      vy: -ballSpeedForStage(1),
    }, 0.02, 1);
    expect(next.bricks).toHaveLength(state.bricks.length - 1);
    expect(next.score).toBeGreaterThan(0);
    expect(next.vy).toBeGreaterThan(0);
  });

  it('挡板能把下落的球反弹回去', () => {
    const state = createInitialState(1);
    const next = stepBreakout({
      ...state,
      status: 'playing',
      ballX: state.paddleX,
      ballY: PADDLE_Y - BALL_RADIUS - 0.2,
      vx: 0,
      vy: ballSpeedForStage(1),
    }, 0.02, 1);
    expect(next.vy).toBeLessThan(0);
  });

  it('球掉出底边扣一条命，最后一条命掉完判负', () => {
    const state = createInitialState(1);
    const dropped = stepBreakout({
      ...state,
      status: 'playing',
      ballY: FIELD_HEIGHT + BALL_RADIUS + 1,
      vy: ballSpeedForStage(1),
      lives: 2,
    }, 0.02, 1);
    expect(dropped.lives).toBe(1);
    expect(dropped.status).toBe('idle');

    const lost = stepBreakout({ ...dropped, status: 'playing', ballY: FIELD_HEIGHT + 3 }, 0.02, 1);
    expect(lost.lives).toBe(0);
    expect(lost.status).toBe('lost');
  });

  it('最后一块砖被击中就通关', () => {
    const base = createInitialState(1);
    const brick = base.bricks[0]!;
    const won = stepBreakout({
      ...base,
      bricks: [brick],
      status: 'playing',
      ballX: brick.x + brick.width / 2,
      ballY: brick.y + brick.height + BALL_RADIUS + 0.1,
      vx: 0,
      vy: -ballSpeedForStage(1),
    }, 0.02, 1);
    expect(won.bricks).toHaveLength(0);
    expect(won.status).toBe('won');
  });
});
