import { expect } from '@playwright/test';
import { test } from './fixtures';

/**
 * 响应式布局回归（验收节点补全）：
 * 360×640（经典小屏）视口下，大厅与全部游戏均不得出现横向溢出。
 * 溢出判据：documentElement.scrollWidth 与 body.scrollWidth 均 ≤ 视口宽度。
 *
 * 另外锁住棋盘一律容器相对，不得再按视口单位算宽；图片拼图新增的选图卡与
 * 正方形棋盘也必须在窄面板里完整收住。
 */

test.use({ viewport: { width: 360, height: 640 } });

const ROUTES: Array<{ path: string; ready: string }> = [
  { path: '/', ready: 'lobby' },
  { path: '/#/game/2048', ready: '2048-board' },
  { path: '/#/game/breakout', ready: 'breakout-field' },
  { path: '/#/game/jigsaw', ready: 'jigsaw-picker' },
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

test('图片拼图的选图卡与棋盘都不超出容器宽度', async ({ page }) => {
  await page.goto('/#/game/jigsaw');
  await expect(page.getByTestId('jigsaw-picker')).toBeVisible();
  await page.getByTestId('jigsaw-image-lighthouse').click();
  await expect(page.getByTestId('jigsaw-board')).toBeVisible();

  const metrics = await page.evaluate(() => {
    const board = document.querySelector('[data-testid="jigsaw-board"]') as HTMLElement;
    const container = board.parentElement as HTMLElement;
    const piece = document.querySelector('[data-testid="jigsaw-piece"]') as HTMLElement;
    return {
      boardWidth: board.getBoundingClientRect().width,
      containerWidth: container.getBoundingClientRect().width,
      pieceWidth: piece.getBoundingClientRect().width,
      docScrollWidth: document.documentElement.scrollWidth,
      clientWidth: document.documentElement.clientWidth,
    };
  });

  expect(metrics.boardWidth).toBeLessThanOrEqual(metrics.containerWidth + 0.5);
  expect(metrics.pieceWidth).toBeLessThanOrEqual(metrics.boardWidth / 3 + 0.5);
  expect(metrics.docScrollWidth).toBeLessThanOrEqual(metrics.clientWidth);
});
