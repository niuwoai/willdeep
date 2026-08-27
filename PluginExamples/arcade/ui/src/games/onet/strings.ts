/**
 * 连连看模块本地化文案。
 *
 * 平台 i18n 字典（src/core/i18n/*）只放大厅/外壳文案，
 * 游戏内部文案按同一语言契约（zh-Hans 默认 / en 同构）维护在模块内。
 */
import type { Locale } from '../../core/types';

export interface OnetStrings {
  stageLabel: string;
  totalLabel: string;
  restartRun: string;
  remaining: string;
  moves: string;
  restart: string;
  hint: string;
  shuffle: string;
  statusIdle: string;
  statusPlaying: string;
  statusWon: string;
  statusShuffled: string;
  boardLabel: string;
  tileLabel: string;
  help: string;
}

const dict: Record<Locale, OnetStrings> = {
  'zh-Hans': {
    stageLabel: '关卡',
    totalLabel: '累计',
    restartRun: '从头开始',
    remaining: '剩余',
    moves: '尝试',
    restart: '重开',
    hint: '提示',
    shuffle: '洗牌',
    statusIdle: '点两张相同的图案，连线不超过两个折角就能消',
    statusPlaying: '进行中',
    statusWon: '全部消完，下一关准备中……',
    statusShuffled: '没有可消的了，已自动洗牌',
    boardLabel: '连连看棋盘',
    tileLabel: '第 {index} 张牌',
    help: '点选两张相同图案的牌：连线只走空格、拐弯不超过两次即可消除；棋盘外围一圈可以绕行。死局会自动洗牌，提示与洗牌都会扣分。',
  },
  en: {
    stageLabel: 'Stage',
    totalLabel: 'Total',
    restartRun: 'Start over',
    remaining: 'Left',
    moves: 'Tries',
    restart: 'Restart',
    hint: 'Hint',
    shuffle: 'Shuffle',
    statusIdle: 'Match two identical tiles linked by at most two turns',
    statusPlaying: 'Playing',
    statusWon: 'Cleared! Next stage coming up…',
    statusShuffled: 'No moves left — board reshuffled',
    boardLabel: 'Onet board',
    tileLabel: 'Tile {index}',
    help: 'Pick two identical tiles: the link may only cross empty cells with at most two turns, and it may route around the outside of the board. Deadlocks reshuffle automatically; hints and shuffles cost points.',
  },
};

export function onetStrings(locale: Locale): OnetStrings {
  return dict[locale] ?? dict['zh-Hans'];
}

/** 图案表：下标即 logic.ts 里的 symbol id。 */
export const ONET_FACES: readonly string[] = [
  '🌞',
  '🌙',
  '⭐',
  '🍀',
  '🔥',
  '💧',
  '🍎',
  '🍋',
  '🐟',
  '🦋',
  '🌵',
  '🎈',
];
