/**
 * 印加弹珠模块本地化文案。
 *
 * 平台 i18n 字典（src/core/i18n/*）只放大厅/外壳文案，
 * 游戏内部文案按同一语言契约（zh-Hans 默认 / en 同构）维护在模块内。
 */
import type { Locale } from '../../core/types';

export interface MarbleStrings {
  stageLabel: string;
  colorsUnit: string;
  totalLabel: string;
  restartRun: string;
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
  statusFalling: string;
  statusWon: string;
  statusLost: string;
  fieldLabel: string;
  legendBomb: string;
  legendReverse: string;
  help: string;
}

const dict: Record<Locale, MarbleStrings> = {
  'zh-Hans': {
    stageLabel: '关卡',
    colorsUnit: '色',
    totalLabel: '累计',
    restartRun: '从头开始',
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
    statusFalling: '弹珠正在滚进骷髅口……',
    statusWon: '清空链条，下一关准备中……',
    statusLost: '弹珠滚进洞里了',
    fieldLabel: '印加弹珠场地',
    legendBomb: '炸弹：连它一起消掉，会炸飞周围一整片',
    legendReverse: '闪光：连它一起消掉，整条链往回倒退一段',
    help: '弹珠沿螺旋轨道往洞口滚，用中央发射器把同色弹珠打进链条：三颗同色即消除，缺口合拢还能触发连锁。链条上带 💣 的是炸弹珠，消掉时炸飞周围一片，还能引爆别的炸弹；带 ⚡ 的是闪光珠，消掉时把已经跑到前面的珠子整条拉回来。鼠标/触屏瞄准点击发射，键盘用 ← → 瞄准、空格发射、S 换色。',
  },
  en: {
    stageLabel: 'Stage',
    colorsUnit: 'colors',
    totalLabel: 'Total',
    restartRun: 'Start over',
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
    statusFalling: 'The marbles are pouring into the skull…',
    statusWon: 'Chain cleared! Next stage coming up…',
    statusLost: 'The marbles reached the hole',
    fieldLabel: 'Inca marbles field',
    legendBomb: 'Bomb: clearing it blows up everything nearby',
    legendReverse: 'Flash: clearing it rolls the whole chain backwards',
    help: 'Marbles roll along the spiral toward the hole. Shoot matching colors into the chain: three of a kind clears, and closing gaps can chain. Marbles marked 💣 blow up a patch around them (and set off other bombs); marbles marked ⚡ roll the chain back, dragging the leaders away from the hole. Aim with pointer or touch and click to shoot; on a keyboard use ← → to aim, space to shoot and S to swap.',
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
