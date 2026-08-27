import type { Locale } from '../../core/types';

export interface PongStrings {
  stageLabel: string;
  restartRun: string;
  score: string;
  restart: string;
  controls: string;
  up: string;
  down: string;
  status: string;
}

const zhHans: PongStrings = {
  stageLabel: '关卡', restartRun: '从头开始',
  score: '比分', restart: '重新开始', controls: '方向键或按钮移动球拍', up: '上移', down: '下移', status: '先得 5 分获胜',
};
const en: PongStrings = {
  stageLabel: 'Stage', restartRun: 'Start over',
  score: 'Score', restart: 'Restart', controls: 'Move with arrow keys or buttons', up: 'Up', down: 'Down', status: 'First to 5 wins',
};
export const pongStrings = (locale: Locale): PongStrings => locale === 'en' ? en : zhHans;
