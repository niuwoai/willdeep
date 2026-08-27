import type { Locale } from '../../core/types';

export interface PongStrings {
  stageLabel: string;
  totalLabel: string;
  restartRun: string;
  score: string;
  restart: string;
  controls: string;
  courtLabel: string;
  up: string;
  down: string;
  status: string;
  statusServing: string;
  statusWon: string;
  statusLost: string;
}

const zhHans: PongStrings = {
  stageLabel: '关卡', totalLabel: '累计', restartRun: '从头开始',
  score: '比分', restart: '重新开始', controls: '方向键、鼠标或按钮移动球拍；先得 5 分赢下这一关',
  courtLabel: '乒乓球桌', up: '上移', down: '下移', status: '先得 5 分获胜',
  statusServing: '准备发球……', statusWon: '拿下这一关！下一关准备中……', statusLost: '这局输了，按重新开始再来',
};
const en: PongStrings = {
  stageLabel: 'Stage', totalLabel: 'Total', restartRun: 'Start over',
  score: 'Score', restart: 'Restart', controls: 'Move with arrow keys, pointer or buttons; first to 5 takes the stage',
  courtLabel: 'Ping-pong table', up: 'Up', down: 'Down', status: 'First to 5 wins',
  statusServing: 'Serving…', statusWon: 'Stage won! Next one coming up…', statusLost: 'Lost this one — hit restart',
};
export const pongStrings = (locale: Locale): PongStrings => locale === 'en' ? en : zhHans;
