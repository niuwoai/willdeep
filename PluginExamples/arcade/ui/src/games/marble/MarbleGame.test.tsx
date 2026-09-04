import { act, render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it } from 'vitest';
import { App } from '../../App';
import { HashRouter } from '../../core/hashRouter';
import { I18nProvider } from '../../core/i18n';
import { HOLE_RING_MAX, holeRingRadius } from './index';
import { BALL_RADIUS, FIELD, pathLength, pointAt } from './engine';
import type { MarbleTrackId } from './engine';

/**
 * 印加弹珠集成回归（jsdom）。
 *
 * jsdom 没有 canvas 2D 上下文，draw() 会安全跳过；这里验证的是
 * 挂载、主循环推进（补给逐颗入场）、发射与换色、重开这些 React 侧行为。
 */
const SEED = 'jsdom-marble';

function renderAtMarble() {
  window.location.hash = `#/game/marble?seed=${SEED}`;
  return render(
    <HashRouter>
      <I18nProvider>
        <App />
      </I18nProvider>
    </HashRouter>,
  );
}

/** 推进若干帧 requestAnimationFrame（jsdom 里由定时器驱动）。 */
async function frames(count: number): Promise<void> {
  for (let i = 0; i < count; i += 1) {
    await act(async () => {
      await new Promise((resolve) => window.requestAnimationFrame(() => resolve(null)));
    });
  }
}

describe('印加弹珠集成', () => {
  beforeEach(() => {
    window.localStorage.clear();
    window.location.hash = '';
  });

  it('挂载后场地与 HUD 就位，链条逐颗入场', async () => {
    renderAtMarble();
    await screen.findByTestId('marble-field');
    expect(screen.getByTestId('marble-score-value')).toHaveTextContent('0');
    const before = Number(screen.getByTestId('marble-remaining').textContent?.replace(/\D/g, ''));

    await frames(6);
    // 补给总数不变（只是从待入场挪进链条），但状态机已经在跑
    const after = Number(screen.getByTestId('marble-remaining').textContent?.replace(/\D/g, ''));
    expect(after).toBe(before);
    expect(screen.getByTestId('marble-status')).toBeInTheDocument();
  });

  it('发射按钮把状态推进到进行中', async () => {
    const user = userEvent.setup();
    renderAtMarble();
    await screen.findByTestId('marble-field');

    await user.click(screen.getByTestId('marble-shoot'));
    await waitFor(() => expect(screen.getByTestId('marble-status')).toHaveTextContent('进行中'));
  });

  it('换色交换当前与下一发的配色', async () => {
    const user = userEvent.setup();
    renderAtMarble();
    await screen.findByTestId('marble-field');

    const chips = () =>
      Array.from(screen.getByTestId('marble-ammo').querySelectorAll('i')).map(
        (chip) => (chip as HTMLElement).style.background,
      );
    const before = chips();
    await user.click(screen.getByTestId('marble-swap'));
    await waitFor(() => expect(chips()).toEqual([before[1], before[0]]));
  });

  it('瞄准按钮与重开都不会打断主循环', async () => {
    const user = userEvent.setup();
    renderAtMarble();
    await screen.findByTestId('marble-field');

    await user.click(screen.getByTestId('marble-aim-left'));
    await user.click(screen.getByTestId('marble-aim-right'));
    await user.click(screen.getByTestId('marble-restart'));
    await frames(4);

    expect(screen.getByTestId('marble-score-value')).toHaveTextContent('0');
    expect(screen.getByTestId('marble-field')).toBeInTheDocument();
  });

  it('从第 1 关开局，关卡与累计分同时上报给外壳', async () => {
    renderAtMarble();
    await screen.findByTestId('marble-field');

    expect(screen.getByTestId('marble-stage')).toHaveTextContent('关卡 1');
    expect(screen.getByTestId('game-stage')).toHaveTextContent('关卡: 1');
    expect(screen.getByTestId('game-score')).toHaveTextContent('分数: 0');
    // 第 1 关 40 颗弹珠（开局链条 + 待入场补给）
    expect(screen.getByTestId('marble-remaining').textContent?.replace(/\D/g, '')).toBe('40');
  });

  it('从头开始会把关卡与累计分打回起点', async () => {
    const user = userEvent.setup();
    renderAtMarble();
    await screen.findByTestId('marble-field');
    await user.click(screen.getByTestId('marble-restart-run'));
    await waitFor(() => expect(screen.getByTestId('marble-stage')).toHaveTextContent('关卡 1'));
    expect(screen.getByTestId('marble-score-value')).toHaveTextContent('0');
  });
});

describe('印加弹珠：洞口金环', () => {
  // 洞口半径与 draw() 里传给 drawHoleRing 的一致
  const HOLE_RADIUS = BALL_RADIUS * 1.75;

  it('金环半径随时间一涨一缩，危险时张得更大、喘得更急', () => {
    const calm: number[] = [];
    const danger: number[] = [];
    for (let time = 0; time < 3; time += 0.05) {
      calm.push(holeRingRadius(HOLE_RADIUS, time, false));
      danger.push(holeRingRadius(HOLE_RADIUS, time, true));
    }
    const span = (values: readonly number[]): number => Math.max(...values) - Math.min(...values);
    // 平时也在呼吸
    expect(span(calm)).toBeGreaterThan(HOLE_RADIUS * 0.1);
    // 危险时幅度更大
    expect(span(danger)).toBeGreaterThan(span(calm));
    // 危险时节拍更急：同样 3 秒里过零（穿过均值）的次数更多
    const crossings = (values: readonly number[]): number => {
      const middle = (Math.max(...values) + Math.min(...values)) / 2;
      let count = 0;
      for (let i = 1; i < values.length; i += 1) {
        const before = (values[i - 1] as number) - middle;
        const after = (values[i] as number) - middle;
        if (before <= 0 && after > 0) count += 1;
      }
      return count;
    };
    expect(crossings(danger)).toBeGreaterThan(crossings(calm));
  });

  it('金环涨到最大也不会被场地边缘切掉', () => {
    const ids: readonly MarbleTrackId[] = ['spiral', 'valley', 'switchback'];
    for (const id of ids) {
      const hole = pointAt(pathLength(id), id);
      const outer = HOLE_RADIUS * HOLE_RING_MAX;
      expect(hole.x - outer).toBeGreaterThanOrEqual(0);
      expect(hole.y - outer).toBeGreaterThanOrEqual(0);
      expect(hole.x + outer).toBeLessThanOrEqual(FIELD);
      expect(hole.y + outer).toBeLessThanOrEqual(FIELD);
    }
  });
});
