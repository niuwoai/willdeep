import { describe, expect, it } from 'vitest';
import { createTranslator, localeFromContext } from './i18n';

describe('i18n', () => {
  it('selects Chinese variants and falls back to English', () => {
    expect(localeFromContext('zh-Hans-CN')).toBe('zh-Hans');
    expect(localeFromContext('fr')).toBe('en');
    expect(createTranslator('zh-Hans')('appName')).toBe('短剧工坊');
  });

  it('interpolates values', () => {
    expect(createTranslator('en')('episodeCount', { count: 42 })).toBe('42 episodes');
  });
});
