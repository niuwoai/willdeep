import { expect } from '@playwright/test';
import { test } from './fixtures';
import type { Page } from '@playwright/test';

/**
 * 记忆翻牌端到端回归（并行节点交付）。
 *
 * 策略：
 *  - 牌组布局不再写死：1.297.0-rc1 起每次重开都会换一副新牌，
 *    因此配对顺序一律从 DOM 的 data-pair 现取，2 对配置下 2 步通关，
 *    效率分 = 2×100 − 2×10 = 180
 *  - 2 对配置：先点“简单 · 2 对”难度按钮（memory-pairs-2）
 *  - “真实触屏”用 CDP Input.dispatchTouchEvent 注入 touch tap
 *  - best:memory 持久化直接断言 localStorage `arcade.best.memory`
 *    与重载后的 GameShell 徽章
 */

const BEST_KEY = 'arcade.best.memory';
const WIN_SCORE = 180;

/** 按 data-index 取卡牌。 */
function card(page: Page, index: number) {
  return page.locator(`[data-testid="memory-card"][data-index="${index}"]`);
}

/** 当前牌面的 pairId 序列（用于比对「重开是否换了布局」）。 */
async function layout(page: Page): Promise<string[]> {
  return page.locator('[data-testid="memory-card"]').evaluateAll((nodes) =>
    nodes.map((node) => (node as HTMLElement).dataset.pair ?? ''),
  );
}

/** 按当前布局把每一对牌依次点掉。 */
async function clearBoard(page: Page): Promise<void> {
  const pairs = await layout(page);
  const groups = new Map<string, number[]>();
  pairs.forEach((pairId, index) => {
    const group = groups.get(pairId);
    if (group) group.push(index);
    else groups.set(pairId, [index]);
  });
  for (const indices of groups.values()) {
    await card(page, indices[0] as number).click();
    await card(page, indices[1] as number).click();
  }
}

/** 进入 2 对配置：默认 6 对开局，先切到“简单 · 2 对”。 */
async function openTwoPairs(page: Page): Promise<void> {
  await page.goto('/#/game/memory?seed=e2e-memory-2p');
  await expect(page.getByTestId('memory-board')).toBeVisible();
  await page.getByTestId('memory-pairs-2').click();
  await expect(page.locator('[data-testid="memory-card"]')).toHaveCount(4);
}

test.describe('记忆翻牌（2 对配置）', () => {
  test('终局：2 步配齐两对并通关，写入 best:memory 且刷新后持久化', async ({ page }) => {
    await openTwoPairs(page);

    await clearBoard(page);

    await expect(page.getByTestId('memory-status')).toHaveText('恭喜通关！');
    await expect(page.getByTestId('memory-moves-value')).toHaveText('2');

    // best:memory 持久化：徽章与 localStorage 同步
    await expect(page.getByTestId('game-best-score')).toContainText(String(WIN_SCORE));
    const stored = await page.evaluate((key) => localStorage.getItem(key), BEST_KEY);
    expect(stored).not.toBeNull();
    const record = JSON.parse(stored as string) as { value: number; achievedAt: number };
    expect(record.value).toBe(WIN_SCORE);
    expect(typeof record.achievedAt).toBe('number');

    // 重载后徽章仍显示持久化的最佳成绩
    await page.reload();
    await expect(page.getByTestId('memory-board')).toBeVisible();
    await expect(page.getByTestId('game-best-score')).toContainText(String(WIN_SCORE));
    const afterReload = await page.evaluate((key) => localStorage.getItem(key), BEST_KEY);
    expect(JSON.parse(afterReload as string).value).toBe(WIN_SCORE);
  });

  test('restart：清空配对与步数并复位 idle，随后可再次通关', async ({ page }) => {
    await openTwoPairs(page);

    await card(page, 0).click();
    await card(page, 1).click();
    await expect(page.getByTestId('memory-moves-value')).toHaveText('1');

    await page.getByTestId('memory-restart').click();

    await expect(page.getByTestId('memory-moves-value')).toHaveText('0');
    await expect(page.getByTestId('memory-status')).toHaveText('翻开两张相同的卡牌开始');
    for (const index of [0, 1, 2, 3]) {
      await expect(card(page, index)).toHaveAttribute('aria-pressed', 'false');
    }

    // 复位后完整重开一局仍可通关
    await clearBoard(page);
    await expect(page.getByTestId('memory-status')).toHaveText('恭喜通关！');
    await expect(page.getByTestId('memory-moves-value')).toHaveText('2');
  });

  test('restart：每次重开都换一副新牌（6 对连开五次不重样）', async ({ page }) => {
    await page.goto('/#/game/memory?seed=e2e-memory-reshuffle');
    await expect(page.getByTestId('memory-board')).toBeVisible();
    await page.getByTestId('memory-pairs-6').click();
    await expect(page.locator('[data-testid="memory-card"]')).toHaveCount(12);

    const seen = new Set<string>();
    for (let round = 0; round < 5; round += 1) {
      seen.add((await layout(page)).join(','));
      await page.getByTestId('memory-restart').click();
      await expect(page.getByTestId('memory-moves-value')).toHaveText('0');
    }
    expect(seen.size).toBe(5);
  });

  test.describe('真实触屏', () => {
    test.use({ hasTouch: true, viewport: { width: 390, height: 844 } });

    test('点按翻牌（CDP touch tap）并完成配对', async ({ page }) => {
      await openTwoPairs(page);

      const board = page.getByTestId('memory-board');
      const boxes = await Promise.all([0, 1].map((i) => card(page, i).boundingBox()));

      const cdp = await page.context().newCDPSession(page);
      const tap = async (box: { x: number; y: number; width: number; height: number }) => {
        const x = box.x + box.width / 2;
        const y = box.y + box.height / 2;
        await cdp.send('Input.dispatchTouchEvent', {
          type: 'touchStart',
          touchPoints: [{ x, y, id: 1, radiusX: 2, radiusY: 2, force: 1 }],
        });
        await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
      };

      await tap(boxes[0] as { x: number; y: number; width: number; height: number });
      await expect(card(page, 0)).toHaveAttribute('aria-pressed', 'true');
      await expect(page.getByTestId('memory-moves-value')).toHaveText('0');

      await tap(boxes[1] as { x: number; y: number; width: number; height: number });
      await expect(page.getByTestId('memory-moves-value')).toHaveText('1');
      await expect(page.getByTestId('memory-status')).toHaveText('进行中');
      expect(board).toBeTruthy();
    });
  });
});
