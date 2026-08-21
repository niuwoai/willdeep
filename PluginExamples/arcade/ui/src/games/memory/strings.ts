/**
 * 记忆翻牌模块本地化文案（并行节点交付）。
 *
 * 平台 i18n 字典（src/core/i18n/*）属于冻结共享契约，游戏节点不得修改；
 * 本模块文案按同一语言契约（zh-Hans 默认 / en 同构）维护在模块内部，
 * 集成节点可在合入后统一迁移到核心字典。
 */
import type { Locale } from '../../core/types';

export interface MemoryStrings {
  pairsLabel: string;
  pairsEasy: string;
  pairsMedium: string;
  pairsHard: string;
  moves: string;
  restart: string;
  statusIdle: string;
  statusPlaying: string;
  statusWon: string;
  hint: string;
  boardLabel: string;
}

const dict: Record<Locale, MemoryStrings> = {
  'zh-Hans': {
    pairsLabel: '牌对数',
    pairsEasy: '简单 · 2 对',
    pairsMedium: '中等 · 4 对',
    pairsHard: '挑战 · 6 对',
    moves: '步数',
    restart: '重开',
    statusIdle: '翻开两张相同的卡牌开始',
    statusPlaying: '进行中',
    statusWon: '恭喜通关！',
    hint: '点击/点按卡牌翻面；花色相同的两张成对消除，用最少步数清空棋盘',
    boardLabel: '记忆翻牌棋盘',
  },
  en: {
    pairsLabel: 'Pairs',
    pairsEasy: 'Easy · 2',
    pairsMedium: 'Medium · 4',
    pairsHard: 'Hard · 6',
    moves: 'Moves',
    restart: 'Restart',
    statusIdle: 'Flip two matching cards to start',
    statusPlaying: 'Playing',
    statusWon: 'You Win!',
    hint: 'Tap cards to flip; match pairs to clear the board in the fewest moves',
    boardLabel: 'Memory board',
  },
};

export function memoryStrings(locale: Locale): MemoryStrings {
  return dict[locale] ?? dict['zh-Hans'];
}
