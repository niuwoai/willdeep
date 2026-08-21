import type { Locale } from '../../core/types';

export interface PongStrings {
  score: string;
  restart: string;
  controls: string;
  up: string;
  down: string;
  status: string;
}

const zhHans: PongStrings = {
  score: '比分', restart: '重新开始', controls: '方向键或按钮移动球拍', up: '上移', down: '下移', status: '先得 5 分获胜',
};
const en: PongStrings = {
  score: 'Score', restart: 'Restart', controls: 'Move with arrow keys or buttons', up: 'Up', down: 'Down', status: 'First to 5 wins',
};
export const pongStrings = (locale: Locale): PongStrings => locale === 'en' ? en : zhHans;
