/**
 * data-testid 契约（冻结）。
 *
 * 所有可交互元素与关键结构必须带有稳定的 data-testid，命名规则：
 *   <scope>-<name>
 * 其中 scope 为所属组件/路由（如 lobby、game-shell、lobby-card），
 * name 为该元素在组件内的语义（如 snake、back）。
 * 游戏模块新增可交互元素时沿用本规则，并优先复用 TEST_IDS 中的定义。
 */
export function makeTestId(scope: string, name?: string): string {
  return name === undefined ? scope : `${scope}-${name}`;
}

export const TEST_IDS = {
  lobby: 'lobby',
  lobbyTitle: 'lobby-title',
  lobbyCard: (id: string) => makeTestId('lobby-card', id),
  langSwitch: 'lang-switch',
  backToLobby: 'back-to-lobby',
  gameShell: (id: string) => makeTestId('game-shell', id),
  gameTitle: 'game-title',
  bestScore: 'game-best-score',
  controlsHelp: 'game-controls-help',
  seed: 'game-seed',
  soundToggle: 'game-sound',
  notFound: 'not-found',
  dummyCounter: 'dummy-counter',
  dummySubmit: 'dummy-submit',
} as const;
