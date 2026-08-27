import { act, render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it } from 'vitest';
import { App } from './App';
import { HashRouter } from './core/hashRouter';
import { I18nProvider } from './core/i18n';
import { GAME_MANIFEST } from './games/manifest';

function renderApp() {
  return render(
    <HashRouter>
      <I18nProvider>
        <App />
      </I18nProvider>
    </HashRouter>,
  );
}

const GAME_IDS = GAME_MANIFEST.map((g) => g.id);

describe('大厅与路由（骨架契约）', () => {
  it('大厅渲染清单里的全部游戏卡片（data-testid 契约）', () => {
    renderApp();
    expect(screen.getByTestId('lobby')).toBeInTheDocument();
    expect(screen.getByTestId('lobby-title')).toHaveTextContent('经典网页小游戏');
    for (const id of GAME_IDS) {
      expect(screen.getByTestId(`lobby-card-${id}`)).toBeInTheDocument();
    }
  });

  it('点击卡片进入对应游戏外壳并渲染贪吃蛇', async () => {
    const user = userEvent.setup();
    renderApp();

    await user.click(screen.getByTestId('lobby-card-snake'));
    await waitFor(() =>
      expect(screen.getByTestId('game-shell-snake')).toBeInTheDocument(),
    );
    expect(screen.getByTestId('game-title')).toHaveTextContent('贪吃蛇');
    expect(screen.getByTestId('snake-game')).toBeInTheDocument();
    expect(screen.getByTestId('game-controls-help')).toBeInTheDocument();
  });

  it('返回大厅链接可用', async () => {
    const user = userEvent.setup();
    renderApp();

    await user.click(screen.getByTestId('lobby-card-tetris'));
    await waitFor(() =>
      expect(screen.getByTestId('game-shell-tetris')).toBeInTheDocument(),
    );
    await user.click(screen.getByTestId('back-to-lobby'));
    await waitFor(() => expect(screen.getByTestId('lobby')).toBeInTheDocument());
  });

  it('未知路由渲染 404', async () => {
    renderApp();
    act(() => {
      window.location.hash = '#/nope';
    });
    await waitFor(() => expect(screen.getByTestId('not-found')).toBeInTheDocument());
  });
});

describe('已集成游戏可运行', () => {
  it('记忆翻牌完成配对后外壳徽章更新', async () => {
    const user = userEvent.setup();
    renderApp();

    await user.click(screen.getByTestId('lobby-card-memory'));
    await waitFor(() =>
      expect(screen.getByTestId('game-shell-memory')).toBeInTheDocument(),
    );

    expect(screen.getByTestId('game-best-score')).toHaveTextContent('暂无记录');
    expect(screen.getAllByTestId('memory-card')).toHaveLength(12);
  });

  it('路由携带 ?seed= 时外壳展示种子徽章', async () => {
    renderApp();
    act(() => {
      window.location.hash = '#/game/pong?seed=abc';
    });
    await waitFor(() =>
      expect(screen.getByTestId('game-shell-pong')).toBeInTheDocument(),
    );
    expect(screen.getByTestId('game-seed')).toHaveTextContent('abc');
  });
});
