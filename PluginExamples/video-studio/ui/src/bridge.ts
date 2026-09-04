import type { Drama, DramaPlan, ProviderEntry } from './types';

/// 宿主的 executeCommand 对 mcpTool 类命令回的是**完整的 MCP result**，
/// 形如 {"content":[{"type":"text","text":"{\"ok\":true,…}"}]}，工具真正的
/// 载荷在 content 里那条 text 上再包了一层 JSON。直接把外层当业务对象用，
/// payload.ok 永远是 undefined，于是每个命令都会被当成失败。
function unwrapCommandResult(value: unknown): unknown {
  if (!value || typeof value !== 'object') return value;
  const content = (value as { content?: unknown }).content;
  if (!Array.isArray(content)) return value;
  const entry = content.find((item) => typeof item === 'object' && item !== null && (item as { type?: unknown }).type === 'text');
  const text = (entry as { text?: unknown } | undefined)?.text;
  if (typeof text !== 'string') return value;
  try {
    return JSON.parse(text);
  } catch {
    // 不是 JSON 的工具输出就把外层原样交出去，别把内容吞掉。
    return value;
  }
}

export async function callCommand<T>(command: string, argumentsValue: Record<string, unknown> = {}): Promise<T> {
  const bridge = window.willdeep;
  if (!bridge) throw new Error('willdeep_bridge_unavailable');
  const raw = await bridge.executeCommand(command, argumentsValue);
  if (!raw) throw new Error('empty_command_response');
  return unwrapCommandResult(JSON.parse(raw)) as T;
}

export async function loadDramas(): Promise<Drama[]> {
  const payload = await callCommand<{ ok: boolean; dramas?: Drama[]; error?: { message?: string } }>('drama.list');
  if (!payload.ok) throw new Error(payload.error?.message || 'list_failed');
  return payload.dramas ?? [];
}

export async function loadProviders(): Promise<ProviderEntry[]> {
  return (await window.willdeep?.ai?.providers())?.providers ?? [];
}

export function parseDramaPlan(raw: string): DramaPlan | null {
  const block = raw.match(/```short_drama_plan\s*([\s\S]*?)```/i)?.[1] ?? raw;
  const start = block.indexOf('{');
  const end = block.lastIndexOf('}');
  if (start < 0 || end <= start) return null;
  try {
    const value = JSON.parse(block.slice(start, end + 1)) as Partial<DramaPlan>;
    if (!value.title?.trim()) return null;
    return {
      title: value.title.trim(), genre: value.genre?.trim() || '', format: value.format?.trim() || '',
      episodeCount: Math.min(100, Math.max(1, Number(value.episodeCount) || 12)),
      episodeDurationSeconds: Math.min(600, Math.max(15, Number(value.episodeDurationSeconds) || 90)),
      logline: value.logline?.trim() || '', coreConflict: value.coreConflict?.trim() || '',
      audience: value.audience?.trim() || '', tone: value.tone?.trim() || '', arc: value.arc?.trim() || '',
      episodes: Array.isArray(value.episodes) ? value.episodes : [],
    };
  } catch { return null; }
}
