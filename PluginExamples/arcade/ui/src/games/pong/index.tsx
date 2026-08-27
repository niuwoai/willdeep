import { useCallback, useEffect, useRef, useState } from 'react';
import type { CSSProperties } from 'react';
import type { GameProps } from '../../core/types';
import { useKeyControls } from '../../core/input';
import { saveBestScore } from '../../core/bestScore';
import { playCue } from '../../core/audio';
import { useI18n } from '../../core/i18n';
import { pongStrings } from './strings';
import './pong.css';

const COURT_WIDTH = 100;
const COURT_HEIGHT = 100;
const PADDLE_HEIGHT = 20;
const WIN_SCORE = 5;

interface PongState {
  playerY: number; cpuY: number; ballX: number; ballY: number; dx: number; dy: number; player: number; cpu: number; won: boolean;
}

const initialState = (): PongState => ({ playerY: 40, cpuY: 40, ballX: 48, ballY: 48, dx: 1.4, dy: .8, player: 0, cpu: 0, won: false });

export default function PongGame({ onWin }: GameProps) {
  const { locale } = useI18n();
  const strings = pongStrings(locale);
  const [game, setGame] = useState<PongState>(initialState);
  const move = useCallback((delta: number) => setGame((current) => ({ ...current, playerY: Math.max(0, Math.min(COURT_HEIGHT - PADDLE_HEIGHT, current.playerY + delta)) })), []);
  useKeyControls([
    { key: 'ArrowUp', onDown: () => move(-6), preventDefault: true },
    { key: 'ArrowDown', onDown: () => move(6), preventDefault: true },
    { key: 'w', onDown: () => move(-6) },
    { key: 's', onDown: () => move(6) },
  ], [move]);

  useEffect(() => {
    if (game.won) return undefined;
    const timer = window.setInterval(() => {
      setGame((current) => {
        let { ballX, ballY, dx, dy, player, cpu } = current;
        const previousBallX = ballX;
        const cpuY = Math.max(0, Math.min(COURT_HEIGHT - PADDLE_HEIGHT, current.cpuY + Math.sign(ballY - (current.cpuY + PADDLE_HEIGHT / 2)) * 2.2));
        ballX += dx; ballY += dy;
        if (ballY <= 0 || ballY >= COURT_HEIGHT - 4) { dy *= -1; ballY = Math.max(0, Math.min(COURT_HEIGHT - 4, ballY)); }
        if (previousBallX > 8 && ballX <= 8 && ballY + 4 >= current.playerY && ballY <= current.playerY + PADDLE_HEIGHT) { dx = Math.abs(dx) * 1.06; dy *= 1.06; ballX = 8; }
        if (previousBallX < 88 && ballX >= 88 && ballY + 4 >= cpuY && ballY <= cpuY + PADDLE_HEIGHT) { dx = -Math.abs(dx) * 1.06; dy *= 1.06; ballX = 88; }
        if (ballX < 0 || ballX > COURT_WIDTH) { if (ballX < 0) cpu += 1; else player += 1; ballX = 48; ballY = 48; dx = 1.4; dy = .8; }
        const won = player >= WIN_SCORE || cpu >= WIN_SCORE;
        if (won && player > cpu) saveBestScore('pong', player);
        return { ...current, cpuY, ballX, ballY, dx, dy, player, cpu, won };
      });
    }, 32);
    return () => window.clearInterval(timer);
  }, [game.won]);

  // 球拍回球（dx 换向）、得分与终局各给一声反馈；胜利再撒花。
  const mounted = useRef(false);
  useEffect(() => {
    // 挂载那一下不要凭空响一声，只有真的换向才出声
    if (!mounted.current) {
      mounted.current = true;
      return;
    }
    playCue('bounce');
  }, [Math.sign(game.dx)]);
  useEffect(() => {
    if (game.player > 0) playCue('point');
  }, [game.player]);
  useEffect(() => {
    if (game.cpu > 0) playCue('miss');
  }, [game.cpu]);
  useEffect(() => {
    if (!game.won) return;
    if (game.player > game.cpu) {
      playCue('win');
      onWin?.();
    } else {
      playCue('lose');
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [game.won]);

  return <section className="pong" data-testid="pong-game">
    <div><strong data-testid="pong-score">{strings.score}: {game.player} – {game.cpu}</strong><p>{game.won ? (game.player > game.cpu ? '✓' : '×') : strings.status}</p></div>
    <div className="pong__court" data-testid="pong-court" onPointerMove={(event) => { const rect = event.currentTarget.getBoundingClientRect(); move(((event.clientY - rect.top) / rect.height * COURT_HEIGHT - game.playerY - PADDLE_HEIGHT / 2) * .55); }}>
      <i className="pong__paddle pong__paddle--player" style={{ '--paddle-y': `${game.playerY}%` } as CSSProperties} /><i className="pong__paddle pong__paddle--cpu" style={{ '--paddle-y': `${game.cpuY}%` } as CSSProperties} /><i className="pong__ball" style={{ '--ball-x': `${game.ballX}%`, '--ball-y': `${game.ballY}%` } as CSSProperties} />
    </div>
    <div className="pong__controls"><button type="button" className="btn" onClick={() => move(-8)}>{strings.up}</button><button type="button" className="btn" onClick={() => move(8)}>{strings.down}</button><button type="button" className="btn btn--ghost" onClick={() => setGame(initialState)}>{strings.restart}</button></div><p>{strings.controls}</p>
  </section>;
}
