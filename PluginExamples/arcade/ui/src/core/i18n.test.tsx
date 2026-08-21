import { act, render, screen } from '@testing-library/react';
import { describe, expect, it } from 'vitest';
import { DEFAULT_LOCALE, I18nProvider, useI18n } from './i18n';
import { en } from './i18n/en';
import { zhHans } from './i18n/zh-Hans';

function Probe() {
  const { locale, setLocale, t } = useI18n();
  return (
    <div>
      <span data-testid="locale">{locale}</span>
      <span data-testid="title">{t('app.title')}</span>
      <span data-testid="interp">{t('common.seedValue', { seed: 42 })}</span>
      <button type="button" onClick={() => setLocale('en')}>
        to-en
      </button>
    </div>
  );
}

describe('i18n（契约）', () => {
  it('默认语言为 zh-Hans', () => {
    render(
      <I18nProvider>
        <Probe />
      </I18nProvider>,
    );
    expect(screen.getByTestId('locale')).toHaveTextContent(DEFAULT_LOCALE);
    expect(screen.getByTestId('title')).toHaveTextContent('经典网页小游戏');
    expect(screen.getByTestId('interp')).toHaveTextContent('种子: 42');
  });

  it('setLocale 切换语言并持久化', () => {
    render(
      <I18nProvider>
        <Probe />
      </I18nProvider>,
    );
    act(() => screen.getByText('to-en').click());
    expect(screen.getByTestId('locale')).toHaveTextContent('en');
    expect(screen.getByTestId('title')).toHaveTextContent('Classic Arcade');
    expect(window.localStorage.getItem('arcade.locale')).toBe('en');
  });

  it('缺失 key 回退到 key 本身', () => {
    function MissingKey() {
      const { t } = useI18n();
      return <span data-testid="missing">{t('no.such.key')}</span>;
    }
    render(
      <I18nProvider>
        <MissingKey />
      </I18nProvider>,
    );
    expect(screen.getByTestId('missing')).toHaveTextContent('no.such.key');
  });

  it('en 字典与 zh-Hans 字典 key 完全同构', () => {
    const zhKeys = Object.keys(zhHans).sort();
    const enKeys = Object.keys(en).sort();
    expect(enKeys).toEqual(zhKeys);
  });
});
