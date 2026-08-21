/**
 * 统一游戏大厅（冻结）：从 GameManifest 渲染卡片，展示 i18n 标题与最佳成绩。
 */
import { Link } from '../core/hashRouter';
import { useI18n } from '../core/i18n';
import { useBestScore } from '../core/bestScore';
import { TEST_IDS } from '../core/testid';
import { GAME_MANIFEST } from '../games/manifest';

function GameCard({ gameId }: { gameId: (typeof GAME_MANIFEST)[number]['id'] }) {
  const { t } = useI18n();
  const entry = GAME_MANIFEST.find((g) => g.id === gameId);
  const best = useBestScore(gameId);
  if (!entry) return null;

  return (
    <Link
      className="card"
      to={`/game/${entry.id}`}
      data-testid={TEST_IDS.lobbyCard(entry.id)}
    >
      <h2 className="card__title">{t(entry.nameKey)}</h2>
      <p className="card__desc">{t(entry.descriptionKey)}</p>
      <span className="card__best">
        {t('lobby.bestLabel')}: {best ? best.value : '—'}
      </span>
    </Link>
  );
}

export function Lobby() {
  const { t, locale, setLocale } = useI18n();

  return (
    <div className="lobby" data-testid={TEST_IDS.lobby}>
      <header className="lobby__header">
        <h1 data-testid={TEST_IDS.lobbyTitle}>{t('app.title')}</h1>
        <p className="lobby__subtitle">{t('lobby.subtitle')}</p>
      </header>

      <div className="lobby__toolbar">
        <button
          type="button"
          className="btn btn--ghost"
          data-testid={TEST_IDS.langSwitch}
          onClick={() => setLocale(locale === 'zh-Hans' ? 'en' : 'zh-Hans')}
        >
          {t(locale === 'zh-Hans' ? 'locale.switchToEnglish' : 'locale.switchToChinese')}
        </button>
      </div>

      <div className="lobby__grid">
        {GAME_MANIFEST.map((game) => (
          <GameCard key={game.id} gameId={game.id} />
        ))}
      </div>
    </div>
  );
}
