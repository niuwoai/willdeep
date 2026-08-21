import type { Locale } from '../../core/types';

export interface MinesweeperStrings { mines: string; restart: string; newGame: string; safe: string; flags: string; won: string; lost: string; help: string; }
const zhHans: MinesweeperStrings = { mines: '地雷', restart: '重新开始', newGame: '新游戏', safe: '安全格', flags: '旗帜', won: '已清除雷区', lost: '踩到地雷', help: '点击翻开格子，右键或长按插旗。' };
const en: MinesweeperStrings = { mines: 'Mines', restart: 'Restart', newGame: 'New game', safe: 'Safe cells', flags: 'Flags', won: 'Minefield cleared', lost: 'Mine hit', help: 'Click to reveal; right-click or long-press to flag.' };
export const minesweeperStrings = (locale: Locale): MinesweeperStrings => locale === 'en' ? en : zhHans;
