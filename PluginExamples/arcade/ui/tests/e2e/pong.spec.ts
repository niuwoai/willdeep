import { expect } from '@playwright/test';
import { test } from './fixtures';
import type { Locator, Page } from '@playwright/test';

/**
 * 乒乓球端到端回归（验收节点补全）。
 *
 * 策略：
 *  - page.clock.install() 冻结定时器；物理完全确定（无随机数）
 *  - “真实触屏”用 CDP Input.dispatchTouchEvent 注入 touch tap（走 pointerType=touch）
 *  - 胜利：每个 tick 把指针对准球的 y（并外推一个 tick 的 dy），球员球拍
 *    全程跟踪；CPU 追速 2.2/tick，球速随反弹 ×1.06 增长，迟早漏球 → 球员 5 分获胜
 *  - 失败：球拍停在顶部（y=0），球员漏球为主 → CPU 先到 5 分，展示 '×' 且不写 best
 */

const WIN_CHECKMARK = '✓';
const LOSE_CROSS = '×';

async function paddleY(page: Page): Promise<number> {
  return page.evaluate(() => {
    const el = document.querySelector('.pong__paddle--player') as HTMLElement | null;
    return el ? Number.parseFloat(getComputedStyle(el).getPropertyValue('--paddle-y')) : NaN;
  });
}

async function ballY(page: Page): Promise<number> {
  return page.evaluate(() => {
    const el = document.querySelector('.pong__ball') as HTMLElement | null;
    return el ? Number.parseFloat(getComputedStyle(el).getPropertyValue('--ball-y')) : NaN;
  });
}

async function tapElement(page: Page, locator: Locator): Promise<void> {
  const box = await locator.boundingBox();
  expect(box).not.toBeNull();
  const cdp = await page.context().newCDPSession(page);
  const { x, y, width, height } = box as { x: number; y: number; width: number; height: number };
  await cdp.send('Input.dispatchTouchEvent', {
    type: 'touchStart',
    touchPoints: [{ x: x + width / 2, y: y + height / 2, id: 1, radiusX: 2, radiusY: 2, force: 1 }],
  });
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
  await cdp.detach();
}

test.describe('乒乓球', () => {
  test.setTimeout(300_000);

  test.beforeEach(async ({ page }) => {
    await page.clock.install();
    await page.goto('/#/game/pong');
    await expect(page.getByTestId('pong-game')).toBeVisible();
  });

  test('键盘通道：方向键移动球拍', async ({ page }) => {
    expect(await paddleY(page)).toBe(40);

    await page.keyboard.press('ArrowDown');
    await page.keyboard.press('ArrowDown');
    await page.keyboard.press('ArrowDown');
    expect(await paddleY(page)).toBe(58);

    await page.keyboard.press('ArrowUp');
    await page.keyboard.press('ArrowUp');
    expect(await paddleY(page)).toBe(46);

    await page.keyboard.press('s');
    expect(await paddleY(page)).toBe(52);
  });

  test('真实触屏通道：CDP touch tap 按钮驱动球拍', async ({ page }) => {
    expect(await paddleY(page)).toBe(40);

    await tapElement(page, page.getByRole('button', { name: '下移' }));
    await tapElement(page, page.getByRole('button', { name: '下移' }));
    expect(await paddleY(page)).toBe(56);

    await tapElement(page, page.getByRole('button', { name: '上移' }));
    expect(await paddleY(page)).toBe(48);
  });

  test('球员跟踪球至 5 分获胜，写入并持久化 best:pong', async ({ page }) => {
    const court = page.getByTestId('pong-court');
    const box = await court.boundingBox();
    expect(box).not.toBeNull();

    // 跟踪策略：每个 tick 派发 1 个合成 pointermove（走 React 同一条
    // onPointerMove 路径）。注意不可连发多个——handler 闭包里的
    // game.playerY 在同一渲染内不变，5 连发会按同一基准叠加 5 次 55% 收敛
    // 而过冲撞钳位，导致球拍在上下边界震荡漏球。单发收敛 55%/次 →
    // 稳态滞后 ≈ 0.82×dy，dy≤6（约第 33 次反弹前）玩家必不漏球；CPU 追速
    // 2.2/tick，球速随反弹 ×1.06 增长，约第 25-35 次反弹后 CPU 追不上 →
    // 球员得分。物理完全确定，胜负可复现。
    const courtX = (box as { x: number; width: number }).x + (box as { width: number }).width / 2;
    const courtTop = (box as { y: number }).y;
    const courtHeight = (box as { height: number }).height;
    const track = (targetY: number) =>
      page.evaluate(
        ({ x, y }) => {
          const el = document.querySelector('[data-testid="pong-court"]') as HTMLElement | null;
          if (!el) return;
          el.dispatchEvent(
            new PointerEvent('pointermove', {
              bubbles: true,
              cancelable: true,
              clientX: x,
              clientY: y,
              pointerType: 'mouse',
            }),
          );
        },
        { x: courtX, y: courtTop + (targetY / 100) * courtHeight },
      );

    let previous = await ballY(page);
    let playerScore = -1;
    const deadline = Date.now() + 240_000;
    let iter = 0;
    while (Date.now() < deadline) {
      const current = await ballY(page);
      const dy = current - previous;
      previous = current;
      await track(Math.min(98, Math.max(2, current + dy)));
      await page.clock.runFor(32);

      iter += 1;
      if (iter % 16 !== 0) continue;
      const scoreText = await page.getByTestId('pong-score').textContent();
      const match = /(\d+)/.exec(scoreText ?? '');
      if (match && Number(match[1]) >= 5) {
        playerScore = Number(match[1]);
        break;
      }
    }

    expect(playerScore).toBe(5);
    await expect(page.getByTestId('pong-game')).toContainText(WIN_CHECKMARK);

    const stored = await page.evaluate(() => localStorage.getItem('arcade.best.pong'));
    expect(stored).not.toBeNull();
    expect(JSON.parse(stored as string).value).toBe(5);
    await expect(page.getByTestId('game-best-score')).toContainText('5');

    await page.reload();
    await expect(page.getByTestId('pong-game')).toBeVisible();
    await expect(page.getByTestId('game-best-score')).toContainText('5');
  });

  test('球拍停顶漏球判负（CPU 5 分、不写 best），重开复位', async ({ page }) => {
    for (let index = 0; index < 10; index += 1) await page.keyboard.press('ArrowUp');
    expect(await paddleY(page)).toBe(0);

    await page.clock.runFor(150_000);
    await expect(page.getByTestId('pong-game')).toContainText(LOSE_CROSS);

    // 计分证据：CPU 先到 5
    const scoreText = await page.getByTestId('pong-score').textContent();
    expect(/5/.test(scoreText ?? '')).toBe(true);

    // 输家不写入 best
    const stored = await page.evaluate(() => localStorage.getItem('arcade.best.pong'));
    expect(stored).toBeNull();

    // 重开复位：比分、球拍、球位
    await page.getByRole('button', { name: '重新开始' }).click();
    await expect(page.getByTestId('pong-score')).toContainText('0 – 0');
    expect(await paddleY(page)).toBe(40);
    const ball = await page.evaluate(() => {
      const el = document.querySelector('.pong__ball') as HTMLElement;
      return {
        x: Number.parseFloat(getComputedStyle(el).getPropertyValue('--ball-x')),
        y: Number.parseFloat(getComputedStyle(el).getPropertyValue('--ball-y')),
      };
    });
    // 复位点为 (48,48)、dx=1.4、dy=0.8；断言读取与重启提交存在 0~若干
    // tick 的竞态（实测 0–3 tick），故用覆盖“中心向右下移动”的有界窗口，
    // 同时排除复位前球可能所处的任意位置。
    expect(ball.x).toBeGreaterThanOrEqual(48);
    expect(ball.x).toBeLessThanOrEqual(65);
    expect(ball.y).toBeGreaterThanOrEqual(48);
    expect(ball.y).toBeLessThanOrEqual(60);
  });
});
