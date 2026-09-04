import { describe, expect, it } from 'vitest';
import { createTranslator, localeFromContext } from './i18n';

describe('i18n', () => {
  it('selects Chinese variants and falls back to English', () => {
    expect(localeFromContext('zh-Hans-CN')).toBe('zh-Hans');
    expect(localeFromContext('fr')).toBe('en');
    expect(createTranslator('zh-Hans')('appTitle')).toBe('视频工坊');
  });

  it('interpolates values', () => {
    expect(createTranslator('en')('progress', { value: 42 })).toBe('42%');
  });
});
