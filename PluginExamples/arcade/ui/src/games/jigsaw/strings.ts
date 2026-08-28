import type { Locale } from '../../core/types';

export type JigsawImageId = 'lighthouse' | 'railway' | 'greenhouse';

export interface JigsawStrings {
  chooseTitle: string;
  chooseHint: string;
  imageNames: Record<JigsawImageId, string>;
  imageDescriptions: Record<JigsawImageId, string>;
  chooseImage: string;
  changeImage: string;
  preview: string;
  hidePreview: string;
  moves: string;
  restart: string;
  restartRun: string;
  stageLabel: string;
  totalLabel: string;
  statusIdle: string;
  statusPlaying: string;
  statusWon: string;
  boardLabel: string;
  pieceLabel: string;
  hint: string;
}

const dict: Record<Locale, JigsawStrings> = {
  'zh-Hans': {
    chooseTitle: '先选一张想拼的图片',
    chooseHint: '暂时提供三张内置原创插画；选定后从 3×3 开始，通关会自动增加块数。',
    imageNames: {
      lighthouse: '海岸灯塔',
      railway: '山谷列车',
      greenhouse: '月夜花房',
    },
    imageDescriptions: {
      lighthouse: '暖阳、海浪与红白灯塔',
      railway: '蒸汽列车驶过群山石桥',
      greenhouse: '月光下亮着灯的玻璃花房',
    },
    chooseImage: '选择这张',
    changeImage: '换一张图片',
    preview: '查看原图',
    hidePreview: '收起原图',
    moves: '交换次数',
    restart: '重新打乱',
    restartRun: '从头开始',
    stageLabel: '关卡',
    totalLabel: '累计',
    statusIdle: '点一块，再点目标位置进行交换',
    statusPlaying: '正在拼图',
    statusWon: '拼好了！下一关会切得更细……',
    boardLabel: '图片拼图棋盘',
    pieceLabel: '拼图块 {piece}，当前位置 {position}',
    hint: '拖动两块互换位置；触屏或键盘也可以依次点选两块。需要时可展开原图对照。',
  },
  en: {
    chooseTitle: 'Choose a picture first',
    chooseHint: 'Pick one of three built-in original illustrations. Start at 3×3; later stages add more pieces.',
    imageNames: {
      lighthouse: 'Coastal Lighthouse',
      railway: 'Mountain Railway',
      greenhouse: 'Moonlit Greenhouse',
    },
    imageDescriptions: {
      lighthouse: 'Warm sun, turquoise waves and a striped lighthouse',
      railway: 'A steam train crossing a mountain viaduct',
      greenhouse: 'A glowing glasshouse in a moonlit garden',
    },
    chooseImage: 'Choose this picture',
    changeImage: 'Choose another picture',
    preview: 'Show reference',
    hidePreview: 'Hide reference',
    moves: 'Swaps',
    restart: 'Reshuffle',
    restartRun: 'Start over',
    stageLabel: 'Stage',
    totalLabel: 'Total',
    statusIdle: 'Select a piece, then select its destination',
    statusPlaying: 'Solving',
    statusWon: 'Complete! The next stage has more pieces…',
    boardLabel: 'Picture jigsaw board',
    pieceLabel: 'Puzzle piece {piece}, current position {position}',
    hint: 'Drag one piece onto another to swap them. On touch or keyboard, select two pieces in sequence. Open the reference image whenever needed.',
  },
};

export function jigsawStrings(locale: Locale): JigsawStrings {
  return dict[locale] ?? dict['zh-Hans'];
}
