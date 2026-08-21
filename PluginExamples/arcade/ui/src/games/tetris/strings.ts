/**
 * 俄罗斯方块模块本地化文案（并行节点交付）。
 *
 * 平台 i18n 字典（src/core/i18n/*）属于冻结共享契约，游戏节点不得修改；
 * 本模块文案按同一语言契约（zh-Hans 默认 / en 同构）维护在模块内部，
 * 集成节点可在合入后统一迁移到核心字典。
 */
import type { Locale } from '../../core/types';

export interface TetrisStrings {
  title: string;
  score: string;
  lines: string;
  level: string;
  restart: string;
  gameOver: string;
  controls: string;
  boardLabel: string;
  btnLeft: string;
  btnRight: string;
  btnRotate: string;
  btnDown: string;
  btnDrop: string;
}

const dict: Record<Locale, TetrisStrings> = {
  'zh-Hans': {
    title: '俄罗斯方块',
    score: '得分',
    lines: '消行',
    level: '等级',
    restart: '重开',
    gameOver: '游戏结束',
    controls: '方向键 / WASD 移动，上键 / W 旋转，空格硬降，R 重开',
    boardLabel: '俄罗斯方块棋盘',
    btnLeft: '←',
    btnRight: '→',
    btnRotate: '↻',
    btnDown: '↓',
    btnDrop: '⤓',
  },
  en: {
    title: 'Tetris',
    score: 'Score',
    lines: 'Lines',
    level: 'Level',
    restart: 'Restart',
    gameOver: 'Game Over',
    controls: 'Arrows / WASD move, Up / W rotate, Space hard drop, R restart',
    boardLabel: 'Tetris board',
    btnLeft: '←',
    btnRight: '→',
    btnRotate: '↻',
    btnDown: '↓',
    btnDrop: '⤓',
  },
};

export function tetrisStrings(locale: Locale): TetrisStrings {
  return dict[locale] ?? dict['zh-Hans'];
}
