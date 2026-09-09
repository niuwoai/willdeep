import { expect, it } from 'vitest';
import { zh, en } from './strings';
it('has complete nonempty Chinese and English dictionaries', () => {
  expect(Object.keys(en).sort()).toEqual(Object.keys(zh).sort());
  expect([...Object.values(en), ...Object.values(zh)].every(value => value.trim().length > 0)).toBe(true);
});
