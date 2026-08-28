import type { Rng } from '../../core/rng';

export const BOARD_SIZE = 4;
export const CELL_COUNT = BOARD_SIZE * BOARD_SIZE;

export type MoveDirection = 'up' | 'down' | 'left' | 'right';
export type Twenty48Status = 'idle' | 'playing' | 'won' | 'lost';

export interface Twenty48State {
  board: readonly number[];
  score: number;
  moves: number;
  target: number;
  status: Twenty48Status;
}

export interface MoveResult {
  board: readonly number[];
  moved: boolean;
  scoreDelta: number;
}

export function targetForStage(stage: number): number {
  return 2 ** (10 + Math.max(1, stage));
}

export function slideLine(line: readonly number[]): { line: number[]; scoreDelta: number } {
  const values = line.filter((value) => value !== 0);
  const merged: number[] = [];
  let scoreDelta = 0;

  for (let index = 0; index < values.length; index += 1) {
    const current = values[index] as number;
    if (current === values[index + 1]) {
      const value = current * 2;
      merged.push(value);
      scoreDelta += value;
      index += 1;
    } else {
      merged.push(current);
    }
  }

  while (merged.length < BOARD_SIZE) merged.push(0);
  return { line: merged, scoreDelta };
}

function lineIndexes(direction: MoveDirection, line: number): number[] {
  const indexes = Array.from({ length: BOARD_SIZE }, (_, offset) => {
    if (direction === 'left' || direction === 'right') return line * BOARD_SIZE + offset;
    return offset * BOARD_SIZE + line;
  });
  return direction === 'right' || direction === 'down' ? indexes.reverse() : indexes;
}

export function moveBoard(board: readonly number[], direction: MoveDirection): MoveResult {
  const next = board.slice();
  let scoreDelta = 0;

  for (let line = 0; line < BOARD_SIZE; line += 1) {
    const indexes = lineIndexes(direction, line);
    const result = slideLine(indexes.map((index) => board[index] as number));
    scoreDelta += result.scoreDelta;
    indexes.forEach((index, offset) => {
      next[index] = result.line[offset] as number;
    });
  }

  return {
    board: next,
    moved: next.some((value, index) => value !== board[index]),
    scoreDelta,
  };
}

export function addRandomTile(board: readonly number[], rng: Rng): number[] {
  const empty = board.flatMap((value, index) => (value === 0 ? [index] : []));
  if (empty.length === 0) return board.slice();
  const position = empty[Math.floor(rng() * empty.length)] as number;
  const next = board.slice();
  next[position] = rng() < 0.9 ? 2 : 4;
  return next;
}

export function canMove(board: readonly number[]): boolean {
  if (board.some((value) => value === 0)) return true;
  for (let row = 0; row < BOARD_SIZE; row += 1) {
    for (let column = 0; column < BOARD_SIZE; column += 1) {
      const index = row * BOARD_SIZE + column;
      const value = board[index];
      if (column + 1 < BOARD_SIZE && board[index + 1] === value) return true;
      if (row + 1 < BOARD_SIZE && board[index + BOARD_SIZE] === value) return true;
    }
  }
  return false;
}

export function createInitialState(rng: Rng, target = 2048): Twenty48State {
  const first = addRandomTile(Array(CELL_COUNT).fill(0), rng);
  return {
    board: addRandomTile(first, rng),
    score: 0,
    moves: 0,
    target,
    status: 'idle',
  };
}

export function moveState(
  state: Twenty48State,
  direction: MoveDirection,
  rng: Rng,
): Twenty48State {
  if (state.status === 'won' || state.status === 'lost') return state;
  const result = moveBoard(state.board, direction);
  if (!result.moved) {
    return canMove(state.board) ? state : { ...state, status: 'lost' };
  }

  const board = addRandomTile(result.board, rng);
  const reachedTarget = board.some((value) => value >= state.target);
  return {
    ...state,
    board,
    score: state.score + result.scoreDelta,
    moves: state.moves + 1,
    status: reachedTarget ? 'won' : canMove(board) ? 'playing' : 'lost',
  };
}
