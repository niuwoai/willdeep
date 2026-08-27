export const BOARD_SIZE = 9;
export const MINE_COUNT = 10;
/** 第 stage 关的雷数：10 颗起步，每关 +2，30 颗封顶（9×9 再多就没法玩了）。 */
export function minesForStage(stage: number): number {
  return Math.min(30, MINE_COUNT + Math.max(0, stage - 1) * 2);
}
export interface Cell { mine: boolean; revealed: boolean; flagged: boolean; adjacent: number; }
export type Board = Cell[];

const neighbors = (index: number): number[] => { const row = Math.floor(index / BOARD_SIZE); const col = index % BOARD_SIZE; const result: number[] = []; for (let y = row - 1; y <= row + 1; y += 1) for (let x = col - 1; x <= col + 1; x += 1) if ((x !== col || y !== row) && y >= 0 && y < BOARD_SIZE && x >= 0 && x < BOARD_SIZE) result.push(y * BOARD_SIZE + x); return result; };
export function createBoard(seed = 'default', mineCount = MINE_COUNT): Board { let value = [...seed].reduce((total, character) => (total * 31 + character.charCodeAt(0)) >>> 0, 2166136261); const random = () => { value = (value * 1664525 + 1013904223) >>> 0; return value / 4294967296; }; const mines = new Set<number>(); const total = Math.max(1, Math.min(BOARD_SIZE * BOARD_SIZE - 1, mineCount)); while (mines.size < total) mines.add(Math.floor(random() * BOARD_SIZE * BOARD_SIZE)); return Array.from({ length: BOARD_SIZE * BOARD_SIZE }, (_, index) => ({ mine: mines.has(index), revealed: false, flagged: false, adjacent: 0 })).map((cell, index, board) => ({ ...cell, adjacent: neighbors(index).filter((neighbor) => board[neighbor]?.mine).length })); }
export function reveal(board: Board, index: number): Board { if (board[index]?.revealed || board[index]?.flagged) return board; const next = board.map((cell) => ({ ...cell })); const visit = (current: number) => { const cell = next[current]; if (!cell || cell.revealed || cell.flagged) return; cell.revealed = true; if (!cell.mine && cell.adjacent === 0) neighbors(current).forEach(visit); }; visit(index); return next; }
