import { afterEach, describe, expect, it, vi } from 'vitest';
import { callCommand, loadDramas, parseDramaPlan } from './bridge';

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
