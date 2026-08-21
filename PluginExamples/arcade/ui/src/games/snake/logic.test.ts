import { describe, expect, it } from 'vitest';
import {
  GRID_COLS,
  GRID_ROWS,
  INITIAL_LENGTH,
  MILESTONE_FOOD,
  canTurn,
  initialState,
  placeFood,
  resetState,
  step,
} from './logic';
import type { Direction, Point, SnakeState } from './logic';

function cell(row: number, col: number): Point {
  return { row, col };
}

/** 构造 playing 状态：food 默认放在 (0, GRID_COLS-1)，与蛇身保持远离。 */
function stateWith(
  snake: Point[],
  direction: Direction,
  overrides: Partial<Pick<SnakeState, 'food' | 'score' | 'foodsEaten' | 'seed'>> = {},
): SnakeState {
  return {
    snake,
    direction,
    food: overrides.food ?? cell(0, GRID_COLS - 1),
    status: 'playing',
    score: overrides.score ?? 0,
    foodsEaten: overrides.foodsEaten ?? 0,
    seed: overrides.seed ?? 'test',
  };
}

describe('贪吃蛇逻辑：碰撞（撞墙）', () => {
  it('头部越出右墙判负', () => {
    const s = stateWith([cell(10, GRID_COLS - 1), cell(10, GRID_COLS - 2), cell(10, GRID_COLS - 3)], 'right');
    const next = step(s);
    expect(next.status).toBe('gameover');
    expect(next.score).toBe(0);
  });

  it('头部越出上墙判负，且终局状态不可再推进', () => {
    const s = stateWith([cell(0, 5), cell(1, 5), cell(2, 5)], 'up');
    const over = step(s);
    expect(over.status).toBe('gameover');
    expect(step(over)).toBe(over);
  });
});

describe('贪吃蛇逻辑：自咬', () => {
  it('头部走入自身身体（非尾格）判负', () => {
    // 蛇身笔直向右，(5,4) 紧邻头部后方
    const s = stateWith([cell(5, 3), cell(5, 4), cell(5, 5)], 'right');
    const next = step(s);
    expect(next.status).toBe('gameover');
  });

  it('回环后头部咬住自身中部判负', () => {
    // 蛇身绕圈，(6,5) 位于身体中部（尾巴在 (5,3)），向下一步直接咬中
    const s = stateWith(
      [
        cell(5, 5),
        cell(5, 6),
        cell(6, 6),
        cell(6, 7),
        cell(7, 7),
        cell(7, 6),
        cell(7, 5),
        cell(6, 5),
        cell(6, 4),
        cell(5, 4),
        cell(5, 3),
      ],
      'down',
    );
    const next = step(s);
    expect(next.status).toBe('gameover');
  });

  it('头部走入原尾格不算自咬（尾巴让位）', () => {
    // 2x2 方块闭环：向下一步恰好落入即将离开的尾格
    const s = stateWith([cell(5, 5), cell(5, 6), cell(6, 6), cell(6, 5)], 'down');
    const next = step(s);
    expect(next.status).toBe('playing');
    expect(next.snake[0]).toEqual(cell(6, 5));
  });
});

describe('贪吃蛇逻辑：计分', () => {
  it('吃到食物分数 +1、蛇身增长、食物重新放置且不在蛇身上', () => {
    const s = stateWith([cell(5, 5), cell(5, 4), cell(5, 3)], 'right', {
      food: cell(5, 6),
    });
    const next = step(s);
    expect(next.foodsEaten).toBe(1);
    expect(next.score).toBe(1);
    expect(next.snake).toHaveLength(INITIAL_LENGTH + 1);
    expect(next.snake[0]).toEqual(cell(5, 6));
    // 新食物不在蛇身内
    const keys = new Set(next.snake.map((p) => `${p.row},${p.col}`));
    expect(keys.has(`${next.food.row},${next.food.col}`)).toBe(false);
  });

  it('分数随连续进食累加', () => {
    let s = stateWith([cell(5, 5), cell(5, 4), cell(5, 3)], 'right', {
      food: cell(5, 6),
      seed: 'scoring',
    });
    s = step(s); // 吃 1，head (5,6)
    s = step(s); // 前进一格到 (5,7)，未吃
    expect(s.score).toBe(1);
    s = { ...s, food: cell(5, 8) };
    s = step(s); // 吃 2
    expect(s.score).toBe(2);
    expect(s.foodsEaten).toBe(2);
  });
});

describe('贪吃蛇逻辑：里程碑胜利', () => {
  it('吃满 MILESTONE_FOOD 个食物触发通关', () => {
    let s = stateWith([cell(5, 5), cell(5, 4), cell(5, 3)], 'right', {
      food: cell(5, 6),
      foodsEaten: MILESTONE_FOOD - 1,
      seed: 'milestone',
    });
    s = step(s);
    expect(s.foodsEaten).toBe(MILESTONE_FOOD);
    expect(s.score).toBe(MILESTONE_FOOD);
    expect(s.status).toBe('won');
    // 通关后不再推进
    expect(step(s)).toBe(s);
  });

  it('未吃满里程碑前状态保持 playing', () => {
    const s = stateWith([cell(5, 5), cell(5, 4), cell(5, 3)], 'right', {
      food: cell(5, 6),
      foodsEaten: MILESTONE_FOOD - 2,
    });
    expect(step(s).status).toBe('playing');
  });
});

describe('贪吃蛇逻辑：重开复位', () => {
  it('resetState 回到初始状态（分数、长度、方向、状态、食物）', () => {
    const initial = initialState('reset-seed');
    const head = initial.snake[0]!;
    let played = stateWith(initial.snake, 'right', {
      food: cell(head.row, head.col + 1),
      seed: 'reset-seed',
    });
    played = step(played); // 吃 1 分
    played = step(played); // 继续走
    expect(played.score).toBeGreaterThan(0);

    const restarted = resetState(played);
    expect(restarted.seed).toBe('reset-seed');
    expect(restarted.score).toBe(0);
    expect(restarted.foodsEaten).toBe(0);
    expect(restarted.status).toBe('idle');
    expect(restarted.direction).toBe('right');
    expect(restarted.snake).toHaveLength(INITIAL_LENGTH);
    expect(restarted).toEqual(initialState('reset-seed'));
  });

  it('initialState 保持种子确定性：同种子食物一致、蛇身一致', () => {
    const a = initialState('same');
    const b = initialState('same');
    expect(a.food).toEqual(b.food);
    expect(a.snake).toEqual(b.snake);
    expect(a.score).toBe(0);
    expect(a.status).toBe('idle');
  });
});

describe('贪吃蛇逻辑：方向规则', () => {
  it('禁止 180° 掉头与原地转向', () => {
    expect(canTurn('right', 'up')).toBe(true);
    expect(canTurn('right', 'down')).toBe(true);
    expect(canTurn('right', 'left')).toBe(false);
    expect(canTurn('up', 'down')).toBe(false);
    expect(canTurn('right', 'right')).toBe(false);
  });

  it('step 忽略 180° 掉头请求，维持原方向', () => {
    const s = stateWith([cell(5, 5), cell(5, 4), cell(5, 3)], 'right');
    const next = step(s, 'left');
    expect(next.status).toBe('playing');
    expect(next.direction).toBe('right');
    expect(next.snake[0]).toEqual(cell(5, 6));
  });
});

describe('贪吃蛇逻辑：食物放置', () => {
  it('食物始终落在棋盘内且避开蛇身', () => {
    const s = initialState('food-check');
    const p = placeFood(s.snake, s.seed, 1);
    expect(p.row).toBeGreaterThanOrEqual(0);
    expect(p.row).toBeLessThan(GRID_ROWS);
    expect(p.col).toBeGreaterThanOrEqual(0);
    expect(p.col).toBeLessThan(GRID_COLS);
    const keys = new Set(s.snake.map((q) => `${q.row},${q.col}`));
    expect(keys.has(`${p.row},${p.col}`)).toBe(false);
  });
});
