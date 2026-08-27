/**
 * 贪吃蛇模块本地化文案（并行节点交付）。
 *
 * 平台 i18n 字典（src/core/i18n/*）属于冻结共享契约，游戏节点不得修改；
 * 本模块文案按同一语言契约（zh-Hans 默认 / en 同构）维护在模块内部，
 * 集成节点可在合入后统一迁移到核心字典。
 */
import type { Locale } from '../../core/types';

export interface SnakeStrings {
  stageLabel: string;
  restartRun: string;
  score: string;
  restart: string;
  statusIdle: string;
  statusPlaying: string;
  statusGameover: string;
  statusWon: string;
  hint: string;
  milestone: string;
  boardLabel: string;
}

const dict: Record<Locale, SnakeStrings> = {
  'zh-Hans': {
    stageLabel: '关卡',
    restartRun: '从头开始',
    score: '得分',
    restart: '重开',
    statusIdle: '按方向键或滑动开始',
    statusPlaying: '游戏中',
    statusGameover: '游戏结束',
    statusWon: '恭喜通关！',
    hint: '方向键 / WASD / 滑动控制方向；吃满 5 个食物通关',
    milestone: '食物 {eaten}/{total}',
    boardLabel: '贪吃蛇棋盘',
  },
  en: {
    stageLabel: 'Stage',
    restartRun: 'Start over',
    score: 'Score',
    restart: 'Restart',
    statusIdle: 'Press a direction key or swipe to start',
    statusPlaying: 'Playing',
    statusGameover: 'Game Over',
    statusWon: 'You Win!',
    hint: 'Arrows / WASD / swipe to steer; eat 5 foods to win',
    milestone: 'Food {eaten}/{total}',
    boardLabel: 'Snake board',
  },
};

export function snakeStrings(locale: Locale): SnakeStrings {
  return dict[locale] ?? dict['zh-Hans'];
}
