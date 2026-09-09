import type { CharacterDraft, Drama, DramaPlan, ProviderEntry } from './types';

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

/// 从一段文字里切出第一个**括号配平**的 JSON 对象。
///
/// 早先是 `indexOf('{')` 到 `lastIndexOf('}')`。模型只要在 JSON 前后写一句
/// 解释而那句话里带了花括号，或者末尾又补了一段说明，切出来的片段就不是
/// 合法 JSON，整轮策划直接判失败。字符串内的括号和转义要跳过，否则
/// 剧名里一个「{」就能把配平算歪。
export function firstBalancedObject(text: string): { json: string; truncated: boolean } | null {
  const start = text.indexOf('{');
  if (start < 0) return null;
  let depth = 0;
  let inString = false;
  let escaped = false;
  for (let index = start; index < text.length; index += 1) {
    const character = text[index];
    if (escaped) { escaped = false; continue; }
    if (character === '\\') { escaped = true; continue; }
    if (character === '"') { inString = !inString; continue; }
    if (inString) continue;
    if (character === '{') depth += 1;
    else if (character === '}') {
      depth -= 1;
      if (depth === 0) return { json: text.slice(start, index + 1), truncated: false };
    }
  }
  // 有开头没配平的结尾，基本就是输出被截断了。
  return { json: text.slice(start), truncated: true };
}

/// 候选片段，按可信度从高到低：约定的围栏、任意带语言标记的围栏、裸围栏、
/// 整段原文。模型把 ```short_drama_plan 写成 ```json 的概率不低，而系统
/// 提示词里那句「```short_drama_plan JSON```」本身就在诱导它这么写。
export function planCandidates(raw: string): string[] {
  const candidates: string[] = [];
  const named = raw.match(/```[ \t]*short_drama_plan[^\n]*\n([\s\S]*?)```/i);
  if (named?.[1]) candidates.push(named[1]);
  const fenced = raw.matchAll(/```[^\n]*\n([\s\S]*?)```/g);
  for (const match of fenced) if (match[1]) candidates.push(match[1]);
  const unterminated = raw.match(/```[^\n]*\n([\s\S]*)$/);
  if (unterminated?.[1]) candidates.push(unterminated[1]);
  candidates.push(raw);
  return candidates;
}

export type PlanFailure = 'no_json' | 'malformed_json' | 'truncated' | 'missing_title';
export type PlanParse = { ok: true; plan: DramaPlan } | { ok: false; reason: PlanFailure };

function normalizePlan(value: Partial<DramaPlan>): DramaPlan | null {
  if (!value.title?.trim()) return null;
  return {
    title: value.title.trim(), genre: value.genre?.trim() || '', format: value.format?.trim() || '',
    episodeCount: Math.min(100, Math.max(1, Number(value.episodeCount) || 12)),
    episodeDurationSeconds: Math.min(600, Math.max(15, Number(value.episodeDurationSeconds) || 90)),
    logline: value.logline?.trim() || '', coreConflict: value.coreConflict?.trim() || '',
    audience: value.audience?.trim() || '', tone: value.tone?.trim() || '', arc: value.arc?.trim() || '',
    episodes: Array.isArray(value.episodes) ? value.episodes : [],
  };
}

/// 带原因的解析。失败原因要能区分开：截断该建议减少集数，格式错该让模型
/// 重发，缺标题是内容问题。一句「没有有效数据块」把三种都盖住了，用户
/// 只能反复重试同一件必然失败的事。
export function parsePlanWithReason(raw: string): PlanParse {
  let sawJSON = false;
  let sawTruncation = false;
  for (const candidate of planCandidates(raw)) {
    const found = firstBalancedObject(candidate);
    if (!found) continue;
    sawJSON = true;
    if (found.truncated) { sawTruncation = true; continue; }
    let parsed: Partial<DramaPlan> | null = null;
    try {
      parsed = JSON.parse(found.json) as Partial<DramaPlan>;
    } catch {
      continue;
    }
    const plan = normalizePlan(parsed);
    if (plan) return { ok: true, plan };
    return { ok: false, reason: 'missing_title' };
  }
  if (sawTruncation) return { ok: false, reason: 'truncated' };
  return { ok: false, reason: sawJSON ? 'malformed_json' : 'no_json' };
}

export function parseDramaPlan(raw: string): DramaPlan | null {
  const result = parsePlanWithReason(raw);
  return result.ok ? result.plan : null;
}

/// 宿主对一次请求的硬上限：24 条消息、合计 32000 字符，system 也算在内。
/// 撞上不是截断而是整条请求被拒，所以发之前先自己数一遍。
export const HOST_MESSAGE_LIMIT = 24;
export const HOST_CHARACTER_LIMIT = 32_000;

export function requestBudget(system: string, messages: Array<{ content: string }>): { characters: number; messages: number; withinLimits: boolean } {
  const characters = messages.reduce((total, item) => total + item.content.length, system.length);
  const count = messages.length + 1;
  return { characters, messages: count, withinLimits: characters <= HOST_CHARACTER_LIMIT && count <= HOST_MESSAGE_LIMIT };
}

/// 每个阶段一个围栏名。没有围栏就是模型在正常说话或反问，不该动草稿；
/// 有围栏才当成结构化产出。
export type FencedResult<T> = { kind: 'chat' } | { kind: 'draft'; value: T; note: string } | { kind: 'invalid'; note: string };

/// 只认第一个围栏。模型偶尔会把同一份内容重发一遍，认最后一个会让
/// 「改了又改回去」这种输出以后一个为准，用户看到的却是前一个。
export function extractFenced(raw: string, fence: string): { body: string; note: string } | null {
  const pattern = new RegExp('```' + fence + '\\s*([\\s\\S]*?)```', 'i');
  const match = raw.match(pattern);
  if (!match) return null;
  return { body: match[1] ?? '', note: (raw.slice(0, match.index ?? 0) + raw.slice((match.index ?? 0) + match[0].length)).trim() };
}

function firstJSONObject(body: string): unknown {
  const start = body.indexOf('{');
  const end = body.lastIndexOf('}');
  if (start < 0 || end <= start) return null;
  return JSON.parse(body.slice(start, end + 1));
}

/// 围栏内的 JSON 解析加白名单裁剪。白名单在这里而不是靠提示词：模型返回
/// 整个对象，表外的键一律丢掉，它就改不动 id、候选图和身份版本。
export function parseFencedDraft<T extends object>(raw: string, fence: string, allowed: Array<keyof T & string>): FencedResult<T> {
  const found = extractFenced(raw, fence);
  if (!found) return { kind: 'chat' };
  try {
    const value = firstJSONObject(found.body);
    if (!value || typeof value !== 'object') return { kind: 'invalid', note: found.note };
    const picked: Record<string, unknown> = {};
    for (const key of allowed) {
      const entry = (value as Record<string, unknown>)[key];
      if (typeof entry === 'string' && entry.trim()) picked[key] = entry.trim();
    }
    if (Object.keys(picked).length === 0) return { kind: 'invalid', note: found.note };
    return { kind: 'draft', value: picked as T, note: found.note };
  } catch {
    return { kind: 'invalid', note: found.note };
  }
}

export const CHARACTER_DRAFT_FIELDS: Array<keyof CharacterDraft & string> = ['name', 'description', 'visualPrompt'];

/// 流式增量里围栏一开始，后面就全是 JSON 了。直接刷给用户看是一屏大括号，
/// 所以从围栏开头起换成占位，只把围栏之前的说明文字显示出来。
export function visibleStream(buffer: string, fence: string): { text: string; structured: boolean } {
  const marker = buffer.indexOf('```' + fence);
  const loose = marker < 0 ? buffer.indexOf('```') : marker;
  if (loose < 0) return { text: buffer, structured: false };
  return { text: buffer.slice(0, loose).trim(), structured: true };
}
