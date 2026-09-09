import type { CharacterDraft, Drama, DramaPlan, EpisodeDraftFields, ProviderEntry } from './types';

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
    characters: Array.isArray(value.characters) ? value.characters : [],
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
export const EPISODE_DRAFT_FIELDS: Array<keyof EpisodeDraftFields & string> = ['title', 'summary', 'script'];

/// 从还没写完的流式 JSON 里抠出某个字段已经到达的部分。
///
/// 这几个阶段的模型几乎都是一上手就开围栏，后面全是 JSON。整段刷给用户是
/// 一屏转义序列，换成「正在生成…」的占位则是让人对着干等——一集剧本要写
/// 三十秒以上，能看着它一行行冒出来和干等是两种体验。
///
/// JSON 没闭合所以不能 `JSON.parse`，但字段值本身可以按位置取：找到
/// `"script":"` 之后一路读到还没出现的收尾引号，再把转义还原。反斜杠必须
/// 成对处理，否则正文里一个换行转义会被当成字面的反斜杠加 n 显示出来。
export function streamingFieldValue(buffer: string, field: string): string | null {
  const key = '"' + field + '"';
  const keyAt = buffer.lastIndexOf(key);
  if (keyAt < 0) return null;
  const colonAt = buffer.indexOf(':', keyAt + key.length);
  if (colonAt < 0) return null;
  const quoteAt = buffer.indexOf('"', colonAt + 1);
  if (quoteAt < 0) return null;

  let out = '';
  for (let index = quoteAt + 1; index < buffer.length; index += 1) {
    const character = buffer[index];
    if (character === '\\') {
      const next = buffer[index + 1];
      // 转义序列被切在两个数据块中间：这一轮先不显示它，下一轮就完整了。
      if (next === undefined) break;
      if (next === 'n') out += '\n';
      else if (next === 't') out += '\t';
      else if (next === 'r') out += '';
      else if (next === 'u') {
        const hex = buffer.slice(index + 2, index + 6);
        if (hex.length < 4) break;
        out += String.fromCharCode(parseInt(hex, 16));
        index += 4;
      } else out += next;
      index += 1;
      continue;
    }
    // 收尾引号：这个字段写完了。
    if (character === '"') break;
    out += character;
  }
  return out;
}

/// 流式该显示什么。
///
/// 优先显示正在生成的正文字段；还没到那一步就显示围栏之前的说明文字；
/// 都没有就交给调用方兜底。刻意不把 JSON 结构本身刷出来。
export function visibleStream(
  buffer: string,
  fence: string,
  fields: string[] = []
): { text: string; structured: boolean } {
  for (const field of fields) {
    const value = streamingFieldValue(buffer, field);
    if (value !== null && value.trim()) return { text: value, structured: false };
  }
  const marker = buffer.indexOf('```' + fence);
  const loose = marker < 0 ? buffer.indexOf('```') : marker;
  if (loose < 0) return { text: buffer, structured: false };
  return { text: buffer.slice(0, loose).trim(), structured: true };
}

/// 剧本里出现了角色表里没有的人。
///
/// 只认台词行首那个「名字：」的写法，这是剧本最稳定的结构特征。刻意**不**
/// 调模型：模型很乐意把「路人」「护士」「司机」都报成新角色，自动建会把
/// 角色表撑成一堆空壳，而这正是要避免的事。
///
/// 三道过滤，宁可漏不可滥：
/// 1. 名字长度 2 到 6 个字，且只含中文或字母——排掉「内景 日」这种场景标记
///    和把整句话写在冒号前的行。
/// 2. 功能性称谓直接丢：它们是职业不是角色。
/// 3. 至少出现两次。只说一句话的人几乎都是路人，这条挡掉的比前两条加起来还多。
const FUNCTIONAL_ROLES = new Set([
  '路人', '护士', '医生', '司机', '店员', '服务员', '保安', '警察', '快递员',
  '同事', '邻居', '老板', '客人', '乘客', '观众', '记者', '秘书', '助理',
  '男人', '女人', '男孩', '女孩', '老人', '孩子', '众人', '旁白', '画外音',
  '声音', '广播', '手机', '短信', '字幕', '镜头', '场景', '内景', '外景',
]);

export function detectUnknownCharacters(script: string, knownNames: string[]): string[] {
  const known = new Set(knownNames.map((name) => name.trim()).filter(Boolean));
  const counts = new Map<string, number>();
  for (const line of script.split(/\r?\n/)) {
    // 全角冒号和半角冒号都认；冒号后必须真的有台词，否则那是个标题行。
    const match = line.trim().match(/^([^\s:：]{2,6})[:：]\s*\S/);
    const name = match?.[1];
    if (!name) continue;
    if (known.has(name)) continue;
    if (FUNCTIONAL_ROLES.has(name)) continue;
    if (!/^[\u4e00-\u9fa5A-Za-z]+$/.test(name)) continue;
    counts.set(name, (counts.get(name) ?? 0) + 1);
  }
  return [...counts.entries()]
    .filter(([, count]) => count >= 2)
    .sort((left, right) => right[1] - left[1])
    .map(([name]) => name);
}

/// 只改正文里的一段。
///
/// 整集重出和改一段是两件事，用两个围栏分开：一集剧本几千字，为了改三句话
/// 让模型重写全篇，既贵又会顺手改掉用户满意的部分——而它会声称自己只改了
/// 那三句。片段替换把「改哪儿」交给用户的选区，模型只需要给出替换文本。
export const PASSAGE_FENCE = 'short_drama_passage';

export function parseFencedPassage(raw: string): FencedResult<{ replacement: string }> {
  const found = extractFenced(raw, PASSAGE_FENCE);
  if (!found) return { kind: 'chat' };
  try {
    const value = firstJSONObject(found.body);
    if (!value || typeof value !== 'object') return { kind: 'invalid', note: found.note };
    const replacement = (value as { replacement?: unknown }).replacement;
    if (typeof replacement !== 'string' || !replacement.trim()) {
      return { kind: 'invalid', note: found.note };
    }
    return { kind: 'draft', value: { replacement }, note: found.note };
  } catch {
    return { kind: 'invalid', note: found.note };
  }
}

/// 选区周围的上下文。给模型看的不是全篇，只是这一段和它的前后各一小段。
///
/// 全篇塞进去有两个代价：一集剧本几千字，加上策划与角色表很容易撞上宿主
/// 那 32000 字符的硬上限（撞上是整条请求被拒，不是截断）；而且模型看到全篇
/// 就会想改全篇。
export function passageContext(
  script: string,
  start: number,
  end: number,
  margin = 400
): { before: string; selection: string; after: string } {
  const safeStart = Math.max(0, Math.min(start, script.length));
  const safeEnd = Math.max(safeStart, Math.min(end, script.length));
  return {
    before: script.slice(Math.max(0, safeStart - margin), safeStart),
    selection: script.slice(safeStart, safeEnd),
    after: script.slice(safeEnd, Math.min(script.length, safeEnd + margin)),
  };
}

/// 把替换文本装回正文。按位置替换而不是按内容搜索：同一句台词在一集里
/// 出现两次很常见，按内容替换会改错那一处。
export function applyPassage(script: string, start: number, end: number, replacement: string): string {
  const safeStart = Math.max(0, Math.min(start, script.length));
  const safeEnd = Math.max(safeStart, Math.min(end, script.length));
  return script.slice(0, safeStart) + replacement + script.slice(safeEnd);
}
