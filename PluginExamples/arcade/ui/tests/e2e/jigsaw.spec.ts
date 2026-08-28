import { expect } from '@playwright/test';
import { test } from './fixtures';

test.describe('图片拼图', () => {
  test('先选内置图片，再进入 3×3 棋盘并可查看原图', async ({ page }) => {
    await page.goto('/#/game/jigsaw?seed=e2e-jigsaw');
    await expect(page.getByTestId('jigsaw-picker')).toBeVisible();
    await expect(page.getByTestId('jigsaw-board')).toHaveCount(0);

    await page.getByTestId('jigsaw-image-lighthouse').click();
    await expect(page.getByTestId('jigsaw-board')).toBeVisible();
    await expect(page.getByTestId('jigsaw-piece')).toHaveCount(9);

    await page.getByTestId('jigsaw-preview-toggle').click();
    await expect(page.getByTestId('jigsaw-preview')).toBeVisible();
    await expect(page.getByTestId('jigsaw-preview').locator('img')).toHaveAttribute('src', /coastal-lighthouse/);
  });

  test('连续点选两块可以交换，换图返回选择页', async ({ page }) => {
    await page.goto('/#/game/jigsaw?seed=e2e-swap');
    await page.getByTestId('jigsaw-image-railway').click();
    const pieces = page.getByTestId('jigsaw-piece');
    const first = await pieces.nth(0).getAttribute('data-piece');
    const second = await pieces.nth(1).getAttribute('data-piece');

    await pieces.nth(0).click();
    await pieces.nth(1).click();
    await expect(pieces.nth(0)).toHaveAttribute('data-piece', second as string);
    await expect(pieces.nth(1)).toHaveAttribute('data-piece', first as string);
    await expect(page.getByTestId('jigsaw-moves')).toContainText('1');

    await page.getByTestId('jigsaw-change-image').click();
    await expect(page.getByTestId('jigsaw-picker')).toBeVisible();
  });
});
