import { describe, expect, it } from 'vitest';
import { parseDramaPlan } from './bridge';

describe('parseDramaPlan', () => {
  it('accepts the short_drama_plan fenced contract', () => {
    const raw = '```short_drama_plan\n{"title":"错时来信","episodeCount":8,"episodeDurationSeconds":80,"logline":"来自未来的短信"}\n```';
    expect(parseDramaPlan(raw)).toMatchObject({ title: '错时来信', episodeCount: 8, episodeDurationSeconds: 80 });
  });

  it('rejects prose and plans without a title', () => {
    expect(parseDramaPlan('just prose')).toBeNull();
    expect(parseDramaPlan('{"genre":"悬疑"}')).toBeNull();
  });
});
