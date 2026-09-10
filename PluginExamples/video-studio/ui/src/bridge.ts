import type { CharacterDraft, CreativeSkill, Drama, DramaPlan, EpisodeDraftFields, ProviderEntry, SkillStage } from './types';
import { validCreative } from './creative-schema';

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
    if (plan) return validCreative('plan', plan) ? { ok: true, plan } : { ok: false, reason: 'malformed_json' };
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
  // 围栏名后面必须是空白或行尾，不能直接接别的字母。
  //
  // `short_drama_shot` 是 `short_drama_shots` 的前缀，没有这道边界时单镜
  // 解析器会把整集的围栏认下来——一句「整集微调」的输出会被当成只改一镜，
  // 而它带的是 shots 数组，于是解析失败或者只写进去一镜。
  //
  // 允许围栏名后面跟别的词（旧提示词诱导出的 ```short_drama_plan JSON``
  // 就是这种形状），只是不允许紧接着字母数字下划线。
  const pattern = new RegExp('```' + fence + '(?![A-Za-z0-9_])\\s*([\\s\\S]*?)```', 'i');
  const match = raw.match(pattern);
  if (!match) return null;
  return { body: match[1] ?? '', note: (raw.slice(0, match.index ?? 0) + raw.slice((match.index ?? 0) + match[0].length)).trim() };
}

/// 命名围栏找不到时的兜底。
///
/// 提示词要求 ```short_drama_episode，模型却经常回一个普通的 ```json——
/// 于是整块内容被当成「模型在正常说话」原样贴进对话，草稿一个字没动，
/// 用户看到右边明明有 script 字段，左边「完整剧本」却还是空的，并且连
/// 「有草稿待采用」都不会提示。这是纯粹的格式合同失效，而这一层救得了。
///
/// 只认信息串为空或恰好是 `json` 的围栏：`short_drama_shots` 这类别的
/// 命名围栏不能从这里溜进来，否则单镜解析器又会把整集的块认下来（见
/// `extractFenced` 里那段边界注释）。采不采纳最终由调用方的形状检查决定，
/// 所以一个只是用来举例说明数据结构的 ```json 块不会被当成产出。
function extractGeneric(raw: string): { body: string; note: string } | null {
  const pattern = /(^|\n)```[ \t]*(?:json)?[ \t]*\r?\n([\s\S]*?)```/i;
  const match = raw.match(pattern);
  if (match?.index === undefined) return null;
  const start = match.index + (match[1]?.length ?? 0);
  const end = match.index + match[0].length;
  return { body: match[2] ?? '', note: (raw.slice(0, start) + raw.slice(end)).trim() };
}

/// 先找命名围栏，找不到再看通用块是否通过 `shaped`。形状检查由每个阶段
/// 自己给：分段替换只认 `replacement`，批量集只认 `episodes` 数组，所以
/// 各阶段之间不会互相把对方的块认走。
export function extractFencedOrShaped(
  raw: string,
  fence: string,
  shaped: (value: unknown) => boolean,
): { body: string; note: string } | null {
  const named = extractFenced(raw, fence);
  if (named) return named;
  const generic = extractGeneric(raw);
  if (!generic) return null;
  let value: unknown;
  try {
    value = firstJSONObject(generic.body);
  } catch {
    return null;
  }
  if (!value || typeof value !== 'object') return null;
  return shaped(value) ? generic : null;
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
  // 通用块要被采纳，键必须**全部**落在白名单内。只要求「至少命中一个」
  // 会把模型顺手举例的 JSON 也吞进来；全落在表内的块基本只能是产出。
  const found = extractFencedOrShaped(raw, fence, (value) => {
    const keys = Object.keys(value as Record<string, unknown>);
    if (keys.length === 0 || !keys.every((key) => (allowed as string[]).includes(key))) return false;
    return keys.some((key) => {
      const entry = (value as Record<string, unknown>)[key];
      return typeof entry === 'string' && entry.trim().length > 0;
    });
  });
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
    const kind = fence === 'short_drama_character' ? 'character' : fence === 'short_drama_frames' ? 'frames' : 'episode';
    if (!validCreative(kind, value) || !validCreative(kind, picked)) return { kind: 'invalid', note: found.note };
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
  const found = extractFencedOrShaped(raw, PASSAGE_FENCE, (value) => {
    const keys = Object.keys(value as Record<string, unknown>);
    const replacement = (value as { replacement?: unknown }).replacement;
    return keys.length === 1 && keys[0] === 'replacement'
      && typeof replacement === 'string' && replacement.trim().length > 0;
  });
  if (!found) return { kind: 'chat' };
  try {
    const value = firstJSONObject(found.body);
    if (!value || typeof value !== 'object') return { kind: 'invalid', note: found.note };
    const replacement = (value as { replacement?: unknown }).replacement;
    if (!validCreative('passage', value)) return { kind: 'invalid', note: found.note };
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

/// 提示消息队列。
///
/// 早先只有一个字符串：新消息直接冲掉旧的，批量出稿那种连着十条通知的场景
/// 只能看到最后一条。改成队列之后要解决三件事——存多少、什么时候收起、
/// 时间怎么显示——都在这里，界面只负责画。
export const NOTICE_LIMIT = 10;
/// 多久之后自动收起成一个入口。够看完一条，又不至于一直挡着右下角。
export const NOTICE_COLLAPSE_MS = 10_000;

export type NoticeKind = 'info' | 'error';
export type Notice = { id: string; text: string; kind: NoticeKind; createdAt: number };

/// 最多留 NOTICE_LIMIT 条，超出丢最旧的。刻意不做无限历史：这是提示不是
/// 日志，留着几百条只会让展开面板变成一个没人读的滚动条。
export function appendNotice(queue: Notice[], notice: Notice): Notice[] {
  return [...queue, notice].slice(-NOTICE_LIMIT);
}

/// 相对时间。用户要的是「刚刚 / 3 秒前 / 1 分钟前」这种，而不是时间戳：
/// 提示的价值在于「这是不是我刚才那个动作的结果」，绝对时间回答不了。
export function relativeTime(from: number, now: number, locale: 'zh-Hans' | 'en'): string {
  const seconds = Math.max(0, Math.floor((now - from) / 1000));
  const zh = locale === 'zh-Hans';
  if (seconds < 3) return zh ? '刚刚' : 'just now';
  if (seconds < 60) return zh ? `${seconds} 秒前` : `${seconds}s ago`;
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return zh ? `${minutes} 分钟前` : `${minutes}m ago`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return zh ? `${hours} 小时前` : `${hours}h ago`;
  return zh ? `${Math.floor(hours / 24)} 天前` : `${Math.floor(hours / 24)}d ago`;
}

/// 图片生成的并发上限。
///
/// 四张一次性并发打过去，实测网关回 502 `relay: upstream / bad_gateway`，
/// 成功一张、其余全挂。图片生成本身重，上游又是中继，同一时刻并行几路
/// 就顶不住。两路是「比串行快、又不打爆」的折中。
export const IMAGE_CONCURRENCY = 2;

/// 两次请求发出的最小间隔。
///
/// 只限并发数不够：两路并发时那两个请求几乎同时出发，瞬时压力仍是 2。
/// 把发出的时刻摊开一秒，上游拿到的是稳定的一路一路，而不是一簇。相对
/// 十几秒的生成时间，这一秒几乎不影响总耗时。
export const IMAGE_MIN_INTERVAL_MS = 1_000;

/// 有限并发地跑一批任务，保持结果顺序，并保证相邻两次启动之间隔开
/// `minIntervalMs`。
///
/// `Promise.allSettled` 一次全发，`for await` 一次一个：前者打爆上游，
/// 后者慢到用户以为卡住。这里取中间，并且失败不影响其余任务——已经付过费
/// 的那几张必须交出来。
export async function mapWithConcurrency<T, R>(
  items: T[],
  limit: number,
  run: (item: T, index: number) => Promise<R>,
  options: { minIntervalMs?: number; sleep?: (ms: number) => Promise<void> } = {}
): Promise<Array<PromiseSettledResult<R>>> {
  const minInterval = options.minIntervalMs ?? 0;
  const sleep = options.sleep ?? ((ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms)));
  const results = new Array<PromiseSettledResult<R>>(items.length);
  let cursor = 0;
  // 用 null 而不是 0 表示「还没发过」：0 是一个合法的时间戳，拿它当哨兵
  // 会在时钟从 0 起算时把每次等待都算成不用等。
  let lastStart: number | null = null;

  // 取号与「等到可以发」必须是同一段不被打断的逻辑，否则两个 worker 会
  // 同时算出「现在可以发」然后一起出发，间隔就白设了。
  async function claim(): Promise<number | null> {
    const index = cursor;
    cursor += 1;
    if (index >= items.length) return null;
    if (minInterval > 0) {
      const now = Date.now();
      const wait = lastStart === null ? 0 : Math.max(0, minInterval - (now - lastStart));
      lastStart = now + wait;
      if (wait > 0) await sleep(wait);
    }
    return index;
  }

  const workers = Array.from({ length: Math.max(1, Math.min(limit, items.length)) }, async () => {
    while (true) {
      const index = await claim();
      if (index === null) return;
      try {
        results[index] = { status: 'fulfilled', value: await run(items[index]!, index) };
      } catch (reason) {
        results[index] = { status: 'rejected', reason };
      }
    }
  });
  await Promise.all(workers);
  return results;
}

/// 阶段的系统提示词从技能文件拼出来，不再写死在字典里。
///
/// 拼装放在后端：阶段技能与通用技能的拼接顺序、以及「阶段技能不能被当成
/// 通用技能挂上去」这条约束都由存储层保证，前端只管把勾选传过去。
export async function composeSkillPrompt(
  stage: SkillStage,
  common: string[]
): Promise<string | null> {
  try {
    const payload = await callCommand<{ ok: boolean; system?: string }>('skill.compose', { stage, common });
    const system = payload.system?.trim();
    return system ? system : null;
  } catch {
    // 技能读不出来时回落到字典里那份内置提示词，而不是发一个没有系统提示
    // 的请求——后者会让模型完全不知道输出格式，整轮白跑。
    return null;
  }
}

export async function loadCreativeSkills(): Promise<CreativeSkill[]> {
  try {
    const payload = await callCommand<{ ok: boolean; skills?: CreativeSkill[] }>('skill.list');
    return payload.skills ?? [];
  } catch {
    return [];
  }
}

export async function loadCreativeSkill(id: string): Promise<CreativeSkill | null> {
  const payload = await callCommand<{ ok: boolean; skill?: CreativeSkill }>('skill.get', { id });
  return payload.skill ?? null;
}

export async function saveCreativeSkill(id: string, body: string): Promise<CreativeSkill | null> {
  const payload = await callCommand<{ ok: boolean; skill?: CreativeSkill; error?: { message?: string } }>(
    'skill.save', { id, body }
  );
  if (!payload.ok) throw new Error(payload.error?.message || 'skill_save_failed');
  return payload.skill ?? null;
}

export async function resetCreativeSkill(id: string): Promise<CreativeSkill | null> {
  const payload = await callCommand<{ ok: boolean; skill?: CreativeSkill; error?: { message?: string } }>(
    'skill.reset', { id }
  );
  if (!payload.ok) throw new Error(payload.error?.message || 'skill_reset_failed');
  return payload.skill ?? null;
}

/// 批量丰富多集的围栏。
export const EPISODES_FENCE = 'short_drama_episodes';
/// 一批多少集。二十集是「一批」的合理规模：够串起一段完整的走向，又不至于
/// 让模型开始偷工——集数太多时它会给每集只写一句空话。
export const EPISODE_BATCH_SIZE = 10;

export type EpisodeDraftEntry = { order: number; title?: string; summary?: string };

/// 解析一批分集。
///
/// 每个元素必须带 `order`：模型手上只有集号，而集号是唯一能把内容对回正确
/// 一集的东西。没有 order 的条目直接丢，宁可少写一集也不能填错集。
export function parseFencedEpisodes(raw: string): FencedResult<{ episodes: EpisodeDraftEntry[] }> {
  const found = extractFencedOrShaped(raw, EPISODES_FENCE, (value) =>
    Array.isArray((value as { episodes?: unknown }).episodes));
  if (!found) return { kind: 'chat' };
  try {
    const value = firstJSONObject(found.body);
    const list = (value as { episodes?: unknown } | null)?.episodes;
    if (!Array.isArray(list)) return { kind: 'invalid', note: found.note };
    const episodes: EpisodeDraftEntry[] = [];
    for (const item of list) {
      if (!item || typeof item !== 'object') continue;
      const entry = item as { order?: unknown; title?: unknown; summary?: unknown };
      const order = Number(entry.order);
      if (!Number.isInteger(order) || order < 1) continue;
      const next: EpisodeDraftEntry = { order };
      if (typeof entry.title === 'string' && entry.title.trim()) next.title = entry.title.trim();
      if (typeof entry.summary === 'string' && entry.summary.trim()) next.summary = entry.summary.trim();
      if (next.title === undefined && next.summary === undefined) continue;
      episodes.push(next);
    }
    if (episodes.length === 0 || episodes.length > 30 || !episodes.every((entry) => validCreative('episode', entry))) return { kind: 'invalid', note: found.note };
    return { kind: 'draft', value: { episodes }, note: found.note };
  } catch {
    return { kind: 'invalid', note: found.note };
  }
}

/// 把整季切成一批批。
///
/// 分批不是为了省 token，是因为一次让模型写完二十集以上时它会开始偷工：
/// 前几集写得细，后面每集只剩一句空话。分批之后每批都能拿到完整的注意力，
/// 而批与批之间靠相邻批次的梗概衔接。
export function episodeBatches(total: number, size = EPISODE_BATCH_SIZE): Array<{ from: number; to: number }> {
  const batches: Array<{ from: number; to: number }> = [];
  for (let from = 1; from <= total; from += size) {
    batches.push({ from, to: Math.min(total, from + size - 1) });
  }
  return batches;
}

/// 分镜的两个围栏：改一整集的镜列表，或只改一镜。
export const SHOTS_FENCE = 'short_drama_shots';
export const SHOT_FENCE = 'short_drama_shot';

export type ShotDraftEntry = {
  order: number;
  title?: string;
  summary?: string;
  actionStart?: string;
  actionEnd?: string;
  cameraIntent?: string;
  startPrompt?: string;
  endPrompt?: string;
  dialogue?: Array<{ speaker: string; text: string }>;
  duration?: number;
};

const SHOT_TEXT_KEYS = ['title', 'summary', 'actionStart', 'actionEnd', 'cameraIntent', 'startPrompt', 'endPrompt'] as const;

function pickShotEntry(raw: unknown, fallbackOrder?: number): ShotDraftEntry | null {
  if (!raw || typeof raw !== 'object') return null;
  const source = raw as Record<string, unknown>;
  const order = Number(source.order ?? fallbackOrder);
  // 镜号是唯一能把内容对回正确一镜的东西。没有它宁可丢掉，也不能填错镜。
  if (!Number.isInteger(order) || order < 1) return null;
  const entry: ShotDraftEntry = { order };
  for (const key of SHOT_TEXT_KEYS) {
    const value = source[key];
    if (typeof value === 'string' && value.trim()) entry[key] = value.trim();
  }
  if (Array.isArray(source.dialogue)) {
    const lines = source.dialogue.flatMap((item) => {
      if (!item || typeof item !== 'object') return [];
      const line = item as { speaker?: unknown; text?: unknown };
      const text = typeof line.text === 'string' ? line.text.trim() : '';
      if (!text) return [];
      return [{ speaker: typeof line.speaker === 'string' ? line.speaker.trim() : '', text }];
    });
    // 空数组是合法的意图（这一镜不要台词），所以不能用「非空才写」来判。
    entry.dialogue = lines;
  }
  const duration = Number(source.duration);
  if (Number.isFinite(duration) && duration > 0) entry.duration = Math.round(duration);
  const written = Object.keys(entry).filter((key) => key !== 'order');
  return written.length > 0 && validCreative('shot', entry) ? entry : null;
}

/// 一次改多镜。
export function parseFencedShots(raw: string): FencedResult<{ shots: ShotDraftEntry[] }> {
  const found = extractFencedOrShaped(raw, SHOTS_FENCE, (value) =>
    Array.isArray((value as { shots?: unknown }).shots));
  if (!found) return { kind: 'chat' };
  try {
    const value = firstJSONObject(found.body);
    const list = (value as { shots?: unknown } | null)?.shots;
    if (!Array.isArray(list)) return { kind: 'invalid', note: found.note };
    const shots = list.flatMap((item) => {
      const entry = pickShotEntry(item);
      return entry ? [entry] : [];
    });
    if (shots.length === 0 || shots.length > 40 || new Set(shots.map((entry) => entry.order)).size !== shots.length) return { kind: 'invalid', note: found.note };
    return { kind: 'draft', value: { shots }, note: found.note };
  } catch {
    return { kind: 'invalid', note: found.note };
  }
}

/// 只改一镜。围栏里可以省掉 order，用当前选中那一镜的镜号补上。
export function parseFencedShot(raw: string, fallbackOrder: number): FencedResult<{ shots: ShotDraftEntry[] }> {
  // 带 `shots` 数组的通用块是整集分镜，不是单镜：让它落到 parseFencedShots
  // 去，否则一句「整集微调」会被当成只改一镜——命名围栏那条前缀边界防的
  // 就是这个，兜底这一层不能把它放回来。
  const found = extractFencedOrShaped(raw, SHOT_FENCE, (value) =>
    !Array.isArray((value as { shots?: unknown }).shots)
      && pickShotEntry(value, fallbackOrder) !== null);
  if (!found) return { kind: 'chat' };
  try {
    const entry = pickShotEntry(firstJSONObject(found.body), fallbackOrder);
    if (!entry) return { kind: 'invalid', note: found.note };
    return { kind: 'draft', value: { shots: [entry] }, note: found.note };
  } catch {
    return { kind: 'invalid', note: found.note };
  }
}

/// 分镜清单里给模型看的一行。刻意不带候选图：一集二十镜就是几十条候选记录，
/// 整份丢过去既撑爆预算，又让模型以为那些是可以改的东西。
export type ShotDigest = {
  id: string;
  order: number;
  title: string;
  summary: string;
  dialogue: Array<{ speaker: string; text: string }>;
  actionStart: string;
  actionEnd: string;
  cameraIntent: string;
  duration: number;
  rev: number;
  draftRev: number;
  hasDraft: boolean;
  startCandidateCount: number;
  endCandidateCount: number;
};

export function shotDigestLines(shots: ShotDigest[]): string {
  return shots.map((shot) => {
    const lines = shot.dialogue.map((line) => `${line.speaker}：${line.text}`).join(' / ');
    return [
      `第 ${shot.order} 镜 ${shot.title}（${shot.duration} 秒，${shot.cameraIntent || '未定运镜'}）`,
      shot.summary ? `  剧情：${shot.summary}` : '',
      lines ? `  台词：${lines}` : '',
      shot.actionStart ? `  开场：${shot.actionStart}` : '',
      shot.actionEnd ? `  收尾：${shot.actionEnd}` : '',
    ].filter(Boolean).join('\n');
  }).join('\n');
}
