import { expect } from '@playwright/test';
import { test } from './fixtures';
import type { Page } from '@playwright/test';

/**
 * 贪吃蛇端到端回归（并行节点交付）。
 *
 * 策略：
 *  - page.clock.install() 冻结浏览器定时器，用 runFor 精确推进 tick，
 *    键盘/触屏输入与断言之间没有真实时间的竞态
 *  - “真实触屏”用 CDP Input.dispatchTouchEvent 注入真实 touch 事件
 *    （浏览器随之合成 pointerType=touch 的指针事件，走与真机一致的路径）
 *  - best:snake 持久化直接断言 localStorage `arcade.best.snake`
 *    与重载后的 GameShell 徽章
 */

const TICK_MS = 220;
const INITIAL_HEAD = { row: 10, col: 5 };

async function headPos(page: Page): Promise<{ row: number; col: number }> {
  const head = page.getByTestId('snake-head');
  return {
    row: Number(await head.getAttribute('data-row')),
    col: Number(await head.getAttribute('data-col')),
  };
}

/** 按一次方向键并推进 n 个 tick（真实等待让 React 完成 effect 注册）。 */
async function pressAndTick(page: Page, key: string, ticks = 1): Promise<void> {
  await page.keyboard.press(key);
  await page.waitForTimeout(60);
  await page.clock.runFor(ticks * TICK_MS + 20);
}

test.describe('贪吃蛇', () => {
  test.beforeEach(async ({ page }) => {
    // 固定种子（e2e-snake-236）：初始食物在蛇头正前方 (10,6)，
    // 直线向右 20 tick 必吃 1 个食物后撞墙终局（脚本确定性校验）。
    await page.clock.install();
    await page.goto('/#/game/snake?seed=e2e-snake-236');
    await expect(page.getByTestId('snake-board')).toBeVisible();
  });

  test('键盘方向键控制移动（idle 起步、单 tick 一格）', async ({ page }) => {
    await expect(page.getByTestId('snake-score-value')).toHaveText('0');
    await expect(page.getByTestId('snake-status')).toHaveText('按方向键或滑动开始');
    expect(await headPos(page)).toEqual(INITIAL_HEAD);

    await pressAndTick(page, 'ArrowUp');

    await expect(page.getByTestId('snake-head')).toHaveAttribute('data-row', String(INITIAL_HEAD.row - 1));
    await expect(page.getByTestId('snake-head')).toHaveAttribute('data-col', String(INITIAL_HEAD.col));
    await expect(page.getByTestId('snake-status')).toHaveText('游戏中');
  });

  test.describe('真实触屏', () => {
    test.use({ hasTouch: true, viewport: { width: 390, height: 844 } });

    test('滑动控制方向（CDP touch 事件）', async ({ page }) => {
      const board = page.getByTestId('snake-board');
      const box = (await board.boundingBox())!;
      const cx = box.x + box.width / 2;
      const cy = box.y + box.height / 2;

      const cdp = await page.context().newCDPSession(page);
      const point = (x: number, y: number) => ({ x, y, id: 1, radiusX: 2, radiusY: 2, force: 1 });
      await cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [point(cx, cy)] });
      await cdp.send('Input.dispatchTouchEvent', { type: 'touchMove', touchPoints: [point(cx, cy - 30)] });
      await cdp.send('Input.dispatchTouchEvent', { type: 'touchMove', touchPoints: [point(cx, cy - 60)] });
      await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });

      await page.waitForTimeout(60);
      await page.clock.runFor(TICK_MS + 20);

      await expect(page.getByTestId('snake-head')).toHaveAttribute('data-row', String(INITIAL_HEAD.row - 1));
      await expect(page.getByTestId('snake-status')).toHaveText('游戏中');
    });
  });

  test('撞墙终局，写入并持久化 best:snake', async ({ page }) => {
    // 直线向右 20 tick：吃 1 个食物后撞墙终局（种子经脚本确定性校验）
    await pressAndTick(page, 'ArrowRight', 20);

    await expect(page.getByTestId('snake-status')).toHaveText('游戏结束');
    await expect(page.getByTestId('snake-score-value')).toHaveText('1');

    // best:snake 已写入且与展示分数一致
    const stored = await page.evaluate(() => localStorage.getItem('arcade.best.snake'));
    expect(stored).not.toBeNull();
    expect(JSON.parse(stored!).value).toBe(1);

    // 重载后徽章仍显示该最佳成绩（持久化）
    await page.goto('/#/game/snake?seed=e2e-snake-236');
    await expect(page.getByTestId('game-best-score')).toContainText('1');
  });

  test('终局后重开复位（分数、状态、蛇头位置）', async ({ page }) => {
    await pressAndTick(page, 'ArrowRight', 20);
    await expect(page.getByTestId('snake-status')).toHaveText('游戏结束');

    await page.getByTestId('snake-restart').click();

    await expect(page.getByTestId('snake-score-value')).toHaveText('0');
    await expect(page.getByTestId('snake-status')).toHaveText('按方向键或滑动开始');
    expect(await headPos(page)).toEqual(INITIAL_HEAD);
  });
});
