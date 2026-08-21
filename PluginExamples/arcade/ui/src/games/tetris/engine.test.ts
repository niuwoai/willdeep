import { describe, expect, it } from 'vitest';
import {
  BOARD_HEIGHT,
  PIECE_KINDS,
  createBoard,
  createPieceQueue,
  createState,
  hardDrop,
  lock,
  move,
  rotate,
  scoreForLines,
  step,
  type TetrisState,
} from './engine';

const stateWith = (overrides: Partial<TetrisState>): TetrisState => ({ ...createState(), ...overrides });

describe('Tetris engine', () => {
  it('rotates a piece', () => {
    const result = rotate(createState('T'));
    expect(result.active.rotation).toBe(1);
  });

  it('kicks a rotating piece away from a wall', () => {
    const result = rotate(stateWith({ active: { kind: 'T', rotation: 3, x: -1, y: 2 } }));
    expect(result.active.rotation).toBe(0);
    expect(result.active.x).toBe(0);
  });

  it('clears complete rows and increases score', () => {
    const board = createBoard();
    const bottom = board[BOARD_HEIGHT - 1]!;
    const second = board[BOARD_HEIGHT - 2]!;
    bottom.fill(1);
    bottom[4] = 0;
    second.fill(1);
    second[4] = 0;
    const result = lock(
      stateWith({
        board,
        active: { kind: 'I', rotation: 1, x: 2, y: BOARD_HEIGHT - 4 },
        score: 25,
        lines: 8,
        level: 1,
      }),
      'O',
    );
    expect(result.lines).toBe(10);
    expect(result.level).toBe(2);
    expect(result.score).toBe(25 + scoreForLines(2, 1));
    expect(result.board.flat().filter(Boolean)).toHaveLength(2);
  });

  it('ends the game when a locked piece remains above the board', () => {
    const board = createBoard();
    board[1]![4] = 1;
    const state = stateWith({ board, active: { kind: 'T', rotation: 0, x: 3, y: -1 } });
    expect(move(state, 0, 1)).toBe(state);
    expect(lock(state).gameOver).toBe(true);
  });

  it('scores hard drops and resets through a fresh state', () => {
    const dropped = hardDrop(createState('O', 'I'), 'T');
    expect(dropped.state.score).toBeGreaterThan(0);
    expect(dropped.state.board.flat().filter(Boolean)).toHaveLength(4);
    const restarted = createState('O', 'I');
    expect(restarted.score).toBe(0);
    expect(restarted.lines).toBe(0);
    expect(restarted.gameOver).toBe(false);
  });

  it('reports lock only when the piece settles', () => {
    const falling = step(createState('T', 'I'));
    expect(falling.locked).toBe(false);
    expect(falling.state.active.y).toBe(0);
    const settled = step(stateWith({ active: { kind: 'O', rotation: 0, x: 3, y: BOARD_HEIGHT - 2 } }), 'T');
    expect(settled.locked).toBe(true);
    expect(settled.state.board.flat().filter(Boolean)).toHaveLength(4);
  });

  it('produces a deterministic 7-bag queue from a seed', () => {
    const first = createPieceQueue('e2e-tetris', 14);
    const second = createPieceQueue('e2e-tetris', 14);
    expect(first).toEqual(second);
    expect(new Set(first.slice(0, 7))).toEqual(new Set(PIECE_KINDS));
  });
});
