import { expect } from '@playwright/test';
import { test } from './fixtures';

/**
 * 响应式布局回归（验收节点补全）：
 * 360×640（经典小屏）视口下，大厅与五款游戏均不得出现横向溢出。
 * 溢出判据：documentElement.scrollWidth 与 body.scrollWidth 均 ≤ 视口宽度。
 */

test.use({ viewport: { width: 360, height: 640 } });

const ROUTES: Array<{ path: string; ready: string }> = [
  { path: '/', ready: 'lobby' },
  { path: '/#/game/memory', ready: 'memory-board' },
  { path: '/#/game/minesweeper', ready: 'minesweeper-board' },
  { path: '/#/game/pong', ready: 'pong-game' },
  { path: '/#/game/snake', ready: 'snake-board' },
  { path: '/#/game/tetris', ready: 'tetris-board' },
];

test('360×640 下大厅与五游戏均无横向溢出', async ({ page }) => {
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
