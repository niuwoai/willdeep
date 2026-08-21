import { expect } from '@playwright/test';
import { test } from './fixtures';
import type { Page } from '@playwright/test';

/**
 * 最佳成绩存储契约回归（验收节点补全）：
 *  1) 跨游戏存储隔离：arcade.best.<id> 各自独立，互不串扰
 *  2) 损坏 JSON 降级：坏纪录不白屏、按“暂无记录”处理、可继续游玩并写入新纪录
 *  3) localStorage 抛异常（隐私模式/配额超限）降级不白屏
 */

const BEST_MEMORY = 'arcade.best.memory';
const BEST_SNAKE = 'arcade.best.snake';

function card(page: Page, index: number) {
  return page.locator(`[data-testid="memory-card"][data-index="${index}"]`);
}

async function winMemoryTwoPairs(page: Page): Promise<void> {
  await page.goto('/#/game/memory?seed=e2e-memory-2p');
  await expect(page.getByTestId('memory-board')).toBeVisible();
  await page.getByTestId('memory-pairs-2').click();
  await expect(page.locator('[data-testid="memory-card"]')).toHaveCount(4);
  for (const index of [0, 1, 2, 3]) await card(page, index).click();
  await expect(page.getByTestId('memory-status')).toHaveText('恭喜通关！');
}

test('跨游戏存储隔离：memory 成绩不串扰 snake', async ({ page }) => {
  await page.goto('/');
  await page.evaluate(() => window.localStorage.clear());

  // 打一局记忆翻牌：写入 arcade.best.memory = 180
  await winMemoryTwoPairs(page);
  await expect(page.getByTestId('game-best-score')).toContainText('180');

  // 打开贪吃蛇：徽章显示暂无记录，且 arcade.best.snake 不存在
  await page.goto('/#/game/snake?seed=e2e-snake-236');
  await expect(page.getByTestId('snake-board')).toBeVisible();
  await expect(page.getByTestId('game-best-score')).toContainText('暂无记录');
  expect(await page.evaluate((key) => window.localStorage.getItem(key), BEST_SNAKE)).toBeNull();

  // memory 纪录原样保留
  const memoryRecord = await page.evaluate((key) => window.localStorage.getItem(key), BEST_MEMORY);
  expect(memoryRecord).not.toBeNull();
  expect(JSON.parse(memoryRecord as string).value).toBe(180);
});

test('损坏 JSON 降级：不白屏、按暂无记录、可重玩并写入新纪录', async ({ page }) => {
  await page.goto('/');
  await page.evaluate((key) => window.localStorage.setItem(key, '{broken json'), BEST_MEMORY);

  await page.goto('/#/game/memory?seed=e2e-memory-2p');
  await expect(page.getByTestId('memory-board')).toBeVisible();
  await expect(page.getByTestId('game-best-score')).toContainText('暂无记录');

  // 坏纪录被当作“无纪录”，通关后正常写入新纪录
  await page.getByTestId('memory-pairs-2').click();
  await expect(page.locator('[data-testid="memory-card"]')).toHaveCount(4);
  for (const index of [0, 1, 2, 3]) await card(page, index).click();
  await expect(page.getByTestId('memory-status')).toHaveText('恭喜通关！');
  await expect(page.getByTestId('game-best-score')).toContainText('180');

  const record = await page.evaluate((key) => JSON.parse(window.localStorage.getItem(key) as string), BEST_MEMORY);
  expect(record.value).toBe(180);
});

test('localStorage 抛异常（隐私模式/配额超限）时应用降级不白屏', async ({ page }) => {
  await page.addInitScript(() => {
    const blocked = (): never => {
      throw new Error('storage blocked');
    };
    Storage.prototype.getItem = blocked;
    Storage.prototype.setItem = blocked;
    Storage.prototype.removeItem = blocked;
  });

  await page.clock.install();
  await page.goto('/');
  await expect(page.getByTestId('lobby')).toBeVisible();

  await page.goto('/#/game/snake?seed=e2e-snake-236');
  await expect(page.getByTestId('snake-board')).toBeVisible();
  await expect(page.getByTestId('game-best-score')).toContainText('暂无记录');

  // 玩法不受影响：键盘可驱动蛇移动
  await page.keyboard.press('ArrowRight');
  await page.waitForTimeout(60);
  await page.clock.runFor(240);
  await expect(page.getByTestId('snake-status')).toHaveText('游戏中');
});
