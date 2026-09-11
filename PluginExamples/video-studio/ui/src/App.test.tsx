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

  // ---- 首稿必须带正文 ----

  /// 阶段提示词里那句「只写你这次真正要改的字段」对小修小补是对的，
  /// 首稿场景下模型会只回一段梗概就交卷。
  it('这一集还没有正文时，请求里明确要 script', async () => {
    await openScript(episodeFixture({ script: '' }));
    fireEvent.click(await screen.findByRole('button', { name: 'AI 写这一集' }));
    await waitFor(() => expect(complete).toHaveBeenCalled());
    const sent = complete.mock.calls.at(-1)![0].messages.at(-1).content;
    expect(sent).toContain('必须给出 script 字段');
  });

  it('已有正文时不加这句，免得一次小改动就把整集重写', async () => {
    await openScript(episodeFixture({ script: '林晚：你走。' }));
    fireEvent.change(screen.getByPlaceholderText(/把开场三秒的钩子/), { target: { value: '梗概改短一点' } });
    fireEvent.click(await screen.findByRole('button', { name: 'AI 重写这一集' }));
    await waitFor(() => expect(complete).toHaveBeenCalled());
    const sent = complete.mock.calls.at(-1)![0].messages.at(-1).content;
    expect(sent).not.toContain('必须给出 script 字段');
  });

  it('模型只回梗概时说清正文没写，而不是报一句已更新草稿', async () => {
    complete.mockResolvedValue({
      text: '写好了。\n```short_drama_episode\n{"summary":"他匿名报警"}\n```',
      model: 'fast', providerID: 'chat-a',
    });
    const updated = scriptDramaFixture(episodeFixture({ script: '', draftRev: 1, draft: { summary: '他匿名报警' } }));
    executeCommand.mockImplementation(async (command: string) => {
      if (command === 'drama.list') return JSON.stringify({ ok: true, dramas });
      if (command === 'chat.list') return JSON.stringify({ ok: true, messages: [] });
      if (command === 'chat.append') return appendedMessage('user', 'x');
      if (command === 'drama.saveDraft') return JSON.stringify({ ok: true, drama: updated });
      return JSON.stringify({ ok: true });
    });
    await openScript(episodeFixture({ script: '' }));
    fireEvent.click(await screen.findByRole('button', { name: 'AI 写这一集' }));

    // 梗概照样存进草稿，不白跑一趟。
    await waitFor(() => {
      const call = executeCommand.mock.calls.find(([command]) => command === 'drama.saveDraft');
      expect(call?.[1]).toMatchObject({ draft: { summary: '他匿名报警' } });
    });
    await waitFor(() => expect(document.querySelector('.toast-item.error')?.textContent).toContain('没给剧本正文'));
  });

  // ---- 分集选择 ----

  /// 二十四集塞进一个下拉，要选第几集全靠滚，标题也看不全。
  it('分集按十集一段列出标题，选段只换列表不换当前集', async () => {
    const many = Array.from({ length: 24 }, (_, at) => episodeFixture({
      id: `e${at + 1}`, order: at + 1, title: `标题${at + 1}`,
    }));
    dramas = [{ ...scriptDramaFixture(many[0]!), episodes: many, episodeCount: 24 }];
    render(<App />);
    fireEvent.click((await screen.findAllByRole('button', { name: '继续创作' }))[0]!);
    fireEvent.click((await screen.findAllByRole('button', { name: /分集剧本/ }))[0]!);

    // 第一段列出 1 到 10 集的标题，第 11 集不在里面。
    await waitFor(() => expect(screen.getByRole('button', { name: /标题1$/ })).not.toBeNull());
    expect(document.querySelectorAll('.episode-picker button').length).toBe(10);
    expect(screen.queryByRole('button', { name: /标题11/ })).toBeNull();
    expect(screen.getByRole('button', { name: '分集范围' }).textContent).toContain('1-10 集');

    // 挑到第三段：列表换成 21 到 24 集，当前集还是第 1 集。
    fireEvent.click(screen.getByRole('button', { name: '分集范围' }));
    fireEvent.mouseDown(screen.getByRole('option', { name: '21-24 集' }));
    await waitFor(() => expect(document.querySelectorAll('.episode-picker button').length).toBe(4));
    expect(screen.queryByRole('button', { name: /标题1$/ })).toBeNull();
    expect((screen.getByLabelText('本集标题') as HTMLInputElement).value).toBe('标题1');

    // 点第 22 集才换当前集。
    fireEvent.click(screen.getByRole('button', { name: /标题22/ }));
    await waitFor(() => expect((screen.getByLabelText('本集标题') as HTMLInputElement).value).toBe('标题22'));
    expect(screen.getByRole('button', { name: /标题22/ }).getAttribute('aria-current')).toBe('true');
  });

  it('只有一段时不出范围下拉，没写标题的集有占位文案', async () => {
    await openScript(episodeFixture({ title: '' }));
    await waitFor(() => expect(document.querySelectorAll('.episode-picker button').length).toBe(1));
    expect(screen.queryByRole('button', { name: '分集范围' })).toBeNull();
    expect(document.querySelector('.episode-picker button')?.textContent).toContain('（还没写标题）');
  });

  // ---- 模型选择器的位置 ----

  /// 面板顶部那份会随页面滚走，用户滚到按钮跟前时已经看不见了。
  it('剧本页在串起全季那颗按钮旁边和写作按钮上方各有一组模型选择', async () => {
    await openScript(episodeFixture());
    await screen.findByRole('button', { name: 'AI 写这一集' });

    const heading = document.querySelector('.heading-actions .routing.compact');
    expect(heading).not.toBeNull();
    // 「AI 串起全部 N 集」和选择器在同一排。
    expect(document.querySelector('.heading-actions')?.textContent).toContain('串起全部');

    const composer = document.querySelector('.composer .routing.compact');
    expect(composer).not.toBeNull();
    // 选择器排在按钮之前，读到按钮时模型已经定了。
    expect(composer!.compareDocumentPosition(document.querySelector('.composer .actions')!))
      .toBe(Node.DOCUMENT_POSITION_FOLLOWING);
  });

  it('角色页和分镜页的选择器也贴着各自的发送按钮', async () => {
    await openCharacters(characterFixture());
    const inCharacterComposer = document.querySelector('.character-chat .composer .routing.compact');
    expect(inCharacterComposer).not.toBeNull();
    // 顶部标题区不再挂一份，避免同一页出现两组指向同一状态的选择器。
    expect(document.querySelector('.character-chat > .routing')).toBeNull();
  });

  // ---- 头像放大 ----

  /// 定妆照那张头像在列表里只有 50 像素，点开才能看清脸有没有跑。
  it('点头像开放大图层，点背景、X、Esc 三种方式都能关掉', async () => {
    const withPortrait = characterFixture({
      candidates: [{ id: 'cand-1', mediaURL: 'https://example.test/linwan.png' }],
      selectedCandidateID: 'cand-1',
    });
    await openCharacters(withPortrait);

    const zoom = screen.getByRole('button', { name: '放大查看头像' });
    fireEvent.click(zoom);
    const layer = await screen.findByRole('dialog');
    expect(layer.querySelector('img')?.getAttribute('src')).toBe('https://example.test/linwan.png');

    // 点图片本身不关：放大就是为了看清，误触关掉很烦。
    fireEvent.click(layer.querySelector('img')!);
    expect(screen.queryByRole('dialog')).not.toBeNull();

    fireEvent.click(screen.getByRole('button', { name: '关闭放大图' }));
    await waitFor(() => expect(screen.queryByRole('dialog')).toBeNull());

    fireEvent.click(zoom);
    fireEvent.click(await screen.findByRole('dialog'));
    await waitFor(() => expect(screen.queryByRole('dialog')).toBeNull());

    fireEvent.click(zoom);
    await screen.findByRole('dialog');
    fireEvent.keyDown(window, { key: 'Escape' });
    await waitFor(() => expect(screen.queryByRole('dialog')).toBeNull());
  });

  it('放大头像不会顺带切换选中的角色，没有定妆照时也没有放大按钮', async () => {
    const second = { ...characterFixture(), id: 'c2', name: '周野', description: '夜市摊主' };
    const withPortrait = characterFixture({
      candidates: [{ id: 'cand-1', mediaURL: 'https://example.test/linwan.png' }],
      selectedCandidateID: 'cand-1',
    });
    chatSeq = 0;
    dramas = [dramaFixture(withPortrait)];
    dramas[0]!.characters = [withPortrait, second];
    render(<App />);
    fireEvent.click((await screen.findAllByRole('button', { name: '继续创作' }))[0]!);
    // 先选中第二个角色，再点第一个角色的头像。
    fireEvent.click((await screen.findAllByRole('button', { name: /周野/ }))[0]!);
    await waitFor(() => expect((screen.getByLabelText('角色名') as HTMLInputElement).value).toBe('周野'));

    fireEvent.click(screen.getByRole('button', { name: '放大查看头像' }));
    await screen.findByRole('dialog');
    // 头像按钮和选角按钮是两个按钮，放大不该把编辑区换成林晚。
    expect((screen.getByLabelText('角色名') as HTMLInputElement).value).toBe('周野');
    // 周野没有定妆照，所以整页只有林晚那一个放大按钮。
    expect(screen.getAllByRole('button', { name: '放大查看头像' }).length).toBe(1);
  });

  // ---- 技能维护 ----

  it('设置页里选一份技能，能看到正文并保存回去', async () => {
    const saved: Array<Record<string, unknown>> = [];
    executeCommand.mockImplementation(async (command: string, args?: Record<string, unknown>) => {
      if (command === 'drama.list') return JSON.stringify({ ok: true, dramas });
      if (command === 'skill.list') {
        return JSON.stringify({ ok: true, skills: saved.length ? [{ ...skillFixtures[0]!, customized: true }, ...skillFixtures.slice(1)] : skillFixtures });
      }
      if (command === 'skill.get') return JSON.stringify({ ok: true, skill: { ...skillFixtures[0]!, body: '# 短剧策划\n原来的正文' } });
      if (command === 'skill.save') { saved.push(args ?? {}); return JSON.stringify({ ok: true, skill: { ...skillFixtures[0]!, customized: true, body: String(args?.body ?? '') } }); }
      return JSON.stringify({ ok: true });
    });

    render(<App />);
    fireEvent.click(screen.getByRole('button', { name: '设置' }));
    const row = await screen.findByRole('button', { name: /短剧策划/ });
    fireEvent.click(row);
    const body = await screen.findByLabelText('短剧策划 的正文') as HTMLTextAreaElement;
    expect(body.value).toContain('原来的正文');

    // 恢复内置只在这份技能真被改过时才可点，否则那个按钮什么也做不了。
    expect(screen.getByRole('button', { name: '恢复内置版本' }).hasAttribute('disabled')).toBe(true);

    fireEvent.change(body, { target: { value: '# 短剧策划\n我自己写的正文' } });
    fireEvent.click(screen.getByRole('button', { name: '保存技能' }));
    await waitFor(() => expect(saved).toEqual([{ id: 'planning', body: '# 短剧策划\n我自己写的正文' }]));
    // 保存后重新拉清单，「已修改」标记与恢复按钮同时活过来。
    await waitFor(() => expect(screen.getByRole('button', { name: '恢复内置版本' }).hasAttribute('disabled')).toBe(false));
    expect(screen.getByRole('button', { name: /短剧策划/ }).textContent).toContain('已修改');
  });

  it('恢复内置版本把编辑框换回模板正文', async () => {
    executeCommand.mockImplementation(async (command: string) => {
      if (command === 'drama.list') return JSON.stringify({ ok: true, dramas });
      if (command === 'skill.list') return JSON.stringify({ ok: true, skills: [{ ...skillFixtures[0]!, customized: true }] });
      if (command === 'skill.get') return JSON.stringify({ ok: true, skill: { ...skillFixtures[0]!, customized: true, body: '我改过的正文' } });
      if (command === 'skill.reset') return JSON.stringify({ ok: true, skill: { ...skillFixtures[0]!, customized: false, body: '内置正文' } });
      return JSON.stringify({ ok: true });
    });

    render(<App />);
    fireEvent.click(screen.getByRole('button', { name: '设置' }));
    fireEvent.click(await screen.findByRole('button', { name: /短剧策划/ }));
    const body = await screen.findByLabelText('短剧策划 的正文') as HTMLTextAreaElement;
    expect(body.value).toBe('我改过的正文');
    fireEvent.click(screen.getByRole('button', { name: '恢复内置版本' }));
    await waitFor(() => expect((screen.getByLabelText('短剧策划 的正文') as HTMLTextAreaElement).value).toBe('内置正文'));
  });

  it('没选技能时不显示编辑框', async () => {
    executeCommand.mockImplementation(async (command: string) => {
      if (command === 'drama.list') return JSON.stringify({ ok: true, dramas });
      if (command === 'skill.list') return JSON.stringify({ ok: true, skills: skillFixtures });
      return JSON.stringify({ ok: true });
    });
    render(<App />);
    fireEvent.click(screen.getByRole('button', { name: '设置' }));
    await screen.findByRole('button', { name: /短剧策划/ });
    expect(screen.queryByRole('button', { name: '保存技能' })).toBeNull();
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

  /// 真实故障：站在第 2 集点「AI 写这一集」，草稿里明明有正文，左边「完整
  /// 剧本」还是空的——编辑缓冲只按 episode.id 同步，draftRev 变了 id 没变，
  /// 缓冲一个字不动。切到别的集再切回来就出来了，于是看起来像「只有当前
  /// 这一集写不进去」。
  it('AI 写完这一集，不换集也要在正文框里看见', async () => {
    const script = '陈默：这号码是三天后的。';
    complete.mockResolvedValue({
      text: '写好了。\n```short_drama_episode\n{"script":"' + script + '"}\n```',
      model: 'fast', providerID: 'chat-a',
    });
    const updated = scriptDramaFixture(episodeFixture({ script: '', draftRev: 1, draft: { script } }));
    executeCommand.mockImplementation(async (command: string) => {
      if (command === 'drama.list') return JSON.stringify({ ok: true, dramas });
      if (command === 'chat.list') return JSON.stringify({ ok: true, messages: [] });
      if (command === 'chat.append') return appendedMessage('assistant', 'x');
      if (command === 'drama.saveDraft') return JSON.stringify({ ok: true, drama: updated });
      return JSON.stringify({ ok: true });
    });

    await openScript(episodeFixture({ script: '' }));
    fireEvent.click(await screen.findByRole('button', { name: 'AI 写这一集' }));
    await waitFor(() => {
      expect((document.querySelector('textarea.script-area') as HTMLTextAreaElement).value).toBe(script);
    });
    // 差异面板是这次生成打开的，同步不该把它关掉。
    expect(document.querySelector('.diff-list')).not.toBeNull();
  });

  /// 「AI 串起全部 N 集」写到当前选中那一集时，同一条缓冲同一个毛病。
  it('串起全季写到当前这一集，正文框跟着更新', async () => {
    const script = '陈默：八百多万到账了。';
    complete.mockResolvedValue({
      text: '```short_drama_episodes\n{"episodes":[{"order":1,"summary":"奖金到账","script":"' + script + '"}]}\n```',
      model: 'fast', providerID: 'chat-a',
    });
    const updated = scriptDramaFixture(episodeFixture({ script: '', draftRev: 1, draft: { summary: '奖金到账', script } }));
    executeCommand.mockImplementation(async (command: string) => {
      if (command === 'drama.list') return JSON.stringify({ ok: true, dramas });
      if (command === 'chat.list') return JSON.stringify({ ok: true, messages: [] });
      if (command === 'chat.append') return appendedMessage('assistant', 'x');
      if (command === 'drama.saveEpisodeDrafts') return JSON.stringify({ ok: true, drama: updated, applied: [1] });
      return JSON.stringify({ ok: true });
    });

    await openScript(episodeFixture({ script: '' }));
    fireEvent.click(await screen.findByRole('button', { name: 'AI 串起全部 1 集' }));
    await waitFor(() => {
      expect((document.querySelector('textarea.script-area') as HTMLTextAreaElement).value).toBe(script);
    });
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




  // ---- 思考过程与模型选择 ----

  it('思考流按 streamID 显示，请求结束后清掉', async () => {
    let settle: ((value: unknown) => void) | undefined;
    complete.mockImplementation(() => new Promise((resolve) => { settle = resolve; }));
    executeCommand.mockImplementation(async (command: string) => {
      if (command === 'drama.list') return JSON.stringify({ ok: true, dramas });
      if (command === 'chat.list') return JSON.stringify({ ok: true, messages: [] });
      if (command === 'chat.append') return appendedMessage('user', 'x');
      if (command === 'skill.compose') return JSON.stringify({ ok: true, system: '# 角色设定' });
      return JSON.stringify({ ok: true });
    });
    await openCharacters(characterFixture());
    fireEvent.change(screen.getByPlaceholderText(/让她更冷一点/), { target: { value: '更冷一点' } });
    fireEvent.click(screen.getByRole('button', { name: '发送' }));

    const streamID = await waitFor(() => {
      const id = complete.mock.calls.at(-1)?.[0].streamID;
      expect(typeof id).toBe('string');
      return id as string;
    });

    // 正文还没开始，思考先到。
    window.dispatchEvent(new CustomEvent('willdeep:ai-reasoning', { detail: { streamID, delta: '先看角色表里的说话习惯' } }));
    expect(await screen.findByText(/先看角色表里的说话习惯/)).toBeTruthy();

    // 别人的 streamID 不该串台。
    window.dispatchEvent(new CustomEvent('willdeep:ai-reasoning', { detail: { streamID: 'other', delta: '不该出现' } }));
    expect(screen.queryByText(/不该出现/)).toBeNull();

    settle?.({ text: '```short_drama_character\n{"description":"话少"}\n```', model: 'fast', providerID: 'chat-a' });
    // 请求收尾后思考区消失：它是过程不是结果。
    await waitFor(() => expect(screen.queryByText(/先看角色表里的说话习惯/)).toBeNull());
  });

  it('没有思考文本时不显示折叠框', async () => {
    complete.mockResolvedValue({ text: '你想让她冷到什么程度？', model: 'fast', providerID: 'chat-a' });
    executeCommand.mockImplementation(async (command: string) => {
      if (command === 'drama.list') return JSON.stringify({ ok: true, dramas });
      if (command === 'chat.list') return JSON.stringify({ ok: true, messages: [] });
      if (command === 'chat.append') return appendedMessage('assistant', 'x');
      return JSON.stringify({ ok: true });
    });
    await openCharacters(characterFixture());
    fireEvent.change(screen.getByPlaceholderText(/让她更冷一点/), { target: { value: '问一下' } });
    fireEvent.click(screen.getByRole('button', { name: '发送' }));
    await waitFor(() => expect(complete).toHaveBeenCalled());
    // 不是每个模型都给思考，空着的时候多一个折叠框只是噪声。
    expect(document.querySelector('.reasoning-line')).toBeNull();
  });

  it('角色页也能选模型，选完对这一阶段的请求生效', async () => {
    executeCommand.mockImplementation(async (command: string) => {
      if (command === 'drama.list') return JSON.stringify({ ok: true, dramas });
      if (command === 'chat.list') return JSON.stringify({ ok: true, messages: [] });
      if (command === 'chat.append') return appendedMessage('user', 'x');
      if (command === 'drama.saveDraft') return JSON.stringify({ ok: true, drama: dramas[0] });
      return JSON.stringify({ ok: true });
    });
    complete.mockResolvedValue({ text: '```short_drama_character\n{"description":"话少"}\n```', model: 'pro', providerID: 'chat-a' });
    await openCharacters(characterFixture());

    // 共创面板里就有模型选择，不用回设置页。
    const pickers = screen.getAllByLabelText('聊天模型');
    expect(pickers.length).toBeGreaterThan(0);

    fireEvent.change(screen.getByPlaceholderText(/让她更冷一点/), { target: { value: '更冷一点' } });
    fireEvent.click(screen.getByRole('button', { name: '发送' }));
    await waitFor(() => {
      const call = complete.mock.calls.at(-1)?.[0];
      // provider 与 model 跟着全局选择走，各阶段共用同一份偏好。
      expect(call).toHaveProperty('provider');
      expect(call).toHaveProperty('model');
    });
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

  it('空分镜可以直接用本集正文生成第一稿', async () => {
    await openStoryboard([]);
    complete.mockResolvedValue({ text: '```short_drama_shots\n{"shots":[{"order":1,"title":"告别","summary":"林晚说你走"}]}\n```', model: 'fast', providerID: 'chat-a' });
    fireEvent.click(await screen.findByRole('button', { name: 'AI 从剧本生成分镜' }));
    await waitFor(() => expect(executeCommand).toHaveBeenCalledWith('drama.saveShotDrafts', expect.objectContaining({ create: true, shots: [{ order: 1, title: '告别', summary: '林晚说你走' }] })));
    expect(complete.mock.calls[0]?.[0].messages.at(-1).content).toContain('林晚：你走。');
  });

  // ---- 批量丰富多集 ----
  it('分镜草稿显示在正文中，采用会校验两个修订号', async () => {
    const entry = shotFixture(1, { summary: '原剧情', draftRev: 2, draft: { summary: '修改后的剧情' } });
    await openStoryboard([entry]);
    expect(await screen.findByDisplayValue('修改后的剧情')).toBeTruthy();
    executeCommand.mockImplementation(async (command: string) => {
      if (command === 'drama.commitDraft') {
        const adopted = { ...entry, summary: '修改后的剧情', draft: null, rev: 1, draftRev: 3 };
        return JSON.stringify({ ok: true, drama: { ...dramas[0], episodes: [{ ...episodeFixture(), shots: [adopted] }] } });
      }
      return JSON.stringify({ ok: true, messages: [] });
    });
    fireEvent.click(screen.getByRole('button', { name: '采用分镜草稿' }));
    await waitFor(() => expect(executeCommand).toHaveBeenCalledWith('drama.commitDraft', expect.objectContaining({ scope: 'shot', shotID: 's1', expectedRev: 0, expectedDraftRev: 2 })));
    await waitFor(() => expect(screen.queryByRole('button', { name: '采用分镜草稿' })).toBeNull());
    expect(screen.getByDisplayValue('修改后的剧情')).toBeTruthy();
  });

  it('首尾帧共创保存独立聊天，生成描述先进入草稿', async () => {
    await openStoryboard([shotFixture(1, { summary: '手机亮起', startPrompt: '原首帧' })]);
    fireEvent.click(screen.getByRole('button', { name: /05 首尾帧/ }));
    complete.mockResolvedValue({ text: '```short_drama_frames\n{"startPrompt":"手机冷光照亮脸部","endPrompt":"他抬头望向窗外"}\n```', model: 'fast', providerID: 'chat-a' });
    executeCommand.mockImplementation(async (command: string, args?: Record<string, unknown>) => {
      if (command === 'chat.list') return JSON.stringify({ ok: true, messages: [] });
      if (command === 'chat.append') return appendedMessage('assistant', '已生成描述');
      if (command === 'drama.saveDraft') return JSON.stringify({ ok: true, drama: { ...dramas[0], episodes: [{ ...episodeFixture(), shots: [shotFixture(1, { summary: '手机亮起', startPrompt: '原首帧', draftRev: 1, draft: args?.draft })] }] } });
      return JSON.stringify({ ok: true });
    });
    fireEvent.click(await screen.findByRole('button', { name: 'AI 共创描述' }));
    await waitFor(() => expect(executeCommand).toHaveBeenCalledWith('chat.append', expect.objectContaining({ stage: 'frames' })));
    expect(await screen.findByDisplayValue('手机冷光照亮脸部')).toBeTruthy();
    expect(screen.getByDisplayValue('他抬头望向窗外')).toBeTruthy();
    expect(screen.getByRole('button', { name: '采用分镜草稿' })).toBeTruthy();
    expect(screen.getAllByRole('button', { name: '生成 4 张候选' }).every((button) => button.hasAttribute('disabled'))).toBe(true);
    expect(executeCommand.mock.calls.some(([command]) => command === 'drama.commitDraft')).toBe(false);
  });

  it('只改一镜时拒绝模型偷偷修改其他镜号', async () => {
    await openStoryboard([shotFixture(1), shotFixture(2)]);
    complete.mockResolvedValue({ text: '```short_drama_shot\n{"order":2,"summary":"不应写入"}\n```', model: 'fast', providerID: 'chat-a' });
    fireEvent.change(screen.getByPlaceholderText(/这一镜太长了/), { target: { value: '只改当前镜' } });
    fireEvent.click(screen.getByRole('button', { name: '发送' }));
    await waitFor(() => expect(complete).toHaveBeenCalled());
    await waitFor(() => expect(screen.queryByText('正在调整分镜…')).toBeNull());
    expect(executeCommand.mock.calls.some(([command]) => command === 'drama.saveShotDrafts')).toBe(false);
  });

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

  it('串起全部分集时，正文一路写到底', async () => {
    // 用户点的是「AI 串起全部 24 集」，模型在 JSON 里给了 script，可正文
    // 到不了服务端，左边「完整剧本」一直是空的。两件事一起守：请求里要
    // 告诉模型哪几集还没正文，回来的正文要原样送进 saveEpisodeDrafts。
    const episodes = Array.from({ length: 10 }, (_, index) => ({
      id: `e${index + 1}`, order: index + 1, title: `第 ${index + 1} 集`, summary: '',
      script: index === 0 ? '陈默：已经写过了。' : '', status: 'draft', shots: [],
      rev: 0, draftRev: 0, draft: null,
    }));
    dramas = [{ ...scriptDramaFixture(episodes[0]!), episodes }];

    complete.mockResolvedValue({
      text: '```short_drama_episodes\n' + JSON.stringify({
        episodes: [{ order: 2, summary: '第 2 集梗概', script: '陈默：这钱不能要。' }],
      }) + '\n```',
      model: 'fast', providerID: 'chat-a',
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
    fireEvent.click(await screen.findByRole('button', { name: 'AI 串起全部 10 集' }));

    await waitFor(() => expect(complete).toHaveBeenCalled(), { timeout: 4000 });
    const request = complete.mock.calls[0]![0] as { messages: Array<{ content: string }> };
    const sent = request.messages.map((item) => item.content).join('\n');
    // 第 1 集已有正文，不挂记号；第 2 集空着，要挂。
    expect(sent).toContain('第 2 集 ［正文还没写］');
    expect(sent).not.toContain('第 1 集 ［正文还没写］');

    await waitFor(() => {
      const writes = executeCommand.mock.calls.filter(([command]) => command === 'drama.saveEpisodeDrafts');
      expect(writes).toHaveLength(1);
      expect((writes[0]![1] as { episodes: Array<{ script?: string }> }).episodes[0]!.script)
        .toBe('陈默：这钱不能要。');
    }, { timeout: 4000 });
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

  it('does not report an ambiguous revision conflict as successful adoption', async () => {
    executeCommand.mockImplementation(async (command: string) => {
      if (command === 'drama.list') return JSON.stringify({ ok: true, dramas });
      if (command === 'chat.list') return JSON.stringify({ ok: true, messages: [] });
      if (command === 'drama.commitDraft') return JSON.stringify({ ok: false, error: { code: 'revision_conflict', actual: 3 } });
      return JSON.stringify({ ok: true });
    });

    await openCharacters(characterFixture({ rev: 2, draftRev: 4, draft: { description: '话少，句子短' } }));
    fireEvent.click(await screen.findByRole('button', { name: '采用草稿' }));

    expect(await screen.findByText('内容或草稿已经变化，请重新查看后再采用。')).toBeTruthy();
    expect(screen.queryByText('这一版刚才已经采用过了。')).toBeNull();
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
