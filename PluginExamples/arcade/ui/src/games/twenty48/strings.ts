import type { Locale } from '../../core/types';

export interface Twenty48Strings {
  score: string;
  moves: string;
  target: string;
  total: string;
  statusIdle: string;
  statusPlaying: string;
  statusWon: string;
  statusLost: string;
  restart: string;
  restartRun: string;
  boardLabel: string;
  emptyCell: string;
  tileLabel: string;
  moveUp: string;
  moveDown: string;
  moveLeft: string;
  moveRight: string;
  hint: string;
}

const dict: Record<Locale, Twenty48Strings> = {
  'zh-Hans': {
    score: '本关得分',
    moves: '步数',
    target: '目标',
    total: '累计',
    statusIdle: '滑动任意方向开始',
    statusPlaying: '继续合并相同数字',
    statusWon: '达成目标！下一关目标翻倍……',
    statusLost: '没有可移动的位置了',
    restart: '重开本关',
    restartRun: '从头开始',
    boardLabel: '2048 数字棋盘',
    emptyCell: '空格',
    tileLabel: '数字 {value}',
    moveUp: '向上移动',
    moveDown: '向下移动',
    moveLeft: '向左移动',
    moveRight: '向右移动',
    hint: '使用方向键或 WASD；在棋盘上滑动也可以。相同数字每次移动只合并一次。',
  },
  en: {
    score: 'Stage score',
    moves: 'Moves',
    target: 'Target',
    total: 'Total',
    statusIdle: 'Swipe in any direction to begin',
    statusPlaying: 'Keep combining equal numbers',
    statusWon: 'Target reached! The next target doubles…',
    statusLost: 'No moves remain',
    restart: 'Restart stage',
    restartRun: 'Start over',
    boardLabel: '2048 number board',
    emptyCell: 'Empty cell',
    tileLabel: 'Number {value}',
    moveUp: 'Move up',
    moveDown: 'Move down',
    moveLeft: 'Move left',
    moveRight: 'Move right',
    hint: 'Use arrow keys or WASD, or swipe across the board. Equal tiles merge only once per move.',
  },
};

export function twenty48Strings(locale: Locale): Twenty48Strings {
  return dict[locale] ?? dict['zh-Hans'];
}
