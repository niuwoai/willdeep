import { expect } from '@playwright/test';
import { test } from './fixtures';

test.describe('打砖块', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/#/game/breakout');
    await expect(page.getByTestId('breakout-field')).toBeVisible();
  });

  test('首关显示 40 块砖和 3 条命，可发球与暂停', async ({ page }) => {
    await expect(page.getByTestId('breakout-bricks')).toHaveText('40');
    await expect(page.getByTestId('breakout-lives')).toHaveText('3');
    await expect(page.getByTestId('breakout-status')).toHaveText('移动挡板，准备发球');

    await page.getByTestId('breakout-toggle').click();
    await expect(page.getByTestId('breakout-status')).toHaveText('击碎所有砖块');
    await page.getByTestId('breakout-toggle').click();
    await expect(page.getByTestId('breakout-status')).toHaveText('已暂停');
  });

  test('键盘发球，重开恢复首关状态', async ({ page }) => {
    await page.keyboard.press('Space');
    await expect(page.getByTestId('breakout-status')).toHaveText('击碎所有砖块');
    await page.getByTestId('breakout-restart').click();
    await expect(page.getByTestId('breakout-status')).toHaveText('移动挡板，准备发球');
    await expect(page.getByTestId('breakout-score')).toHaveText('0');
  });
});
