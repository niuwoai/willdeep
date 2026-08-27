/**
 * 通关撒花：自绘 canvas 彩纸，不引第三方依赖。
 *
 * 为什么不用 react-confetti / canvas-confetti：插件随 App 发行、跑在 CSP 收紧的
 * WKWebView 里，能不加运行时依赖就不加；这段粒子逻辑本身不过百来行。
 *
 * 用法：`<Confetti trigger={n} />`，trigger 每 +1 放一次；
 * 尊重 prefers-reduced-motion（用户要求减少动效时直接不放）。
 */
import { useEffect, useRef } from 'react';
import './confetti.css';

/** 彩纸颜色（与游戏配色同源，避免另起一套视觉语言）。 */
const COLORS = ['#ff5d73', '#4f8cff', '#3d9b6e', '#e6a23c', '#9b59d0', '#2fb8c9', '#eef1f6'];
/** 每次撒花的彩纸数量。 */
const PIECES = 140;
/** 一次撒花的时长（毫秒）。 */
const DURATION_MS = 3000;
const GRAVITY = 420;
/** 出场错峰的最大延迟（秒）：一起喷会糊成一坨，错开才像撒花。 */
const MAX_DELAY = 0.5;

interface Piece {
  x: number;
  y: number;
  vx: number;
  vy: number;
  size: number;
  tilt: number;
  spin: number;
  /** 出场延迟（秒）。 */
  delay: number;
  /** 飘摆相位与幅度，让下落时左右晃。 */
  phase: number;
  sway: number;
  color: string;
}

function prefersReducedMotion(): boolean {
  if (typeof window === 'undefined' || typeof window.matchMedia !== 'function') return false;
  try {
    return window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  } catch {
    return false;
  }
}

function createPieces(width: number, height: number): Piece[] {
  return Array.from({ length: PIECES }, (_, index) => {
    const fromLeft = index % 2 === 0;
    // 以「斜向上 45°」为中心张开一个大扇面，速度也拉开档次，才不会喷成一坨
    const spread = (Math.random() - 0.5) * 1.5;
    const angle = (fromLeft ? -Math.PI / 4 : -Math.PI * 0.75) + spread;
    const speed = 260 + Math.random() * 380;
    return {
      x: (fromLeft ? width * 0.06 : width * 0.94) + (Math.random() - 0.5) * width * 0.06,
      y: height * (0.62 + Math.random() * 0.16),
      vx: Math.cos(angle) * speed,
      vy: Math.sin(angle) * speed,
      size: 5 + Math.random() * 8,
      tilt: Math.random() * Math.PI,
      spin: (Math.random() - 0.5) * 11,
      delay: Math.random() * MAX_DELAY,
      phase: Math.random() * Math.PI * 2,
      sway: 12 + Math.random() * 26,
      color: COLORS[Math.floor(Math.random() * COLORS.length)] as string,
    };
  });
}

export interface ConfettiProps {
  /** 每次自增就放一次撒花；0 表示还没有触发过。 */
  trigger: number;
}

export function Confetti({ trigger }: ConfettiProps) {
  const canvasRef = useRef<HTMLCanvasElement | null>(null);

  useEffect(() => {
    if (trigger <= 0) return;
    if (prefersReducedMotion()) return;
    const canvas = canvasRef.current;
    if (!canvas) return;
    let context: CanvasRenderingContext2D | null = null;
    try {
      context = canvas.getContext('2d');
    } catch {
      context = null;
    }
    if (!context) return;

    const ratio = window.devicePixelRatio || 1;
    const width = canvas.clientWidth || 320;
    const height = canvas.clientHeight || 240;
    canvas.width = Math.max(1, Math.round(width * ratio));
    canvas.height = Math.max(1, Math.round(height * ratio));
    context.setTransform(ratio, 0, 0, ratio, 0, 0);

    let pieces = createPieces(width, height);
    let frame = 0;
    let last = 0;
    let elapsed = 0;

    const draw = (now: number): void => {
      const dt = last === 0 ? 0 : Math.min(0.05, (now - last) / 1000);
      last = now;
      elapsed += dt * 1000;
      const seconds = elapsed / 1000;
      // 最后三分之一段淡出，前面保持满不透明
      const fade = Math.max(0, Math.min(1, (DURATION_MS - elapsed) / (DURATION_MS * 0.35)));

      context.clearRect(0, 0, width, height);
      pieces = pieces.map((piece) => {
        if (seconds < piece.delay) return piece;
        return {
          ...piece,
          x: piece.x + (piece.vx + Math.sin(seconds * 3 + piece.phase) * piece.sway) * dt,
          y: piece.y + piece.vy * dt,
          vy: piece.vy + GRAVITY * dt,
          vx: piece.vx * (1 - 1.1 * dt),
          tilt: piece.tilt + piece.spin * dt,
        };
      });

      context.globalAlpha = fade;
      for (const piece of pieces) {
        if (seconds < piece.delay) continue;
        if (piece.y > height + piece.size) continue;
        context.save();
        context.translate(piece.x, piece.y);
        context.rotate(piece.tilt);
        context.fillStyle = piece.color;
        // 用扁矩形加上旋转，视觉上就是翻飞的纸片
        context.fillRect(-piece.size / 2, -piece.size / 4, piece.size, piece.size / 2);
        context.restore();
      }
      context.globalAlpha = 1;

      if (elapsed < DURATION_MS) {
        frame = window.requestAnimationFrame(draw);
      } else {
        context.clearRect(0, 0, width, height);
      }
    };

    frame = window.requestAnimationFrame(draw);
    return () => {
      window.cancelAnimationFrame(frame);
      context?.clearRect(0, 0, width, height);
    };
  }, [trigger]);

  return <canvas ref={canvasRef} className="confetti" data-testid="confetti" aria-hidden="true" />;
}
