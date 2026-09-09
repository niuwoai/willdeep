import { expect, it } from 'vitest';
import { createState, distance, EMPTY_INPUT, EXIT, PASS_POINTS, pathTo, step, type Vec } from './engine';

it('can complete a full moving playthrough against live guards', () => {
  const state = createState();
  let frames = 0;
  const moveTo = (goal: Vec) => {
    let route = pathTo(state.player, goal);
    while (distance(state.player, goal) > 45 && state.status === 'playing' && frames < 10000) {
      if (route.length && distance(state.player, route[0]) < 10) route.shift();
      const next = route[0] ?? goal;
      const nearest = [...state.guards].sort((a, b) => distance(a, state.player) - distance(b, state.player))[0];
      step(state, { ...EMPTY_INPUT, x: next.x - state.player.x, y: next.y - state.player.y,
        dash: state.stamina > 55, throw: state.ammo > 0 && distance(nearest, state.player) < 150,
        aim: nearest }, 1 / 60);
      frames++;
      if (frames % 60 === 0) route = pathTo(state.player, goal);
    }
  };
  for (const pass of PASS_POINTS) { moveTo(pass); step(state, { ...EMPTY_INPUT, interact: true }, 1 / 60); }
  moveTo({ x: EXIT.x + 80, y: EXIT.y + 80 });
  step(state, { ...EMPTY_INPUT, interact: true }, 1 / 60);
  expect(state.stamps).toEqual([true, true, true]);
  expect(state.status).toBe('won');
  expect(state.time).toBeGreaterThan(0);
});
