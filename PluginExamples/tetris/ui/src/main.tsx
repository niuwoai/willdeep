import React, { useEffect, useMemo, useReducer } from "react";
import { createRoot } from "react-dom/client";
import "./style.css";
import en from "./locales/en.json";
import zhHans from "./locales/zh-Hans.json";

const BOARD_WIDTH = 10;
const BOARD_HEIGHT = 20;
const EMPTY = 0;
const messages = {en, "zh-Hans": zhHans} as const;

type Difficulty = "easy" | "normal" | "hard";
type Matrix = number[][];
type Piece = {shape: Matrix; color: number; x: number; y: number};
type Board = number[][];
type Context = {selectedItemID?: string; locale?: string};
type State = {
  board: Board;
  piece: Piece;
  next: Piece;
  score: number;
  lines: number;
  level: number;
  difficulty: Difficulty;
  paused: boolean;
  gameOver: boolean;
};
type Action =
  | {type: "tick"}
  | {type: "move"; dx: number; dy: number}
  | {type: "rotate"}
  | {type: "drop"}
  | {type: "togglePause"}
  | {type: "reset"; difficulty?: Difficulty};

declare global {
  interface Window {
    willdeep?: {getContext(): Context};
  }
}

const SHAPES: Matrix[] = [
  [[1, 1, 1, 1]],
  [[1, 1], [1, 1]],
  [[0, 1, 0], [1, 1, 1]],
  [[0, 1, 1], [1, 1, 0]],
  [[1, 1, 0], [0, 1, 1]],
  [[1, 0, 0], [1, 1, 1]],
  [[0, 0, 1], [1, 1, 1]]
];

const emptyBoard = (): Board => Array.from({length: BOARD_HEIGHT}, () => Array(BOARD_WIDTH).fill(EMPTY));

function randomPiece(): Piece {
  const index = Math.floor(Math.random() * SHAPES.length);
  const shape = SHAPES[index].map((row) => [...row]);
  return {shape, color: index + 1, x: Math.floor((BOARD_WIDTH - shape[0].length) / 2), y: 0};
}

function rotate(shape: Matrix): Matrix {
  return shape[0].map((_, column) => shape.map((row) => row[column]).reverse());
}

function collides(board: Board, piece: Piece, dx = 0, dy = 0, shape = piece.shape): boolean {
  return shape.some((row, rowIndex) => row.some((cell, columnIndex) => {
    if (!cell) return false;
    const x = piece.x + columnIndex + dx;
    const y = piece.y + rowIndex + dy;
    return x < 0 || x >= BOARD_WIDTH || y >= BOARD_HEIGHT || (y >= 0 && board[y][x] !== EMPTY);
  }));
}

function merge(board: Board, piece: Piece): Board {
  const next = board.map((row) => [...row]);
  piece.shape.forEach((row, rowIndex) => row.forEach((cell, columnIndex) => {
    const y = piece.y + rowIndex;
    const x = piece.x + columnIndex;
    if (cell && y >= 0) next[y][x] = piece.color;
  }));
  return next;
}

function removeFullLines(board: Board): {board: Board; cleared: number} {
  const remaining = board.filter((row) => row.some((cell) => cell === EMPTY));
  const cleared = BOARD_HEIGHT - remaining.length;
  return {
    board: [...Array.from({length: cleared}, () => Array(BOARD_WIDTH).fill(EMPTY)), ...remaining],
    cleared
  };
}

function initialState(difficulty: Difficulty = "normal"): State {
  return {
    board: emptyBoard(),
    piece: randomPiece(),
    next: randomPiece(),
    score: 0,
    lines: 0,
    level: 1,
    difficulty,
    paused: false,
    gameOver: false
  };
}

function lockPiece(state: State): State {
  const result = removeFullLines(merge(state.board, state.piece));
  const totalLines = state.lines + result.cleared;
  const level = 1 + Math.floor(totalLines / 10);
  const spawned = {...state.next, x: Math.floor((BOARD_WIDTH - state.next.shape[0].length) / 2), y: 0};
  return {
    ...state,
    board: result.board,
    piece: spawned,
    next: randomPiece(),
    score: state.score + [0, 100, 300, 500, 800][result.cleared] * level,
    lines: totalLines,
    level,
    gameOver: collides(result.board, spawned)
  };
}

function reducer(state: State, action: Action): State {
  if (action.type === "reset") return initialState(action.difficulty ?? state.difficulty);
  if (action.type === "togglePause") return state.gameOver ? state : {...state, paused: !state.paused};
  if (state.paused || state.gameOver) return state;
  if (action.type === "rotate") {
    const shape = rotate(state.piece.shape);
    for (const offset of [0, -1, 1, -2, 2]) {
      if (!collides(state.board, state.piece, offset, 0, shape)) {
        return {...state, piece: {...state.piece, shape, x: state.piece.x + offset}};
      }
    }
    return state;
  }
  if (action.type === "move") {
    if (!collides(state.board, state.piece, action.dx, action.dy)) {
      return {...state, piece: {...state.piece, x: state.piece.x + action.dx, y: state.piece.y + action.dy}};
    }
    return action.dy > 0 ? lockPiece(state) : state;
  }
  if (action.type === "drop") {
    let distance = 0;
    while (!collides(state.board, state.piece, 0, distance + 1)) distance += 1;
    return lockPiece({...state, piece: {...state.piece, y: state.piece.y + distance}, score: state.score + distance * 2});
  }
  if (!collides(state.board, state.piece, 0, 1)) {
    return {...state, piece: {...state.piece, y: state.piece.y + 1}};
  }
  return lockPiece(state);
}

function selectedDifficulty(context: Context): Difficulty {
  return context.selectedItemID === "easy" || context.selectedItemID === "hard"
    ? context.selectedItemID
    : "normal";
}

function renderBoard(state: State): Board {
  const board = state.board.map((row) => [...row]);
  let ghostY = state.piece.y;
  while (!collides(state.board, state.piece, 0, ghostY - state.piece.y + 1)) ghostY += 1;
  state.piece.shape.forEach((row, rowIndex) => row.forEach((cell, columnIndex) => {
    if (!cell) return;
    const ghostRow = ghostY + rowIndex;
    const column = state.piece.x + columnIndex;
    if (ghostRow >= 0 && board[ghostRow][column] === EMPTY) board[ghostRow][column] = -state.piece.color;
    const pieceRow = state.piece.y + rowIndex;
    if (pieceRow >= 0) board[pieceRow][column] = state.piece.color;
  }));
  return board;
}

function App() {
  const initialContext = window.willdeep?.getContext() ?? {};
  const [context, setContext] = React.useState<Context>(initialContext);
  const [state, dispatch] = useReducer(reducer, selectedDifficulty(initialContext), initialState);
  const language = context.locale?.startsWith("zh") ? "zh-Hans" : "en";
  const t = messages[language];
  const visibleBoard = useMemo(() => renderBoard(state), [state]);

  useEffect(() => {
    const update = (event: Event) => setContext((event as CustomEvent<Context>).detail);
    window.addEventListener("willdeep:context-changed", update);
    return () => window.removeEventListener("willdeep:context-changed", update);
  }, []);

  useEffect(() => {
    const difficulty = selectedDifficulty(context);
    if (difficulty !== state.difficulty) dispatch({type: "reset", difficulty});
  }, [context.selectedItemID, state.difficulty]);

  useEffect(() => {
    if (state.paused || state.gameOver) return;
    const base = {easy: 900, normal: 700, hard: 430}[state.difficulty];
    const timer = window.setInterval(
      () => dispatch({type: "tick"}),
      Math.max(90, base - (state.level - 1) * 55)
    );
    return () => window.clearInterval(timer);
  }, [state.paused, state.gameOver, state.level, state.difficulty]);

  useEffect(() => {
    const keydown = (event: KeyboardEvent) => {
      const actions: Record<string, Action> = {
        ArrowLeft: {type: "move", dx: -1, dy: 0},
        ArrowRight: {type: "move", dx: 1, dy: 0},
        ArrowDown: {type: "move", dx: 0, dy: 1},
        ArrowUp: {type: "rotate"},
        " ": {type: "drop"},
        p: {type: "togglePause"},
        P: {type: "togglePause"}
      };
      const action = actions[event.key];
      if (!action) return;
      event.preventDefault();
      dispatch(action);
    };
    window.addEventListener("keydown", keydown);
    return () => window.removeEventListener("keydown", keydown);
  }, []);

  return (
    <main>
      <header>
        <div>
          <p className="eyebrow">{t[state.difficulty]}</p>
          <h1>{t.title}</h1>
        </div>
        <button className="primary" onClick={() => dispatch({type: "reset"})}>{t.newGame}</button>
      </header>
      <div className="game-layout">
        <section className="board-wrap">
          <div className="board" role="grid" aria-label={t.title}>
            {visibleBoard.flatMap((row, rowIndex) => row.map((cell, columnIndex) => (
              <span
                className={`cell color-${Math.abs(cell)}${cell < 0 ? " ghost" : ""}`}
                key={`${rowIndex}-${columnIndex}`}
              />
            )))}
          </div>
          {(state.paused || state.gameOver) && (
            <div className="overlay">
              <strong>{state.gameOver ? t.gameOver : t.paused}</strong>
              <span>{state.gameOver ? t.restartHint : t.resume}</span>
            </div>
          )}
        </section>
        <aside>
          <div className="metrics">
            <article><span>{t.score}</span><strong>{state.score.toLocaleString()}</strong></article>
            <article><span>{t.lines}</span><strong>{state.lines}</strong></article>
            <article><span>{t.level}</span><strong>{state.level}</strong></article>
          </div>
          <div className="next-card">
            <span>{t.next}</span>
            <div className="next-grid" style={{gridTemplateColumns: `repeat(${state.next.shape[0].length}, 1fr)`}}>
              {state.next.shape.flatMap((row, rowIndex) => row.map((cell, columnIndex) => (
                <i className={`preview-cell ${cell ? `color-${state.next.color}` : ""}`} key={`${rowIndex}-${columnIndex}`} />
              )))}
            </div>
          </div>
          <button className="secondary" onClick={() => dispatch({type: "togglePause"})}>
            {state.paused ? t.resume : t.pause}
          </button>
          <div className="controls">
            <button aria-label={t.moveLeft} onClick={() => dispatch({type: "move", dx: -1, dy: 0})}>←</button>
            <button aria-label={t.rotate} onClick={() => dispatch({type: "rotate"})}>↻</button>
            <button aria-label={t.moveRight} onClick={() => dispatch({type: "move", dx: 1, dy: 0})}>→</button>
            <button aria-label={t.softDrop} onClick={() => dispatch({type: "move", dx: 0, dy: 1})}>↓</button>
            <button className="wide" aria-label={t.hardDrop} onClick={() => dispatch({type: "drop"})}>⇣</button>
          </div>
        </aside>
      </div>
    </main>
  );
}

createRoot(document.getElementById("root")!).render(<App />);
