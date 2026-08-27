/**
 * 印加弹珠模块本地化文案。
 *
 * 平台 i18n 字典（src/core/i18n/*）只放大厅/外壳文案，
 * 游戏内部文案按同一语言契约（zh-Hans 默认 / en 同构）维护在模块内。
 */
import type { Locale } from '../../core/types';

export interface MarbleStrings {
  levelLabel: string;
  levelEasy: string;
  levelMedium: string;
  levelHard: string;
  score: string;
  combo: string;
  remaining: string;
  restart: string;
  shoot: string;
  swap: string;
  aimLeft: string;
  aimRight: string;
  statusIdle: string;
  statusPlaying: string;
  statusWon: string;
  statusLost: string;
  fieldLabel: string;
  help: string;
}

const dict: Record<Locale, MarbleStrings> = {
  'zh-Hans': {
    levelLabel: '关卡',
    levelEasy: '简单 · 4 色',
    levelMedium: '中等 · 5 色',
    levelHard: '挑战 · 6 色',
    score: '得分',
    combo: '连锁',
    remaining: '剩余弹珠',
    restart: '重开',
    shoot: '发射',
    swap: '换色',
    aimLeft: '← 转',
    aimRight: '转 →',
    statusIdle: '移动鼠标瞄准，点击或空格发射',
    statusPlaying: '进行中',
    statusWon: '清空链条，通关！',
    statusLost: '弹珠滚进洞里了',
    fieldLabel: '印加弹珠场地',
    help: '弹珠沿螺旋轨道往洞口滚，用中央发射器把同色弹珠打进链条：三颗同色即消除，缺口合拢还能触发连锁。鼠标/触屏瞄准点击发射，键盘用 ← → 瞄准、空格发射、S 换色。',
  },
  en: {
    levelLabel: 'Level',
    levelEasy: 'Easy · 4 colors',
    levelMedium: 'Medium · 5 colors',
    levelHard: 'Hard · 6 colors',
    score: 'Score',
    combo: 'Chain',
    remaining: 'Marbles left',
    restart: 'Restart',
    shoot: 'Shoot',
    swap: 'Swap',
    aimLeft: '← Aim',
    aimRight: 'Aim →',
    statusIdle: 'Aim with the pointer, click or press space to shoot',
    statusPlaying: 'Playing',
    statusWon: 'Chain cleared!',
    statusLost: 'The marbles reached the hole',
    fieldLabel: 'Inca marbles field',
    help: 'Marbles roll along the spiral toward the hole. Shoot matching colors into the chain: three of a kind clears, and closing gaps can chain. Aim with pointer or touch and click to shoot; on a keyboard use ← → to aim, space to shoot and S to swap.',
  },
};

export function marbleStrings(locale: Locale): MarbleStrings {
  return dict[locale] ?? dict['zh-Hans'];
}

/** 弹珠配色：下标即 engine 里的 color id。 */
export const MARBLE_COLORS: readonly string[] = [
  '#ff5d73',
  '#4f8cff',
  '#3d9b6e',
  '#e6a23c',
  '#9b59d0',
  '#2fb8c9',
];
