import type { Drama, DramaPlan, ImageResult } from './types';

const emptyEpisode = (id: string, title: string, order: number) => ({
  id, title, order, summary: '', script: '', status: 'draft', shots: [],
});

const dramas: Drama[] = [
  {
    id: 'demo-wrong-time-message', title: '错时来信', genre: '都市悬疑', format: '竖屏短剧', status: 'production',
    episodeCount: 8, episodeDurationSeconds: 90, logline: '落魄程序员收到三天后的短信，每次改写命运都会失去一段重要记忆。',
    coreConflict: '拯救他人与保住自我之间的选择', audience: '18–35 岁', tone: '冷峻、克制', arc: '追查短信来源并承担改写未来的代价。',
    coverURL: '/demo/cuo-shi-lai-xin.webp', characters: [], episodes: [emptyEpisode('e-1', '凌晨三点的短信', 1)],
    createdAt: '2026-09-01T08:00:00Z', updatedAt: '2026-09-04T03:20:00Z',
  },
  {
    id: 'demo-moon-harbor', title: '月港追光', genre: '都市情感', format: '竖屏短剧', status: 'planning',
    episodeCount: 12, episodeDurationSeconds: 75, logline: '两个关系疏远的年轻影像作者，在港城寻找一卷记录真相的失落胶片。',
    coreConflict: '共同目标与旧日误解', audience: '年轻女性', tone: '温柔、写实', arc: '在寻找胶片的路上重新理解彼此。',
    coverURL: '/demo/yue-gang-zhui-guang.webp', characters: [], episodes: [emptyEpisode('e-2', '最后一班渡轮', 1)],
    createdAt: '2026-09-02T08:00:00Z', updatedAt: '2026-09-03T12:00:00Z',
  },
  {
    id: 'demo-memory-tape', title: '记忆磁带', genre: '近未来亲情', format: '竖屏短剧', status: 'completed',
    episodeCount: 10, episodeDurationSeconds: 80, logline: '女孩从外婆留下的磁带机里，听见了被家人共同遗忘的往事。',
    coreConflict: '留下记忆还是放下过去', audience: '全年龄', tone: '温暖、微悬疑', arc: '拼起家庭记忆，并做出属于自己的告别。',
    coverURL: '/demo/ji-yi-ci-dai.webp', characters: [], episodes: [emptyEpisode('e-3', '没有标签的磁带', 1)],
    createdAt: '2026-08-20T08:00:00Z', updatedAt: '2026-09-01T16:00:00Z',
  },
];

const demoPlan: DramaPlan = {
  title: '错时来信', genre: '都市悬疑', format: '竖屏短剧', episodeCount: 8, episodeDurationSeconds: 90,
  logline: '落魄程序员收到三天后的短信，每次改写命运都会失去一段重要记忆。',
  coreConflict: '拯救他人与保住自我之间的选择', audience: '18–35 岁', tone: '冷峻、克制',
  arc: '追查短信来源并承担改写未来的代价。',
};

export function installDevelopmentBridge() {
  if (!import.meta.env.DEV || window.willdeep) return;
  window.willdeep = {
    getContext: () => ({ locale: 'zh-Hans', colorScheme: 'light' }),
    executeCommand: async (command) => {
      if (command === 'drama.list') return JSON.stringify({ ok: true, dramas });
      return JSON.stringify({ ok: true });
    },
    ai: {
      providers: async () => ({ providers: [{ providerID: 'some-im', displayName: 'some.im', isActive: true, isLocal: false, models: ['gpt-5.4-mini'], flashModel: 'gpt-5.4-mini' }] }),
      complete: async () => ({ text: `\`\`\`short_drama_plan\n${JSON.stringify(demoPlan)}\n\`\`\``, model: 'gpt-5.4-mini', providerID: 'some-im' }),
      generateImage: async (): Promise<ImageResult> => { throw new Error('imageBridgeMissing'); },
    },
  };
}
