import { expect } from '@playwright/test';
import { test } from './fixtures';
import type { Page } from '@playwright/test';
import { BOARD_SIZE, createBoard } from '../../src/games/minesweeper/logic';

/**
 * 扫雷端到端回归（验收节点补全）。
 *
 * 策略：
 *  - createBoard 为确定性算法：对 `e2e-mine-1:0`（?seed=e2e-mine-1，round 0）
 *    可在用例内复算雷位，从而“只点安全格通关 / 只点雷判负”均为确定行为
 *  - 终局把 best:minesweeper 写入 localStorage（81 − 旗帜数），断言徽章与
 *    刷新后的持久化
 *  - 右键（contextmenu）插旗作为计分/状态证据
 */

const BEST_KEY = 'arcade.best.minesweeper';
const CELL_COUNT = BOARD_SIZE * BOARD_SIZE;

function cell(page: Page, index: number) {
  return page.locator('[data-testid="minesweeper-cell"]').nth(index);
}

function mineIndices(seed: string): Set<number> {
  const mines = new Set<number>();
  createBoard(seed).forEach((item, index) => {
    if (item.mine) mines.add(index);
  });
  return mines;
}

async function openGame(page: Page): Promise<Set<number>> {
  await page.goto('/#/game/minesweeper?seed=e2e-mine-1');
  await expect(page.getByTestId('minesweeper-board')).toBeVisible();
  await expect(page.locator('[data-testid="minesweeper-cell"]')).toHaveCount(CELL_COUNT);
  return mineIndices('e2e-mine-1:0');
}

test.describe('扫雷', () => {
  test('点开全部安全格通关：计分、best:minesweeper 写入并持久化', async ({ page }) => {
    const mines = await openGame(page);

    // 相邻为 0 的安全格会洪水式翻开邻居，可能提前通关（棋盘随即禁用）；
    // force 点击已翻开/已禁用的格子是无害 no-op，因此顺序点完全部安全格即可。
    for (let index = 0; index < CELL_COUNT; index += 1) {
      if (!mines.has(index)) await cell(page, index).click({ force: true });
    }

    await expect(page.getByTestId('minesweeper-status')).toHaveText('已清除雷区');
    await expect(page.getByTestId('game-best-score')).toContainText('81');

    const stored = await page.evaluate((key) => localStorage.getItem(key), BEST_KEY);
    expect(stored).not.toBeNull();
    expect(JSON.parse(stored as string).value).toBe(81);

    await page.reload();
    await expect(page.getByTestId('minesweeper-board')).toBeVisible();
    await expect(page.getByTestId('game-best-score')).toContainText('81');
  });

  test('右键插旗计分，随后踩雷判负并可新开局复位', async ({ page }) => {
    const mines = await openGame(page);
    const mineIndex = [...mines][0] as number;
    const safeIndex = (() => {
      for (let index = 0; index < CELL_COUNT; index += 1) {
        if (!mines.has(index)) return index;
      }
      return -1;
    })();

    // 插旗：旗帜计数 0 → 1 → 0
    await cell(page, safeIndex).click({ button: 'right' });
    await expect(page.getByTestId('minesweeper-flags')).toContainText('1');
    await cell(page, safeIndex).click({ button: 'right' });
    await expect(page.getByTestId('minesweeper-flags')).toContainText('0');

    // 踩雷判负
    await cell(page, mineIndex).click();
    await expect(page.getByTestId('minesweeper-status')).toHaveText('踩到地雷');

    // 新游戏：棋盘换布局、状态复位、旗帜清零
    await page.getByRole('button', { name: '新游戏' }).click();
    await expect(page.getByTestId('minesweeper-status')).toHaveText('点击翻开格子，右键或长按插旗。');
    await expect(page.getByTestId('minesweeper-flags')).toContainText('0');
    await expect(cell(page, 0)).not.toHaveClass(/revealed/);
    await expect(page.locator('[data-testid="minesweeper-cell"]')).toHaveCount(CELL_COUNT);
  });
});
