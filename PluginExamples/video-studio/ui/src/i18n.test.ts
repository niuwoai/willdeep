import { describe, expect, it } from 'vitest';
import { createTranslator, dictionaries, localeFromContext } from './i18n';
import appSource from './App.tsx?raw';

describe('i18n', () => {
  it('selects Chinese variants and falls back to English', () => {
    expect(localeFromContext('zh-Hans-CN')).toBe('zh-Hans');
    expect(localeFromContext('fr')).toBe('en');
    expect(createTranslator('zh-Hans')('appName')).toBe('短剧工坊');
  });

  it('interpolates values', () => {
    expect(createTranslator('en')('episodeCount', { count: 42 })).toBe('42 episodes');
  });

  // 早先 en 是 `{...zhHans, 有空翻的那些}`，没覆盖到的 89 个 key 静默显示中文，
  // 连发给模型的 plannerSystem 都是中文。key 对等这条必须由测试盯住。
  it('keeps both dictionaries at the same key set', () => {
    const zhKeys = Object.keys(dictionaries['zh-Hans']).sort();
    const enKeys = Object.keys(dictionaries.en).sort();
    expect(enKeys).toEqual(zhKeys);
  });

  it('has no Chinese characters left in the English dictionary', () => {
    const leaked = Object.entries(dictionaries.en)
      .filter(([, value]) => /[　-〿㐀-鿿＀-￯]/.test(value))
      .map(([key]) => key);
    expect(leaked).toEqual([]);
  });

  it('leaves no blank entry in either dictionary', () => {
    const blank = Object.entries(dictionaries)
      .flatMap(([locale, dictionary]) => Object.entries(dictionary)
        .filter(([, value]) => value.trim() === '')
        .map(([key]) => `${locale}.${key}`));
    expect(blank).toEqual([]);
  });
});

describe('界面引用的 key 都存在', () => {
  // 拼错一个 key 不会崩，只会在界面上原样显示键名（`noCandidatesYet` 就
  // 这么漏出去过一次）。翻译器的回落链是 `字典 → en → key 本身`，最后那
  // 一档正是为了不崩，代价就是错误无声。这条守卫补上那个声音。
  it('App.tsx 里的 t(...) 全部命中字典', () => {
    // Vite 的 ?raw 导入：不引入 node 类型，也不依赖测试的工作目录。
    const source = appSource;
    const known = new Set(Object.keys(dictionaries['zh-Hans']));
    const referenced = [...source.matchAll(/\bt\(\s*'([A-Za-z_][A-Za-z0-9_]*)'/g)].map((m) => m[1]!);
    const missing = [...new Set(referenced)].filter((key) => !known.has(key)).sort();
    expect(missing).toEqual([]);
  });
});
