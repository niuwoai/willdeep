import { expect } from '@playwright/test';
import { test } from './fixtures';

/**
 * 响应式布局回归（验收节点补全）：
 * 360×640（经典小屏）视口下，大厅与全部游戏均不得出现横向溢出。
 * 溢出判据：documentElement.scrollWidth 与 body.scrollWidth 均 ≤ 视口宽度。
 *
 * 另外锁一条 1.297.0-rc1 的回归：棋盘一律容器相对，不得再按视口单位算宽——
 * 记忆翻牌「挑战 · 6 对」曾因 width: min(92vw, 420px) 在窄面板里被撑出可视区。
 */

test.use({ viewport: { width: 360, height: 640 } });

const ROUTES: Array<{ path: string; ready: string }> = [
  { path: '/', ready: 'lobby' },
  { path: '/#/game/memory', ready: 'memory-board' },
  { path: '/#/game/onet', ready: 'onet-board' },
  { path: '/#/game/marble', ready: 'marble-field' },
  { path: '/#/game/minesweeper', ready: 'minesweeper-board' },
  { path: '/#/game/pong', ready: 'pong-game' },
  { path: '/#/game/snake', ready: 'snake-board' },
  { path: '/#/game/tetris', ready: 'tetris-board' },
];

test('360×640 下大厅与全部游戏均无横向溢出', async ({ page }) => {
  for (const route of ROUTES) {
    await page.goto(route.path);
    await expect(page.getByTestId(route.ready)).toBeVisible();

    const metrics = await page.evaluate(() => {
      const root = document.documentElement;
      return {
        clientWidth: root.clientWidth,
        docScrollWidth: root.scrollWidth,
        bodyScrollWidth: document.body.scrollWidth,
      };
    });

    expect(
      metrics.docScrollWidth,
      `${route.path} 页面横向溢出：docScrollWidth=${metrics.docScrollWidth}`,
    ).toBeLessThanOrEqual(metrics.clientWidth);
    expect(
      metrics.bodyScrollWidth,
      `${route.path} body 横向溢出：bodyScrollWidth=${metrics.bodyScrollWidth}`,
    ).toBeLessThanOrEqual(metrics.clientWidth);
  }
});

test('记忆翻牌各难度的棋盘都不超出容器宽度', async ({ page }) => {
  await page.goto('/#/game/memory');
  await expect(page.getByTestId('memory-board')).toBeVisible();

  for (const pairs of [2, 4, 6]) {
    await page.getByTestId(`memory-pairs-${pairs}`).click();
    const metrics = await page.evaluate(() => {
      const board = document.querySelector('[data-testid="memory-board"]') as HTMLElement;
      const container = board.parentElement as HTMLElement;
      const card = document.querySelector('[data-testid="memory-card"]') as HTMLElement;
      return {
        boardWidth: board.getBoundingClientRect().width,
        containerWidth: container.getBoundingClientRect().width,
        cardWidth: card.getBoundingClientRect().width,
        docScrollWidth: document.documentElement.scrollWidth,
        clientWidth: document.documentElement.clientWidth,
      };
    });
    expect(
      metrics.boardWidth,
      `${pairs} 对：棋盘 ${metrics.boardWidth} 超出容器 ${metrics.containerWidth}`,
    ).toBeLessThanOrEqual(metrics.containerWidth + 0.5);
    // 单张牌有绝对上限，任何面板宽度下都不会被放大到离谱尺寸
    expect(metrics.cardWidth).toBeLessThanOrEqual(96.5);
    expect(metrics.docScrollWidth).toBeLessThanOrEqual(metrics.clientWidth);
  }
});
