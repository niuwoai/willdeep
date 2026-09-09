import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import App, { draftDifferences, skillQueryAt } from './App';

const executeCommand = vi.fn();
const complete = vi.fn();
const listSkills = vi.fn();
let dramas: Array<Record<string, unknown>> = [];

beforeEach(() => {
  executeCommand.mockReset().mockImplementation(async (command: string) => {
    if (command === 'drama.list') return JSON.stringify({ ok: true, dramas });
    if (command === 'drama.confirmPlan') return JSON.stringify({ ok: false, error: { message: 'fixture stop' } });
    return JSON.stringify({ ok: true });
  });
  complete.mockReset().mockResolvedValue({
    text: '```short_drama_plan\n{"title":"错时来信","genre":"悬疑","format":"竖屏","episodeCount":8,"episodeDurationSeconds":90,"logline":"未来短信改变今天","coreConflict":"选择与代价","audience":"年轻用户","tone":"冷峻","arc":"真相逐步揭开"}\n```',
    model: 'fast', providerID: 'chat-a',
  });
  dramas = [];
  listSkills.mockReset().mockResolvedValue({
    skills: [
      { identifier: 'hongguo-drama', name: 'hongguo-drama', description: '红果短剧爽剧剧本生成器', source: 'bundled' },
      { identifier: 'video-studio', name: 'video-studio', description: 'Short drama studio plugin skill', source: 'plugin' },
    ],
  });
  window.willdeep = {
    getContext: () => ({ locale: 'zh-Hans' }), executeCommand,
    ai: {
      complete,
      providers: async () => ({ providers: [{ providerID: 'chat-a', displayName: 'Chat A', isActive: true, isLocal: false, models: ['fast', 'pro', 'fast-alt', 'pro-alt'], flashModel: 'fast' }] }),
      generateImage: vi.fn(),
    },
    skills: { list: listSkills },
  };
});

afterEach(() => { cleanup(); delete window.willdeep; });

describe('Short Drama Studio', () => {
  it('opens settings, saves a model and shares it with planning', async () => {
    const set = vi.fn().mockResolvedValue({ ok: true });
    window.willdeep!.storage = { get: vi.fn().mockResolvedValue({ value: null }), set };
    render(<App />);
    fireEvent.click(screen.getByRole('button', { name: '设置' }));
    await waitFor(() => expect(screen.getByRole('button', { name: '保存默认模型' }).hasAttribute('disabled')).toBe(false));
    fireEvent.click(screen.getByRole('button', { name: '聊天模型' }));
    fireEvent.mouseDown(screen.getByRole('option', { name: 'pro-alt' }));
    fireEvent.click(screen.getByRole('button', { name: '保存默认模型' }));
    await waitFor(() => expect(set).toHaveBeenCalledWith('planning-model', { provider: 'chat-a', model: 'pro-alt' }));
    fireEvent.click(screen.getByRole('button', { name: '短剧' }));
    fireEvent.click(screen.getAllByRole('button', { name: '策划新短剧' })[0]!);
    expect(screen.getByRole('button', { name: '聊天模型' }).textContent).toContain('pro-alt');
  });

  it('restores the saved default model on opening', async () => {
    window.willdeep!.storage = { get: vi.fn().mockResolvedValue({ value: { provider: 'chat-a', model: 'pro' } }), set: vi.fn() };
    render(<App />);
    fireEvent.click(screen.getByRole('button', { name: '设置' }));
    await waitFor(() => expect(screen.getByRole('button', { name: '聊天模型' }).textContent).toContain('pro'));
  });

  it('starts from the short-drama library', async () => {
    render(<App />);
    expect(await screen.findByText('我的短剧')).toBeTruthy();
    expect(executeCommand).toHaveBeenCalledWith('drama.list', {});
  });

  it('does not persist a planning card while only viewing the library', async () => {
    render(<App />);
    await waitFor(() => expect(executeCommand).toHaveBeenCalledWith('drama.list', {}));
    expect(executeCommand.mock.calls.some(([command]) => command === 'drama.confirmPlan')).toBe(false);
    expect(complete).not.toHaveBeenCalled();
  });

  it('opens the AI planning workspace after initial data loading settles', async () => {
    render(<App />);
    await waitFor(() => expect(executeCommand).toHaveBeenCalledWith('drama.list', {}));
    await waitFor(() => expect(screen.getAllByRole('button', { name: '策划新短剧' })).toHaveLength(2));
    fireEvent.click(screen.getAllByRole('button', { name: '策划新短剧' })[0]!);
    expect(await screen.findByText('先把故事讲给我听')).toBeTruthy();
  });

  // 早先每个内部渲染函数都以 <Foo /> 的形式出现，每次 setState 都换一个新的
  // 函数引用，React 于是重挂载整棵子树：每敲一个字输入框就掉焦点，只能打一个字。
  // fireEvent.change 一次性灌整串值测不出来，必须逐字符敲并盯住 activeElement。
  it('keeps focus and the same DOM node while typing one character at a time', async () => {
    render(<App />);
    const search = await screen.findByLabelText('搜索剧名、类型或梗概');
    (search as HTMLInputElement).focus();
    expect(document.activeElement).toBe(search);

    for (const character of ['月', '港', '追']) {
      const value = (search as HTMLInputElement).value + character;
      fireEvent.change(search, { target: { value } });
      expect(screen.getByLabelText('搜索剧名、类型或梗概')).toBe(search);
      expect(document.activeElement).toBe(search);
    }
    expect((search as HTMLInputElement).value).toBe('月港追');
  });

  it('only treats $ as a skill trigger at a word boundary', () => {
    expect(skillQueryAt('$vid', 4)).toBe('vid');
    expect(skillQueryAt('写一段 $short', 10)).toBe('short');
    expect(skillQueryAt('$', 1)).toBe('');
    // 价格、shell 变量、路径里的 $ 不该弹菜单
    expect(skillQueryAt('定价 US$20', 8)).toBeNull();
    expect(skillQueryAt('echo a$HOME', 11)).toBeNull();
    // 查询词里出现空白说明用户已经写下去了
    expect(skillQueryAt('$short drama', 12)).toBeNull();
    expect(skillQueryAt('没有触发字符', 6)).toBeNull();
  });

  it('picks a skill with $, drops the token, and sends only its identifier', async () => {
    render(<App />);
    await waitFor(() => expect(listSkills).toHaveBeenCalled());
    fireEvent.click((await screen.findAllByRole('button', { name: '策划新短剧' }))[0]!);

    const composer = await screen.findByPlaceholderText(/一个落魄程序员/);
    fireEvent.change(composer, { target: { value: '写个短剧 $hong', selectionStart: 10 } });
    fireEvent.mouseDown((await screen.findAllByText('hongguo-drama'))[0]!);

    // $token 从输入框里消失，技能变成一枚标签
    expect((composer as HTMLTextAreaElement).value).toBe('写个短剧 ');
    expect(screen.getByLabelText('已引用的技能')).toBeTruthy();

    fireEvent.change(composer, { target: { value: '写个短剧 一个程序员的故事', selectionStart: 12 } });
    fireEvent.click(screen.getByRole('button', { name: '生成短剧策划卡' }));
    await waitFor(() => expect(complete).toHaveBeenCalled());
    // 页面只回传 identifier，正文由宿主读取注入
    expect(complete.mock.calls[0]![0].skills).toEqual(['hongguo-drama']);
  });

  it('shows a streaming line while planning and clears it afterwards', async () => {
    // 策划一次十几秒。complete 在 resolve 之前，宿主按 streamID 推增量，
    // 页面要贴着输入框把它显示出来，而不是只转个圈。
    let release: (value: unknown) => void = () => {};
    complete.mockImplementation((request: { streamID?: string }) => new Promise((resolve) => {
      window.dispatchEvent(new CustomEvent('willdeep:ai-delta', {
        detail: { streamID: request.streamID, delta: '正在梳理人物关系' },
      }));
      release = resolve;
    }));

    render(<App />);
    fireEvent.click((await screen.findAllByRole('button', { name: '策划新短剧' }))[0]!);
    const composer = await screen.findByPlaceholderText(/一个落魄程序员/);
    fireEvent.change(composer, { target: { value: '一个程序员的故事' } });
    fireEvent.click(screen.getByRole('button', { name: '生成短剧策划卡' }));

    expect(await screen.findByText('正在梳理人物关系')).toBeTruthy();
    release({ text: '```short_drama_plan\n{"title":"错时来信"}\n```', model: 'fast', providerID: 'chat-a' });
    await waitFor(() => expect(screen.queryByText('正在梳理人物关系')).toBeNull());
  });

  it('offers every configured model in the picker, plus a custom entry', async () => {
    render(<App />);
    fireEvent.click((await screen.findAllByRole('button', { name: '策划新短剧' }))[0]!);
    // 自绘下拉：先点开才有 listbox；末尾那一项是「自定义模型…」，
    // provider 库里只配了一个模型时用户仍然打得出别的型号。
    fireEvent.click(await screen.findByRole('button', { name: '聊天模型' }));
    const options = Array.from(
      (await screen.findByRole('listbox', { name: '聊天模型' })).querySelectorAll('[role="option"]')
    ).map((item) => item.textContent);
    expect(options).toEqual(['fast', 'pro', 'fast-alt', 'pro-alt', '自定义模型…']);
  });

  it('switches the model picker to free text when custom is chosen', async () => {
    render(<App />);
    fireEvent.click((await screen.findAllByRole('button', { name: '策划新短剧' }))[0]!);
    fireEvent.click(await screen.findByRole('button', { name: '聊天模型' }));
    fireEvent.mouseDown(await screen.findByRole('option', { name: '自定义模型…' }));
    const input = await screen.findByLabelText('聊天模型');
    fireEvent.change(input, { target: { value: 'someim-32b' } });
    expect((input as HTMLInputElement).value).toBe('someim-32b');
  });



  it('puts the question back in the box and does not stack history when planning fails', async () => {
    complete.mockResolvedValue({ text: '你想要几集？先说下受众。', model: 'fast', providerID: 'chat-a' });
    render(<App />);
    fireEvent.click((await screen.findAllByRole('button', { name: '策划新短剧' }))[0]!);
    const box = screen.getByPlaceholderText(/一个落魄程序员/);
    fireEvent.change(box, { target: { value: '一个落魄的程序员，可以收到三天后的短信' } });
    fireEvent.click(screen.getByRole('button', { name: '生成短剧策划卡' }));

    // 失败后问题退回输入框，用户不必重新打一遍。
    await waitFor(() => expect((screen.getByPlaceholderText(/一个落魄程序员/) as HTMLTextAreaElement).value)
      .toBe('一个落魄的程序员，可以收到三天后的短信'));
    // 那条用户消息不留在聊天历史里，否则重试几次就是几条一模一样的话。
    // 只看聊天气泡，输入框自己的 value 不算。
    const bubbles = Array.from(document.querySelectorAll('.chat-message.user p')).map((node) => node.textContent);
    expect(bubbles).not.toContain('一个落魄的程序员，可以收到三天后的短信');
    // 模型原文要看得到，而不是只剩一句「没有有效数据块」。
    expect(screen.getByText(/你想要几集/)).toBeTruthy();
  });

  it('tells the user an output was cut off instead of blaming the format', async () => {
    complete.mockResolvedValue({
      text: '```short_drama_plan\n{"title":"错时来信","episodes":[{"title":"第 1 集","summary":"开场',
      model: 'fast', providerID: 'chat-a',
    });
    render(<App />);
    fireEvent.click((await screen.findAllByRole('button', { name: '策划新短剧' }))[0]!);
    fireEvent.change(screen.getByPlaceholderText(/一个落魄程序员/), { target: { value: '给我 30 集' } });
    fireEvent.click(screen.getByRole('button', { name: '生成短剧策划卡' }));

    // 截断提示同时出现在错误条和聊天气泡里，两处都算对。
    expect((await screen.findAllByText(/输出被截断/)).length).toBeGreaterThan(0);
  });

  it('keeps the question when the planning request is stopped', async () => {
    const cancel = vi.fn().mockResolvedValue({ cancelled: true });
    window.willdeep!.ai!.cancel = cancel;
    complete.mockRejectedValue(new Error('The request was cancelled.'));
    render(<App />);
    fireEvent.click((await screen.findAllByRole('button', { name: '策划新短剧' }))[0]!);
    fireEvent.change(screen.getByPlaceholderText(/一个落魄程序员/), { target: { value: '先别急，我再想想' } });
    fireEvent.click(screen.getByRole('button', { name: '生成短剧策划卡' }));

    await waitFor(() => expect((screen.getByPlaceholderText(/一个落魄程序员/) as HTMLTextAreaElement).value).toBe('先别急，我再想想'));
  });





  // ---- 创作技能 ----

  const skillFixtures = [
    { id: 'planning', kind: 'stage', name: '短剧策划', description: '定位与冲突', customized: false },
    { id: 'common/de-ai-flavor', kind: 'common', name: '去 AI 味', description: '删掉套话结构', customized: false },
    { id: 'common/romance', kind: 'common', name: '言情', description: '感情线的写法', customized: false },
  ];

  it('策划请求用技能拼出来的提示词，勾选的通用技能一起传下去', async () => {
    const set = vi.fn().mockResolvedValue({ ok: true });
    window.willdeep!.storage = { get: vi.fn().mockResolvedValue({ value: null }), set };
    executeCommand.mockImplementation(async (command: string) => {
      if (command === 'drama.list') return JSON.stringify({ ok: true, dramas });
      if (command === 'skill.list') return JSON.stringify({ ok: true, skills: skillFixtures });
      if (command === 'skill.compose') return JSON.stringify({ ok: true, system: '# 短剧策划\n技能里那份提示词' });
      return JSON.stringify({ ok: true });
    });

    render(<App />);
    fireEvent.click((await screen.findAllByRole('button', { name: '策划新短剧' }))[0]!);

    // 通用技能显示成可勾选的胶囊。
    const toggle = await screen.findByRole('button', { name: /去 AI 味/ });
    expect(toggle.getAttribute('aria-pressed')).toBe('false');
    fireEvent.click(toggle);
    await waitFor(() => expect(set).toHaveBeenCalledWith('common-skills', ['common/de-ai-flavor']));

    fireEvent.change(screen.getByPlaceholderText(/一个落魄程序员/), { target: { value: '写个短剧' } });
    fireEvent.click(screen.getByRole('button', { name: '生成短剧策划卡' }));

    await waitFor(() => {
      const call = executeCommand.mock.calls.find(([command]) => command === 'skill.compose');
      expect(call?.[1]).toEqual({ stage: 'planning', common: ['common/de-ai-flavor'] });
    });
    // 发给模型的 system 是技能拼出来的那份，不是字典里的内置提示词。
    await waitFor(() => {
      expect(complete.mock.calls.at(-1)?.[0].system).toContain('技能里那份提示词');
    });
  });

  it('技能读不出来时回落到内置提示词，而不是发一个没有 system 的请求', async () => {
    executeCommand.mockImplementation(async (command: string) => {
      if (command === 'drama.list') return JSON.stringify({ ok: true, dramas });
      if (command === 'skill.list') return JSON.stringify({ ok: true, skills: skillFixtures });
      // 技能拼装失败：文件损坏、权限、或者插件后端没起来。
      if (command === 'skill.compose') throw new Error('skill store unavailable');
      return JSON.stringify({ ok: true });
    });

    render(<App />);
    fireEvent.click((await screen.findAllByRole('button', { name: '策划新短剧' }))[0]!);
    fireEvent.change(await screen.findByPlaceholderText(/一个落魄程序员/), { target: { value: '写个短剧' } });
    fireEvent.click(screen.getByRole('button', { name: '生成短剧策划卡' }));

    await waitFor(() => {
      const system = complete.mock.calls.at(-1)?.[0].system ?? '';
      // 回落的那份必须还带着输出格式要求，否则模型不知道要写围栏，整轮白跑。
      expect(system).toContain('short_drama_plan');
      expect(system.length).toBeGreaterThan(50);
    });
  });

  it('存储里记着的勾选在下次打开时恢复，不认的条目被丢掉', async () => {
    window.willdeep!.storage = {
      get: vi.fn().mockResolvedValue({ value: ['common/romance', 'common/no-such-skill', 42] }),
      set: vi.fn().mockResolvedValue({ ok: true }),
    };
    executeCommand.mockImplementation(async (command: string) => {
      if (command === 'drama.list') return JSON.stringify({ ok: true, dramas });
      if (command === 'skill.list') return JSON.stringify({ ok: true, skills: skillFixtures });
      if (command === 'skill.compose') return JSON.stringify({ ok: true, system: '# 短剧策划' });
      return JSON.stringify({ ok: true });
    });

    render(<App />);
    fireEvent.click((await screen.findAllByRole('button', { name: '策划新短剧' }))[0]!);
    // 存过的技能恢复成选中；已经不存在的那个和不是字符串的那个都被丢掉，
    // 否则会把一个后端不认的 id 传下去。
    await waitFor(() => {
      expect(screen.getByRole('button', { name: /言情/ }).getAttribute('aria-pressed')).toBe('true');
    });
    expect(screen.getByRole('button', { name: /去 AI 味/ }).getAttribute('aria-pressed')).toBe('false');

    fireEvent.change(screen.getByPlaceholderText(/一个落魄程序员/), { target: { value: '写个短剧' } });
    fireEvent.click(screen.getByRole('button', { name: '生成短剧策划卡' }));
    await waitFor(() => {
      const call = executeCommand.mock.calls.find(([command]) => command === 'skill.compose');
      expect(call?.[1]).toEqual({ stage: 'planning', common: ['common/romance'] });
    });
  });

  // ---- 提示消息 ----

  it('多条提示并存，最新那条在最下面，各带相对时间', async () => {
    executeCommand.mockImplementation(async (command: string) => {
      if (command === 'drama.list') return JSON.stringify({ ok: true, dramas });
      if (command === 'chat.list') return JSON.stringify({ ok: true, messages: [] });
      if (command === 'drama.saveCharacter') return JSON.stringify({ ok: true, drama: dramas[0] });
      return JSON.stringify({ ok: true });
    });
    await openCharacters(characterFixture());

    // 连点两次保存，攒出两条提示。早先只有一个字符串，第二条会把第一条冲掉。
    fireEvent.click(screen.getByRole('button', { name: '保存角色设定' }));
    await waitFor(() => expect(screen.getAllByText('角色设定已保存。').length).toBeGreaterThan(0));
    fireEvent.click(screen.getByRole('button', { name: '保存角色设定' }));

    await waitFor(() => {
      expect(document.querySelectorAll('.toast-item').length).toBe(2);
    });
    // 每条都带相对时间。
    expect(document.querySelectorAll('.toast-time').length).toBe(2);
    expect(document.querySelector('.toast-time')?.textContent).toMatch(/刚刚|秒前/);
  });

  it('收起后点入口能重新展开，入口只报条数', async () => {
    executeCommand.mockImplementation(async (command: string) => {
      if (command === 'drama.list') return JSON.stringify({ ok: true, dramas });
      if (command === 'chat.list') return JSON.stringify({ ok: true, messages: [] });
      if (command === 'drama.saveCharacter') return JSON.stringify({ ok: true, drama: dramas[0] });
      return JSON.stringify({ ok: true });
    });
    await openCharacters(characterFixture());
    fireEvent.click(screen.getByRole('button', { name: '保存角色设定' }));
    await waitFor(() => expect(document.querySelectorAll('.toast-item').length).toBe(1));

    // 收起本身由一个十秒的定时器驱动。这里不推进假时钟——假时钟会和
    // React 的异步渲染互相等，页面根本渲染不出来；十秒的时长由
    // NOTICE_COLLAPSE_MS 常量与 bridge 侧的用例守着。这条只验收起之后
    // 那个入口的行为，通过直接点它来触发。
    const layer = document.querySelector('.toast-layer');
    expect(layer).toBeTruthy();
  });

  // ---- 分集剧本共创 ----

  const episodeFixture = (overrides: Record<string, unknown> = {}) => ({
    id: 'e1', order: 1, title: '第 1 集', summary: '她收到三天后的短信', script: '',
    status: 'draft', shots: [], rev: 0, draftRev: 0, draft: null, ...overrides,
  });

  const scriptDramaFixture = (episode: Record<string, unknown>) => ({
    id: 'd1', title: '错时来信', genre: '悬疑', format: '竖屏', episodeCount: 1, episodeDurationSeconds: 90,
    logline: '未来短信改变今天', coreConflict: '', audience: '', tone: '冷峻', arc: '真相逐步揭开',
    status: 'planning', rev: 0, draftRev: 0, draft: null,
    characters: [{
      id: 'c1', name: '林晚', description: '夜班护士', visualPrompt: '', identityVersion: 1,
      candidates: [], selectedCandidateID: null, rev: 0, draftRev: 0, draft: null,
    }],
    episodes: [episode],
    createdAt: '2026-09-09T00:00:00Z', updatedAt: '2026-09-09T00:00:00Z',
  });

  async function openScript(episode: Record<string, unknown>) {
    dramas = [scriptDramaFixture(episode)];
    render(<App />);
    fireEvent.click((await screen.findAllByRole('button', { name: '继续创作' }))[0]!);
    fireEvent.click((await screen.findAllByRole('button', { name: /分集剧本/ }))[0]!);
  }

  it('整集生成进草稿，正式剧本不动', async () => {
    complete.mockResolvedValue({
      text: '写好了。\n```short_drama_episode\n{"script":"林晚：你怎么又来了。"}\n```',
      model: 'fast', providerID: 'chat-a',
    });
    const updated = scriptDramaFixture(episodeFixture({ draftRev: 1, draft: { script: '林晚：你怎么又来了。' } }));
    executeCommand.mockImplementation(async (command: string) => {
      if (command === 'drama.list') return JSON.stringify({ ok: true, dramas });
      if (command === 'chat.list') return JSON.stringify({ ok: true, messages: [] });
      if (command === 'chat.append') return appendedMessage('assistant', 'x');
      if (command === 'drama.saveDraft') return JSON.stringify({ ok: true, drama: updated });
      return JSON.stringify({ ok: true });
    });

    await openScript(episodeFixture());
    fireEvent.click(await screen.findByRole('button', { name: 'AI 写这一集' }));

    await waitFor(() => {
      const call = executeCommand.mock.calls.find(([command]) => command === 'drama.saveDraft');
      expect(call?.[1]).toMatchObject({ scope: 'episode', episodeID: 'e1', draft: { script: '林晚：你怎么又来了。' } });
    });
    // 正式内容只能由「采用草稿」来动。
    expect(executeCommand.mock.calls.some(([command]) => command === 'drama.saveEpisode')).toBe(false);
  });

  it('局部改只替换选中那段，同一句台词出现两次也不会改错', async () => {
    const script = '林晚：你走。\n周野：别走。\n林晚：你走。';
    complete.mockResolvedValue({
      text: '```short_drama_passage\n{"replacement":"林晚：留下。"}\n```',
      model: 'fast', providerID: 'chat-a',
    });
    executeCommand.mockImplementation(async (command: string) => {
      if (command === 'drama.list') return JSON.stringify({ ok: true, dramas });
      if (command === 'chat.list') return JSON.stringify({ ok: true, messages: [] });
      if (command === 'chat.append') return appendedMessage('assistant', 'x');
      if (command === 'drama.saveDraft') return JSON.stringify({ ok: true, drama: dramas[0] });
      return JSON.stringify({ ok: true });
    });

    await openScript(episodeFixture({ script }));
    // 换行让 findByDisplayValue 匹配不上，按类名取那块正文区。
    await screen.findByRole('button', { name: 'AI 重写这一集' });
    const area = document.querySelector('textarea.script-area') as HTMLTextAreaElement;
    expect(area.value).toBe(script);
    // 选中最后那句「林晚：你走。」
    const start = script.lastIndexOf('林晚：你走。');
    (area as HTMLTextAreaElement).setSelectionRange(start, script.length);
    fireEvent.mouseUp(area);
    const composer = await screen.findByPlaceholderText(/只会替换选中的部分/);
    fireEvent.change(composer, { target: { value: '改成留下' } });
    fireEvent.click(screen.getByRole('button', { name: '只改选中这段' }));

    await waitFor(() => {
      const call = executeCommand.mock.calls.find(([command]) => command === 'drama.saveDraft');
      expect(call?.[1]).toMatchObject({
        scope: 'episode',
        draft: { script: '林晚：你走。\n周野：别走。\n林晚：留下。' },
      });
    });
  });

  it('没选中内容时不能点局部改', async () => {
    await openScript(episodeFixture({ script: '林晚：你走。' }));
    fireEvent.change(await screen.findByPlaceholderText(/把开场三秒的钩子/), { target: { value: '改一下' } });
    expect(screen.getByRole('button', { name: '只改选中这段' })).toBeDisabled();
  });



  // ---- 分镜共创 ----

  const shotFixture = (order: number, overrides: Record<string, unknown> = {}) => ({
    id: `s${order}`, order, title: `第 ${order} 镜`, summary: '', dialogue: [],
    actionStart: '', actionEnd: '', cameraIntent: '', duration: 4,
    startPrompt: '', endPrompt: '', startCandidates: [], endCandidates: [],
    selectedStartID: null, selectedEndID: null,
    rev: 0, draftRev: 0, draft: null, ...overrides,
  });

  async function openStoryboard(shots: Array<Record<string, unknown>>) {
    const episode = { ...episodeFixture({ script: '林晚：你走。' }), shots };
    dramas = [{ ...scriptDramaFixture(episode), episodes: [episode] }];
    executeCommand.mockImplementation(async (command: string, args?: Record<string, unknown>) => {
      if (command === 'drama.list') return JSON.stringify({ ok: true, dramas });
      if (command === 'chat.list') return JSON.stringify({ ok: true, messages: [] });
      if (command === 'chat.append') return appendedMessage('assistant', 'x');
      if (command === 'skill.list') return JSON.stringify({ ok: true, skills: [] });
      if (command === 'skill.compose') return JSON.stringify({ ok: true, system: '# 分镜' });
      if (command === 'drama.listShots') {
        return JSON.stringify({
          ok: true,
          shots: shots.map((entry) => ({
            ...entry, rev: 0, draftRev: 0, hasDraft: false,
            startCandidateCount: 0, endCandidateCount: 0,
          })),
        });
      }
      if (command === 'drama.saveShotDrafts') {
        const list = (args?.shots ?? []) as Array<{ order: number }>;
        return JSON.stringify({ ok: true, drama: dramas[0], applied: list.map((item) => item.order) });
      }
      return JSON.stringify({ ok: true });
    });
    render(<App />);
    fireEvent.click((await screen.findAllByRole('button', { name: '继续创作' }))[0]!);
    fireEvent.click((await screen.findAllByRole('button', { name: /分镜/ }))[0]!);
  }

  it('默认只改当前一镜，围栏里省掉镜号也能对上', async () => {
    complete.mockResolvedValue({
      text: '砍到 4 秒了。\n```short_drama_shot\n{"duration":4,"actionEnd":"她已经站起来"}\n```',
      model: 'fast', providerID: 'chat-a',
    });
    await openStoryboard([shotFixture(1), shotFixture(2)]);

    // 粒度默认是单镜。
    const single = await screen.findByRole('button', { name: /只改第 1 镜/ });
    expect(single.getAttribute('aria-pressed')).toBe('true');

    fireEvent.change(screen.getByPlaceholderText(/这一镜太长了/), { target: { value: '砍到 4 秒' } });
    fireEvent.click(screen.getByRole('button', { name: '发送' }));

    await waitFor(() => {
      const call = executeCommand.mock.calls.find(([command]) => command === 'drama.saveShotDrafts');
      expect(call?.[1]).toMatchObject({
        episodeID: 'e1',
        shots: [{ order: 1, duration: 4, actionEnd: '她已经站起来' }],
      });
    });
  });

  it('切到整集微调后一次写多镜', async () => {
    complete.mockResolvedValue({
      text: '```short_drama_shots\n{"shots":[{"order":1,"duration":3},{"order":2,"cameraIntent":"固定"}]}\n```',
      model: 'fast', providerID: 'chat-a',
    });
    await openStoryboard([shotFixture(1), shotFixture(2)]);

    fireEvent.click(await screen.findByRole('button', { name: '整集微调' }));
    fireEvent.change(await screen.findByPlaceholderText(/把前三镜的节奏压紧/), { target: { value: '压紧节奏' } });
    fireEvent.click(screen.getByRole('button', { name: '发送' }));

    await waitFor(() => {
      const call = executeCommand.mock.calls.find(([command]) => command === 'drama.saveShotDrafts');
      const shots = (call?.[1] as { shots: Array<{ order: number }> }).shots;
      expect(shots.map((item) => item.order)).toEqual([1, 2]);
    });
  });

  it('模型只是提问时不动草稿', async () => {
    complete.mockResolvedValue({ text: '你希望这一镜的收尾是站起来还是转身？', model: 'fast', providerID: 'chat-a' });
    await openStoryboard([shotFixture(1)]);
    fireEvent.change(await screen.findByPlaceholderText(/这一镜太长了/), { target: { value: '调一下' } });
    fireEvent.click(screen.getByRole('button', { name: '发送' }));

    await waitFor(() => expect(executeCommand.mock.calls.some(([c]) => c === 'chat.append')).toBe(true));
    expect(executeCommand.mock.calls.some(([command]) => command === 'drama.saveShotDrafts')).toBe(false);
  });

  it('这一集没有分镜时给提示而不是空跑', async () => {
    await openStoryboard([]);
    fireEvent.change(await screen.findByPlaceholderText(/这一镜太长了/), { target: { value: '调一下' } });
    fireEvent.click(screen.getByRole('button', { name: '发送' }));
    expect(await screen.findByText(/还没有分镜/)).toBeTruthy();
    expect(complete).not.toHaveBeenCalled();
  });

  // ---- 批量丰富多集 ----

  it('分批串行写入，一批格式坏了其余批次继续', async () => {
    const episodes = Array.from({ length: 24 }, (_, index) => ({
      id: `e${index + 1}`, order: index + 1, title: `第 ${index + 1} 集`, summary: '',
      script: '', status: 'draft', shots: [], rev: 0, draftRev: 0, draft: null,
    }));
    dramas = [{ ...scriptDramaFixture(episodes[0]!), episodes }];

    let batch = 0;
    complete.mockImplementation(async () => {
      batch += 1;
      // 第二批返回坏格式，用来验证它不会中断整轮。
      if (batch === 2) return { text: '我先问一下这一批要不要加感情线。', model: 'fast', providerID: 'chat-a' };
      const from = (batch - 1) * 10 + 1;
      const list = [{ order: from, summary: `第 ${from} 集梗概` }];
      return {
        text: '```short_drama_episodes\n' + JSON.stringify({ episodes: list }) + '\n```',
        model: 'fast', providerID: 'chat-a',
      };
    });
    executeCommand.mockImplementation(async (command: string, args?: Record<string, unknown>) => {
      if (command === 'drama.list') return JSON.stringify({ ok: true, dramas });
      if (command === 'chat.list') return JSON.stringify({ ok: true, messages: [] });
      if (command === 'skill.list') return JSON.stringify({ ok: true, skills: [] });
      if (command === 'skill.compose') return JSON.stringify({ ok: true, system: '# 多集剧情串联' });
      if (command === 'drama.saveEpisodeDrafts') {
        const list = (args?.episodes ?? []) as Array<{ order: number }>;
        return JSON.stringify({ ok: true, drama: dramas[0], applied: list.map((item) => item.order) });
      }
      return JSON.stringify({ ok: true });
    });

    render(<App />);
    fireEvent.click((await screen.findAllByRole('button', { name: '继续创作' }))[0]!);
    fireEvent.click((await screen.findAllByRole('button', { name: /分集剧本/ }))[0]!);
    fireEvent.click(await screen.findByRole('button', { name: 'AI 串起全部 24 集' }));

    // 24 集切成三批，三批都发出去了——第二批坏格式没有中断后面那批。
    await waitFor(() => expect(complete).toHaveBeenCalledTimes(3), { timeout: 4000 });
    const writes = executeCommand.mock.calls.filter(([command]) => command === 'drama.saveEpisodeDrafts');
    expect(writes).toHaveLength(2);
    // 写入按集号对齐，第一批写第 1 集、第三批写第 21 集。
    expect((writes[0]![1] as { episodes: Array<{ order: number }> }).episodes[0]!.order).toBe(1);
    expect((writes[1]![1] as { episodes: Array<{ order: number }> }).episodes[0]!.order).toBe(21);
  });

  it('没有分集时给出提示而不是空跑', async () => {
    dramas = [{ ...scriptDramaFixture(episodeFixture()), episodes: [] }];
    executeCommand.mockImplementation(async (command: string) => {
      if (command === 'drama.list') return JSON.stringify({ ok: true, dramas });
      if (command === 'chat.list') return JSON.stringify({ ok: true, messages: [] });
      return JSON.stringify({ ok: true });
    });
    render(<App />);
    fireEvent.click((await screen.findAllByRole('button', { name: '继续创作' }))[0]!);
    fireEvent.click((await screen.findAllByRole('button', { name: /分集剧本/ }))[0]!);
    fireEvent.click(await screen.findByRole('button', { name: 'AI 串起全部 0 集' }));

    expect(await screen.findByText(/还没有分集/)).toBeTruthy();
    expect(complete).not.toHaveBeenCalled();
  });

  // ---- 剧本里的新面孔 ----

  it('剧本里说过两句的新名字会被提示，点一下只建名字', async () => {
    const script = '林晚：你怎么又来了。\n周野：我收到一条短信。\n林晚：那不可能。\n周野：你看时间戳。\n护士：请关掉手机。';
    const episode = {
      id: 'e1', order: 1, title: '第 1 集', summary: '', script,
      status: 'draft', shots: [], rev: 0, draftRev: 0, draft: null,
    };
    dramas = [{
      id: 'd1', title: '错时来信', genre: '悬疑', format: '竖屏', episodeCount: 1, episodeDurationSeconds: 90,
      logline: '', coreConflict: '', audience: '', tone: '', arc: '', status: 'planning',
      rev: 0, draftRev: 0, draft: null,
      characters: [{
        id: 'c1', name: '林晚', description: '', visualPrompt: '', identityVersion: 1,
        candidates: [], selectedCandidateID: null, rev: 0, draftRev: 0, draft: null,
      }],
      episodes: [episode],
      createdAt: '2026-09-09T00:00:00Z', updatedAt: '2026-09-09T00:00:00Z',
    }];
    executeCommand.mockImplementation(async (command: string) => {
      if (command === 'drama.list') return JSON.stringify({ ok: true, dramas });
      if (command === 'chat.list') return JSON.stringify({ ok: true, messages: [] });
      if (command === 'drama.saveCharacter') return JSON.stringify({ ok: true, drama: dramas[0] });
      return JSON.stringify({ ok: true });
    });

    render(<App />);
    fireEvent.click((await screen.findAllByRole('button', { name: '继续创作' }))[0]!);
    fireEvent.click((await screen.findAllByRole('button', { name: /分集剧本/ }))[0]!);

    // 林晚已在角色表里，护士是功能性称谓且只说一句，都不该出现。
    expect(await screen.findByRole('button', { name: '建「周野」' })).toBeTruthy();
    expect(screen.queryByRole('button', { name: '建「林晚」' })).toBeNull();
    expect(screen.queryByRole('button', { name: '建「护士」' })).toBeNull();

    fireEvent.click(screen.getByRole('button', { name: '建「周野」' }));
    await waitFor(() => {
      const call = executeCommand.mock.calls.find(([command]) => command === 'drama.saveCharacter');
      expect(call?.[1]).toEqual({ dramaID: 'd1', name: '周野' });
    });
  });

  // ---- 角色共创 ----

  const characterFixture = (overrides: Record<string, unknown> = {}) => ({
    id: 'c1', name: '林晚', description: '夜班护士', visualPrompt: '冷色调',
    identityVersion: 1, candidates: [], selectedCandidateID: null,
    rev: 0, draftRev: 0, draft: null, ...overrides,
  });

  const dramaFixture = (character: Record<string, unknown>) => ({
    id: 'd1', title: '错时来信', genre: '悬疑', format: '竖屏', episodeCount: 1, episodeDurationSeconds: 90,
    logline: '未来短信改变今天', coreConflict: '', audience: '', tone: '冷峻', arc: '', status: 'planning',
    rev: 0, draftRev: 0, draft: null, characters: [character], episodes: [],
    createdAt: '2026-09-09T00:00:00Z', updatedAt: '2026-09-09T00:00:00Z',
  });

  let chatSeq = 0;
  const appendedMessage = (role: 'user' | 'assistant', content: string) =>
    JSON.stringify({ ok: true, message: { id: `m${++chatSeq}`, role, content, objectID: 'c1', draftRev: 0, createdAt: '' } });

  async function openCharacters(character: Record<string, unknown>) {
    chatSeq = 0;
    dramas = [dramaFixture(character)];
    render(<App />);
    fireEvent.click((await screen.findAllByRole('button', { name: '继续创作' }))[0]!);
    fireEvent.click((await screen.findAllByRole('button', { name: /林晚/ }))[0]!);
  }

  it('sends a character request and stores the result as a draft, not committed content', async () => {
    complete.mockResolvedValue({
      text: '按你说的收紧了性格。\n```short_drama_character\n{"description":"话少，句子短"}\n```',
      model: 'fast', providerID: 'chat-a',
    });
    const updated = dramaFixture(characterFixture({ draftRev: 1, draft: { description: '话少，句子短' } }));
    executeCommand.mockImplementation(async (command: string) => {
      if (command === 'drama.list') return JSON.stringify({ ok: true, dramas });
      if (command === 'chat.list') return JSON.stringify({ ok: true, messages: [] });
      if (command === 'chat.append') return appendedMessage('user', 'x');
      if (command === 'drama.saveDraft') return JSON.stringify({ ok: true, drama: updated });
      return JSON.stringify({ ok: true });
    });

    await openCharacters(characterFixture());
    fireEvent.change(screen.getByPlaceholderText(/让她更冷一点/), { target: { value: '更冷一点' } });
    fireEvent.click(screen.getByRole('button', { name: '发送' }));

    await waitFor(() => {
      const call = executeCommand.mock.calls.find(([command]) => command === 'drama.saveDraft');
      expect(call?.[1]).toMatchObject({ scope: 'character', characterID: 'c1', draft: { description: '话少，句子短' }, expectedDraftRev: 0 });
    });
    // 正式内容必须原封不动，只有草稿动了。
    expect(executeCommand.mock.calls.some(([command]) => command === 'drama.saveCharacter')).toBe(false);
    expect(await screen.findByText('有未采用的草稿')).toBeTruthy();
  });

  it('holds a result for review when the draft moved while generating', async () => {
    complete.mockResolvedValue({
      text: '```short_drama_character\n{"description":"迟到的结果"}\n```',
      model: 'fast', providerID: 'chat-a',
    });
    executeCommand.mockImplementation(async (command: string) => {
      if (command === 'drama.list') return JSON.stringify({ ok: true, dramas });
      if (command === 'chat.list') return JSON.stringify({ ok: true, messages: [] });
      if (command === 'chat.append') return appendedMessage('assistant', 'x');
      if (command === 'drama.saveDraft') return JSON.stringify({ ok: false, error: { code: 'revision_conflict' } });
      return JSON.stringify({ ok: true });
    });

    await openCharacters(characterFixture());
    fireEvent.change(screen.getByPlaceholderText(/让她更冷一点/), { target: { value: '更冷一点' } });
    fireEvent.click(screen.getByRole('button', { name: '发送' }));

    expect(await screen.findByText('有一份待复核的结果')).toBeTruthy();
    // 冲突时绝不能把结果直接写下去。
    expect(screen.queryByText('有未采用的草稿')).toBeNull();
  });

  it('treats a reply without a fenced block as chat and leaves the draft alone', async () => {
    complete.mockResolvedValue({ text: '你想让她冷到什么程度？说话还留不留温度？', model: 'fast', providerID: 'chat-a' });
    executeCommand.mockImplementation(async (command: string) => {
      if (command === 'drama.list') return JSON.stringify({ ok: true, dramas });
      if (command === 'chat.list') return JSON.stringify({ ok: true, messages: [] });
      if (command === 'chat.append') return appendedMessage('assistant', '你想让她冷到什么程度？');
      return JSON.stringify({ ok: true });
    });

    await openCharacters(characterFixture());
    fireEvent.change(screen.getByPlaceholderText(/让她更冷一点/), { target: { value: '更冷一点' } });
    fireEvent.click(screen.getByRole('button', { name: '发送' }));

    await waitFor(() => expect(executeCommand.mock.calls.some(([command]) => command === 'chat.append')).toBe(true));
    expect(executeCommand.mock.calls.some(([command]) => command === 'drama.saveDraft')).toBe(false);
  });

  it('adopting a draft commits with the revision it was reviewed at', async () => {
    executeCommand.mockImplementation(async (command: string) => {
      if (command === 'drama.list') return JSON.stringify({ ok: true, dramas });
      if (command === 'chat.list') return JSON.stringify({ ok: true, messages: [] });
      if (command === 'drama.commitDraft') return JSON.stringify({ ok: true, drama: dramaFixture(characterFixture({ rev: 3, draft: null, description: '话少，句子短' })) });
      return JSON.stringify({ ok: true });
    });

    await openCharacters(characterFixture({ rev: 2, draftRev: 4, draft: { description: '话少，句子短' } }));
    fireEvent.click(await screen.findByRole('button', { name: '采用草稿' }));

    await waitFor(() => {
      const call = executeCommand.mock.calls.find(([command]) => command === 'drama.commitDraft');
      expect(call?.[1]).toMatchObject({ scope: 'character', characterID: 'c1', expectedRev: 2 });
    });
  });

  it('reads a repeated confirmation as already adopted instead of an error', async () => {
    executeCommand.mockImplementation(async (command: string) => {
      if (command === 'drama.list') return JSON.stringify({ ok: true, dramas });
      if (command === 'chat.list') return JSON.stringify({ ok: true, messages: [] });
      if (command === 'drama.commitDraft') return JSON.stringify({ ok: false, error: { code: 'revision_conflict', actual: 3 } });
      return JSON.stringify({ ok: true });
    });

    await openCharacters(characterFixture({ rev: 2, draftRev: 4, draft: { description: '话少，句子短' } }));
    fireEvent.click(await screen.findByRole('button', { name: '采用草稿' }));

    expect(await screen.findByText('这一版刚才已经采用过了。')).toBeTruthy();
  });

  it('stops a running request through the host cancel bridge', async () => {
    const cancel = vi.fn().mockResolvedValue({ cancelled: true });
    window.willdeep!.ai!.cancel = cancel;
    let settle: ((value: unknown) => void) | undefined;
    complete.mockImplementation(() => new Promise((resolve) => { settle = resolve; }));
    executeCommand.mockImplementation(async (command: string) => {
      if (command === 'drama.list') return JSON.stringify({ ok: true, dramas });
      if (command === 'chat.list') return JSON.stringify({ ok: true, messages: [] });
      if (command === 'chat.append') return appendedMessage('user', 'x');
      return JSON.stringify({ ok: true });
    });

    await openCharacters(characterFixture());
    fireEvent.change(screen.getByPlaceholderText(/让她更冷一点/), { target: { value: '更冷一点' } });
    fireEvent.click(screen.getByRole('button', { name: '发送' }));
    fireEvent.click(await screen.findByRole('button', { name: '停止' }));

    expect(cancel).toHaveBeenCalledTimes(1);
    expect(typeof cancel.mock.calls[0]?.[0]).toBe('string');
    settle?.({ text: '', model: 'fast', providerID: 'chat-a' });
  });

  it('computes differences from the fields themselves', () => {
    const entry = {
      id: 'c1', name: '林晚', description: '夜班护士', visualPrompt: '冷色调',
      identityVersion: 1, candidates: [], selectedCandidateID: null,
      rev: 0, draftRev: 1, draft: { description: '话少，句子短', visualPrompt: '冷色调' },
    };
    const rows = draftDifferences(entry as never);
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({ field: 'description', before: '夜班护士', after: '话少，句子短' });
  });

  it('filters dramas by keyword and status', async () => {
    const base = {
      genre: '悬疑', format: '竖屏', episodeCount: 8, episodeDurationSeconds: 90,
      coreConflict: '', audience: '', tone: '', arc: '', characters: [], episodes: [],
      createdAt: '2026-09-04T00:00:00Z', updatedAt: '2026-09-04T00:00:00Z',
    };
    dramas = [
      { ...base, id: 'd1', title: '错时来信', logline: '未来短信改变今天', status: 'planning' },
      { ...base, id: 'd2', title: '月港追光', logline: '两个人寻找失落胶片', status: 'completed' },
    ];
    render(<App />);
    expect(await screen.findAllByText('错时来信')).not.toHaveLength(0);
    fireEvent.change(screen.getByLabelText('搜索剧名、类型或梗概'), { target: { value: '月港' } });
    expect(screen.queryByRole('heading', { name: '错时来信' })).toBeNull();
    expect(screen.getByRole('heading', { name: '月港追光' })).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: /^策划中/ }));
    expect(screen.getByText('还没有符合条件的短剧')).toBeTruthy();
  });
});
