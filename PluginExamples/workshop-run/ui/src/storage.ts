import type { Locale } from './strings';
export type Preferences = { locale: Locale; sound: boolean; reduced: boolean; best: number | null };
const KEY = 'willdeep.workshop-run.v1';
export function readPreferences(): Preferences {
  const defaults: Preferences = { locale: navigator.language.startsWith('zh') ? 'zh-Hans' : 'en', sound: true, reduced: window.matchMedia?.('(prefers-reduced-motion: reduce)').matches ?? false, best: null };
  try {
    const raw: unknown = JSON.parse(localStorage.getItem(KEY) ?? 'null');
    if (!raw || typeof raw !== 'object') return defaults;
    const p = raw as Record<string, unknown>;
    return { locale: p.locale === 'en' || p.locale === 'zh-Hans' ? p.locale : defaults.locale,
      sound: typeof p.sound === 'boolean' ? p.sound : defaults.sound,
      reduced: typeof p.reduced === 'boolean' ? p.reduced : defaults.reduced,
      best: typeof p.best === 'number' && Number.isFinite(p.best) && p.best > 0 && p.best <= 180 ? p.best : null };
  } catch { return defaults; } // Storage is optional inside an isolated host.
}
export function writePreferences(p: Preferences): void {
  try { localStorage.setItem(KEY, JSON.stringify(p)); } catch { /* Session state remains usable when storage is blocked. */ }
}
