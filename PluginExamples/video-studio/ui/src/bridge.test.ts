import { afterEach, describe, expect, it, vi } from 'vitest';
import { CHARACTER_DRAFT_FIELDS, callCommand, loadDramas, parseDramaPlan, parseFencedDraft, requestBudget, visibleStream } from './bridge';
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
