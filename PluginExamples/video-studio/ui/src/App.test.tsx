import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import App, { skillQueryAt } from './App';

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

  it('offers every configured model in the picker', async () => {
    render(<App />);
    fireEvent.click((await screen.findAllByRole('button', { name: '策划新短剧' }))[0]!);
    const picker = await screen.findByLabelText('聊天模型');
    const options = Array.from(picker.querySelectorAll('option')).map((item) => item.textContent);
    expect(options).toEqual(['fast', 'pro', 'fast-alt', 'pro-alt']);
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
