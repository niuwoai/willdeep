import { expect } from '@playwright/test';
import { test } from './fixtures';

/**
 * 印加弹珠端到端回归。
 *
 * canvas 内部像素不做断言，只锁 HUD 与交互契约：
 * 链条入场、发射进入进行中、换色、关卡切换与重开。
 */
test.describe('印加弹珠', () => {
  test('场地渲染且链条开始入场', async ({ page }) => {
    await page.goto('/#/game/marble?seed=e2e-marble');
    await expect(page.getByTestId('marble-field')).toBeVisible();
    await expect(page.getByTestId('marble-score-value')).toHaveText('0');
    await expect(page.getByTestId('marble-status')).toHaveText(
      '移动鼠标瞄准，点击或空格发射',
    );

    // canvas 背板尺寸随容器铺满（devicePixelRatio 缩放后仍是正方形）
    const box = await page.getByTestId('marble-field').boundingBox();
    expect(box?.width).toBeGreaterThan(0);
    expect(Math.abs((box?.width ?? 0) - (box?.height ?? 0))).toBeLessThan(2);
  });

  test('发射后进入进行中，弹药按序换上', async ({ page }) => {
    await page.goto('/#/game/marble?seed=e2e-marble-shoot');
    await expect(page.getByTestId('marble-field')).toBeVisible();

    const chips = () =>
      page
        .locator('[data-testid="marble-ammo"] i')
        .evaluateAll((nodes) => nodes.map((node) => (node as HTMLElement).style.background));
    const before = await chips();

    await page.getByTestId('marble-swap').click();
    await expect.poll(chips).toEqual([before[1], before[0]]);

    await page.getByTestId('marble-shoot').click();
    await expect(page.getByTestId('marble-status')).toHaveText('进行中');
  });

  test('切换关卡重置剩余弹珠数，重开回到零分', async ({ page }) => {
    await page.goto('/#/game/marble?seed=e2e-marble-level');
    await expect(page.getByTestId('marble-field')).toBeVisible();

    await page.getByTestId('marble-level-hard').click();
    await expect(page.getByTestId('marble-remaining')).toContainText('70');

    await page.getByTestId('marble-shoot').click();
    await page.getByTestId('marble-restart').click();
    await expect(page.getByTestId('marble-score-value')).toHaveText('0');
  });
});
