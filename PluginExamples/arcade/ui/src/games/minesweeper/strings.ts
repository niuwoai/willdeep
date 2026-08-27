import type { Locale } from '../../core/types';

export interface MinesweeperStrings { mines: string; restart: string; newGame: string; restartRun: string; stage: string; total: string; safe: string; flags: string; won: string; lost: string; help: string; }
const zhHans: MinesweeperStrings = { mines: '地雷', restart: '重新开始', newGame: '新一局', restartRun: '从头开始', stage: '关卡', total: '累计', safe: '安全格', flags: '旗帜', won: '已清除雷区，下一关准备中……', lost: '踩到地雷', help: '点击翻开格子，右键或长按插旗。' };
const en: MinesweeperStrings = { mines: 'Mines', restart: 'Restart', newGame: 'New round', restartRun: 'Start over', stage: 'Stage', total: 'Total', safe: 'Safe cells', flags: 'Flags', won: 'Minefield cleared — next stage coming up…', lost: 'Mine hit', help: 'Click to reveal; right-click or long-press to flag.' };
export const minesweeperStrings = (locale: Locale): MinesweeperStrings => locale === 'en' ? en : zhHans;
