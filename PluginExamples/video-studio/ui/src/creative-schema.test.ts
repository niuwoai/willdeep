import { describe, expect, it } from 'vitest';
import { validCreative } from './creative-schema';
import { parseFencedDraft, parseFencedShots } from './bridge';

describe('creative-v1', () => {
  it('rejects wrong field types and overlong text in every artifact', () => {
    expect(validCreative('character', { description: [] })).toBe(false);
    expect(validCreative('episode', { script: 'a'.repeat(20001) })).toBe(false);
    expect(validCreative('shot', { dialogue: [{ speaker: 'A', text: 42 }] })).toBe(false);
    expect(validCreative('frames', { startPrompt: 42 })).toBe(false);
    expect(validCreative('plan', { title: 'Drama', episodeCount: -1 })).toBe(false);
    expect(validCreative('passage', { replacement: [] })).toBe(false);
  });
  it('preserves valid partial revisions and silent shots', () => {
    expect(validCreative('shot', { dialogue: [], duration: 4 })).toBe(true);
    expect(validCreative('frames', { endPrompt: '夜色中的背影' })).toBe(true);
    expect(validCreative('episode', { script: '对白正文' })).toBe(true);
  });
  it('does not accept duplicate shot orders', () => {
    expect(parseFencedShots('```short_drama_shots\n{"shots":[{"order":1,"summary":"A"},{"order":1,"summary":"B"}]}\n```').kind).toBe('invalid');
  });
  it('rejects invalid frame descriptions before draft storage', () => {
    expect(parseFencedDraft('```short_drama_frames\n{"startPrompt":3}\n```', 'short_drama_frames', ['startPrompt']).kind).toBe('invalid');
  });
});
