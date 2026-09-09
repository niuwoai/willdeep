import { describe, expect, it } from 'vitest';
import { BOXES, createState, EMPTY_INPUT, EXIT, interaction, lineOfSight, PASS_POINTS, pathTo, RACKS, RULES, SAFE, step, SUPPLIES, blocked, type Input, type State } from './engine';
const advance = (s: State, seconds: number, input: Partial<Input> = {}) => { for (let i = 0; i < Math.ceil(seconds * 60); i++) step(s, { ...EMPTY_INPUT, ...input }, 1 / 60); };

describe('world and movement', () => {
  it('connects spawn to every objective without rack collisions', () => {
    const spawn = createState().player;
    for (const goal of [...PASS_POINTS, ...BOXES, ...SUPPLIES, { x: EXIT.x + 70, y: EXIT.y + 70 }, { x: SAFE.x + 60, y: SAFE.y + 60 }]) {
      const route = pathTo(spawn, goal);
      expect(route.length).toBeGreaterThan(0);
      expect(route.some(p => blocked(p))).toBe(false);
    }
  });
  it('cannot walk or dash through racks', () => {
    const s = createState(); s.guards = []; s.player = { x: 270, y: 320 };
    advance(s, 2, { x: 1, dash: true });
    expect(s.player.x).toBeLessThanOrEqual(RACKS[0].x - RULES.radius);
  });
  it('normalizes diagonal speed', () => {
    const a = createState(), b = createState(); a.guards = []; b.guards = [];
    const origin = { ...a.player };
    advance(a, .3, { x: 1 }); advance(b, .3, { x: 1, y: -1 });
    expect(Math.hypot(a.player.x - origin.x, a.player.y - origin.y)).toBeCloseTo(Math.hypot(b.player.x - origin.x, b.player.y - origin.y), 3);
  });
  it('bounds long-frame movement and time', () => {
    const s = createState(); step(s, { ...EMPTY_INPUT, x: 1 }, 30);
    expect(s.time).toBeGreaterThan(179.9); expect(s.player.x).toBeLessThan(190);
  });
});
describe('objectives and endings', () => {
  it('requires three distinct passes and exit interaction', () => {
    const s = createState(); s.guards = []; s.player = { x: EXIT.x + 70, y: EXIT.y + 70 };
    expect(interaction(s)).toBe('locked'); step(s, { ...EMPTY_INPUT, interact: true }, 1 / 60); expect(s.status).toBe('playing');
    for (const point of PASS_POINTS) { s.player = { ...point }; step(s, { ...EMPTY_INPUT, interact: true }, 1 / 60); step(s, { ...EMPTY_INPUT, interact: true }, 1 / 60); }
    expect(s.stamps.filter(Boolean)).toHaveLength(3);
    s.player = { x: EXIT.x + 70, y: EXIT.y + 70 }; step(s, { ...EMPTY_INPUT, interact: true }, 1 / 60);
    expect(s.status).toBe('won');
  });
  it('pauses all simulation and timers', () => {
    const s = createState(); s.status = 'paused'; const before = JSON.stringify(s);
    advance(s, 10, { x: 1, throw: true, dash: true }); expect(JSON.stringify(s)).toBe(before);
  });
  it('times out and stops advancing after the result', () => {
    const s = createState(); s.guards = []; s.time = .01; advance(s, .1); expect(s.status).toBe('timeout');
    const before = JSON.stringify(s); advance(s, 4); expect(JSON.stringify(s)).toBe(before);
  });
  it('requires sustained contact rather than one touch', () => {
    const s = createState(); s.guards = [s.guards[0]]; s.guards[0].x = s.player.x; s.guards[0].y = s.player.y;
    advance(s, .3); expect(s.status).toBe('playing'); expect(s.capture).toBeGreaterThan(0);
    s.player.x = 1200; advance(s, .5); expect(s.capture).toBe(0);
    s.guards[0].x = s.player.x + 10; s.guards[0].y = s.player.y; advance(s, 1.3); expect(s.status).toBe('caught');
  });
});
describe('abilities and pursuit', () => {
  it('racks interrupt line of sight', () => { expect(lineOfSight({ x: 200, y: 320 }, { x: 600, y: 320 })).toBe(false); });
  it('guard remembers the last position when target hides', () => {
    const s = createState(); s.guards = [s.guards[0]]; s.guards[0].x = 400; s.guards[0].y = 830;
    advance(s, .1); expect(s.guards[0].lastSeen).not.toBeNull();
    const seen = { ...s.guards[0].lastSeen! }; s.hidden = true; s.player.x = 610; advance(s, .1);
    expect(s.guards[0].lastSeen).toEqual(seen);
  });
  it('shot hits and slows a guard, consuming one ammo', () => {
    const s = createState(); s.guards = [s.guards[0]]; s.guards[0].x = 300; s.guards[0].y = 830;
    step(s, { ...EMPTY_INPUT, throw: true, aim: { x: 300, y: 830 } }, 1 / 60); advance(s, .2);
    expect(s.hits).toBe(1); expect(s.ammo).toBe(2); expect(s.guards[0].slow).toBeGreaterThan(0);
  });
  it('shots cannot hit through a rack', () => {
    const s = createState(); s.player = { x: 230, y: 320 }; s.guards[0].x = 580; s.guards[0].y = 320; s.guards = [s.guards[0]];
    step(s, { ...EMPTY_INPUT, throw: true }, 1 / 60); advance(s, .5); expect(s.hits).toBe(0); expect(s.shots).toHaveLength(0);
  });
  it('hides and exits a box; movement breaks concealment', () => {
    const s = createState(); s.player = { ...BOXES[0] };
    step(s, { ...EMPTY_INPUT, interact: true }, 1 / 60); expect(s.hidden).toBe(true);
    advance(s, .1, { x: 1 }); expect(s.hidden).toBe(false);
  });
  it('limits rests to two per round', () => {
    const s = createState(); s.player = { x: 100, y: 100 };
    for (let i = 0; i < 3; i++) step(s, { ...EMPTY_INPUT, interact: true }, 1 / 60);
    expect(s.restLeft).toBe(0); expect(interaction(s)).toBe('exhausted');
  });
  it('supply cannot be farmed without waiting', () => {
    const s = createState(); s.player = { ...SUPPLIES[0] }; s.ammo = 0;
    step(s, { ...EMPTY_INPUT, interact: true }, 1 / 60); expect(s.ammo).toBe(3);
    s.ammo = 0; step(s, { ...EMPTY_INPUT, interact: true }, 1 / 60); expect(s.ammo).toBe(0);
  });
  it('cannot dash without sufficient stamina', () => {
    const s = createState(); s.stamina = 0; step(s, { ...EMPTY_INPUT, dash: true }, 1 / 60); expect(s.dashTime).toBe(0);
  });
});
