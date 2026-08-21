/**
 * 统一游戏外壳（冻结）。
 *
 * 所有游戏渲染在 GameShell 内：顶部为返回大厅链接、标题、最佳成绩与
 * 种子展示，底部为操作说明。游戏模块只负责渲染 GameProps.seed 与玩法区。
 */
import type { ReactNode } from 'react';
import type { GameId } from '../core/types';
import { Link, useRoute } from '../core/hashRouter';
import { useI18n } from '../core/i18n';
import { useBestScore } from '../core/bestScore';
import { TEST_IDS } from '../core/testid';
import { getGameEntry } from '../games/manifest';

export interface GameShellProps {
  gameId: GameId;
  children: ReactNode;
}

export function GameShell({ gameId, children }: GameShellProps) {
  const { t } = useI18n();
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
          <span className="badge" data-testid={TEST_IDS.bestScore}>
            {t('game.bestScore')}: {best ? best.value : t('game.noScore')}
          </span>
          {route.seed !== undefined && (
            <span className="badge badge--seed" data-testid={TEST_IDS.seed}>
              {t('game.seedLabel')}: {route.seed}
            </span>
          )}
        </div>
      </header>

      <main className="shell__body">{children}</main>

      <footer className="shell__footer" data-testid={TEST_IDS.controlsHelp}>
        {t(entry.controlsKey)}
      </footer>
    </div>
  );
}
