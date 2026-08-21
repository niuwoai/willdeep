/**
 * 占位/演示游戏（dummy）：在真实游戏模块合入前让大厅与外壳可运行、可回归。
 *
 * 演示内容刻意覆盖三条冻结契约：
 *  1. 确定性种子：初始步数 = f(seed)，同一种子渲染结果一致
 *  2. 输入清理：键盘经 useKeyControls 注册（卸载自动移除）
 *  3. 最佳成绩：saveBestScore / useBestScore 联动 GameShell 徽章
 */
import { useState } from 'react';
import type { GameProps } from '../../core/types';
import { useKeyControls } from '../../core/input';
import { createRng } from '../../core/rng';
import { useI18n } from '../../core/i18n';
import { useRoute } from '../../core/hashRouter';
import { saveBestScore, useBestScore } from '../../core/bestScore';
import { TEST_IDS } from '../../core/testid';

export function DummyGame({ seed }: GameProps) {
  const { t } = useI18n();
  const { route } = useRoute();
  // 占位组件跟随路由推导宿主游戏 id，演示成绩写入契约（arcade.best.<id>）。
  const gameId = /^\/game\/([^/]+)$/.exec(route.path)?.[1] ?? 'dummy';
  const best = useBestScore(gameId);
  const [moves, setMoves] = useState<number>(() =>
    Math.floor(createRng(seed ?? 'dummy')() * 10),
  );

  useKeyControls(
    [
      {
        key: 'ArrowUp',
        onDown: () => setMoves((m) => m + 1),
        allowRepeat: true,
        preventDefault: true,
      },
      {
        key: 'ArrowDown',
        onDown: () => setMoves((m) => Math.max(0, m - 1)),
        allowRepeat: true,
        preventDefault: true,
      },
      { key: ' ', onDown: () => saveBestScore(gameId, moves) },
    ],
    [moves, gameId],
  );

  return (
    <div className="game" data-testid="dummy-game">
      <p className="game__hint">{t('dummy.hint')}</p>
      <div className="dummy">
        <p className="dummy__label">
          {t('dummy.moveLabel')}: <strong data-testid={TEST_IDS.dummyCounter}>{moves}</strong>
        </p>
        <p className="dummy__best">
          {t('game.bestScore')}: {best ? best.value : t('game.noScore')}
        </p>
        <button
          type="button"
          className="btn"
          data-testid={TEST_IDS.dummySubmit}
          onClick={() => saveBestScore(gameId, moves)}
        >
          {t('dummy.submit')}
        </button>
      </div>
    </div>
  );
}
