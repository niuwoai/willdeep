import { expect } from '@playwright/test';
import { test } from './fixtures';
import type { Page } from '@playwright/test';

/**
 * 俄罗斯方块端到端回归（并行节点交付）。
 *
 * 策略：
 *  - 固定种子 e2e-tetris-7bag：方块序列经 createPieceQueue（createRng）
 *    确定性生成；硬降堆叠必然顶出，80 次硬降保证终局
 *  - 键盘输入经 useKeyControls；触屏经 CDP Input.dispatchTouchEvent 注入真实 touch tap
 *  - best 持久化直接断言 localStorage `arcade.best.tetris` 与重载后的 GameShell 徽章
 */
const BEST_KEY = 'arcade.best.tetris';
const SEED = 'e2e-tetris-7bag';

async function openGame(page: Page): Promise<void> {
  await page.goto(`/#/game/tetris?seed=${SEED}`);
  await expect(page.getByTestId('tetris-board')).toBeVisible();
}

async function hardDrops(page: Page, count: number): Promise<void> {
  for (let index = 0; index < count; index += 1) await page.keyboard.press('Space');
}

test.describe('俄罗斯方块契约', () => {
  test('键盘输入：左移与旋转', async ({ page }) => {
    await openGame(page);
    const active = page.getByTestId('tetris-active');
    const x0 = Number(await active.getAttribute('data-x'));
    const rotation0 = Number(await active.getAttribute('data-rotation'));

    await page.keyboard.press('ArrowLeft');
    await expect(active).toHaveAttribute('data-x', String(x0 - 1));

    await page.keyboard.press('ArrowUp');
    await expect(active).toHaveAttribute('data-rotation', String((rotation0 + 1) % 4));
  });

  test('触屏输入：按钮点击与 CDP touch tap', async ({ page }) => {
    await openGame(page);
    const active = page.getByTestId('tetris-active');
    const x0 = Number(await active.getAttribute('data-x'));
    const rotation0 = Number(await active.getAttribute('data-rotation'));

    await page.getByTestId('tetris-btn-left').click();
    await expect(active).toHaveAttribute('data-x', String(x0 - 1));

    const cdp = await page.context().newCDPSession(page);
    const tap = async (testId: string) => {
      const box = await page.getByTestId(testId).boundingBox();
      expect(box).not.toBeNull();
      const { x, y, width, height } = box as { x: number; y: number; width: number; height: number };
      await cdp.send('Input.dispatchTouchEvent', {
        type: 'touchStart',
        touchPoints: [{ x: x + width / 2, y: y + height / 2, id: 1, radiusX: 2, radiusY: 2, force: 1 }],
      });
      await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
    };

    await tap('tetris-btn-right');
    await expect(active).toHaveAttribute('data-x', String(x0));

    await tap('tetris-btn-rotate');
    await expect(active).toHaveAttribute('data-rotation', String((rotation0 + 1) % 4));
  });

  test('终局写入并持久化 best:tetris，重开复位', async ({ page }) => {
    await page.goto('/');
    await page.evaluate((key) => window.localStorage.removeItem(key), BEST_KEY);
    await openGame(page);

    await hardDrops(page, 80);
    await expect(page.getByTestId('tetris-game-over')).toBeVisible();

    const stored = await page.evaluate((key) => {
      const raw = window.localStorage.getItem(key);
      return raw === null ? 0 : (JSON.parse(raw) as { value: number }).value;
    }, BEST_KEY);
    expect(stored).toBeGreaterThan(0);
    await expect(page.getByTestId('game-best-score')).toContainText(String(stored));

    await page.getByTestId('tetris-restart').click();
    await expect(page.getByTestId('tetris-game-over')).toHaveCount(0);
    await expect(page.getByTestId('tetris-score')).toHaveText('0');
    await expect(page.getByTestId('tetris-lines')).toHaveText('0');
    await expect(page.getByTestId('tetris-level')).toHaveText('1');

    await page.reload();
    await expect(page.getByTestId('game-best-score')).toContainText(String(stored));
  });
});
