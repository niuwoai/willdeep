/**
 * 游戏外壳回归：音效开关与通关撒花的挂载点。
 *
 * 撒花画布常驻外壳（trigger 为 0 时不动画），音效开关状态走 localStorage，
 * 两者都不依赖具体游戏，所以在这里统一锁住。
 */
import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { App } from '../App';
import { HashRouter } from '../core/hashRouter';
import { I18nProvider } from '../core/i18n';
import { SOUND_STORAGE_KEY } from '../core/audio';

function renderAt(hash: string) {
  window.location.hash = hash;
  return render(
    <HashRouter>
      <I18nProvider>
        <App />
      </I18nProvider>
    </HashRouter>,
  );
}

describe('游戏外壳', () => {
  beforeEach(() => {
    window.localStorage.clear();
    window.location.hash = '';
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it('每个游戏外壳都挂着撒花画布', async () => {
    for (const id of ['2048', 'breakout', 'jigsaw', 'memory', 'onet', 'marble', 'snake', 'tetris', 'pong', 'minesweeper']) {
      const view = renderAt(`#/game/${id}`);
      await screen.findByTestId(`game-shell-${id}`);
      expect(screen.getByTestId('confetti')).toBeInTheDocument();
      view.unmount();
    }
  });

  it('音效开关默认开启，点击后静音并持久化', async () => {
    const user = userEvent.setup();
    renderAt('#/game/memory');
    const toggle = await screen.findByTestId('game-sound');
    expect(toggle).toHaveAttribute('aria-pressed', 'true');

    await user.click(toggle);
    await waitFor(() => expect(toggle).toHaveAttribute('aria-pressed', 'false'));
    expect(window.localStorage.getItem(SOUND_STORAGE_KEY)).toBe('off');

    await user.click(toggle);
    await waitFor(() => expect(toggle).toHaveAttribute('aria-pressed', 'true'));
    expect(window.localStorage.getItem(SOUND_STORAGE_KEY)).toBe('on');
  });

  it('静音状态在重新进入游戏后仍然生效', async () => {
    window.localStorage.setItem(SOUND_STORAGE_KEY, 'off');
    renderAt('#/game/snake');
    const toggle = await screen.findByTestId('game-sound');
    expect(toggle).toHaveAttribute('aria-pressed', 'false');
  });

  it('通关会一路把撒花放出来（游戏 → 路由 → 外壳）', async () => {
    // jsdom 没有 canvas 2D，桩掉上下文让撒花的动画分支真的跑起来
    vi.spyOn(HTMLCanvasElement.prototype, 'getContext').mockReturnValue({
      clearRect: vi.fn(),
      setTransform: vi.fn(),
      save: vi.fn(),
      restore: vi.fn(),
      translate: vi.fn(),
      rotate: vi.fn(),
      fillRect: vi.fn(),
      globalAlpha: 1,
      fillStyle: '',
    } as unknown as CanvasRenderingContext2D);
    const raf = vi.spyOn(window, 'requestAnimationFrame');

    const user = userEvent.setup();
    renderAt('#/game/memory?seed=shell-confetti');
    await screen.findByTestId('memory-board');
    // 关卡 1 就是 2 对，四张牌点完即通关
    await waitFor(() => expect(screen.getAllByTestId('memory-card')).toHaveLength(4));
    expect(raf).not.toHaveBeenCalled();

    // 按 data-pair 现取配对顺序：布局每局都不同，不能写死下标
    const byPair = new Map<string, HTMLElement[]>();
    for (const card of screen.getAllByTestId('memory-card')) {
      const pair = (card as HTMLElement).dataset.pair as string;
      byPair.set(pair, [...(byPair.get(pair) ?? []), card as HTMLElement]);
    }
    for (const [first, second] of byPair.values()) {
      await user.click(first as HTMLElement);
      await user.click(second as HTMLElement);
    }

    await waitFor(() => expect(screen.getByTestId('memory-status')).toHaveTextContent('恭喜通关！'));
    await waitFor(() => expect(raf).toHaveBeenCalled());
  });
});
