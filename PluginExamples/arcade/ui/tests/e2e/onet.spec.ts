import { expect } from '@playwright/test';
import { test } from './fixtures';

/**
 * 连连看端到端回归。
 *
 * 布局不写死（每次重开都会换牌面），一律从提示按钮拿一对真的可消的牌，
 * 再断言消除、计分持久化与「重开换牌面」。
 */
const BEST_KEY = 'arcade.best.onet';

/** 用提示取一对可消的牌，点掉它们，返回消除前的剩余数。 */
async function clearOnePair(page: import('@playwright/test').Page): Promise<number> {
  const before = Number(await page.getByTestId('onet-remaining-value').textContent());
  await page.getByTestId('onet-hint').click();
  const hinted = page.locator('[data-testid="onet-tile"].onet__tile--hint');
  await expect(hinted).toHaveCount(2);
  await hinted.nth(0).click();
  await hinted.nth(1).click();
  await expect(page.getByTestId('onet-remaining-value')).toHaveText(String(before - 2));
  return before;
}

test.describe('连连看', () => {
  test('提示给出的一对可以连掉，剩余牌数递减', async ({ page }) => {
    await page.goto('/#/game/onet?seed=e2e-onet');
    await expect(page.getByTestId('onet-board')).toBeVisible();
    await expect(page.locator('[data-testid="onet-tile"]')).toHaveCount(24);

    const before = await clearOnePair(page);
    expect(before).toBe(24);
    // 成功连接会画出连线（短暂停留后自动消失）
    await expect(page.getByTestId('onet-status')).toHaveText('进行中');
  });

  test('切到简单档位后清空棋盘，写入 best:onet', async ({ page }) => {
    await page.goto('/#/game/onet?seed=e2e-onet-win');
    await expect(page.getByTestId('onet-board')).toBeVisible();
    await page.getByTestId('onet-level-easy').click();
    await expect(page.locator('[data-testid="onet-tile"]')).toHaveCount(16);

    for (let pair = 0; pair < 8; pair += 1) {
      const remaining = Number(await page.getByTestId('onet-remaining-value').textContent());
      if (remaining === 0) break;
      await clearOnePair(page);
    }

    await expect(page.getByTestId('onet-remaining-value')).toHaveText('0');
    await expect(page.getByTestId('onet-status')).toHaveText('全部消完，漂亮！');
    const stored = await page.evaluate((key) => localStorage.getItem(key), BEST_KEY);
    expect(stored).not.toBeNull();
  });

  test('重开换一副新牌面', async ({ page }) => {
    await page.goto('/#/game/onet?seed=e2e-onet-restart');
    await expect(page.getByTestId('onet-board')).toBeVisible();

    const layout = () =>
      page
        .locator('[data-testid="onet-tile"]')
        .evaluateAll((nodes) => nodes.map((node) => (node as HTMLElement).dataset.symbol).join(','));

    const first = await layout();
    await page.getByTestId('onet-restart').click();
    await expect.poll(layout).not.toBe(first);
  });
});
