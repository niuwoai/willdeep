import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import type { PointerEvent as ReactPointerEvent } from 'react';
import { playCue } from '../../core/audio';
import { saveBestScore } from '../../core/bestScore';
import { useI18n } from '../../core/i18n';
import { useKeyControls } from '../../core/input';
import { createRng, entropySeed } from '../../core/rng';
import { useAutoAdvance, useStageReport } from '../../core/stage';
import type { GameProps } from '../../core/types';
import {
  createInitialState,
  moveState,
  targetForStage,
} from './logic';
import type { MoveDirection, Twenty48State } from './logic';
import { twenty48Strings } from './strings';
import './twenty48.css';

const SWIPE_THRESHOLD = 24;

export default function Twenty48Game({ seed, onWin, onStage }: GameProps) {
  const { locale } = useI18n();
  const strings = twenty48Strings(locale);
  const baseSeed = useMemo(() => seed ?? entropySeed('2048'), [seed]);
  const [stage, setStage] = useState(1);
  const [total, setTotal] = useState(0);
  const rngRef = useRef(createRng(`${baseSeed}@1`));
  const [state, setState] = useState<Twenty48State>(() =>
    createInitialState(rngRef.current, targetForStage(1)));
  const swipeStart = useRef<{ x: number; y: number } | null>(null);
  const terminalHandled = useRef(false);

  const resetStage = useCallback((nextStage: number) => {
    rngRef.current = createRng(`${baseSeed}@${nextStage}`);
    terminalHandled.current = false;
    setState(createInitialState(rngRef.current, targetForStage(nextStage)));
  }, [baseSeed]);

  useEffect(() => resetStage(stage), [resetStage, stage]);

  useStageReport(onStage, {
    stage,
    score: total + state.score,
    label: `${strings.target} ${state.target}`,
  });

  useAutoAdvance(state.status === 'won', () => {
    setTotal((current) => current + state.score);
    setStage((current) => current + 1);
  });

  useEffect(() => {
    if ((state.status !== 'won' && state.status !== 'lost') || terminalHandled.current) return;
    terminalHandled.current = true;
    const finalScore = total + state.score;
    saveBestScore('2048', finalScore);
    if (state.status === 'won') {
      playCue('win');
      onWin?.();
    } else {
      playCue('lose');
    }
  }, [onWin, state.score, state.status, total]);

  const move = useCallback((direction: MoveDirection) => {
    setState((current) => {
      const next = moveState(current, direction, rngRef.current);
      if (next !== current && next.moves !== current.moves) {
        playCue(next.score > current.score ? 'eat' : 'select');
      }
      return next;
    });
  }, []);

  const keyDirections: Record<string, MoveDirection> = {
    ArrowUp: 'up', w: 'up', W: 'up',
    ArrowDown: 'down', s: 'down', S: 'down',
    ArrowLeft: 'left', a: 'left', A: 'left',
    ArrowRight: 'right', d: 'right', D: 'right',
  };
  useKeyControls(
    Object.entries(keyDirections).map(([key, direction]) => ({
      key,
      onDown: () => move(direction),
      preventDefault: true,
    })),
    [move],
  );

  const handlePointerDown = (event: ReactPointerEvent<HTMLDivElement>): void => {
    swipeStart.current = { x: event.clientX, y: event.clientY };
  };

  const handlePointerUp = (event: ReactPointerEvent<HTMLDivElement>): void => {
    const start = swipeStart.current;
    swipeStart.current = null;
    if (!start) return;
    const dx = event.clientX - start.x;
    const dy = event.clientY - start.y;
    if (Math.abs(dx) < SWIPE_THRESHOLD && Math.abs(dy) < SWIPE_THRESHOLD) return;
    if (Math.abs(dx) > Math.abs(dy)) move(dx > 0 ? 'right' : 'left');
    else move(dy > 0 ? 'down' : 'up');
  };

  const statusText: Record<Twenty48State['status'], string> = {
    idle: strings.statusIdle,
    playing: strings.statusPlaying,
    won: strings.statusWon,
    lost: strings.statusLost,
  };

  return (
    <section className="twenty48" data-testid="2048-game">
      <div className="twenty48__bar">
        <span>{strings.score}: <strong data-testid="2048-score">{state.score}</strong></span>
        <span>{strings.moves}: <strong data-testid="2048-moves">{state.moves}</strong></span>
        <span>{strings.target}: <strong>{state.target}</strong></span>
        <span>{strings.total}: <strong>{total}</strong></span>
        <span className="twenty48__status" data-testid="2048-status">{statusText[state.status]}</span>
      </div>

      <div
        className="twenty48__board"
        data-testid="2048-board"
        data-values={state.board.join(',')}
        role="grid"
        aria-label={strings.boardLabel}
        onPointerDown={handlePointerDown}
        onPointerUp={handlePointerUp}
        onPointerCancel={() => { swipeStart.current = null; }}
      >
        {state.board.map((value, index) => (
          <div
            key={index}
            className="twenty48__tile"
            data-testid="2048-tile"
            data-value={value || undefined}
            data-large={value > 2048 || undefined}
            role="gridcell"
            aria-label={value === 0 ? strings.emptyCell : strings.tileLabel.replace('{value}', String(value))}
          >
            {value || ''}
          </div>
        ))}
      </div>

      <div className="twenty48__pad" aria-label={strings.boardLabel}>
        <button type="button" className="btn twenty48__pad-up" aria-label={strings.moveUp} onClick={() => move('up')}>↑</button>
        <button type="button" className="btn twenty48__pad-left" aria-label={strings.moveLeft} onClick={() => move('left')}>←</button>
        <button type="button" className="btn twenty48__pad-down" aria-label={strings.moveDown} onClick={() => move('down')}>↓</button>
        <button type="button" className="btn twenty48__pad-right" aria-label={strings.moveRight} onClick={() => move('right')}>→</button>
      </div>

      <div className="twenty48__tools">
        <button type="button" className="btn" data-testid="2048-restart" onClick={() => resetStage(stage)}>
          {strings.restart}
        </button>
        <button
          type="button"
          className="btn btn--ghost"
          data-testid="2048-restart-run"
          onClick={() => {
            setTotal(0);
            setStage(1);
            resetStage(1);
          }}
        >
          {strings.restartRun}
        </button>
      </div>
      <p className="twenty48__hint">{strings.hint}</p>
    </section>
  );
}
