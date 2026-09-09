import { useEffect, useMemo, useState } from 'react';
import type { ReactNode } from 'react';
import { CHARACTER_DRAFT_FIELDS, callCommand, loadDramas, loadProviders, parseFencedDraft, parsePlanWithReason, requestBudget, visibleStream } from './bridge';
import { Dropdown } from './Dropdown';
import { createTranslator, localeFromContext } from './i18n';
import type { ChatMessage, Character, CharacterDraft, Drama, DramaPlan, ImageModel, ProviderEntry, Shot, SkillEntry, Stage } from './types';
import './styles.css';

const imageModels: ImageModel[] = ['gpt-image-2', 'nano-banana-2'];

// crypto.randomUUID 标了 [SecureContext]，插件页跑在自定义 scheme
// willdeep-plugin:// 下，非安全上下文里这个方法根本不存在。宿主自己注入的
// bootstrap 两处都写了同样的降级，页面这边不能少——首屏就会同步调用它。
function localID(): string {
  const source = globalThis.crypto;
  if (source && typeof source.randomUUID === 'function') return source.randomUUID();
  return `id-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`;
}
// 宿主对一次请求最多接受 3 个技能，这里跟它保持一致，超了不如早点拦住。
const MAX_ATTACHED_SKILLS = 3;
const stageOrder: Stage[] = ['planning', 'characters', 'script', 'storyboard', 'frames', 'video'];
const CHARACTER_FENCE = 'short_drama_character';

/// 显示值：有草稿就看草稿，没有才看已定稿的内容。共创全程改的是草稿，
/// 正式内容要等用户按下采用才动。
function characterView(entry: Character | undefined): CharacterDraft & { name: string; description: string; visualPrompt: string } {
  const draft = entry?.draft ?? null;
  return {
    name: draft?.name ?? entry?.name ?? '',
    description: draft?.description ?? entry?.description ?? '',
    visualPrompt: draft?.visualPrompt ?? entry?.visualPrompt ?? '',
  };
}

/// 差异按字段自己算。模型常说「我只改了小传」，实际把名字也换了，
/// 采用前给用户看的必须是真的差异。
export function draftDifferences(entry: Character | undefined): Array<{ field: keyof CharacterDraft & string; before: string; after: string }> {
  if (!entry?.draft) return [];
  const rows: Array<{ field: keyof CharacterDraft & string; before: string; after: string }> = [];
  for (const field of CHARACTER_DRAFT_FIELDS) {
    const after = entry.draft[field];
    if (typeof after !== 'string') continue;
    const before = (entry[field] ?? '') as string;
    if (before !== after) rows.push({ field, before, after });
  }
  return rows;
}
type DramaStatusFilter = 'all' | 'planning' | 'production' | 'completed';
type PlannerMessage = { id: string; role: 'user' | 'assistant'; content: string; display: string };

function emptyShot(order: number): Shot {
  return { id: '', order, title: '', summary: '', dialogue: [{ id: localID(), speaker: '', text: '' }], actionStart: '', actionEnd: '', cameraIntent: '', duration: 4, startPrompt: '', endPrompt: '', startCandidates: [], endCandidates: [] };
}

// 光标前最近的一个 `$` 到光标之间的文字，就是技能查询词。要求 `$` 在开头或
// 紧跟空白，避免把 shell 变量、价格、路径里的 $ 当成触发；查询词里出现空白就
// 说明用户已经写下去了，收起菜单。宿主主聊天框的判定规则与此一致。
export function skillQueryAt(value: string, caret: number): string | null {
  const before = value.slice(0, Math.max(0, Math.min(caret, value.length)));
  const dollar = before.lastIndexOf('$');
  if (dollar < 0) return null;
  if (dollar > 0 && !/\s/.test(before[dollar - 1] ?? '')) return null;
  const query = before.slice(dollar + 1);
  return /\s/.test(query) ? null : query;
}

function selectedCandidate(shot: Shot | undefined, kind: 'start' | 'end') {
  if (!shot) return undefined;
  const list = kind === 'start' ? shot.startCandidates : shot.endCandidates;
  const id = kind === 'start' ? shot.selectedStartID : shot.selectedEndID;
  return list.find((candidate) => candidate.id === id);
}

export default function App() {
  const [locale, setLocale] = useState(localeFromContext(window.willdeep?.getContext().locale));
  const t = useMemo(() => createTranslator(locale), [locale]);
  const [stage, setStage] = useState<Stage>('library');
  const [dramas, setDramas] = useState<Drama[]>([]);
  const [dramaID, setDramaID] = useState('');
  const drama = dramas.find((item) => item.id === dramaID);
  const [episodeID, setEpisodeID] = useState('');
  const episode = drama?.episodes.find((item) => item.id === episodeID) ?? drama?.episodes[0];
  const [shotID, setShotID] = useState('');
  // 正在起草一个还没落库的新分镜时，shot 必须是 undefined。早先 shotID 为空就
  // 回落到 shots[0]，于是首尾帧页同时显示「第 1 个分镜的候选图」和「空白草稿的
  // 提示词」，选图还会写回第 1 个分镜。
  const [draftingNewShot, setDraftingNewShot] = useState(false);
  const shot = draftingNewShot ? undefined : (episode?.shots.find((item) => item.id === shotID) ?? episode?.shots[0]);
  const [providers, setProviders] = useState<ProviderEntry[]>([]);
  const [assistantProvider, setAssistantProvider] = useState('');
  const [assistantModel, setAssistantModel] = useState('');
  const [loadingModels, setLoadingModels] = useState(false);
  const [imageModel, setImageModel] = useState<ImageModel>('gpt-image-2');
  const [candidateCount, setCandidateCount] = useState(4);
  const [videoCount, setVideoCount] = useState(2);
  const [idea, setIdea] = useState('');
  const [plannerMessages, setPlannerMessages] = useState<PlannerMessage[]>([]);
  const [plan, setPlan] = useState<DramaPlan | null>(null);
  const [plannerStreamID, setPlannerStreamID] = useState('');
  const [character, setCharacter] = useState({ id: '', name: '', description: '', visualPrompt: '' });
  // 共创：当前选中的角色、这一阶段的聊天、以及基准过期时留在内存里的候选。
  const [characterID, setCharacterID] = useState('');
  const [characterChat, setCharacterChat] = useState<ChatMessage[]>([]);
  const [characterInput, setCharacterInput] = useState('');
  const [characterStreamID, setCharacterStreamID] = useState('');
  const [structuredStreaming, setStructuredStreaming] = useState(false);
  const [staleCandidate, setStaleCandidate] = useState<{ characterID: string; draft: CharacterDraft; note: string } | null>(null);
  const [showDiff, setShowDiff] = useState(false);
  const [batchProgress, setBatchProgress] = useState<{ done: number; total: number } | null>(null);
  const [episodeDraft, setEpisodeDraft] = useState({ title: '', summary: '', script: '' });
  const [shotDraft, setShotDraft] = useState<Shot>(emptyShot(1));
  const [busy, setBusy] = useState('');
  const [notice, setNotice] = useState('');
  const [failure, setFailure] = useState('');
  const [query, setQuery] = useState('');
  const [statusFilter, setStatusFilter] = useState<DramaStatusFilter>('all');
  const [streamingText, setStreamingText] = useState('');
  const [skills, setSkills] = useState<SkillEntry[]>([]);
  const [skillQuery, setSkillQuery] = useState<string | null>(null);
  const [attachedSkills, setAttachedSkills] = useState<SkillEntry[]>([]);

  const skillMatches = skillQuery === null ? [] : skills.filter((item) => {
    if (attachedSkills.some((entry) => entry.identifier === item.identifier)) return false;
    const needle = skillQuery.toLocaleLowerCase(locale);
    if (!needle) return true;
    return `${item.identifier} ${item.name} ${item.description}`.toLocaleLowerCase(locale).includes(needle);
  }).slice(0, 8);

  function attachSkill(entry: SkillEntry) {
    // 和宿主聊天框一样：选中后把 $token 从输入框里删掉，技能变成上方的一枚
    // 标签，而不是留一串字面量在正文里。
    setIdea((current) => {
      const dollar = current.lastIndexOf('$');
      return dollar < 0 ? current : current.slice(0, dollar) + current.slice(dollar + 1 + (skillQuery ?? '').length);
    });
    setAttachedSkills((current) => current.length >= MAX_ATTACHED_SKILLS || current.some((item) => item.identifier === entry.identifier)
      ? current
      : [...current, entry]);
    setSkillQuery(null);
  }

  function errorMessage(error: unknown) {
    if (!(error instanceof Error)) return t('operationFailed');
    return t(error.message) === error.message ? error.message : t(error.message);
  }

  async function reload(preferredID?: string) {
    const next = await loadDramas();
    setDramas(next);
    if (preferredID) setDramaID(preferredID);
  }

  // 只在挂载时拉一次。早先这个 effect 依赖 [t]，切一次语言就把短剧列表和
  // provider 列表重新拉一遍。
  useEffect(() => {
    void reload().catch((error) => setFailure(errorMessage(error)));
    void window.willdeep?.skills?.list()
      .then((payload) => setSkills(payload.skills ?? []))
      .catch(() => setSkills([]));
    void refreshModels(true);
  }, []);

  async function refreshModels(restore = false) {
    setLoadingModels(true);
    try {
      const items = await loadProviders();
      setProviders(items);
      const saved = restore ? (await window.willdeep?.storage?.get('planning-model'))?.value : null;
      const selection = saved && typeof saved === 'object' ? saved as Record<string, unknown> : {};
      const active = items.find(item => item.providerID === (selection.provider ?? assistantProvider)) ?? items.find(item => item.isActive) ?? items[0];
      if (active) {
        setAssistantProvider(active.providerID);
        const model = selection.model ?? assistantModel;
        setAssistantModel(typeof model === 'string' && active.models.includes(model) ? model : active.flashModel || active.models[0] || '');
      }
    } catch (error) { setFailure(errorMessage(error)); }
    finally { setLoadingModels(false); }
  }

  async function savePreferences() {
    try {
      if (!window.willdeep?.storage) throw new Error(t('willdeep_bridge_unavailable'));
      await window.willdeep.storage.set('planning-model', { provider: assistantProvider, model: assistantModel });
      setNotice(t('settingsSaved'));
    } catch (error) { setFailure(errorMessage(error)); }
  }

  function Settings() {
    return AppShell(<main className="content"><h1>{t('nav_settings')}</h1><section className="editor-card"><h2>{t('planningTitle')}</h2><p>{t('modelCatalogHint')}</p>{ModelRouting()}<div className="actions"><button disabled={loadingModels} onClick={() => void refreshModels()}>{t(loadingModels ? 'loadingModels' : 'refreshModels')}</button><button className="primary" disabled={loadingModels || !assistantModel} onClick={() => void savePreferences()}>{t('saveSettings')}</button></div></section></main>);
  }

  useEffect(() => { document.title = t('appName'); }, [t]);

  // 语言和深浅色都从同一次 context 读。早先主题只在依赖 [t] 的 effect 里读，
  // 宿主切主题但语言没变时 React 会 bail out，页面永远停在挂载时那一档。
  useEffect(() => {
    const apply = () => {
      const context = window.willdeep?.getContext();
      setLocale(localeFromContext(context?.locale));
      document.documentElement.dataset.theme = context?.colorScheme === 'dark' ? 'dark' : 'light';
    };
    apply();
    window.addEventListener('willdeep:context-changed', apply);
    return () => window.removeEventListener('willdeep:context-changed', apply);
  }, []);

  useEffect(() => {
    if (!episode) return;
    setEpisodeID(episode.id);
    setEpisodeDraft({ title: episode.title, summary: episode.summary, script: episode.script });
  }, [episode?.id]);

  useEffect(() => {
    if (!shot) { setShotDraft(emptyShot((episode?.shots.length ?? 0) + 1)); return; }
    setShotID(shot.id);
    setShotDraft(structuredClone(shot));
  }, [shot?.id, episode?.id]);

  const provider = providers.find((item) => item.providerID === assistantProvider);

  function enterProject(item: Drama, nextStage: Stage = 'characters') {
    setDramaID(item.id);
    setEpisodeID(item.episodes[0]?.id ?? '');
    setDraftingNewShot(false);
    setShotID(item.episodes[0]?.shots[0]?.id ?? '');
    setStage(nextStage);
    setFailure('');
  }

  async function selectCharacter(entry: Character) {
    setCharacterID(entry.id);
    const view = characterView(entry);
    setCharacter({ id: entry.id, name: view.name, description: view.description, visualPrompt: view.visualPrompt });
    setShowDiff(false);
    setStaleCandidate(null);
    await loadCharacterChat(drama?.id ?? '');
  }

  function openPlanning() {
    setDramaID('');
    setPlan(null);
    setIdea('');
    setPlannerMessages([]);
    setFailure('');
    setStage('planning');
  }

  async function askPlanner() {
    const question = idea.trim();
    if (!question) { setFailure(t('ideaRequired')); return; }
    const userMessage: PlannerMessage = { id: localID(), role: 'user', content: question, display: question };
    const requestMessages = [...plannerMessages, userMessage];
    setPlannerMessages(requestMessages);
    setIdea('');
    setBusy('plan'); setFailure(''); setStreamingText('');
    // 策划一次要十几秒。宿主按 streamID 把增量推回来，贴着输入框滚动显示，
    // 用户至少知道模型在动，而不是对着一个转圈干等。
    const streamID = localID();
    setPlannerStreamID(streamID);
    const onDelta = (event: Event) => {
      const detail = (event as CustomEvent<{ streamID?: string; delta?: string }>).detail;
      if (detail?.streamID !== streamID || typeof detail.delta !== 'string') return;
      setStreamingText((current) => (current + detail.delta).slice(-1200));
    };
    window.addEventListener('willdeep:ai-delta', onDelta);
    // 这一轮失败就把问题退回输入框，并把刚追加的那条用户消息撤掉。
    // 早先两样都不回滚：输入框空了、消息留在历史里，用户只能重新打一遍，
    // 而每次重试又往历史里多堆一条一模一样的话。
    const rollback = () => { setPlannerMessages(plannerMessages); setIdea(question); };
    try {
      const response = await window.willdeep?.ai?.complete({
        system: t('plannerSystem'), messages: requestMessages.map(({ role, content }) => ({ role, content })),
        provider: assistantProvider || undefined, model: assistantModel || undefined,
        skills: attachedSkills.map((item) => item.identifier), streamID,
      });
      if (!response) { rollback(); setFailure(t('operationFailed')); return; }
      const parsed = parsePlanWithReason(response.text);
      if (!parsed.ok) {
        // 模型原文留进聊天记录。早先直接丢掉，用户和我们都看不到它到底
        // 回了什么，只能对着一句「没有有效数据块」反复重试。
        setPlannerMessages([...plannerMessages, { id: localID(), role: 'assistant', content: response.text, display: `${t(`planFailure_${parsed.reason}`)}\n\n${response.text.slice(0, 1200)}` }]);
        setIdea(question);
        setFailure(t(`planFailure_${parsed.reason}`));
        return;
      }
      setPlan(parsed.plan);
      setPlannerMessages([...requestMessages, { id: localID(), role: 'assistant', content: response.text, display: t('planGeneratedMessage', { title: parsed.plan.title }) }]);
    } catch (error) {
      rollback();
      const message = errorMessage(error);
      setFailure(message.toLowerCase().includes('cancel') ? t('requestStopped') : message);
    }
    finally {
      window.removeEventListener('willdeep:ai-delta', onDelta);
      setStreamingText(''); setPlannerStreamID(''); setBusy('');
    }
  }

  function stopPlanner() {
    const cancel = window.willdeep?.ai?.cancel;
    if (cancel && plannerStreamID) void cancel(plannerStreamID);
  }

  async function confirmPlan() {
    if (!plan) return;
    setBusy('confirm');
    try {
      const payload = await callCommand<{ ok: boolean; drama?: Drama; error?: { message?: string } }>('drama.confirmPlan', { plan });
      if (!payload.ok || !payload.drama) throw new Error(payload.error?.message || t('operationFailed'));
      await reload(payload.drama.id); enterProject(payload.drama, 'characters'); setNotice(t('planSaved'));
    } catch (error) { setFailure(errorMessage(error)); }
    finally { setBusy(''); }
  }

  async function saveCharacter() {
    if (!drama || !character.name.trim()) return;
    setBusy('character');
    try {
      // 刻意不传 identityVersion。服务端只改收到的字段，硬传 1 会把用户
      // 刻意升过的身份版本每次都打回去。
      const payload = await callCommand<{ ok: boolean; drama?: Drama }>('drama.saveCharacter', { dramaID: drama.id, characterID: character.id || undefined, ...character });
      if (payload.drama) {
        setDramas((items) => items.map((item) => item.id === payload.drama?.id ? payload.drama : item));
        const saved = payload.drama.characters.find((item) => item.id === character.id) ?? payload.drama.characters.at(-1);
        if (saved) setCharacter({ id: saved.id, name: saved.name, description: saved.description, visualPrompt: saved.visualPrompt });
      }
      setNotice(t('characterSaved'));
    } catch (error) { setFailure(errorMessage(error)); } finally { setBusy(''); }
  }

  // ---- 角色共创 ----

  const selectedCharacter = drama?.characters.find((item) => item.id === characterID);

  async function loadCharacterChat(id: string) {
    if (!id) { setCharacterChat([]); return; }
    try {
      const payload = await callCommand<{ ok: boolean; messages?: ChatMessage[] }>('chat.list', { dramaID: id, stage: 'characters' });
      setCharacterChat(payload.messages ?? []);
    } catch { setCharacterChat([]); }
  }

  async function appendCharacterChat(role: 'user' | 'assistant', content: string, objectID: string, draftRev: number) {
    const message = { role, content, objectID, draftRev };
    try {
      const payload = await callCommand<{ ok: boolean; message?: ChatMessage }>('chat.append', { dramaID: drama?.id, stage: 'characters', message });
      if (payload.message) setCharacterChat((current) => [...current, payload.message as ChatMessage]);
    } catch (error) { setFailure(errorMessage(error)); }
  }

  function applyDrama(next: Drama | undefined) {
    if (!next) return;
    setDramas((items) => items.map((item) => (item.id === next.id ? next : item)));
  }

  /// 手改和 AI 结果走同一条路。expectedDraftRev 对不上就不写，把结果留在
  /// 内存里让用户复核——静默覆盖丢的是用户刚敲进去的字。
  async function saveCharacterDraft(draft: CharacterDraft, expectedDraftRev: number | undefined, options: { silent?: boolean } = {}) {
    if (!drama || !characterID) return false;
    try {
      const payload = await callCommand<{ ok: boolean; drama?: Drama; error?: { code?: string; message?: string } }>('drama.saveDraft', {
        dramaID: drama.id, scope: 'character', characterID, draft,
        expectedDraftRev,
      });
      if (!payload.ok) {
        if (payload.error?.code === 'revision_conflict') return false;
        throw new Error(payload.error?.message || t('operationFailed'));
      }
      applyDrama(payload.drama);
      if (!options.silent) setNotice(t('draftSaved'));
      return true;
    } catch (error) { setFailure(errorMessage(error)); return false; }
  }

  async function commitCharacterDraft() {
    if (!drama || !selectedCharacter) return;
    setBusy('commit');
    try {
      const payload = await callCommand<{ ok: boolean; drama?: Drama; error?: { code?: string; message?: string } }>('drama.commitDraft', {
        dramaID: drama.id, scope: 'character', characterID, expectedRev: selectedCharacter.rev ?? 0,
      });
      // 重复确认拿到的就是这条冲突：第一次已经写进去了，不该报错也不该再写一遍。
      if (!payload.ok && payload.error?.code === 'revision_conflict') { await reload(drama.id); setNotice(t('draftAlreadyAdopted')); return; }
      if (!payload.ok) throw new Error(payload.error?.message || t('operationFailed'));
      applyDrama(payload.drama);
      setShowDiff(false);
      setNotice(t('draftAdopted'));
    } catch (error) { setFailure(errorMessage(error)); } finally { setBusy(''); }
  }

  async function discardCharacterDraft() {
    if (!drama || !selectedCharacter) return;
    try {
      const payload = await callCommand<{ ok: boolean; drama?: Drama; error?: { message?: string } }>('drama.discardDraft', {
        dramaID: drama.id, scope: 'character', characterID, expectedDraftRev: selectedCharacter.draftRev ?? 0,
      });
      if (!payload.ok) throw new Error(payload.error?.message || t('operationFailed'));
      applyDrama(payload.drama);
      setShowDiff(false);
      setNotice(t('draftDiscarded'));
    } catch (error) { setFailure(errorMessage(error)); }
  }

  function stopCharacterRequest() {
    const cancel = window.willdeep?.ai?.cancel;
    if (cancel && characterStreamID) void cancel(characterStreamID);
  }

  /// 让 AI 给一个角色出第一稿。和继续对话走同一条链路，区别只是请求文本
  /// 由固定指令给出，不需要用户先打字。
  async function draftCharacter(entry: Character) {
    setCharacterID(entry.id);
    const view = characterView(entry);
    setCharacter({ id: entry.id, name: view.name, description: view.description, visualPrompt: view.visualPrompt });
    await runCharacterRequest(entry, t('characterFirstDraftRequest', { name: view.name }));
  }

  /// 给还空着的角色批量出第一稿。刻意串行：宿主对一个插件页面同时在跑的
  /// AI 请求有上限（2 条），并发发出去只会被当场拒掉一半。
  async function draftAllCharacters() {
    if (!drama) return;
    const pending = drama.characters.filter((item) => {
      const view = characterView(item);
      return !view.description.trim() || !view.visualPrompt.trim();
    });
    if (pending.length === 0) { setNotice(t('allCharactersDrafted')); return; }
    setBatchProgress({ done: 0, total: pending.length });
    for (const [index, entry] of pending.entries()) {
      setBatchProgress({ done: index, total: pending.length });
      // 每轮都从最新的 dramas 里重取：上一轮写完草稿后 draftRev 变了，
      // 拿旧对象发请求会被版本检查判成冲突。
      const latest = dramas.find((item) => item.id === drama.id)?.characters.find((item) => item.id === entry.id);
      await runCharacterRequest(latest ?? entry, t('characterFirstDraftRequest', { name: (latest ?? entry).name }));
    }
    setBatchProgress(null);
    setNotice(t('batchDraftDone', { count: pending.length }));
  }

  async function askCharacter() {
    if (!drama || !selectedCharacter) { setFailure(t('selectCharacterFirst')); return; }
    const question = characterInput.trim();
    if (!question) { setFailure(t('characterAskRequired')); return; }
    setCharacterInput('');
    await runCharacterRequest(selectedCharacter, question);
  }

  async function runCharacterRequest(target: Character, question: string) {
    if (!drama) return;
    const selectedCharacter = target;

    const view = characterView(selectedCharacter);
    const baseDraftRev = selectedCharacter.draftRev ?? 0;
    const objectID = selectedCharacter.id;
    const system = t('characterSystem');
    // 装配顺序：本轮要求 → 当前对象 → 相关上游 → 近期对话。整部剧的资料
    // 按需取，不是每次都全塞进去。
    const context = [
      `${t('contextDramaLabel')}: ${drama.title} / ${drama.genre} / ${drama.tone}`,
      `${t('contextLoglineLabel')}: ${drama.logline}`,
      `${t('contextCharacterLabel')}: ${JSON.stringify({ name: view.name, description: view.description, visualPrompt: view.visualPrompt })}`,
    ].join('\n');
    const history = characterChat
      .filter((item) => !item.objectID || item.objectID === objectID)
      .slice(-8)
      .map(({ role, content }) => ({ role, content }));
    const messages = [...history, { role: 'user' as const, content: `${context}\n\n${question}` }];

    const budget = requestBudget(system, messages);
    if (!budget.withinLimits) { setFailure(t('requestTooLarge', { characters: budget.characters })); return; }

    setBusy('character-ask'); setFailure(''); setStreamingText(''); setStructuredStreaming(false);
    void appendCharacterChat('user', question, objectID, baseDraftRev);

    const streamID = localID();
    setCharacterStreamID(streamID);
    let buffer = '';
    const onDelta = (event: Event) => {
      const detail = (event as CustomEvent<{ streamID?: string; delta?: string }>).detail;
      if (detail?.streamID !== streamID || typeof detail.delta !== 'string') return;
      buffer += detail.delta;
      const visible = visibleStream(buffer, CHARACTER_FENCE);
      setStructuredStreaming(visible.structured);
      setStreamingText(visible.text.slice(-1200));
    };
    window.addEventListener('willdeep:ai-delta', onDelta);
    try {
      const response = await window.willdeep?.ai?.complete({
        system, messages,
        provider: assistantProvider || undefined, model: assistantModel || undefined,
        skills: attachedSkills.map((item) => item.identifier), streamID,
      });
      if (!response) throw new Error(t('operationFailed'));
      const parsed = parseFencedDraft<CharacterDraft>(response.text, CHARACTER_FENCE, CHARACTER_DRAFT_FIELDS);
      if (parsed.kind === 'chat') { await appendCharacterChat('assistant', response.text, objectID, baseDraftRev); return; }
      if (parsed.kind === 'invalid') {
        await appendCharacterChat('assistant', response.text, objectID, baseDraftRev);
        setFailure(t('characterDraftInvalid'));
        return;
      }
      await appendCharacterChat('assistant', parsed.note || t('characterDraftReady'), objectID, baseDraftRev);
      const written = await saveCharacterDraft(parsed.value, baseDraftRev, { silent: true });
      if (written) { setShowDiff(true); return; }
      // 基准变了：多半是这段时间里用户自己动了手。结果留在内存里等复核，
      // 关窗即丢，这一版刻意不做候选持久化。
      setStaleCandidate({ characterID: objectID, draft: parsed.value, note: parsed.note });
      setFailure(t('characterDraftStale'));
    } catch (error) {
      const message = errorMessage(error);
      setFailure(message.includes('cancel') ? t('requestStopped') : message);
    } finally {
      window.removeEventListener('willdeep:ai-delta', onDelta);
      setStreamingText(''); setStructuredStreaming(false); setCharacterStreamID(''); setBusy('');
    }
  }

  /// 用户看过内存候选后决定采用。这时才按最新的 draftRev 写进去。
  async function acceptStaleCandidate() {
    if (!staleCandidate || staleCandidate.characterID !== characterID) return;
    const written = await saveCharacterDraft(staleCandidate.draft, selectedCharacter?.draftRev ?? 0, { silent: true });
    if (written) { setStaleCandidate(null); setShowDiff(true); }
  }

  // 抽卡的前提是每张不一样。some.im 网关对 gpt-image 系会把 n 强制改成 1，
  // seed 在部分上游路径上会被静默丢弃，所以差异只能落在 prompt 本身。
  function variedPrompt(prompt: string, index: number) {
    return index === 0 ? prompt : `${prompt}\n\n(variation ${index + 1})`;
  }

  // 并发发起，逐个收口。早先是串行 for 循环，六张要等六倍时间；中途抛错还会
  // 跳过循环之后的刷新，前面已经扣过费的图一张也显示不出来。
  async function drawImages(prompt: string, count: number) {
    const bridge = window.willdeep?.ai?.generateImage;
    if (!bridge) throw new Error('imageBridgeMissing');
    const settled = await Promise.allSettled(
      Array.from({ length: count }, (_, index) => bridge({
        prompt: variedPrompt(prompt, index), provider: 'some-im', model: imageModel, size: '1024x1536',
      })),
    );
    const done = settled.flatMap((entry) => (entry.status === 'fulfilled' && entry.value ? [entry.value] : []));
    const firstFailure = settled.find((entry) => entry.status === 'rejected');
    return { done, failed: count - done.length, firstFailure: firstFailure?.reason as unknown };
  }

  function reportDraw(done: number, failed: number, firstFailure: unknown) {
    if (done > 0) setNotice(failed > 0 ? t('imagesPartial', { done, failed }) : t('imagesGenerated', { count: done }));
    if (failed > 0) setFailure(done > 0 ? errorMessage(firstFailure) : errorMessage(firstFailure));
  }

  async function generateCharacterImages() {
    if (!drama || !character.id || !character.visualPrompt.trim()) { setFailure(t('saveCharacterFirst')); return; }
    setBusy('characterImage'); setFailure('');
    try {
      const { done, failed, firstFailure } = await drawImages(character.visualPrompt, candidateCount);
      for (const result of done) {
        await callCommand('drama.recordCharacterImage', { dramaID: drama.id, characterID: character.id, prompt: character.visualPrompt, ...result });
      }
      // 成功那几张先落库再刷新，失败的单独报，不让已花的钱看不见。
      await reload(drama.id);
      reportDraw(done.length, failed, firstFailure);
    } catch (error) { setFailure(errorMessage(error)); } finally { setBusy(''); }
  }

  async function chooseCharacterImage(candidateID: string) {
    if (!drama || !character.id) return;
    await callCommand('drama.selectCharacterImage', { dramaID: drama.id, characterID: character.id, candidateID });
    await reload(drama.id);
  }

  async function saveEpisode() {
    if (!drama || !episode) return;
    setBusy('episode');
    try { await callCommand('drama.saveEpisode', { dramaID: drama.id, episodeID: episode.id, ...episodeDraft }); await reload(drama.id); setNotice(t('episodeSaved')); }
    catch (error) { setFailure(errorMessage(error)); } finally { setBusy(''); }
  }

  // 不碰 busy：generateFrames 会先调它，再接着生成图片。早先 saveShot 自己在
  // finally 里清空 busy，把外层刚设的状态一起清掉，生成期间按钮提前解锁，
  // 用户看着没反应就再点一次，白白多抽一轮。
  async function persistShot(): Promise<string | undefined> {
    if (!drama || !episode) return undefined;
    const payload = await callCommand<{ ok: boolean; drama?: Drama }>('drama.saveShot', { dramaID: drama.id, episodeID: episode.id, shotID: shotDraft.id || undefined, ...shotDraft });
    const saved = payload.drama?.episodes.find((item) => item.id === episode.id)?.shots.find((item) => item.id === shotDraft.id)
      ?? payload.drama?.episodes.find((item) => item.id === episode.id)?.shots.find((item) => item.order === shotDraft.order);
    if (payload.drama) setDramas((items) => items.map((item) => item.id === payload.drama?.id ? payload.drama : item));
    if (saved) { setDraftingNewShot(false); setShotID(saved.id); setShotDraft(structuredClone(saved)); }
    return saved?.id;
  }

  async function saveShot(): Promise<string | undefined> {
    setBusy('shot');
    try {
      const id = await persistShot();
      if (id) setNotice(t('shotSaved'));
      return id;
    } catch (error) { setFailure(errorMessage(error)); return undefined; } finally { setBusy(''); }
  }

  async function generateFrames(kind: 'start' | 'end') {
    if (!drama || !episode) return;
    const prompt = kind === 'start' ? shotDraft.startPrompt : shotDraft.endPrompt;
    if (!prompt.trim()) { setFailure(t('framePromptRequired')); return; }
    setBusy(kind); setFailure('');
    try {
      const savedShotID = await persistShot();
      if (!savedShotID) throw new Error(t('saveShotFailed'));
      const { done, failed, firstFailure } = await drawImages(prompt, candidateCount);
      for (const result of done) {
        await callCommand('drama.recordImage', { dramaID: drama.id, episodeID: episode.id, shotID: savedShotID, kind, prompt, ...result });
      }
      await reload(drama.id);
      reportDraw(done.length, failed, firstFailure);
    } catch (error) { setFailure(errorMessage(error)); }
    finally { setBusy(''); }
  }

  async function chooseFrame(kind: 'start' | 'end', candidateID: string) {
    if (!drama || !episode || !shot) return;
    await callCommand('drama.selectImage', { dramaID: drama.id, episodeID: episode.id, shotID: shot.id, kind, candidateID });
    await reload(drama.id);
  }

  async function generateVideos() {
    if (!shot) return;
    const start = selectedCandidate(shot, 'start');
    if (!start) { setFailure(t('selectStartFirst')); return; }
    setBusy('video'); setFailure('');
    try {
      const basePrompt = shot.summary || shot.cameraIntent;
      const settled = await Promise.allSettled(
        Array.from({ length: videoCount }, (_, index) => callCommand('video.generate', {
          title: `${drama?.title ?? ''} · ${episode?.title ?? ''} · ${shot.title}`,
          prompt: variedPrompt(basePrompt, index), referenceImagePath: start.filePath,
          duration: [2, 4, 6].includes(shot.duration) ? shot.duration : 4, source: 'short-drama',
        })),
      );
      // 一条提交失败不该让另外几条已经计过费的提交无声消失。
      const done = settled.filter((entry) => entry.status === 'fulfilled').length;
      const firstFailure = settled.find((entry) => entry.status === 'rejected');
      if (done > 0) setNotice(done === videoCount ? t('videosSubmitted', { count: done }) : t('videosPartial', { done, failed: videoCount - done }));
      if (firstFailure) setFailure(errorMessage(firstFailure.reason));
    } catch (error) { setFailure(errorMessage(error)); } finally { setBusy(''); }
  }

  function Sidebar() {
    const globalItems = ['library', 'assets', 'queue', 'settings'] as const;
    return <aside className="sidebar"><button className="wordmark" onClick={() => setStage('library')}>{t('appName')}</button><nav className="global-nav" aria-label={t('mainNavigation')}>{globalItems.map((item) => <button key={item} className={(item === 'settings' ? stage === 'settings' : item === 'library' && stage !== 'settings') ? 'active' : ''} disabled={item !== 'library' && item !== 'settings'} onClick={() => { if (item === 'library' || item === 'settings') setStage(item); }}>{t(`nav_${item}`)}</button>)}</nav>{drama && <div className="project-nav"><p>{t('productionFlow')}</p><strong>{drama.title}</strong>{stageOrder.map((item, index) => <button key={item} className={stage === item ? 'active' : ''} onClick={() => setStage(item)}><span>{String(index + 1).padStart(2, '0')}</span>{t(`stage_${item}`)}</button>)}</div>}<div className="sidebar-foot"><span>{t('localPlugin')}</span><button onClick={() => setLocale(locale === 'zh-Hans' ? 'en' : 'zh-Hans')}>{locale === 'zh-Hans' ? 'EN' : '中文'}</button></div></aside>;
  }

  // 这一组是渲染函数，不是组件，调用点一律写成 Foo() 而不是 <Foo />。
  // 它们定义在 App 函数体内，每次渲染都是新的函数引用；一旦以 JSX 元素的形式
  // 出现，React 就按类型引用比对，于是每个 setState 都会 unmount + remount
  // 整棵子树，所有受控输入框打一个字就掉焦点。
  function AppShell(children: ReactNode) {
    return <div className="app-shell">{Sidebar()}<div className="app-main">{children}</div></div>;
  }

  function ProjectHeader() {
    if (!drama) return null;
    return <header className="project-header"><div><button className="breadcrumb" onClick={() => setStage('library')}>{t('allProjects')}</button><span>{drama.title}</span></div><span className={`status-pill status-${drama.status}`}>{t(`status_${drama.status}`)}</span></header>;
  }

  function EpisodeSwitcher() {
    if (!drama) return null;
    return <div className="episode-switcher"><label>{t('episode')}</label><Dropdown ariaLabel={t('episode')} value={episode?.id ?? ''} options={drama.episodes.map((item) => ({ value: item.id, label: `${t('episodeNumber', { number: item.order })} · ${item.title}` }))} onChange={(next) => { setEpisodeID(next); setShotID(''); }} /><span>{t('episodeProgress', { current: episode?.order ?? 0, total: drama.episodes.length })}</span></div>;
  }

  function ShotRail() {
    if (!episode) return null;
    return <aside className="shot-rail"><div className="rail-title"><strong>{t('shots')}</strong><button onClick={() => { setDraftingNewShot(true); setShotID(''); setShotDraft(emptyShot(episode.shots.length + 1)); }}>{t('addShot')}</button></div>{episode.shots.map((item) => <button key={item.id} className={shot?.id === item.id ? 'selected' : ''} onClick={() => { setDraftingNewShot(false); setShotID(item.id); }}><span>{String(item.order).padStart(2, '0')}</span><div><strong>{item.title || t('untitledShot')}</strong><small>{item.duration}s · {item.dialogue?.length ?? 0} {t('dialogueLines')}</small></div></button>)}</aside>;
  }

  function Library() {
    const normalizedQuery = query.trim().toLocaleLowerCase(locale);
    const visibleDramas = dramas.filter((item) => {
      const matchesStatus = statusFilter === 'all' || item.status === statusFilter;
      const haystack = `${item.title} ${item.logline} ${item.genre}`.toLocaleLowerCase(locale);
      return matchesStatus && (!normalizedQuery || haystack.includes(normalizedQuery));
    });
    const recent = dramas[0];
    return AppShell(<main className="library"><header className="library-head"><div><p className="eyebrow">{t('workspace')}</p><h1>{t('libraryTitle')}</h1><p>{t('librarySubtitle')}</p></div><button className="primary" onClick={openPlanning}>{t('createDrama')}</button></header><div className="library-toolbar"><input type="search" value={query} onChange={(event) => setQuery(event.target.value)} placeholder={t('searchDrama')} aria-label={t('searchDrama')} /><div className="status-filters">{(['all', 'planning', 'production', 'completed'] as DramaStatusFilter[]).map((status) => { const count = status === 'all' ? dramas.length : dramas.filter((item) => item.status === status).length; return <button key={status} className={statusFilter === status ? 'active' : ''} disabled={count === 0 && statusFilter !== status} onClick={() => setStatusFilter(status)}>{t(`status_${status}`)}<span className="filter-count">{count}</span></button>; })}</div></div>{recent && !query && statusFilter === 'all' && <section className="recent-project"><div className="recent-cover">{recent.coverURL ? <img src={recent.coverURL} alt={recent.title} /> : <span>{t('noCover')}</span>}</div><div><p className="eyebrow">{t('continueCreating')}</p><h2>{recent.title}</h2><p>{recent.logline || t('noLogline')}</p><small>{t('episodeCount', { count: recent.episodes.length })}</small></div><button className="ghost" onClick={() => enterProject(recent)}>{t('continueButton')}</button></section>}<section className="drama-list">{visibleDramas.map((item) => <article className="drama-row" key={item.id}><button className="row-cover" onClick={() => enterProject(item)}>{item.coverURL ? <img src={item.coverURL} alt={item.title} /> : <span>{t('noCover')}</span>}</button><div className="row-copy"><div><h2>{item.title}</h2><span className={`status-pill status-${item.status}`}>{t(`status_${item.status}`)}</span></div><p>{item.logline || t('noLogline')}</p><small>{item.genre} · {item.format} · {t('episodeCount', { count: item.episodes.length })}</small></div><button className="ghost" onClick={() => enterProject(item)}>{t('continueButton')}</button></article>)}{visibleDramas.length === 0 && <div className="empty-library"><h2>{t('emptyLibrary')}</h2><p>{t(query ? 'emptySearchHint' : 'emptyLibraryHint')}</p><button className="primary" onClick={openPlanning}>{t('createDrama')}</button></div>}</section></main>);
  }

  function ModelRouting() {
    return <div className="routing"><label>{t('chatProvider')}<Dropdown ariaLabel={t('chatProvider')} value={assistantProvider} options={providers.map((item) => ({ value: item.providerID, label: item.displayName }))} onChange={(next) => { setAssistantProvider(next); setAssistantModel(providers.find(item => item.providerID === next)?.flashModel || providers.find(item => item.providerID === next)?.models[0] || ''); }} /></label><label>{t('chatModel')}<Dropdown ariaLabel={t('chatModel')} value={assistantModel} options={(provider?.models ?? []).map((item) => ({ value: item, label: item }))} onChange={setAssistantModel} allowCustom disabled={loadingModels} customLabel={t('customModel')} customPlaceholder={t('customModelHint')} placeholder={t('chatModel')} /></label></div>;
  }

  function Planning() {
    return AppShell(<main className="planning-shell"><header className="project-header"><div><button className="breadcrumb" onClick={() => setStage('library')}>{t('allProjects')}</button><span>{t('planningTitle')}</span></div></header><div className="planning-grid"><section className="chat-panel"><div className="section-title"><p className="eyebrow">{t('aiPlanning')}</p><h1>{t('tellStory')}</h1><p>{t('planningHint')}</p></div><div className="chat-history" aria-live="polite"><div className="chat-message assistant"><strong>{t('plannerName')}</strong><p>{t('plannerWelcome')}</p></div>{plannerMessages.map((message) => <div className={`chat-message ${message.role}`} key={message.id}><strong>{t(message.role === 'user' ? 'you' : 'plannerName')}</strong><p>{message.display}</p></div>)}</div><div className="composer">{busy === 'plan' && <div className="stream-line" role="status" aria-live="polite"><span className="stream-dot" aria-hidden="true" />{streamingText ? <span className="stream-text">{streamingText}</span> : <span className="stream-text muted">{t('planningBusy')}</span>}<button className="ghost" onClick={() => stopPlanner()}>{t('stopRequest')}</button></div>}{attachedSkills.length > 0 && <div className="skill-strip" aria-label={t('attachedSkills')}>{attachedSkills.map((item) => <span className="skill-chip" key={item.identifier}>{item.name}<button type="button" onClick={() => setAttachedSkills((current) => current.filter((entry) => entry.identifier !== item.identifier))} aria-label={t('detachSkill', { name: item.name })}>\u00d7</button></span>)}</div>}<div className="composer-input"><textarea className="idea-box" value={idea} placeholder={t(plan ? 'revisionPlaceholder' : 'ideaPlaceholder')} onChange={(event) => { setIdea(event.target.value); setSkillQuery(skills.length > 0 ? skillQueryAt(event.target.value, event.target.selectionStart ?? event.target.value.length) : null); }} onKeyDown={(event) => { if (event.key === 'Escape' && skillQuery !== null) { event.preventDefault(); setSkillQuery(null); } if (event.key === 'Enter' && skillQuery !== null && skillMatches[0]) { event.preventDefault(); attachSkill(skillMatches[0]); } }} onBlur={() => window.setTimeout(() => setSkillQuery(null), 120)} />{skillQuery !== null && <div className="skill-menu" role="listbox" aria-label={t('skillPicker')}>{skillMatches.length === 0 ? <p className="skill-empty">{t('noSkillMatch')}</p> : skillMatches.map((item) => <button type="button" role="option" aria-selected={false} key={item.identifier} onMouseDown={(event) => { event.preventDefault(); attachSkill(item); }}><strong>{item.name}</strong><span>{item.description}</span><small>{item.identifier}</small></button>)}</div>}</div>{ModelRouting()}<button className="primary wide" disabled={busy === 'plan'} onClick={() => void askPlanner()}>{busy === 'plan' ? t('planningBusy') : t(plan ? 'revisePlan' : 'generatePlan')}</button><small>{t('markdownContract')}</small></div></section><section className="plan-card">{plan ? <><div className="plan-summary"><span>{plan.genre}</span><h2>{plan.title}</h2><small>{plan.format}</small></div><div className="plan-body"><div className="facts"><span>{t('episodeCount', { count: plan.episodeCount })}</span><span>{t('minutesPerEpisode', { count: Math.round(plan.episodeDurationSeconds / 60) })}</span><span>{plan.audience}</span></div><h3>{t('logline')}</h3><p>{plan.logline}</p><h3>{t('coreConflict')}</h3><p>{plan.coreConflict}</p><h3>{t('seriesArc')}</h3><p>{plan.arc}</p><div className="actions"><button className="ghost" onClick={() => setIdea(t('revisionStarter'))}>{t('revise')}</button><button className="primary" disabled={busy === 'confirm'} onClick={() => void confirmPlan()}>{t('confirmAndSave')}</button></div></div></> : <div className="empty-plan"><h2>{t('planWaiting')}</h2><p>{t('planWaitingHint')}</p></div>}</section></div></main>);
  }

  function Characters() {
    const current = selectedCharacter;
    const view = characterView(current);
    const differences = draftDifferences(current);
    const hasDraft = differences.length > 0;
    const chatForObject = characterChat.filter((item) => !item.objectID || item.objectID === characterID);
    return AppShell(<div className="page">{ProjectHeader()}<main className="content">
      <div className="page-heading"><div><p className="eyebrow">{t('stage_characters')}</p><h1>{t('characterTitle')}</h1><p>{t('characterHint')}</p></div><div className="heading-actions">{(drama?.characters.length ?? 0) > 0 && <button className="ghost" disabled={busy === 'character-ask' || batchProgress !== null} onClick={() => void draftAllCharacters()}>{batchProgress ? t('batchDraftProgress', { done: batchProgress.done + 1, total: batchProgress.total }) : t('draftAllCharacters')}</button>}<button className="ghost" onClick={() => { setCharacterID(''); setCharacter({ id: '', name: '', description: '', visualPrompt: '' }); setShowDiff(false); setStaleCandidate(null); }}>{t('newCharacter')}</button></div></div>
      <div className="character-grid">
        <section className="character-list">{(drama?.characters.length ?? 0) === 0 && <p className="empty-hint">{t('noCharactersYet')}</p>}{drama?.characters.map((item) => <button key={item.id} className={item.id === characterID ? 'chosen' : ''} aria-current={item.id === characterID} onClick={() => void selectCharacter(item)}>{item.candidates?.find((candidate) => candidate.id === item.selectedCandidateID) ? <img className="avatar photo" src={item.candidates.find((candidate) => candidate.id === item.selectedCandidateID)?.mediaURL} alt={item.name} /> : <div className="avatar">{item.name.slice(0, 1)}</div>}<div><strong>{item.name}</strong><p>{item.description}</p><small>{t('identityVersion', { version: item.identityVersion })}{draftDifferences(item).length > 0 ? ` \u00b7 ${t('draftBadge')}` : ''}</small></div></button>)}</section>
        <section className="editor-card">
          {hasDraft && <div className="identity-note draft-note"><strong>{t('draftPending')}</strong><span>{t('draftPendingHint')}</span><button className="ghost" onClick={() => setShowDiff((value) => !value)}>{t(showDiff ? 'hideDiff' : 'showDiff')}</button></div>}
          {hasDraft && showDiff && <div className="diff-list">{differences.map((row) => <div className="diff-row" key={row.field}><strong>{t(row.field === 'name' ? 'characterName' : row.field === 'description' ? 'characterDescription' : 'identityPrompt')}</strong><p className="diff-before">{row.before || t('diffEmpty')}</p><p className="diff-after">{row.after}</p></div>)}</div>}
          {staleCandidate && staleCandidate.characterID === characterID && <div className="identity-note draft-note"><strong>{t('staleCandidate')}</strong><span>{t('staleCandidateHint')}</span><button className="ghost" onClick={() => void acceptStaleCandidate()}>{t('staleCandidateAccept')}</button><button className="ghost" onClick={() => setStaleCandidate(null)}>{t('staleCandidateDiscard')}</button></div>}
          <label>{t('characterName')}<input value={character.name} onChange={(event) => setCharacter({ ...character, name: event.target.value })} onBlur={() => { if (characterID && character.name !== view.name) void saveCharacterDraft({ name: character.name }, current?.draftRev ?? 0, { silent: true }); }} /></label>
          <label>{t('characterDescription')}<textarea value={character.description} onChange={(event) => setCharacter({ ...character, description: event.target.value })} onBlur={() => { if (characterID && character.description !== view.description) void saveCharacterDraft({ description: character.description }, current?.draftRev ?? 0, { silent: true }); }} /></label>
          <label>{t('identityPrompt')}<textarea className="tall" value={character.visualPrompt} onChange={(event) => setCharacter({ ...character, visualPrompt: event.target.value })} onBlur={() => { if (characterID && character.visualPrompt !== view.visualPrompt) void saveCharacterDraft({ visualPrompt: character.visualPrompt }, current?.draftRev ?? 0, { silent: true }); }} placeholder={t('identityPromptHint')} /></label>
          <div className="identity-note"><strong>{t('identityLock')}</strong><span>{t('identityLockHint')}</span></div>
          <div className="generation-controls"><Dropdown ariaLabel={t('imageModel')} value={imageModel} options={imageModels.map((model) => ({ value: model, label: model }))} onChange={(next) => setImageModel(next as ImageModel)} /><Dropdown ariaLabel={t('imageCount')} value={String(candidateCount)} options={[1, 2, 4, 6].map((count) => ({ value: String(count), label: t('countImages', { count }) }))} onChange={(next) => setCandidateCount(Number(next))} /></div>
          {current && <div className="identity-candidates">{current.candidates.map((candidate) => <button className={candidate.id === current.selectedCandidateID ? 'chosen' : ''} key={candidate.id} onClick={() => void chooseCharacterImage(candidate.id)}><img src={candidate.mediaURL} alt={current.name} /></button>)}</div>}
          <div className="actions">
            {current && <button className="ghost" disabled={busy === 'character-ask'} onClick={() => void draftCharacter(current)}>{t(view.description.trim() || view.visualPrompt.trim() ? 'redraftCharacter' : 'draftCharacter')}</button>}
            <button className="ghost" disabled={busy === 'characterImage'} onClick={() => void generateCharacterImages()}>{t('generateIdentity')}</button>
            {hasDraft && <button className="ghost" onClick={() => void discardCharacterDraft()}>{t('discardDraft')}</button>}
            {hasDraft ? <button className="primary" disabled={busy === 'commit'} onClick={() => void commitCharacterDraft()}>{t('adoptDraft')}</button>
                      : <button className="primary" disabled={busy === 'character'} onClick={() => void saveCharacter()}>{t('saveCharacter')}</button>}
          </div>
        </section>
        <section className="chat-panel character-chat">
          <div className="section-title"><p className="eyebrow">{t('characterCoCreation')}</p><h2>{current ? current.name || t('newCharacter') : t('selectCharacterFirst')}</h2><p>{t('characterCoCreationHint')}</p></div>
          <div className="chat-history" aria-live="polite">{chatForObject.map((message) => <div className={`chat-message ${message.role}`} key={message.id}><strong>{t(message.role === 'user' ? 'you' : 'characterAssistant')}</strong><p>{message.content}</p></div>)}</div>
          <div className="composer">
            {busy === 'character-ask' && <div className="stream-line" role="status" aria-live="polite"><span className="stream-dot" aria-hidden="true" />{structuredStreaming ? <span className="stream-text muted">{t('structuredIncoming')}</span> : streamingText ? <span className="stream-text">{streamingText}</span> : <span className="stream-text muted">{t('characterBusy')}</span>}<button className="ghost" onClick={() => stopCharacterRequest()}>{t('stopRequest')}</button></div>}
            <div className="composer-input"><textarea className="idea-box" value={characterInput} placeholder={t('characterAskPlaceholder')} disabled={!current} onChange={(event) => setCharacterInput(event.target.value)} /></div>
            <button className="primary" disabled={!current || busy === 'character-ask'} onClick={() => void askCharacter()}>{t('askCharacter')}</button>
          </div>
        </section>
      </div>
    </main></div>);
  }

  function Script() {
    return AppShell(<div className="page">{ProjectHeader()}<main className="content">{EpisodeSwitcher()}<div className="page-heading"><div><p className="eyebrow">{t('stage_script')}</p><h1>{t('scriptTitle')}</h1><p>{t('scriptHint')}</p></div><button className="primary" disabled={busy === 'episode'} onClick={() => void saveEpisode()}>{t('saveEpisode')}</button></div><div className="script-grid"><section className="editor-card"><label>{t('episodeTitle')}<input value={episodeDraft.title} onChange={(event) => setEpisodeDraft({ ...episodeDraft, title: event.target.value })} /></label><label>{t('episodeSummary')}<textarea value={episodeDraft.summary} onChange={(event) => setEpisodeDraft({ ...episodeDraft, summary: event.target.value })} /></label><label>{t('episodeScript')}<textarea className="script-area" value={episodeDraft.script} onChange={(event) => setEpisodeDraft({ ...episodeDraft, script: event.target.value })} /></label></section><aside className="script-guide"><h3>{t('episodeChecklist')}</h3><p>{t('checkHook')}</p><p>{t('checkConflict')}</p><p>{t('checkCliffhanger')}</p><button className="ghost" onClick={() => setStage('storyboard')}>{t('goStoryboard')}</button></aside></div></main></div>);
  }

  function Storyboard() {
    return AppShell(<div className="page">{ProjectHeader()}<main className="content">{EpisodeSwitcher()}<div className="board-layout">{ShotRail()}<section className="shot-editor"><div className="page-heading compact"><div><p className="eyebrow">{t('shotNumber', { number: shotDraft.order })}</p><h1>{t('storyboardTitle')}</h1></div><button className="primary" disabled={busy === 'shot'} onClick={() => void saveShot()}>{t('saveShot')}</button></div><div className="two-col"><label>{t('shotTitle')}<input value={shotDraft.title} onChange={(event) => setShotDraft({ ...shotDraft, title: event.target.value })} /></label><label>{t('durationSeconds')}<input type="number" value={shotDraft.duration} onChange={(event) => setShotDraft({ ...shotDraft, duration: Number(event.target.value) })} /></label></div><label>{t('shotStory')}<textarea value={shotDraft.summary} onChange={(event) => setShotDraft({ ...shotDraft, summary: event.target.value })} /></label><div className="dialogue-head"><strong>{t('dialogue')}</strong><button className="ghost" onClick={() => setShotDraft({ ...shotDraft, dialogue: [...shotDraft.dialogue, { id: localID(), speaker: '', text: '' }] })}>{t('addLine')}</button></div>{shotDraft.dialogue.map((line, index) => <div className="dialogue-row" key={line.id}><input value={line.speaker} placeholder={t('speaker')} onChange={(event) => { const lines = [...shotDraft.dialogue]; lines[index] = { ...line, speaker: event.target.value }; setShotDraft({ ...shotDraft, dialogue: lines }); }} /><textarea value={line.text} placeholder={t('lineText')} onChange={(event) => { const lines = [...shotDraft.dialogue]; lines[index] = { ...line, text: event.target.value }; setShotDraft({ ...shotDraft, dialogue: lines }); }} /></div>)}<div className="three-col"><label>{t('startAction')}<textarea value={shotDraft.actionStart} onChange={(event) => setShotDraft({ ...shotDraft, actionStart: event.target.value })} /></label><label>{t('endAction')}<textarea value={shotDraft.actionEnd} onChange={(event) => setShotDraft({ ...shotDraft, actionEnd: event.target.value })} /></label><label>{t('cameraIntent')}<textarea value={shotDraft.cameraIntent} onChange={(event) => setShotDraft({ ...shotDraft, cameraIntent: event.target.value })} /></label></div></section></div></main></div>);
  }

  function FrameColumn(kind: 'start' | 'end') {
    const candidates = kind === 'start' ? shot?.startCandidates ?? [] : shot?.endCandidates ?? [];
    const selectedID = kind === 'start' ? shot?.selectedStartID : shot?.selectedEndID;
    const prompt = kind === 'start' ? shotDraft.startPrompt : shotDraft.endPrompt;
    return <section className="frame-column"><div className="frame-title"><div><span>{kind === 'start' ? t('startLabel') : t('endLabel')}</span><div><h2>{t(kind === 'start' ? 'startFrame' : 'endFrame')}</h2><p>{t(kind === 'start' ? 'startFrameHint' : 'endFrameHint')}</p></div></div><small>{candidates.length} {t('candidates')}</small></div><textarea className="prompt-box" value={prompt} placeholder={t('framePromptPlaceholder')} onChange={(event) => setShotDraft({ ...shotDraft, [kind === 'start' ? 'startPrompt' : 'endPrompt']: event.target.value })} /><div className="candidate-grid">{candidates.map((candidate) => <button className={selectedID === candidate.id ? 'chosen' : ''} key={candidate.id} onClick={() => void chooseFrame(kind, candidate.id)}><img src={candidate.mediaURL} alt={t('frameCandidate')} /><span>{selectedID === candidate.id ? t('selected') : t('select')}</span></button>)}{candidates.length === 0 && <div className="candidate-empty">{t('noCandidates')}</div>}</div><button className="primary wide" disabled={busy === kind} onClick={() => void generateFrames(kind)}>{busy === kind ? t('generatingImages') : t('generateCandidates', { count: candidateCount })}</button></section>;
  }

  function Frames() {
    return AppShell(<div className="page">{ProjectHeader()}<main className="content">{EpisodeSwitcher()}<div className="board-layout">{ShotRail()}<section className="shot-editor"><div className="page-heading compact"><div><p className="eyebrow">{shot?.title || t('selectShot')}</p><h1>{t('frameTitle')}</h1><p>{t('frameHint')}</p></div><div className="generation-controls"><Dropdown ariaLabel={t('imageModel')} value={imageModel} options={imageModels.map((model) => ({ value: model, label: model }))} onChange={(next) => setImageModel(next as ImageModel)} /><Dropdown ariaLabel={t('imageCount')} value={String(candidateCount)} options={[1, 2, 4, 6].map((count) => ({ value: String(count), label: t('countImages', { count }) }))} onChange={(next) => setCandidateCount(Number(next))} /></div></div><div className="frames-grid">{FrameColumn('start')}{FrameColumn('end')}</div></section></div></main></div>);
  }

  function Video() {
    const start = selectedCandidate(shot, 'start'); const end = selectedCandidate(shot, 'end');
    return AppShell(<div className="page">{ProjectHeader()}<main className="content">{EpisodeSwitcher()}<div className="board-layout">{ShotRail()}<section className="shot-editor"><div className="page-heading compact"><div><p className="eyebrow">{shot?.title || t('selectShot')}</p><h1>{t('videoTitle')}</h1><p>{t('videoHint')}</p></div></div><div className="video-flow"><div className="anchor-card"><span>{t('selectedStart')}</span>{start ? <img src={start.mediaURL} alt={t('startFrame')} /> : <div>{t('notSelected')}</div>}</div><div className="flow-duration"><strong>{t('durationValue', { count: shot?.duration ?? 4 })}</strong><small>{t('frameTransition')}</small></div><div className="anchor-card muted"><span>{t('selectedEnd')}</span>{end ? <img src={end.mediaURL} alt={t('endFrame')} /> : <div>{t('optional')}</div>}</div></div><div className="capability-note"><strong>{t('providerCapability')}</strong><p>{t('firstFrameOnly')}</p></div><div className="mode-grid"><label className="mode active"><input type="radio" checked readOnly /><strong>{t('firstFrameMode')}</strong><span>{t('firstFrameModeHint')}</span></label><label className="mode disabled"><input type="radio" disabled /><strong>{t('lockedEndsMode')}</strong><span>{t('lockedEndsModeHint')}</span></label></div><div className="submit-row"><label>{t('videoDrawCount')}<Dropdown ariaLabel={t('videoDrawCount')} value={String(videoCount)} options={[1, 2, 3, 4].map((count) => ({ value: String(count), label: t('countVideos', { count }) }))} onChange={(next) => setVideoCount(Number(next))} /></label><button className="primary" disabled={busy === 'video' || !start} onClick={() => void generateVideos()}>{t('submitVideo')}</button></div></section></div></main></div>);
  }

  let body = Library();
  if (stage === 'settings') body = Settings();
  if (stage === 'planning') body = Planning();
  if (stage === 'characters') body = Characters();
  if (stage === 'script') body = Script();
  if (stage === 'storyboard') body = Storyboard();
  if (stage === 'frames') body = Frames();
  if (stage === 'video') body = Video();
  // role="alert" 让屏幕阅读器读出结果；用 button 而不是 div 是为了键盘也能关掉。
  return <>{body}{(notice || failure) && <div className="toast-layer" role="alert" aria-live={failure ? 'assertive' : 'polite'}><button type="button" className={`toast ${failure ? 'error' : ''}`} onClick={() => { setNotice(''); setFailure(''); }}>{failure || notice}<span className="toast-dismiss" aria-hidden="true">×</span><span className="visually-hidden">{t('dismissNotice')}</span></button></div>}</>;
}
