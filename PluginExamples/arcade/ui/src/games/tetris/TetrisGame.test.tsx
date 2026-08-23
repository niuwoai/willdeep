import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it } from 'vitest';
import { App } from '../../App';
import { HashRouter } from '../../core/hashRouter';
import { I18nProvider } from '../../core/i18n';

/**
 * 俄罗斯方块集成回归（jsdom 镜像 e2e 场景）。
 *
 * 在受限沙箱（node 无网络、无法起 vite/浏览器）下，用真实 App + 路由 +
 * localStorage 复现 tests/e2e/tetris.spec.ts 的三条场景，保证交付的
 * 契约行为（键盘/触屏输入、终局、best:tetris 持久化、重开复位）可回归。
 */
const BEST_KEY = 'arcade.best.tetris';
const SEED = 'e2e-tetris-7bag';

function renderAtTetris() {
  window.location.hash = `#/game/tetris?seed=${SEED}`;
  return render(
    <HashRouter>
      <I18nProvider>
        <App />
      </I18nProvider>
    </HashRouter>,
  );
}

async function hardDrops(user: ReturnType<typeof userEvent.setup>, count: number): Promise<void> {
  for (let index = 0; index < count; index += 1) await user.keyboard(' ');
}

describe('俄罗斯方块集成（镜像 e2e）', () => {
  beforeEach(() => {
    window.localStorage.clear();
    window.location.hash = '/';
  });

  it('键盘输入：左移与旋转', async () => {
    const user = userEvent.setup();
    const view = renderAtTetris();
    const active = await screen.findByTestId('tetris-active');
    const x0 = Number(active.dataset.x);
    const rotation0 = Number(active.dataset.rotation);

    await user.keyboard('{ArrowLeft}');
    expect(Number(active.dataset.x)).toBe(x0 - 1);

    await user.keyboard('{ArrowUp}');
    expect(Number(active.dataset.rotation)).toBe((rotation0 + 1) % 4);

    view.unmount();
  });

  it('按钮输入（触屏等价）：左移与旋转', async () => {
    const user = userEvent.setup();
    const view = renderAtTetris();
    const active = await screen.findByTestId('tetris-active');
    const x0 = Number(active.dataset.x);
    const rotation0 = Number(active.dataset.rotation);

    await user.click(screen.getByTestId('tetris-btn-left'));
    expect(Number(active.dataset.x)).toBe(x0 - 1);

    await user.click(screen.getByTestId('tetris-btn-rotate'));
    expect(Number(active.dataset.rotation)).toBe((rotation0 + 1) % 4);

    view.unmount();
  });

  it('终局写入并持久化 best:tetris，重开复位', async () => {
    const user = userEvent.setup();
    const first = renderAtTetris();
    await screen.findByTestId('tetris-board');

    await hardDrops(user, 80);
    expect(await screen.findByTestId('tetris-game-over')).toBeInTheDocument();

    const stored = JSON.parse(window.localStorage.getItem(BEST_KEY) ?? 'null') as { value: number } | null;
    expect(stored).not.toBeNull();
    expect(stored!.value).toBeGreaterThan(0);
    expect(screen.getByTestId('game-best-score')).toHaveTextContent(String(stored!.value));

    await user.click(screen.getByTestId('tetris-restart'));
    expect(screen.queryByTestId('tetris-game-over')).not.toBeInTheDocument();
    expect(screen.getByTestId('tetris-score')).toHaveTextContent('0');
    expect(screen.getByTestId('tetris-lines')).toHaveTextContent('0');
    expect(screen.getByTestId('tetris-level')).toHaveTextContent('1');

    first.unmount();

    // 等价于 e2e 的 reload：重新挂载后 GameShell 徽章仍显示持久化的最佳成绩
    renderAtTetris();
    expect(await screen.findByTestId('game-best-score')).toHaveTextContent(String(stored!.value));
  });
});
