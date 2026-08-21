/**
 * 应用根组件（冻结）：hash 路由分发。
 *  '/'          → 大厅
 *  '/game/:id'  → GameShell + 对应游戏模块（含 ?seed= 传递）
 *  其他         → 404
 */
import { useRoute } from './core/hashRouter';
import { getGameEntry } from './games/manifest';
import { GameShell } from './ui/GameShell';
import { Lobby } from './ui/Lobby';
import { useI18n } from './core/i18n';
import { TEST_IDS } from './core/testid';
import { Link } from './core/hashRouter';

function NotFound() {
  const { t } = useI18n();
  return (
    <div className="lobby" data-testid={TEST_IDS.notFound}>
      <h1>{t('common.notFound')}</h1>
      <Link className="btn" to="/">
        {t('game.back')}
      </Link>
    </div>
  );
}

export function App() {
  const { route } = useRoute();

  if (route.path === '/') return <Lobby />;

  const match = /^\/game\/([^/]+)$/.exec(route.path);
  if (match) {
    const entry = getGameEntry(match[1] as string);
    if (entry) {
      const GameComponent = entry.component;
      return (
        <GameShell gameId={entry.id}>
          <GameComponent seed={route.seed} />
        </GameShell>
      );
    }
  }

  return <NotFound />;
}
