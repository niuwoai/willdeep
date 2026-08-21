/**
 * i18n 契约（冻结）。
 *
 *  - 所有用户可见文案必须走 t(key)，禁止硬编码在视图代码中
 *  - 默认语言 zh-Hans，fallback 顺序：当前语言 → zh-Hans → 原样返回 key
 *  - 支持 `{param}` 插值；语言选择持久化到 localStorage（arcade.locale）
 *  - 新增语言 = 在 dictionaries 中补一个与 zh-Hans 完全同 key 的字典
 * 决策背景见 docs/i18n.md。
 */
import { createContext, useCallback, useContext, useMemo, useState } from 'react';
import type { ReactNode } from 'react';
import type { Locale } from './types';
import { LOCALE_STORAGE_KEY, safeLocalStorage } from './safeLocalStorage';
import { zhHans } from './i18n/zh-Hans';
import { en } from './i18n/en';

export const SUPPORTED_LOCALES: readonly Locale[] = ['zh-Hans', 'en'];
export const DEFAULT_LOCALE: Locale = 'zh-Hans';

const dictionaries: Record<Locale, Record<string, string>> = {
  'zh-Hans': zhHans,
  en,
};

export type Translate = (key: string, params?: Record<string, string | number>) => string;

export interface I18nValue {
  locale: Locale;
  setLocale: (locale: Locale) => void;
  t: Translate;
}

const I18nContext = createContext<I18nValue | null>(null);

function isLocale(value: unknown): value is Locale {
  return SUPPORTED_LOCALES.includes(value as Locale);
}

function readInitialLocale(): Locale {
  const stored = safeLocalStorage.getItem(LOCALE_STORAGE_KEY);
  if (stored && isLocale(stored)) return stored;
  const htmlLang = typeof document !== 'undefined' ? document.documentElement.lang : '';
  if (htmlLang && isLocale(htmlLang)) return htmlLang;
  return DEFAULT_LOCALE;
}

function interpolate(template: string, params?: Record<string, string | number>): string {
  if (!params) return template;
  return template.replace(/\{(\w+)\}/g, (match, name: string) =>
    name in params ? String(params[name]) : match,
  );
}

export function I18nProvider({ children }: { children: ReactNode }) {
  const [locale, setLocaleState] = useState<Locale>(readInitialLocale);

  const setLocale = useCallback((next: Locale) => {
    setLocaleState(next);
    safeLocalStorage.setItem(LOCALE_STORAGE_KEY, next);
    if (typeof document !== 'undefined') document.documentElement.lang = next;
  }, []);

  const t = useCallback<Translate>(
    (key, params) => {
      const dict = dictionaries[locale] ?? dictionaries[DEFAULT_LOCALE];
      const raw = dict[key] ?? dictionaries[DEFAULT_LOCALE][key] ?? key;
      return interpolate(raw, params);
    },
    [locale],
  );

  const value = useMemo<I18nValue>(() => ({ locale, setLocale, t }), [locale, setLocale, t]);
  return <I18nContext.Provider value={value}>{children}</I18nContext.Provider>;
}

export function useI18n(): I18nValue {
  const ctx = useContext(I18nContext);
  if (!ctx) throw new Error('useI18n 必须在 <I18nProvider> 内使用');
  return ctx;
}
