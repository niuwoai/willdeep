import { BOXES, EXIT, PASS_POINTS, RACKS, RULES, SAFE, SUPPLIES, type State, type Vec } from './engine';
import type { Strings } from './strings';

export type Assets = Record<'runner' | 'guard' | 'rack' | 'pass' | 'box' | 'supply' | 'rest' | 'arrow' | 'shot', HTMLImageElement>;
const C = { floor: '#aec6ce', line: '#8ba9b5', ink: '#102b43', yellow: '#ffdb4c', blue: '#167baa', white: '#eef6f5', green: '#17836c' };
function text(ctx: CanvasRenderingContext2D, content: string, x: number, y: number, size: number, color = C.ink) {
  ctx.fillStyle = color; ctx.font = `900 ${size}px system-ui, sans-serif`; ctx.textAlign = 'center'; ctx.fillText(content, x, y);
}
function icon(ctx: CanvasRenderingContext2D, img: HTMLImageElement, x: number, y: number, size: number) { ctx.drawImage(img, x - size / 2, y - size / 2, size, size); }
function zone(ctx: CanvasRenderingContext2D, rect: typeof SAFE, color: string, title: string, subtitle: string, img: HTMLImageElement) {
  ctx.fillStyle = color; ctx.fillRect(rect.x, rect.y, rect.w, rect.h);
  ctx.strokeStyle = C.white; ctx.lineWidth = 3; ctx.strokeRect(rect.x + 7, rect.y + 7, rect.w - 14, rect.h - 14);
  icon(ctx, img, rect.x + rect.w / 2, rect.y + 54, 45);
  text(ctx, title, rect.x + rect.w / 2, rect.y + 100, 24, C.white);
  text(ctx, subtitle, rect.x + rect.w / 2, rect.y + 126, 13, C.white);
}
function person(ctx: CanvasRenderingContext2D, image: HTMLImageElement, p: Vec, face: number, phase: number, reduced: boolean, size: number) {
  ctx.fillStyle = '#071b3138'; ctx.beginPath(); ctx.ellipse(p.x, p.y + 10, size * .32, 11, 0, 0, Math.PI * 2); ctx.fill();
  const bob = reduced ? 0 : Math.sin(phase * 15) * 3;
  const h = size * 1.35, w = h * image.width / image.height;
  ctx.save(); ctx.translate(p.x, p.y + 15 + bob); if (face < 0) ctx.scale(-1, 1);
  ctx.drawImage(image, -w / 2, -h, w, h); ctx.restore();
}
export function draw(ctx: CanvasRenderingContext2D, s: State, assets: Assets, t: Strings, reduced: boolean) {
  ctx.save(); ctx.scale(ctx.canvas.width / RULES.width, ctx.canvas.height / RULES.height);
  ctx.fillStyle = C.floor; ctx.fillRect(0, 0, RULES.width, RULES.height);
  ctx.strokeStyle = C.line; ctx.lineWidth = 1;
  for (let x = 0; x < RULES.width; x += 80) { ctx.beginPath(); ctx.moveTo(x, 0); ctx.lineTo(x, RULES.height); ctx.stroke(); }
  for (let y = 0; y < RULES.height; y += 80) { ctx.beginPath(); ctx.moveTo(0, y); ctx.lineTo(RULES.width, y); ctx.stroke(); }
  ctx.strokeStyle = C.ink; ctx.lineWidth = 35; ctx.strokeRect(17, 17, RULES.width - 34, RULES.height - 34);
  ctx.strokeStyle = C.yellow; ctx.lineWidth = 4; ctx.setLineDash([24, 18]);
  ctx.strokeRect(245, 220, 1145, 560); ctx.setLineDash([]);
  zone(ctx, SAFE, C.green, t.safeRoom, `${t.safeSub} · ${s.restLeft}/${RULES.restUses}`, assets.rest);
  zone(ctx, EXIT, s.stamps.every(Boolean) ? C.green : C.ink, t.exitSign, `${s.stamps.filter(Boolean).length} / 3`, assets.arrow);
  text(ctx, t.zoneA, 450, 150, 32, '#7596a5'); text(ctx, t.zoneB, 850, 150, 32, '#7596a5');
  text(ctx, t.zoneC, 420, 920, 32, '#7596a5'); text(ctx, t.zoneD, 1250, 920, 32, '#7596a5');
  SUPPLIES.forEach(p => {
    ctx.fillStyle = C.blue; ctx.fillRect(p.x - 38, p.y - 38, 76, 76);
    icon(ctx, assets.supply, p.x, p.y - 2, 43);
    text(ctx, s.supplyCooldown > 0 ? `${Math.ceil(s.supplyCooldown)}` : t.supplySign, p.x, p.y + 62, 20);
  });
  BOXES.forEach(p => { icon(ctx, assets.box, p.x, p.y, 68); });
  PASS_POINTS.forEach((p, i) => {
    if (s.stamps[i]) return;
    const bob = reduced ? 0 : Math.sin(s.tick * 3 + i) * 5;
    ctx.fillStyle = C.yellow; ctx.beginPath(); ctx.arc(p.x, p.y + bob, 30, 0, Math.PI * 2); ctx.fill();
    ctx.strokeStyle = C.ink; ctx.lineWidth = 4; ctx.stroke(); icon(ctx, assets.pass, p.x, p.y + bob, 36);
    text(ctx, `${i + 1}`, p.x, p.y + 58, 19);
  });
  s.guards.forEach(g => {
    if (!g.lastSeen) return;
    ctx.fillStyle = '#ef744424'; ctx.beginPath(); ctx.moveTo(g.x, g.y);
    ctx.arc(g.x, g.y, 100, g.facing - .5, g.facing + .5); ctx.closePath(); ctx.fill();
  });
  const objects = [
    ...RACKS.map(r => ({ y: r.y + r.h, paint: () => {
      ctx.fillStyle = '#071b3125'; ctx.fillRect(r.x + 10, r.y + 12, r.w, r.h);
      ctx.drawImage(assets.rack, r.x - 8, r.y - 32, r.w + 16, r.h + 40);
    } })),
    ...s.guards.map(g => ({ y: g.y, paint: () => {
      person(ctx, assets.guard, g, Math.cos(g.facing), s.tick, reduced, 76);
      if (g.slow > 0) { ctx.strokeStyle = C.blue; ctx.lineWidth = 4; ctx.beginPath(); ctx.arc(g.x, g.y, 32, 0, Math.PI * 2); ctx.stroke(); }
    } })),
    { y: s.player.y, paint: () => {
      if (s.hidden) return;
      ctx.strokeStyle = s.safeTime > 0 ? C.green : C.yellow; ctx.lineWidth = 4;
      ctx.beginPath(); ctx.ellipse(s.player.x, s.player.y + 5, 31, 17, 0, 0, Math.PI * 2); ctx.stroke();
      person(ctx, assets.runner, s.player, s.facing.x || 1, s.tick, reduced, 76);
    } },
  ];
  objects.sort((a, b) => a.y - b.y).forEach(o => o.paint());
  s.shots.forEach(p => icon(ctx, assets.shot, p.x, p.y - 16, 32));
  if (s.hidden) { icon(ctx, assets.box, s.player.x, s.player.y - 10, 65); }
  // Small HUD markers ensure actors remain readable even when behind a rack.
  ctx.fillStyle = C.yellow; ctx.beginPath(); ctx.arc(s.player.x, s.player.y - 104, 6, 0, Math.PI * 2); ctx.fill();
  ctx.restore();
}
