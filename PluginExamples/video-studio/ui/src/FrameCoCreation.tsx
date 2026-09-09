import { useEffect, useRef, useState } from 'react';
import type { ReactNode } from 'react';
import { callCommand, parseFencedDraft, requestBudget } from './bridge';
import type { ChatMessage, Drama, Episode, Shot } from './types';

type FrameDraft = { startPrompt?: string; endPrompt?: string };
type Props = {
  drama: Drama; episode: Episode; shot: Shot;
  provider: string; model: string; routing: ReactNode;
  t: (key: string) => string;
  onUpdate: (drama: Drama) => void;
  blocked: boolean;
  onBusyChange: (busy: boolean) => void;
  buildSystem: () => Promise<string>;
};

export function FrameCoCreation({ drama, episode, shot, provider, model, routing, t, onUpdate, blocked, onBusyChange, buildSystem }: Props) {
  const [messages, setMessages] = useState<ChatMessage[]>([]);
  const [input, setInput] = useState('');
  const [busy, setBusy] = useState(false);
  const [failure, setFailure] = useState('');
  const active = useRef('');

  useEffect(() => {
    let mounted = true;
    void callCommand<{ ok: boolean; messages?: ChatMessage[] }>('chat.list', { dramaID: drama.id, stage: 'frames' })
      .then((result) => { if (mounted) setMessages((result.messages ?? []).filter((item) => item.objectID === shot.id)); })
      .catch((error: unknown) => { if (mounted) setFailure(String(error)); });
    return () => { mounted = false; const id = active.current; active.current = ''; if (id) { void window.willdeep?.ai?.cancel?.(id); onBusyChange(false); } };
  }, [drama.id, shot.id]);

  async function append(role: 'user' | 'assistant', content: string) {
    const result = await callCommand<{ ok: boolean; message?: ChatMessage }>('chat.append', {
      dramaID: drama.id, stage: 'frames', message: { role, content, objectID: shot.id, draftRev: shot.draftRev ?? 0 },
    });
    if (!result.ok) throw new Error(t('operationFailed'));
    if (result.message) setMessages((items) => [...items, result.message as ChatMessage]);
  }

  async function ask() {
    if (active.current || blocked) return;
    const question = input.trim() || t('frameFirstDraftRequest');
    const streamID = `frames-${Date.now()}-${Math.random().toString(36).slice(2)}`;
    active.current = streamID;
    setBusy(true); onBusyChange(true); setFailure('');
    try {
      const context = JSON.stringify({
        drama: { title: drama.title, genre: drama.genre, tone: drama.tone, logline: drama.logline },
        characters: drama.characters.map(({ id, name, description, visualPrompt }) => ({ id, name, description, visualPrompt })),
        episode: { title: episode.title, summary: episode.summary },
        shot: { title: shot.title, summary: shot.summary, dialogue: shot.dialogue, actionStart: shot.actionStart, actionEnd: shot.actionEnd, cameraIntent: shot.cameraIntent,
          startPrompt: shot.draft?.startPrompt ?? shot.startPrompt, endPrompt: shot.draft?.endPrompt ?? shot.endPrompt },
      });
      const request = [...messages.slice(-6).map(({ role, content }) => ({ role, content })), { role: 'user' as const, content: `${context}\n\n${question}` }];
      const system = await buildSystem();
      if (!requestBudget(system, request).withinLimits) throw new Error(t('frameContextTooLarge'));
      await append('user', question);
      const response = await window.willdeep?.ai?.complete({ system, messages: request, provider, model, streamID });
      if (active.current !== streamID) return;
      if (!response) throw new Error(t('operationFailed'));
      const parsed = parseFencedDraft<FrameDraft>(response.text, 'short_drama_frames', ['startPrompt', 'endPrompt']);
      await append('assistant', parsed.kind === 'draft' ? parsed.note || t('draftSaved') : response.text);
      if (active.current !== streamID) return;
      if (parsed.kind === 'invalid') throw new Error(t('frameDraftInvalid'));
      if (parsed.kind === 'draft') {
        const result = await callCommand<{ ok: boolean; drama?: Drama; error?: { message?: string } }>('drama.saveDraft', {
          dramaID: drama.id, episodeID: episode.id, shotID: shot.id, scope: 'shot', expectedDraftRev: shot.draftRev ?? 0,
          draft: parsed.value,
        });
        if (!result.ok || !result.drama) throw new Error(result.error?.message || t('operationFailed'));
        onUpdate(result.drama);
      }
      setInput('');
    } catch (error) { if (active.current === streamID) setFailure(String(error)); }
    finally { if (active.current === streamID) { active.current = ''; setBusy(false); onBusyChange(false); } }
  }

  function stop() {
    const id = active.current;
    active.current = ''; setBusy(false); onBusyChange(false);
    if (id) void window.willdeep?.ai?.cancel?.(id);
  }

  return <section className="chat-panel frame-chat" aria-label={t('frameCoCreation')}>
    <h2>{t('frameCoCreation')}</h2><p>{t('frameCoCreationHint')}</p>
    <div className="chat-history" aria-live="polite">{messages.map((message) => <div className={`chat-message ${message.role}`} key={message.id}><strong>{t(message.role === 'user' ? 'you' : 'frameAssistant')}</strong><p>{message.content}</p></div>)}</div>
    {failure && <p role="alert">{failure}</p>}
    {blocked && <p>{t('saveChangesBeforeAdopting')}</p>}
    <label>{t('frameRevisionLabel')}<textarea value={input} onChange={(event) => setInput(event.target.value)} disabled={busy} /></label>
    {routing}
    {busy ? <div role="status">{t('frameWriting')}<button onClick={stop}>{t('stopRequest')}</button></div> : <button className="primary" disabled={blocked} onClick={() => void ask()}>{t('frameAsk')}</button>}
  </section>;
}
