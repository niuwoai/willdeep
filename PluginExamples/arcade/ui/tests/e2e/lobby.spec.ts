import { expect } from '@playwright/test';
import { test } from './fixtures';

const GAME_IDS = ['memory', 'onet', 'marble', 'minesweeper', 'pong', 'snake', 'tetris'] as const;

test('大厅展示全部游戏，可进入贪吃蛇并返回', async ({ page }) => {
  await page.goto('/');

  await expect(page.getByTestId('lobby')).toBeVisible();
  await expect(page.getByTestId('lobby-title')).toHaveText('经典网页小游戏');

  for (const id of GAME_IDS) {
    await expect(page.getByTestId(`lobby-card-${id}`)).toBeVisible();
  }

  await page.getByTestId('lobby-card-snake').click();
  await expect(page.getByTestId('game-shell-snake')).toBeVisible();
  await expect(page.getByTestId('snake-game')).toBeVisible();

  await page.getByTestId('back-to-lobby').click();
  await expect(page.getByTestId('lobby')).toBeVisible();
});

test('语言切换在真实浏览器生效', async ({ page }) => {
  await page.goto('/');
  await page.getByTestId('lang-switch').click();
  await expect(page.getByTestId('lobby-title')).toHaveText('Classic Arcade');
});
