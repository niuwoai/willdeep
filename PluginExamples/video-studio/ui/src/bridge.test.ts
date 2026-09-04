import { describe, expect, it } from 'vitest';
import { activeStates, parseVideoPlan } from './bridge';

describe('parseVideoPlan', () => {
  it('accepts plain JSON and fenced JSON', () => {
    expect(parseVideoPlan('{"title":"海边","prompt":"缓慢推进","negativePrompt":"模糊"}')?.prompt).toBe('缓慢推进');
    expect(parseVideoPlan('```json\n{"title":"A","prompt":"B","negativePrompt":""}\n```')?.title).toBe('A');
  });

  it('rejects prose and objects without a prompt', () => {
    expect(parseVideoPlan('I would do this')).toBeNull();
    expect(parseVideoPlan('{"title":"missing"}')).toBeNull();
  });
});

describe('job states', () => {
  it('polls only non-terminal submitted states', () => {
    expect(activeStates.has('queued')).toBe(true);
    expect(activeStates.has('in_progress')).toBe(true);
    expect(activeStates.has('completed')).toBe(false);
    expect(activeStates.has('failed')).toBe(false);
  });
});
