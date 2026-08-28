export const FIELD_WIDTH = 100;
export const FIELD_HEIGHT = 72;
export const BALL_RADIUS = 1.25;
export const PADDLE_Y = 66;
export const PADDLE_HEIGHT = 2.4;
export const INITIAL_LIVES = 3;
export const BRICK_COLUMNS = 10;
export const BRICK_SCORE = 10;

export type BreakoutStatus = 'idle' | 'playing' | 'paused' | 'won' | 'lost';

export interface Brick {
  id: number;
  x: number;
  y: number;
  width: number;
  height: number;
  color: number;
}

export interface BreakoutState {
  paddleX: number;
  ballX: number;
  ballY: number;
  vx: number;
  vy: number;
  bricks: readonly Brick[];
  lives: number;
  score: number;
  status: BreakoutStatus;
}

export function brickRowsForStage(stage: number): number {
  return Math.min(8, 3 + Math.max(1, stage));
}

export function paddleWidthForStage(stage: number): number {
  return Math.max(10, 18 - Math.max(0, stage - 1) * 0.75);
}

export function ballSpeedForStage(stage: number): number {
  return Math.min(62, 32 + Math.max(1, stage) * 3);
}

export function createBricks(stage: number): Brick[] {
  const rows = brickRowsForStage(stage);
  const gap = 0.8;
  const margin = 4;
  const width = (FIELD_WIDTH - margin * 2 - gap * (BRICK_COLUMNS - 1)) / BRICK_COLUMNS;
  const height = 3.7;
  const top = 7;
  return Array.from({ length: rows * BRICK_COLUMNS }, (_, id) => {
    const row = Math.floor(id / BRICK_COLUMNS);
    const column = id % BRICK_COLUMNS;
    return {
      id,
      x: margin + column * (width + gap),
      y: top + row * (height + gap),
      width,
      height,
      color: row % 6,
    };
  });
}

function serveVelocity(stage: number): { vx: number; vy: number } {
  const speed = ballSpeedForStage(stage);
  const vx = speed * 0.48;
  return { vx, vy: -Math.sqrt(speed * speed - vx * vx) };
}

export function createInitialState(stage: number): BreakoutState {
  const paddleX = FIELD_WIDTH / 2;
  const velocity = serveVelocity(stage);
  return {
    paddleX,
    ballX: paddleX,
    ballY: PADDLE_Y - BALL_RADIUS - 0.8,
    ...velocity,
    bricks: createBricks(stage),
    lives: INITIAL_LIVES,
    score: 0,
    status: 'idle',
  };
}

export function movePaddle(state: BreakoutState, paddleX: number, stage: number): BreakoutState {
  const half = paddleWidthForStage(stage) / 2;
  const nextX = Math.max(half, Math.min(FIELD_WIDTH - half, paddleX));
  return {
    ...state,
    paddleX: nextX,
    ...(state.status === 'idle' ? { ballX: nextX } : {}),
  };
}

export function togglePlay(state: BreakoutState): BreakoutState {
  if (state.status === 'won' || state.status === 'lost') return state;
  if (state.status === 'playing') return { ...state, status: 'paused' };
  return { ...state, status: 'playing' };
}

function circleTouchesBrick(x: number, y: number, brick: Brick): boolean {
  const nearestX = Math.max(brick.x, Math.min(x, brick.x + brick.width));
  const nearestY = Math.max(brick.y, Math.min(y, brick.y + brick.height));
  const dx = x - nearestX;
  const dy = y - nearestY;
  return dx * dx + dy * dy <= BALL_RADIUS * BALL_RADIUS;
}

function resetServe(state: BreakoutState, stage: number, lives: number): BreakoutState {
  return {
    ...state,
    ballX: state.paddleX,
    ballY: PADDLE_Y - BALL_RADIUS - 0.8,
    ...serveVelocity(stage),
    lives,
    status: lives > 0 ? 'idle' : 'lost',
  };
}

export function stepBreakout(state: BreakoutState, dt: number, stage: number): BreakoutState {
  if (state.status !== 'playing') return state;

  const speed = Math.hypot(state.vx, state.vy);
  const steps = Math.min(12, Math.max(1, Math.ceil((speed * Math.max(0, dt)) / BALL_RADIUS)));
  const stepTime = Math.min(0.05, Math.max(0, dt)) / steps;
  let next = { ...state, bricks: state.bricks.slice() };

  for (let substep = 0; substep < steps; substep += 1) {
    const previousX = next.ballX;
    const previousY = next.ballY;
    let ballX = next.ballX + next.vx * stepTime;
    let ballY = next.ballY + next.vy * stepTime;
    let vx = next.vx;
    let vy = next.vy;

    if (ballX < BALL_RADIUS) {
      ballX = BALL_RADIUS;
      vx = Math.abs(vx);
    } else if (ballX > FIELD_WIDTH - BALL_RADIUS) {
      ballX = FIELD_WIDTH - BALL_RADIUS;
      vx = -Math.abs(vx);
    }
    if (ballY < BALL_RADIUS) {
      ballY = BALL_RADIUS;
      vy = Math.abs(vy);
    }

    const paddleHalf = paddleWidthForStage(stage) / 2;
    const crossesPaddle =
      vy > 0 &&
      previousY + BALL_RADIUS <= PADDLE_Y &&
      ballY + BALL_RADIUS >= PADDLE_Y &&
      ballX >= next.paddleX - paddleHalf - BALL_RADIUS &&
      ballX <= next.paddleX + paddleHalf + BALL_RADIUS;
    if (crossesPaddle) {
      const relative = Math.max(-1, Math.min(1, (ballX - next.paddleX) / paddleHalf));
      const angle = relative * Math.PI * 0.37;
      const currentSpeed = ballSpeedForStage(stage);
      vx = Math.sin(angle) * currentSpeed;
      vy = -Math.cos(angle) * currentSpeed;
      ballY = PADDLE_Y - BALL_RADIUS;
    }

    const hitIndex = next.bricks.findIndex((brick) => circleTouchesBrick(ballX, ballY, brick));
    if (hitIndex >= 0) {
      const hit = next.bricks[hitIndex] as Brick;
      const bricks = next.bricks.filter((_, index) => index !== hitIndex);
      const cameFromSide =
        previousX + BALL_RADIUS <= hit.x || previousX - BALL_RADIUS >= hit.x + hit.width;
      if (cameFromSide) vx = -vx;
      else vy = -vy;
      ballX = previousX;
      ballY = previousY;
      next = {
        ...next,
        bricks,
        score: next.score + BRICK_SCORE * Math.max(1, stage),
      };
      if (bricks.length === 0) {
        return { ...next, ballX, ballY, vx, vy, status: 'won' };
      }
    }

    next = { ...next, ballX, ballY, vx, vy };
    if (ballY - BALL_RADIUS > FIELD_HEIGHT) {
      return resetServe(next, stage, next.lives - 1);
    }
  }

  return next;
}
