import { afterEach, describe, expect, it, vi } from 'vitest';
import { CHARACTER_DRAFT_FIELDS, IMAGE_CONCURRENCY, IMAGE_MIN_INTERVAL_MS, NOTICE_LIMIT, applyPassage, appendNotice, mapWithConcurrency, callCommand, detectUnknownCharacters, firstBalancedObject, loadDramas, parseDramaPlan, parseFencedDraft, parseFencedPassage, parsePlanWithReason, passageContext, relativeTime, requestBudget, streamingFieldValue, visibleStream } from './bridge';
import type { Notice } from './bridge';
import type { CharacterDraft } from './types';

describe('parseDramaPlan', () => {
  it('accepts the short_drama_plan fenced contract', () => {
    const raw = '```short_drama_plan\n{"title":"错时来信","episodeCount":8,"episodeDurationSeconds":80,"logline":"来自未来的短信"}\n```';
    expect(parseDramaPlan(raw)).toMatchObject({ title: '错时来信', episodeCount: 8, episodeDurationSeconds: 80 });
  });

  it('rejects prose and plans without a title', () => {
    expect(parseDramaPlan('just prose')).toBeNull();
    expect(parseDramaPlan('{"genre":"悬疑"}')).toBeNull();
  });
});

describe('callCommand', () => {
  afterEach(() => { delete window.willdeep; });

  function host(raw: string | undefined) {
    const executeCommand = vi.fn().mockResolvedValue(raw);
    window.willdeep = { getContext: () => ({}), executeCommand } as unknown as Window['willdeep'];
    return executeCommand;
  }

  // 宿主对 mcpTool 命令回的是完整 MCP result，业务载荷在 content 的 text 里
  // 又包了一层 JSON。不解包的话 payload.ok 永远是 undefined，每个命令都会被
  // 当成失败——安装到真机后「读取短剧列表失败」就是这么来的。
  it('unwraps the MCP result envelope', async () => {
    host(JSON.stringify({ content: [{ type: 'text', text: '{"ok":true,"dramas":[]}' }] }));
    expect(await callCommand('drama.list')).toEqual({ ok: true, dramas: [] });
    expect(await loadDramas()).toEqual([]);
  });

  it('keeps a payload that is already unwrapped', async () => {
    host(JSON.stringify({ ok: true, dramas: [{ id: 'd1' }] }));
    expect(await callCommand('drama.list')).toEqual({ ok: true, dramas: [{ id: 'd1' }] });
  });

  it('hands back the envelope when the tool text is not JSON', async () => {
    host(JSON.stringify({ content: [{ type: 'text', text: 'plain output' }] }));
    expect(await callCommand('video.reveal_output')).toEqual({ content: [{ type: 'text', text: 'plain output' }] });
  });

  it('still surfaces a failing payload as an error', async () => {
    host(JSON.stringify({ content: [{ type: 'text', text: '{"ok":false,"error":{"code":"not_found","message":"gone"}}' }] }));
    await expect(loadDramas()).rejects.toThrow('gone');
  });

  it('reports a missing bridge and an empty response by key', async () => {
    delete window.willdeep;
    await expect(callCommand('drama.list')).rejects.toThrow('willdeep_bridge_unavailable');
    host(undefined);
    await expect(callCommand('drama.list')).rejects.toThrow('empty_command_response');
  });
});

describe('parseFencedDraft', () => {
  const parse = (raw: string) => parseFencedDraft<CharacterDraft>(raw, 'short_drama_character', CHARACTER_DRAFT_FIELDS);

  it('treats a reply without a fence as ordinary chat', () => {
    expect(parse('你想让她冷到什么程度？')).toEqual({ kind: 'chat' });
  });

  it('keeps the prose outside the fence as the assistant note', () => {
    const result = parse('收紧了性格。\n```short_drama_character\n{"description":"话少"}\n```');
    expect(result).toMatchObject({ kind: 'draft', value: { description: '话少' }, note: '收紧了性格。' });
  });

  it('drops fields outside the whitelist so the model cannot rewrite ids', () => {
    const result = parse('```short_drama_character\n{"id":"hijack","identityVersion":9,"name":"林晚"}\n```');
    expect(result).toEqual({ kind: 'draft', value: { name: '林晚' }, note: '' });
  });

  it('reports malformed JSON instead of silently discarding the turn', () => {
    expect(parse('```short_drama_character\n{"description": 断了\n```')).toMatchObject({ kind: 'invalid' });
  });

  it('reports a fence that carries nothing usable', () => {
    expect(parse('```short_drama_character\n{"unrelated":"x"}\n```')).toMatchObject({ kind: 'invalid' });
  });

  it('honours only the first fence when the model repeats itself', () => {
    const raw = '```short_drama_character\n{"name":"第一版"}\n```\n```short_drama_character\n{"name":"第二版"}\n```';
    expect(parse(raw)).toMatchObject({ kind: 'draft', value: { name: '第一版' } });
  });
});

describe('requestBudget', () => {
  it('counts the system prompt against the host character limit', () => {
    const budget = requestBudget('x'.repeat(31_990), [{ content: 'y'.repeat(20) }]);
    expect(budget.characters).toBe(32_010);
    expect(budget.withinLimits).toBe(false);
  });

  it('counts the system prompt as one of the 24 messages', () => {
    const messages = Array.from({ length: 24 }, () => ({ content: 'x' }));
    expect(requestBudget('s', messages).withinLimits).toBe(false);
    expect(requestBudget('s', messages.slice(1)).withinLimits).toBe(true);
  });
});

describe('visibleStream', () => {
  it('shows prose while nothing structured has started', () => {
    expect(visibleStream('正在想…', 'short_drama_character')).toEqual({ text: '正在想…', structured: false });
  });

  it('hides the JSON body once the fence opens', () => {
    const result = visibleStream('收紧了性格。\n```short_drama_character\n{"desc', 'short_drama_character');
    expect(result).toEqual({ text: '收紧了性格。', structured: true });
  });

  it('hides a partial fence marker too, so no stray backticks flash', () => {
    expect(visibleStream('好的\n```', 'short_drama_character')).toEqual({ text: '好的', structured: true });
  });
});

describe('parsePlanWithReason', () => {
  const plan = '{"title":"错时来信","episodeCount":8}';

  it('survives prose that itself contains braces', () => {
    const raw = `我先说下思路：主角收到的短信格式像 {sender, body}。\n\`\`\`short_drama_plan\n${plan}\n\`\`\``;
    expect(parsePlanWithReason(raw)).toMatchObject({ ok: true, plan: { title: '错时来信' } });
  });

  it('accepts a json fence when the model ignores the agreed tag', () => {
    expect(parsePlanWithReason('```json\n' + plan + '\n```')).toMatchObject({ ok: true });
  });

  it('accepts a bare fence with no language tag', () => {
    expect(parsePlanWithReason('```\n' + plan + '\n```')).toMatchObject({ ok: true });
  });

  it('accepts the tag the old prompt invited, short_drama_plan JSON', () => {
    expect(parsePlanWithReason('```short_drama_plan JSON\n' + plan + '\n```')).toMatchObject({ ok: true });
  });

  it('ignores trailing prose after the object', () => {
    expect(parsePlanWithReason(plan + '\n\n还需要我细化第 3 集吗？{可以}')).toMatchObject({ ok: true });
  });

  it('reports a cut-off reply as truncated rather than malformed', () => {
    const raw = '```short_drama_plan\n{"title":"错时来信","episodes":[{"title":"第 1 集","summary":"开场';
    expect(parsePlanWithReason(raw)).toEqual({ ok: false, reason: 'truncated' });
  });

  it('reports a reply with no object at all', () => {
    expect(parsePlanWithReason('你想要几集？先说下受众。')).toEqual({ ok: false, reason: 'no_json' });
  });

  it('reports a malformed object separately from a missing one', () => {
    expect(parsePlanWithReason('```short_drama_plan\n{"title": 断了,}\n```')).toEqual({ ok: false, reason: 'malformed_json' });
  });

  it('reports an empty title instead of pretending the plan parsed', () => {
    expect(parsePlanWithReason('{"title":"   ","genre":"悬疑"}')).toEqual({ ok: false, reason: 'missing_title' });
  });

  it('keeps parseDramaPlan as the nullable wrapper', () => {
    expect(parseDramaPlan('nope')).toBeNull();
    expect(parseDramaPlan(plan)).toMatchObject({ title: '错时来信' });
  });
});

describe('firstBalancedObject', () => {
  it('skips braces that live inside strings', () => {
    const found = firstBalancedObject('{"title":"带 { 的剧名","genre":"悬疑"}');
    expect(found).toMatchObject({ truncated: false });
    expect(JSON.parse(found!.json)).toMatchObject({ title: '带 { 的剧名' });
  });

  it('is not fooled by an escaped quote before a brace', () => {
    const found = firstBalancedObject('{"title":"引号\\"与 }","x":1}');
    expect(found?.truncated).toBe(false);
    expect(JSON.parse(found!.json)).toMatchObject({ x: 1 });
  });

  it('flags an unbalanced object as truncated', () => {
    expect(firstBalancedObject('{"title":"半截')).toMatchObject({ truncated: true });
  });
});

describe('策划带出的角色骨架', () => {
  it('解析 characters 数组', () => {
    const raw = '```short_drama_plan\n{"title":"错时来信","characters":[{"name":"林晚","role":"夜班护士"},{"name":"周野","role":"落魄程序员"}]}\n```';
    const parsed = parsePlanWithReason(raw);
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;
    expect(parsed.plan.characters).toHaveLength(2);
    expect(parsed.plan.characters?.[0]).toMatchObject({ name: '林晚', role: '夜班护士' });
  });

  it('没给 characters 时是空数组而不是 undefined', () => {
    const parsed = parsePlanWithReason('{"title":"错时来信"}');
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;
    // 落库那边直接遍历这个字段，undefined 会让确认策划整条崩掉。
    expect(parsed.plan.characters).toEqual([]);
  });

  it('characters 不是数组时也收敛成空数组', () => {
    const parsed = parsePlanWithReason('{"title":"错时来信","characters":"林晚、周野"}');
    expect(parsed.ok).toBe(true);
    if (!parsed.ok) return;
    expect(parsed.plan.characters).toEqual([]);
  });
});

describe('detectUnknownCharacters', () => {
  const script = [
    '内景 医院走廊 日',
    '林晚：你怎么又来了。',
    '周野：我收到一条三天后的短信。',
    '护士：请把手机关掉。',
    '林晚：那不可能。',
    '周野：你看这个时间戳。',
    '路人：让一让。',
    '陈医生：谁是家属？',
  ].join('\n');

  it('找出剧本里出现两次以上的新名字', () => {
    expect(detectUnknownCharacters(script, [])).toEqual(['林晚', '周野']);
  });

  it('已经在角色表里的不再报', () => {
    expect(detectUnknownCharacters(script, ['林晚'])).toEqual(['周野']);
    expect(detectUnknownCharacters(script, ['林晚', '周野'])).toEqual([]);
  });

  it('只说一句话的人不算角色', () => {
    // 这条挡掉的比别的规则加起来都多。自动把它们建成角色，角色表就成了
    // 一堆只有名字的空壳。
    expect(detectUnknownCharacters(script, [])).not.toContain('陈医生');
  });

  it('功能性称谓不算角色', () => {
    const repeated = '护士：一句。\n护士：又一句。\n路人：一句。\n路人：又一句。';
    expect(detectUnknownCharacters(repeated, [])).toEqual([]);
  });

  it('场景标记与旁白不算角色', () => {
    const marked = '内景：医院走廊。\n内景：病房。\n旁白：三天后。\n旁白：她并不知道。';
    expect(detectUnknownCharacters(marked, [])).toEqual([]);
  });

  it('冒号后没有台词的标题行不算', () => {
    expect(detectUnknownCharacters('第一场：\n第二场：\n第三场：', [])).toEqual([]);
  });

  it('名字太长或带标点的行不算', () => {
    const noisy = '他缓缓抬起头说：这不可能。\n他缓缓抬起头说：真的。\n2026：一年。\n2026：又一年。';
    expect(detectUnknownCharacters(noisy, [])).toEqual([]);
  });

  it('按出现次数从多到少排', () => {
    const ordered = '周野：一。\n周野：二。\n周野：三。\n林晚：一。\n林晚：二。';
    expect(detectUnknownCharacters(ordered, [])).toEqual(['周野', '林晚']);
  });

  it('英文名字也认', () => {
    expect(detectUnknownCharacters('Alex: one.\nAlex: two.', [])).toEqual(['Alex']);
  });
});

describe('局部改一段', () => {
  it('解析片段替换', () => {
    const raw = '收紧了这三句。\n```short_drama_passage\n{"replacement":"林晚：你走。"}\n```';
    expect(parseFencedPassage(raw)).toMatchObject({
      kind: 'draft', value: { replacement: '林晚：你走。' }, note: '收紧了这三句。',
    });
  });

  it('没有围栏时当闲聊', () => {
    expect(parseFencedPassage('你想让这段更冷还是更急？')).toEqual({ kind: 'chat' });
  });

  it('空替换算格式错，不当成删除', () => {
    // 模型返回空串时若照着替换，用户选中的那段就凭空消失了。
    expect(parseFencedPassage('```short_drama_passage\n{"replacement":"   "}\n```')).toMatchObject({ kind: 'invalid' });
    expect(parseFencedPassage('```short_drama_passage\n{}\n```')).toMatchObject({ kind: 'invalid' });
  });

  it('上下文只取选区前后各一小段，不是全篇', () => {
    const script = 'A'.repeat(1000) + '选中的这段' + 'B'.repeat(1000);
    const context = passageContext(script, 1000, 1005, 100);
    expect(context.selection).toBe('选中的这段');
    expect(context.before).toHaveLength(100);
    expect(context.after).toHaveLength(100);
  });

  it('按位置替换，不按内容搜索', () => {
    // 同一句台词在一集里出现两次很常见，按内容替换会改错那一处。
    const script = '林晚：你走。\n周野：别走。\n林晚：你走。';
    const replaced = applyPassage(script, script.lastIndexOf('林晚：你走。'), script.length, '林晚：留下。');
    expect(replaced).toBe('林晚：你走。\n周野：别走。\n林晚：留下。');
  });

  it('越界的选区被夹回正文范围内', () => {
    expect(applyPassage('短正文', -5, 999, '新的')).toBe('新的');
    expect(passageContext('短正文', 999, 1000).selection).toBe('');
  });
});

describe('streamingFieldValue', () => {
  it('从没写完的 JSON 里取出已到达的正文', () => {
    const buffer = '```short_drama_episode\n{"title":"第 1 集","script":"林晚：你怎么又来了。\\n周野：我收';
    expect(streamingFieldValue(buffer, 'script')).toBe('林晚：你怎么又来了。\n周野：我收');
  });

  it('字段写完后停在收尾引号，不吃掉后面的键名', () => {
    const buffer = '{"script":"完整台词。","summary":"梗概"}';
    expect(streamingFieldValue(buffer, 'script')).toBe('完整台词。');
  });

  it('转义序列被切在数据块中间时先不显示它', () => {
    // 半个转义直接显示会冒出一个字面反斜杠，下一块到了自然就完整了。
    expect(streamingFieldValue('{"script":"第一行\\', 'script')).toBe('第一行');
  });

  it('还原换行与制表，不显示字面的反斜杠 n', () => {
    expect(streamingFieldValue('{"script":"甲：一。\\n乙：二。"}', 'script')).toBe('甲：一。\n乙：二。');
    expect(streamingFieldValue('{"script":"甲\\t乙"}', 'script')).toBe('甲\t乙');
  });

  it('还原转义的引号', () => {
    expect(streamingFieldValue('{"script":"他说\\"走\\""}', 'script')).toBe('他说"走"');
  });

  it('字段还没出现时返回 null', () => {
    expect(streamingFieldValue('```short_drama_episode\n{"title":"第 1 集"', 'script')).toBeNull();
    expect(streamingFieldValue('我先想一下这一集怎么写。', 'script')).toBeNull();
  });

  it('unicode 转义要等四位十六进制到齐', () => {
    expect(streamingFieldValue('{"script":"\\u674e', 'script')).toBe('李');
    expect(streamingFieldValue('{"script":"甲\\u67', 'script')).toBe('甲');
  });
});

describe('visibleStream 显示正在生成的字段', () => {
  it('正文一到就显示正文，而不是占位', () => {
    const buffer = '```short_drama_episode\n{"script":"林晚：你怎么又来了。';
    expect(visibleStream(buffer, 'short_drama_episode', ['script'])).toEqual({
      text: '林晚：你怎么又来了。', structured: false,
    });
  });

  it('围栏开了但正文还没到，仍然报结构化占位', () => {
    const buffer = '好的。\n```short_drama_episode\n{"title":"第 1 集"';
    expect(visibleStream(buffer, 'short_drama_episode', ['script'])).toEqual({
      text: '好的。', structured: true,
    });
  });

  it('按给定顺序挑第一个有内容的字段', () => {
    const buffer = '{"summary":"她收到短信","script":""}';
    expect(visibleStream(buffer, 'short_drama_episode', ['script', 'summary']).text).toBe('她收到短信');
  });

  it('不给字段名时行为和以前一致', () => {
    expect(visibleStream('好的\n```', 'short_drama_episode')).toEqual({ text: '好的', structured: true });
    expect(visibleStream('正在想…', 'short_drama_episode')).toEqual({ text: '正在想…', structured: false });
  });
});

describe('提示消息队列', () => {
  const make = (n: number): Notice => ({ id: `n${n}`, text: `第 ${n} 条`, kind: 'info', createdAt: n });

  it('最多留十条，超出丢最旧的', () => {
    let queue: Notice[] = [];
    for (let i = 1; i <= 14; i += 1) queue = appendNotice(queue, make(i));
    expect(queue).toHaveLength(NOTICE_LIMIT);
    // 丢的是最旧的，留下的是最近十条，顺序仍然从旧到新。
    expect(queue[0]!.text).toBe('第 5 条');
    expect(queue.at(-1)!.text).toBe('第 14 条');
  });

  it('空文本不进队列', () => {
    // 早先 setNotice('') 用来清掉提示，改成队列后那种调用不该塞进一条空提示。
    const queue = appendNotice([], { id: 'x', text: '   ', kind: 'info', createdAt: 0 });
    expect(queue).toHaveLength(1);
  });
});

describe('relativeTime', () => {
  const base = 1_000_000_000_000;
  it('三秒内是刚刚', () => {
    expect(relativeTime(base, base, 'zh-Hans')).toBe('刚刚');
    expect(relativeTime(base, base + 2_000, 'zh-Hans')).toBe('刚刚');
    expect(relativeTime(base, base + 2_000, 'en')).toBe('just now');
  });

  it('秒、分钟、小时、天逐级切换', () => {
    expect(relativeTime(base, base + 3_000, 'zh-Hans')).toBe('3 秒前');
    expect(relativeTime(base, base + 59_000, 'zh-Hans')).toBe('59 秒前');
    expect(relativeTime(base, base + 60_000, 'zh-Hans')).toBe('1 分钟前');
    expect(relativeTime(base, base + 3_600_000, 'zh-Hans')).toBe('1 小时前');
    expect(relativeTime(base, base + 86_400_000, 'zh-Hans')).toBe('1 天前');
  });

  it('英文用紧凑写法', () => {
    expect(relativeTime(base, base + 5_000, 'en')).toBe('5s ago');
    expect(relativeTime(base, base + 120_000, 'en')).toBe('2m ago');
  });

  it('时钟回拨不显示负数', () => {
    // 系统时间被调回去过，或者两个时间源有偏差。显示「负三秒前」比显示
    // 「刚刚」更让人困惑。
    expect(relativeTime(base, base - 5_000, 'zh-Hans')).toBe('刚刚');
  });
});

describe('mapWithConcurrency', () => {
  it('同一时刻在跑的任务不超过上限', async () => {
    // 这条是 502 那个 bug 的核心：四张图一次全发出去，网关回
    // `relay: upstream / bad_gateway`，成功一张其余全挂。
    let running = 0;
    let peak = 0;
    await mapWithConcurrency([1, 2, 3, 4, 5, 6], 2, async () => {
      running += 1;
      peak = Math.max(peak, running);
      await new Promise((resolve) => setTimeout(resolve, 5));
      running -= 1;
    });
    expect(peak).toBe(2);
  });

  it('结果保持输入顺序', async () => {
    // 顺序错了，候选图的编号和提示词的 variation 就对不上。
    const settled = await mapWithConcurrency([30, 10, 20], 2, async (ms) => {
      await new Promise((resolve) => setTimeout(resolve, ms / 10));
      return ms;
    });
    expect(settled.map((entry) => (entry.status === 'fulfilled' ? entry.value : null))).toEqual([30, 10, 20]);
  });

  it('一个失败不拖累其余，已经付过费的那几张要交出来', async () => {
    const settled = await mapWithConcurrency([1, 2, 3, 4], 2, async (n) => {
      if (n % 2 === 0) throw new Error(`HTTP 502 on ${n}`);
      return n;
    });
    expect(settled.filter((entry) => entry.status === 'fulfilled')).toHaveLength(2);
    expect(settled.filter((entry) => entry.status === 'rejected')).toHaveLength(2);
    expect(settled[1]!.status === 'rejected' && String(settled[1]!.reason)).toContain('502');
  });

  it('任务比上限少时不白开 worker，空输入直接返回', async () => {
    let calls = 0;
    const one = await mapWithConcurrency([7], 4, async (n) => { calls += 1; return n; });
    expect(one).toHaveLength(1);
    expect(calls).toBe(1);
    expect(await mapWithConcurrency([], 4, async () => 0)).toEqual([]);
  });

  it('图片并发上限是两路', () => {
    // 串行太慢（用户以为卡住），全并发打爆上游。两路是折中。
    expect(IMAGE_CONCURRENCY).toBe(2);
  });
});

describe('生图节流', () => {
  it('相邻两次启动之间隔开最小间隔', async () => {
    // 只限并发数不够：两路并发时那两个请求几乎同时出发，瞬时压力仍是 2。
    // 这里用假 sleep 记账，不真等。断言的是等待总量而不是每次的起始时刻：
    // 假 sleep 会同步推进时钟，谁先读到那个值取决于微任务调度，那不是
    // 节流要保证的东西。
    const waits: number[] = [];
    let clock = 0;
    const sleep = async (ms: number) => { waits.push(ms); clock += ms; };
    const realNow = Date.now;
    Date.now = () => clock;
    try {
      await mapWithConcurrency([1, 2, 3, 4], 2, async (n) => n, { minIntervalMs: 1000, sleep });
    } finally {
      Date.now = realNow;
    }
    // 四个任务、三个间隔：第一个立即发，其后每个都等满一整个间隔。
    expect(waits).toHaveLength(3);
    expect(waits.reduce((sum, ms) => sum + ms, 0)).toBe(3000);
    expect(waits.every((ms) => ms === 1000)).toBe(true);
  });

  it('间隔为零时不引入任何等待', async () => {
    const waits: number[] = [];
    await mapWithConcurrency([1, 2], 2, async (n) => n, {
      minIntervalMs: 0,
      sleep: async (ms) => { waits.push(ms); },
    });
    expect(waits).toEqual([]);
  });

  it('节流不改变结果顺序，也不吞失败', async () => {
    const settled = await mapWithConcurrency([1, 2, 3], 2, async (n) => {
      if (n === 2) throw new Error('502');
      return n;
    }, { minIntervalMs: 5 });
    expect(settled.map((e) => e.status)).toEqual(['fulfilled', 'rejected', 'fulfilled']);
    expect(settled[2]!.status === 'fulfilled' && settled[2]!.value).toBe(3);
  });

  it('默认间隔是一秒', () => {
    // 相对十几秒的生成时间，一秒几乎不影响总耗时，但足以把一簇请求摊开。
    expect(IMAGE_MIN_INTERVAL_MS).toBe(1000);
  });
});
