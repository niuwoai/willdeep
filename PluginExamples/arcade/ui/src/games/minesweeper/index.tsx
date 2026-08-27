import { useEffect, useMemo, useState } from 'react';
import type { GameProps } from '../../core/types';
import { saveBestScore } from '../../core/bestScore';
import { playCue } from '../../core/audio';
import { useI18n } from '../../core/i18n';
import { BOARD_SIZE, createBoard, reveal, type Board } from './logic';
import { minesweeperStrings } from './strings';
import './minesweeper.css';

export default function MinesweeperGame({ seed, onWin }: GameProps) {
  const { locale } = useI18n();
  const strings = minesweeperStrings(locale);
  const sourceSeed = seed ?? 'default';
  const [round, setRound] = useState(0);
  const [board, setBoard] = useState<Board>(() => createBoard(sourceSeed));
  const lost = useMemo(() => board.some((cell) => cell.mine && cell.revealed), [board]);
  const safeRemaining = board.filter((cell) => !cell.mine && !cell.revealed).length;
  const flags = board.filter((cell) => cell.flagged).length;
  const won = !lost && safeRemaining === 0;
  useEffect(() => { setBoard(createBoard(`${sourceSeed}:${round}`)); }, [sourceSeed, round]);
  useEffect(() => {
    if (!won) return;
    saveBestScore('minesweeper', BOARD_SIZE * BOARD_SIZE - flags);
    playCue('win');
    onWin?.();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [won]);
  // 踩雷给一声闷响
  useEffect(() => { if (lost) playCue('boom'); }, [lost]);
  const restart = () => setRound((value) => value + 1);
  return <section className="minesweeper" data-testid="minesweeper-game">
    <div className="minesweeper__stats"><span>{strings.mines}: 10</span><span data-testid="minesweeper-flags">{strings.flags}: {flags}</span><span>{strings.safe}: {safeRemaining}</span></div>
    <p data-testid="minesweeper-status">{lost ? strings.lost : won ? strings.won : strings.help}</p>
    <div className="minesweeper__board" role="grid" aria-label={strings.mines} data-testid="minesweeper-board">
      {board.map((cell, index) => <button key={index} type="button" className={`minesweeper__cell ${cell.revealed ? 'minesweeper__cell--revealed' : ''} ${cell.revealed && cell.mine ? 'minesweeper__cell--mine' : ''} ${cell.flagged ? 'minesweeper__cell--flagged' : ''}`} data-testid="minesweeper-cell" aria-label={`${Math.floor(index / BOARD_SIZE) + 1}-${index % BOARD_SIZE + 1}`} disabled={lost || won} onClick={() => { playCue('reveal'); setBoard((current) => reveal(current, index)); }} onContextMenu={(event) => { event.preventDefault(); if (!lost && !won) playCue('flag'); if (!lost && !won) setBoard((current) => current.map((item, cellIndex) => cellIndex === index && !item.revealed ? { ...item, flagged: !item.flagged } : item)); }}>
        {cell.revealed ? (cell.mine ? '●' : cell.adjacent || '') : cell.flagged ? '⚑' : ''}
      </button>)}
    </div>
    <button type="button" className="btn" onClick={restart}>{strings.newGame}</button>
  </section>;
}
