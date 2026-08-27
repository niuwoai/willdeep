/**
 * 统一游戏外壳（冻结）。
 *
 * 所有游戏渲染在 GameShell 内：顶部为返回大厅链接、标题、最佳成绩与
 * 种子展示，底部为操作说明。游戏模块只负责渲染 GameProps.seed 与玩法区。
 */
import { useSyncExternalStore } from 'react';
import type { ReactNode } from 'react';
import type { GameId } from '../core/types';
import { Link, useRoute } from '../core/hashRouter';
import { useI18n } from '../core/i18n';
import { useBestScore } from '../core/bestScore';
import { TEST_IDS } from '../core/testid';
import { getGameEntry } from '../games/manifest';
import { isSoundEnabled, playCue, setSoundEnabled, subscribeSound } from '../core/audio';
import type { StageInfo } from '../core/stage';
import { Confetti } from './Confetti';

export interface GameShellProps {
  gameId: GameId;
  children: ReactNode;
  /** 撒花计数：游戏每通关一次由路由层 +1（见 App.tsx 的 GameRoute）。 */
  celebration?: number;
  /** 当前关卡与本轮累计分数，由游戏经 onStage 上报。 */
  stage?: StageInfo | null;
}

export function GameShell({ gameId, children, celebration = 0, stage = null }: GameShellProps) {
  const { t } = useI18n();
  const soundOn = useSyncExternalStore(subscribeSound, isSoundEnabled, () => true);
  const { route } = useRoute();
  const entry = getGameEntry(gameId);
  const best = useBestScore(gameId);

  if (!entry) {
    return (
      <div className="shell" data-testid={TEST_IDS.notFound}>
        <h1>{t('common.notFound')}</h1>
        <Link className="btn" to="/" data-testid={TEST_IDS.backToLobby}>
          {t('game.back')}
        </Link>
      </div>
    );
  }

  return (
    <div className="shell" data-testid={TEST_IDS.gameShell(gameId)}>
      <header className="shell__header">
        <Link className="btn btn--ghost" to="/" data-testid={TEST_IDS.backToLobby}>
          ← {t('game.back')}
        </Link>
        <h1 className="shell__title" data-testid={TEST_IDS.gameTitle}>
          {t(entry.nameKey)}
        </h1>
        <div className="shell__meta">
          {stage && (
            <span className="badge badge--stage" data-testid={TEST_IDS.stage}>
              {t('game.stage')}: {stage.stage}
              {stage.label ? ` · ${stage.label}` : ''}
            </span>
          )}
          {stage && (
            <span className="badge badge--score" data-testid={TEST_IDS.score}>
              {t('game.score')}: {stage.score}
            </span>
          )}
          <span className="badge" data-testid={TEST_IDS.bestScore}>
            {t('game.bestScore')}: {best ? best.value : t('game.noScore')}
          </span>
          {route.seed !== undefined && (
            <span className="badge badge--seed" data-testid={TEST_IDS.seed}>
              {t('game.seedLabel')}: {route.seed}
            </span>
          )}
          <button
            type="button"
            className="btn btn--ghost btn--sound"
            data-testid={TEST_IDS.soundToggle}
            aria-pressed={soundOn}
            aria-label={t(soundOn ? 'sound.on' : 'sound.off')}
            title={t(soundOn ? 'sound.on' : 'sound.off')}
            onClick={() => {
              const next = !soundOn;
              setSoundEnabled(next);
              // 开启的那一下先出个声，用户马上知道生效了（也顺便解锁 AudioContext）
              if (next) playCue('select');
            }}
          >
            {soundOn ? '🔊' : '🔇'}
          </button>
        </div>
      </header>

      <main className="shell__body">{children}</main>

      <footer className="shell__footer" data-testid={TEST_IDS.controlsHelp}>
        {t(entry.controlsKey)}
      </footer>

      <Confetti trigger={celebration} />
    </div>
  );
}
