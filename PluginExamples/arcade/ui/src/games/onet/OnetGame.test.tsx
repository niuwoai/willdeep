import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it } from 'vitest';
import { App } from '../../App';
import { HashRouter } from '../../core/hashRouter';
import { I18nProvider } from '../../core/i18n';
import { boardForStage } from './logic';

/**
 * 连连看集成回归（jsdom）。
 *
 * 覆盖：路由挂载、难度切换、点选消除写盘、提示按钮，
 * 以及「重开换一副牌面」这条本次新增的核心诉求。
 */
const BEST_KEY = 'arcade.best.onet';
const SEED = 'jsdom-onet';

function renderAtOnet() {
  window.location.hash = `#/game/onet?seed=${SEED}`;
  return render(
    <HashRouter>
      <I18nProvider>
        <App />
      </I18nProvider>
    </HashRouter>,
  );
}

/** 当前棋面的图案排布（空位记作 '-'）。 */
function layout(): string {
  return screen
    .getAllByTestId('onet-tile')
    .map((tile) => (tile as HTMLElement).dataset.symbol || '-')
    .join(',');
}

describe('连连看集成', () => {
  beforeEach(() => {
    window.localStorage.clear();
    window.location.hash = '';
  });

  it('从第 1 关的 4×4 开局，外壳与棋内都显示关卡', async () => {
    renderAtOnet();
    await screen.findByTestId('onet-board');
    const first = boardForStage(1);
    expect(screen.getAllByTestId('onet-tile')).toHaveLength(first.rows * first.cols);
    expect(screen.getByTestId('onet-remaining-value')).toHaveTextContent(
      String(first.rows * first.cols),
    );
    expect(screen.getByTestId('onet-stage')).toHaveTextContent('关卡 1');
    expect(screen.getByTestId('game-stage')).toHaveTextContent('关卡: 1');
  });

  it('通关后自动进入下一关，棋盘变大且分数累计', async () => {
    const user = userEvent.setup();
    renderAtOnet();
    await screen.findByTestId('onet-board');

    // 用提示反复消对，清空第 1 关
    for (let round = 0; round < 12; round += 1) {
      const remaining = Number(screen.getByTestId('onet-remaining-value').textContent);
      if (remaining === 0) break;
      await user.click(screen.getByTestId('onet-hint'));
      const hinted = await waitFor(() => {
        const tiles = screen
          .getAllByTestId('onet-tile')
          .filter((tile) => tile.className.includes('onet__tile--hint'));
        expect(tiles).toHaveLength(2);
        return tiles;
      });
      await user.click(hinted[0] as HTMLElement);
      await user.click(hinted[1] as HTMLElement);
      await waitFor(() =>
        expect(Number(screen.getByTestId('onet-remaining-value').textContent)).toBeLessThan(remaining),
      );
    }

    await waitFor(() => expect(screen.getByTestId('onet-stage')).toHaveTextContent('关卡 2'), {
      timeout: 4000,
    });
    const second = boardForStage(2);
    expect(screen.getAllByTestId('onet-tile')).toHaveLength(second.rows * second.cols);
  });

  it('提示指出的一对可以消掉，剩余牌数减二', async () => {
    const user = userEvent.setup();
    renderAtOnet();
    await screen.findByTestId('onet-board');

    await user.click(screen.getByTestId('onet-hint'));
    const hinted = await waitFor(() => {
      const tiles = screen.getAllByTestId('onet-tile').filter((tile) => tile.className.includes('onet__tile--hint'));
      expect(tiles).toHaveLength(2);
      return tiles;
    });

    const before = Number(screen.getByTestId('onet-remaining-value').textContent);
    await user.click(hinted[0] as HTMLElement);
    await user.click(hinted[1] as HTMLElement);
    await waitFor(() =>
      expect(Number(screen.getByTestId('onet-remaining-value').textContent)).toBe(before - 2),
    );
  });

  it('重开换一副新牌面（同一 seed 也不重复）', async () => {
    const user = userEvent.setup();
    renderAtOnet();
    await screen.findByTestId('onet-board');

    const first = layout();
    await user.click(screen.getByTestId('onet-restart'));
    await waitFor(() => expect(layout()).not.toBe(first));
  });

  it('胜利后写入 best:onet', async () => {
    const user = userEvent.setup();
    renderAtOnet();
    await screen.findByTestId('onet-board');
    await waitFor(() => expect(screen.getAllByTestId('onet-tile')).toHaveLength(16));

    // 反复用提示消对，直到清空棋盘（提示保证给出的一定是可消对）
    for (let round = 0; round < 8; round += 1) {
      const remaining = Number(screen.getByTestId('onet-remaining-value').textContent);
      if (remaining === 0) break;
      await user.click(screen.getByTestId('onet-hint'));
      const hinted = await waitFor(() => {
        const tiles = screen
          .getAllByTestId('onet-tile')
          .filter((tile) => tile.className.includes('onet__tile--hint'));
        expect(tiles).toHaveLength(2);
        return tiles;
      });
      await user.click(hinted[0] as HTMLElement);
      await user.click(hinted[1] as HTMLElement);
      await waitFor(() =>
        expect(Number(screen.getByTestId('onet-remaining-value').textContent)).toBeLessThan(remaining),
      );
    }

    await waitFor(() => expect(screen.getByTestId('onet-remaining-value')).toHaveTextContent('0'));
    expect(window.localStorage.getItem(BEST_KEY)).not.toBeNull();
    expect(screen.getByTestId('game-best-score')).toBeInTheDocument();
  });
});
