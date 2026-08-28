import { expect } from '@playwright/test';
import { test } from './fixtures';

test.describe('2048', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/#/game/2048?seed=e2e-2048');
    await expect(page.getByTestId('2048-board')).toBeVisible();
  });

  test('开局两块数字，键盘移动后补入一块', async ({ page }) => {
    await expect(page.getByTestId('2048-tile')).toHaveCount(16);
    const before = await page.getByTestId('2048-board').getAttribute('data-values');
    const initialValues = (before ?? '').split(',').filter((value) => Number(value) > 0);
    expect(initialValues).toHaveLength(2);

    for (const key of ['ArrowLeft', 'ArrowUp', 'ArrowRight', 'ArrowDown']) {
      await page.keyboard.press(key);
    }
    const after = await page.getByTestId('2048-board').getAttribute('data-values');
    expect(after).not.toBe(before);
    await expect(page.getByTestId('2048-moves')).not.toHaveText('0');
  });

  test('触屏方向按钮与重开可用', async ({ page }) => {
    await page.getByRole('button', { name: '向右移动' }).click();
    await expect(page.getByTestId('2048-moves')).not.toHaveText('0');
    await page.getByTestId('2048-restart').click();
    await expect(page.getByTestId('2048-moves')).toHaveText('0');
  });
});
