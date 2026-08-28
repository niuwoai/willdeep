import type { Locale } from '../../core/types';

export interface BreakoutStrings {
  score: string;
  total: string;
  lives: string;
  bricks: string;
  statusIdle: string;
  statusPlaying: string;
  statusPaused: string;
  statusWon: string;
  statusLost: string;
  launch: string;
  pause: string;
  resume: string;
  restart: string;
  restartRun: string;
  moveLeft: string;
  moveRight: string;
  fieldLabel: string;
  stageLabel: string;
  hint: string;
}

const dict: Record<Locale, BreakoutStrings> = {
  'zh-Hans': {
    score: '本关得分',
    total: '累计',
    lives: '生命',
    bricks: '剩余砖块',
    statusIdle: '移动挡板，准备发球',
    statusPlaying: '击碎所有砖块',
    statusPaused: '已暂停',
    statusWon: '清场！下一关砖更多、球更快……',
    statusLost: '生命用完了',
    launch: '发球',
    pause: '暂停',
    resume: '继续',
    restart: '重开本关',
    restartRun: '从头开始',
    moveLeft: '挡板左移',
    moveRight: '挡板右移',
    fieldLabel: '打砖块游戏场地',
    stageLabel: '排砖',
    hint: '鼠标或触屏直接移动挡板；方向键或 A/D 也可以。空格发球或暂停，P 键暂停。',
  },
  en: {
    score: 'Stage score',
    total: 'Total',
    lives: 'Lives',
    bricks: 'Bricks left',
    statusIdle: 'Position the paddle and launch',
    statusPlaying: 'Break every brick',
    statusPaused: 'Paused',
    statusWon: 'Board cleared! More bricks and speed ahead…',
    statusLost: 'No lives remain',
    launch: 'Launch',
    pause: 'Pause',
    resume: 'Resume',
    restart: 'Restart stage',
    restartRun: 'Start over',
    moveLeft: 'Move paddle left',
    moveRight: 'Move paddle right',
    fieldLabel: 'Breakout playfield',
    stageLabel: 'brick rows',
    hint: 'Move the paddle directly with mouse or touch, or use arrows/A/D. Space launches or pauses; P pauses.',
  },
};

export function breakoutStrings(locale: Locale): BreakoutStrings {
  return dict[locale] ?? dict['zh-Hans'];
}
