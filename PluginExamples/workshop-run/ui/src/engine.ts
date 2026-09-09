import type { TextKey } from './strings';

export const RULES = { width: 1600, height: 1000, cell: 40, radius: 17, duration: 180,
  speed: 190, guardSpeed: 145, dashSpeed: 350, dashDuration: .55, dashCost: 28,
  captureTime: 1.2, projectileSpeed: 560, shotCooldown: .38, ammo: 3, restUses: 2 } as const;
export type Vec = { x: number; y: number };
export type Rect = Vec & { w: number; h: number };
export type Status = 'playing' | 'paused' | 'won' | 'caught' | 'timeout';
export type Guard = Vec & { facing: number; slow: number; immune: number; lastSeen: Vec | null; path: Vec[]; repath: number; patrol: Vec };
export type Shot = Vec & { vx: number; vy: number; life: number };
export type Input = { x: number; y: number; throw: boolean; dash: boolean; interact: boolean; aim?: Vec };
export const EMPTY_INPUT: Input = { x: 0, y: 0, throw: false, dash: false, interact: false };
export const RACKS: Rect[] = [
  { x: 300, y: 260, w: 240, h: 135 }, { x: 700, y: 260, w: 240, h: 135 }, { x: 1100, y: 260, w: 240, h: 135 },
  { x: 300, y: 590, w: 240, h: 135 }, { x: 700, y: 590, w: 240, h: 135 }, { x: 1100, y: 590, w: 240, h: 135 },
];
export const SAFE: Rect = { x: 40, y: 40, w: 170, h: 160 };
export const EXIT: Rect = { x: 1400, y: 40, w: 160, h: 155 };
export const BOXES: Vec[] = [{ x: 610, y: 780 }, { x: 1020, y: 440 }];
export const SUPPLIES: Vec[] = [{ x: 100, y: 490 }, { x: 1450, y: 820 }];
export const PASS_POINTS: Vec[] = [{ x: 200, y: 420 }, { x: 820, y: 850 }, { x: 1400, y: 420 }];
export type State = {
  status: Status; player: Vec; facing: Vec; time: number; stamina: number; ammo: number;
  dashTime: number; dashCooldown: number; shotCooldown: number; hidden: boolean; safeTime: number;
  restLeft: number; supplyCooldown: number; capture: number; stamps: boolean[];
  guards: Guard[]; shots: Shot[]; hits: number; toast: TextKey | null; toastTime: number; tick: number;
};
export const distance = (a: Vec, b: Vec) => Math.hypot(a.x - b.x, a.y - b.y);
export const inside = (p: Vec, r: Rect) => p.x >= r.x && p.x <= r.x + r.w && p.y >= r.y && p.y <= r.y + r.h;
export function blocked(p: Vec, radius: number = RULES.radius): boolean {
  if (p.x < 35 + radius || p.y < 35 + radius || p.x > RULES.width - 35 - radius || p.y > RULES.height - 35 - radius) return true;
  return RACKS.some(r => p.x > r.x - radius && p.x < r.x + r.w + radius && p.y > r.y - radius && p.y < r.y + r.h + radius);
}
export function lineOfSight(a: Vec, b: Vec): boolean {
  const count = Math.ceil(distance(a, b) / 12);
  for (let i = 1; i <= count; i++) {
    const f = i / count;
    if (blocked({ x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f }, 0)) return false;
  }
  return true;
}
export function pathTo(from: Vec, to: Vec): Vec[] {
  const cols = RULES.width / RULES.cell;
  const rows = RULES.height / RULES.cell;
  const index = (p: Vec) => Math.floor(p.y / RULES.cell) * cols + Math.floor(p.x / RULES.cell);
  const point = (n: number): Vec => ({ x: (n % cols + .5) * RULES.cell, y: (Math.floor(n / cols) + .5) * RULES.cell });
  const start = index(from), end = index(to);
  const parents = new Int32Array(cols * rows).fill(-1);
  parents[start] = start;
  const queue = [start];
  for (let head = 0; head < queue.length && parents[end] === -1; head++) {
    const current = queue[head];
    for (const next of [current - 1, current + 1, current - cols, current + cols]) {
      if (next < 0 || next >= cols * rows || parents[next] !== -1) continue;
      if (Math.abs(next % cols - current % cols) > 1 || blocked(point(next), 20)) continue;
      parents[next] = current;
      queue.push(next);
    }
  }
  if (parents[end] === -1) return [];
  const path: Vec[] = [];
  for (let n = end; n !== start; n = parents[n]) path.unshift(point(n));
  return path;
}
export function createState(): State {
  const positions = [{ x: 1450, y: 880 }, { x: 850, y: 120 }];
  return { status: 'playing', player: { x: 180, y: 830 }, facing: { x: 1, y: 0 }, time: RULES.duration,
    stamina: 100, ammo: RULES.ammo, dashTime: 0, dashCooldown: 0, shotCooldown: 0,
    hidden: false, safeTime: 0, restLeft: RULES.restUses, supplyCooldown: 0, capture: 0,
    stamps: PASS_POINTS.map(() => false), shots: [], hits: 0, toast: null, toastTime: 0, tick: 0,
    guards: positions.map((p, i) => ({ ...p, facing: Math.PI, slow: 0, immune: 0, lastSeen: null, path: [], repath: 0,
      patrol: i ? { x: 160, y: 450 } : { x: 850, y: 850 } })),
  };
}
function move(p: Vec, x: number, y: number) {
  const steps = Math.max(1, Math.ceil(Math.hypot(x, y) / 8));
  for (let n = 0; n < steps; n++) {
    if (!blocked({ x: p.x + x / steps, y: p.y })) p.x += x / steps;
    if (!blocked({ x: p.x, y: p.y + y / steps })) p.y += y / steps;
  }
}
export function notify(s: State, key: TextKey) { s.toast = key; s.toastTime = 2; }
export function interaction(s: State): TextKey | null {
  if (s.hidden) return 'unhide';
  if (PASS_POINTS.some((p, i) => !s.stamps[i] && distance(p, s.player) < 75)) return 'collect';
  if (inside(s.player, EXIT)) return s.stamps.every(Boolean) ? 'exit' : 'locked';
  if (inside(s.player, SAFE)) return s.restLeft ? 'rest' : 'exhausted';
  if (SUPPLIES.some(p => distance(p, s.player) < 80)) return s.supplyCooldown <= 0 ? 'supply' : 'supplyWait';
  if (BOXES.some(p => distance(p, s.player) < 65)) return 'hide';
  return null;
}
function use(s: State) {
  const action = interaction(s);
  if (action === 'unhide') { s.hidden = false; return; }
  if (action === 'collect') {
    const i = PASS_POINTS.findIndex((p, i) => !s.stamps[i] && distance(p, s.player) < 75);
    s.stamps[i] = true; notify(s, 'stampTaken');
  }
  if (action === 'hide') { s.hidden = true; s.capture = 0; }
  if (action === 'rest') { s.restLeft--; s.safeTime = 5; s.stamina = 100; s.capture = 0; }
  if (action === 'supply') { s.ammo = RULES.ammo; s.supplyCooldown = 15; }
  if (action === 'exit') s.status = 'won';
}
function throwShot(s: State, aim?: Vec) {
  if (s.shotCooldown > 0) return;
  if (!s.ammo) { notify(s, 'miss'); return; }
  const direction = aim ? { x: aim.x - s.player.x, y: aim.y - s.player.y } : s.facing;
  const length = Math.hypot(direction.x, direction.y) || 1;
  s.shots.push({ ...s.player, vx: direction.x / length * RULES.projectileSpeed, vy: direction.y / length * RULES.projectileSpeed, life: .9 });
  s.ammo--; s.shotCooldown = RULES.shotCooldown; s.hidden = false;
}
function updateShots(s: State, dt: number) {
  for (const shot of s.shots) {
    shot.life -= dt;
    const next = { x: shot.x + shot.vx * dt, y: shot.y + shot.vy * dt };
    if (!lineOfSight(shot, next)) { shot.life = 0; continue; }
    Object.assign(shot, next);
    for (const guard of s.guards) {
      if (distance(shot, guard) > 32 || shot.life <= 0) continue;
      shot.life = 0;
      if (guard.immune <= 0) { guard.slow = 1.5; guard.immune = 3.5; s.hits++; notify(s, 'hit'); }
    }
  }
  s.shots = s.shots.filter(shot => shot.life > 0);
}
function updateGuard(s: State, g: Guard, dt: number) {
  g.slow = Math.max(0, g.slow - dt); g.immune = Math.max(0, g.immune - dt); g.repath -= dt;
  const sees = !s.hidden && s.safeTime <= 0 && distance(g, s.player) < 530 && lineOfSight(g, s.player);
  if (sees) g.lastSeen = { ...s.player };
  let target = g.lastSeen ?? g.patrol;
  if (distance(g, target) < 30) {
    g.lastSeen = null;
    g.patrol = { x: g.patrol.x < 800 ? 1450 : 160, y: g.patrol.y < 500 ? 850 : 140 };
    target = g.patrol;
  }
  if (g.repath <= 0) { g.path = pathTo(g, target); g.repath = .35; }
  const next = lineOfSight(g, target) ? target : g.path[0];
  if (!next) return;
  const dx = next.x - g.x, dy = next.y - g.y, length = Math.hypot(dx, dy);
  if (length < 8) { g.path.shift(); return; }
  g.facing = Math.atan2(dy, dx);
  const speed = RULES.guardSpeed * (g.slow > 0 ? .35 : 1) * (sees ? 1 : .8);
  move(g, dx / length * Math.min(speed * dt, length), dy / length * Math.min(speed * dt, length));
}
export function step(s: State, input: Input, elapsed: number): void {
  if (s.status !== 'playing') return;
  // Simulation callers use a fixed 1/60 step. Bound any accidental long frame.
  const dt = Math.min(Math.max(elapsed, 0), 1 / 30);
  s.tick += dt; s.time = Math.max(0, s.time - dt);
  for (const key of ['dashTime', 'dashCooldown', 'shotCooldown', 'safeTime', 'supplyCooldown', 'toastTime'] as const) s[key] = Math.max(0, s[key] - dt);
  if (input.interact) use(s);
  if (s.status !== 'playing') return;
  if (input.dash && s.dashCooldown <= 0) {
    if (s.stamina >= RULES.dashCost) { s.dashTime = RULES.dashDuration; s.dashCooldown = .9; s.stamina -= RULES.dashCost; s.hidden = false; }
    else notify(s, 'low');
  }
  const length = Math.hypot(input.x, input.y);
  if (length > 0) {
    s.hidden = false;
    s.facing = { x: input.x / length, y: input.y / length };
    const speed = s.dashTime > 0 ? RULES.dashSpeed : RULES.speed;
    move(s.player, s.facing.x * speed * dt, s.facing.y * speed * dt);
  }
  if (input.throw) throwShot(s, input.aim);
  if (s.dashTime <= 0) s.stamina = Math.min(100, s.stamina + dt * 11);
  updateShots(s, dt);
  s.guards.forEach(g => updateGuard(s, g, dt));
  const touching = !s.hidden && s.safeTime <= 0 && s.guards.some(g => distance(g, s.player) < 38);
  s.capture = touching ? s.capture + dt : Math.max(0, s.capture - dt * 2.5);
  if (s.capture >= RULES.captureTime) s.status = 'caught';
  else if (s.time <= 0) s.status = 'timeout';
}
export const formatTime = (seconds: number) => `${Math.floor(seconds / 60).toString().padStart(2, '0')}:${Math.floor(seconds % 60).toString().padStart(2, '0')}`;
