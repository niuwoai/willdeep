import { useCallback, useEffect, useMemo, useState } from 'react';
import { activeStates, callCommand, loadProviders, loadStudio, parseVideoPlan } from './bridge';
import { createTranslator, localeFromContext } from './i18n';
import type { JobState, ListResponse, ProviderEntry, ProviderStatus, StudioSettings, VideoJob } from './types';
import './styles.css';

type Filter = 'all' | 'draft' | 'active' | 'completed' | 'failed';

type FormState = {
  draftID: string;
  title: string;
  prompt: string;
  negativePrompt: string;
  referenceImagePath: string;
  seed: string;
};

const defaultSettings: StudioSettings = {
  assistantProviderID: null,
  assistantModel: null,
  videoModel: 'MiniMax-H3',
  duration: 4,
  width: 832,
  height: 480,
  inferenceSteps: 20,
  autoDownload: true,
};

const emptyForm: FormState = {
  draftID: '',
  title: '',
  prompt: '',
  negativePrompt: '',
  referenceImagePath: '',
  seed: '',
};

function resultError(payload: { error?: { message?: string; details?: { message?: string } } }): string {
  return payload.error?.details?.message ?? payload.error?.message ?? '';
}

function stateTranslationKey(state: JobState): string {
  const keys: Record<JobState, string> = {
    draft: 'stateDraft',
    submitting: 'stateSubmitting',
    queued: 'stateQueued',
    in_progress: 'stateInProgress',
    completed: 'stateCompleted',
    failed: 'stateFailed',
  };
  return keys[state];
}

function errorSummary(error: unknown): string {
  if (!error) return '';
  if (typeof error === 'string') return error;
  if (typeof error !== 'object') return String(error);
  const object = error as Record<string, unknown>;
  if (typeof object.message === 'string') return object.message;
  if (object.details && typeof object.details === 'object') {
    const details = object.details as Record<string, unknown>;
    if (typeof details.message === 'string') return details.message;
  }
  return JSON.stringify(error);
}

export default function App() {
  const contextLocale = window.willdeep?.getContext().locale;
  const [locale, setLocale] = useState(localeFromContext(contextLocale));
  const t = useMemo(() => createTranslator(locale), [locale]);
  const [jobs, setJobs] = useState<VideoJob[]>([]);
  const [counts, setCounts] = useState<Record<string, number>>({});
  const [settings, setSettings] = useState<StudioSettings>(defaultSettings);
  const [provider, setProvider] = useState<ProviderStatus>({ id: 'openai-videos-async', apiConfigured: false });
  const [providers, setProviders] = useState<ProviderEntry[]>([]);
  const [filter, setFilter] = useState<Filter>('all');
  const [form, setForm] = useState<FormState>(emptyForm);
  const [busy, setBusy] = useState(false);
  const [aiBusy, setAIBusy] = useState(false);
  const [notice, setNotice] = useState('');
  const [failure, setFailure] = useState('');
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [confirmation, setConfirmation] = useState<{ command: string; job: VideoJob } | null>(null);
  const [jobBusy, setJobBusy] = useState(false);

  useEffect(() => {
    document.title = t('appTitle');
  }, [t]);

  const applyList = useCallback((payload: ListResponse) => {
    if (!payload.ok) throw new Error(resultError(payload) || 'list_failed');
    setJobs(payload.jobs ?? []);
    setCounts(payload.counts ?? {});
    setSettings(payload.settings ?? defaultSettings);
    setProvider(payload.provider ?? { id: 'openai-videos-async', apiConfigured: false });
  }, []);

  const reload = useCallback(async (silent = false) => {
    try {
      const payload = await loadStudio();
      applyList(payload);
      if (!silent) setFailure('');
    } catch (error) {
      if (!silent) setFailure(error instanceof Error ? t(error.message) : t('unknownError'));
    }
  }, [applyList, t]);

  useEffect(() => {
    void reload();
    void loadProviders().then(setProviders).catch(() => setProviders([]));
  }, [reload]);

  useEffect(() => {
    const listener = (event: Event) => {
      const detail = (event as CustomEvent<{ locale?: string }>).detail;
      setLocale(localeFromContext(detail?.locale));
    };
    window.addEventListener('willdeep:context-changed', listener);
    return () => window.removeEventListener('willdeep:context-changed', listener);
  }, []);

  const hasActiveJobs = jobs.some((job) => activeStates.has(job.state));
  useEffect(() => {
    if (!hasActiveJobs) return undefined;
    let stopped = false;
    let timer: number;
    const poll = async () => {
      try {
        await callCommand<{ ok: boolean }>('video.refreshActive');
        if (!stopped) await reload(true);
      } catch {
        if (!stopped) setFailure(t('pollFailed'));
      } finally {
        if (!stopped) timer = window.setTimeout(() => void poll(), 5_000);
      }
    };
    timer = window.setTimeout(() => void poll(), 5_000);
    return () => { stopped = true; window.clearTimeout(timer); };
  }, [hasActiveJobs, reload]);

  const visibleJobs = useMemo(() => jobs.filter((job) => {
    if (filter === 'all') return true;
    if (filter === 'active') return activeStates.has(job.state);
    return job.state === filter;
  }), [filter, jobs]);

  const selectedProvider = providers.find((entry) => entry.providerID === settings.assistantProviderID);

  function resetForm() {
    setForm(emptyForm);
    setNotice('');
    setFailure('');
  }

  function editJob(job: VideoJob) {
    setForm({
      draftID: job.state === 'draft' ? job.id : '',
      title: job.title ?? '',
      prompt: job.prompt ?? '',
      negativePrompt: job.negativePrompt ?? '',
      referenceImagePath: job.referenceImagePath ?? '',
      seed: job.seed == null ? '' : String(job.seed),
    });
    window.scrollTo({ top: 0, behavior: 'smooth' });
  }

  async function chooseReference() {
    setFailure('');
    try {
      const payload = await callCommand<{ ok: boolean; path?: string; error?: { message?: string } }>('video.pickReference');
      if (!payload.ok || !payload.path) throw new Error(resultError(payload));
      setForm((current) => ({ ...current, referenceImagePath: payload.path ?? '' }));
    } catch (error) {
      setFailure(error instanceof Error ? t(error.message) : t('commandFailed'));
    }
  }

  async function directWithAI() {
    if (!form.prompt.trim()) {
      setFailure(t('missingPrompt'));
      return;
    }
    setAIBusy(true);
    setFailure('');
    try {
      const request: {
        system: string;
        messages: Array<{ role: 'user' | 'assistant'; content: string }>;
        provider?: string;
        model?: string;
        maxOutputTokens?: number;
      } = {
        system: t('aiSystem'),
        messages: [{
          role: 'user',
          content: t('aiUserTemplate', {
            prompt: form.prompt,
            mode: form.referenceImagePath ? t('imageToVideo') : t('textToVideo'),
            duration: settings.duration,
            width: settings.width,
            height: settings.height,
          }),
        }],
        maxOutputTokens: 1_000,
      };
      if (settings.assistantProviderID) request.provider = settings.assistantProviderID;
      if (settings.assistantModel) request.model = settings.assistantModel;
      const response = await window.willdeep?.ai?.complete(request);
      if (!response) throw new Error('ai_unavailable');
      const plan = parseVideoPlan(response.text);
      if (!plan) {
        setFailure(t('invalidAIResponse'));
        return;
      }
      setForm((current) => ({
        ...current,
        title: plan.title || current.title,
        prompt: plan.prompt,
        negativePrompt: plan.negativePrompt,
      }));
    } catch {
      setFailure(t('aiUnavailable'));
    } finally {
      setAIBusy(false);
    }
  }

  async function generate() {
    if (!form.prompt.trim()) {
      setFailure(t('missingPrompt'));
      return;
    }
    setBusy(true);
    setFailure('');
    setNotice('');
    try {
      const payload = await callCommand<{ ok: boolean; job?: VideoJob; error?: { message?: string; details?: { message?: string } } }>(
        'video.generate',
        {
          draftID: form.draftID || undefined,
          title: form.title,
          prompt: form.prompt,
          negativePrompt: form.negativePrompt,
          referenceImagePath: form.referenceImagePath || undefined,
          model: settings.videoModel,
          duration: settings.duration,
          width: settings.width,
          height: settings.height,
          inferenceSteps: settings.inferenceSteps,
          seed: form.seed || undefined,
          source: form.draftID ? 'draft' : 'studio',
        },
      );
      if (!payload.ok) throw new Error(resultError(payload) || t('commandFailed'));
      resetForm();
      await reload(true);
    } catch (error) {
      setFailure(error instanceof Error ? t(error.message) : t('commandFailed'));
      await reload(true);
    } finally {
      setBusy(false);
    }
  }

  async function runJobCommand(command: string, job: VideoJob) {
    if (jobBusy) return;
    setJobBusy(true);
    setFailure('');
    try {
      const payload = await callCommand<{ ok: boolean; error?: { message?: string; details?: { message?: string } } }>(command, { id: job.id });
      if (!payload.ok) throw new Error(resultError(payload) || t('commandFailed'));
      await reload(true);
    } catch (error) {
      setFailure(error instanceof Error ? t(error.message) : t('commandFailed'));
      await reload(true);
    } finally {
      setJobBusy(false);
    }
  }

  async function confirmJobCommand() {
    if (!confirmation) return;
    const action = confirmation;
    setConfirmation(null);
    await runJobCommand(action.command, action.job);
  }

  async function saveSettings(next: StudioSettings) {
    setFailure('');
    try {
      const payload = await callCommand<{ ok: boolean; settings?: StudioSettings; error?: { message?: string } }>('video.settings', next);
      if (!payload.ok || !payload.settings) throw new Error(resultError(payload));
      setSettings(payload.settings);
      setNotice(t('saved'));
      setSettingsOpen(false);
    } catch (error) {
      setFailure(error instanceof Error ? t(error.message) : t('commandFailed'));
    }
  }

  const filters: Array<{ id: Filter; label: string }> = [
    { id: 'all', label: t('filtersAll') },
    { id: 'draft', label: t('filtersDraft') },
    { id: 'active', label: t('filtersActive') },
    { id: 'completed', label: t('filtersCompleted') },
    { id: 'failed', label: t('filtersFailed') },
  ];

  return (
    <main className="app-shell">
      <header className="topbar">
        <div>
          <h1>{t('appTitle')}</h1>
          <p>{t('appSubtitle')}</p>
        </div>
        <div className="top-actions">
          <button className="button secondary" onClick={resetForm}>{t('newVideo')}</button>
          <button className="button secondary" onClick={() => setSettingsOpen(true)}>{t('settings')}</button>
        </div>
      </header>

      <section className={`provider-banner ${provider.apiConfigured ? 'ready' : 'missing'}`}>
        <div>
          <strong>{provider.apiConfigured ? t('providerReady') : t('providerMissing')}</strong>
          <span>{t('providerHint')}</span>
        </div>
        <code>{provider.apiBase ?? provider.id}</code>
      </section>

      {failure && <div className="alert error" role="alert">{failure}</div>}
      {notice && <div className="alert success" role="status">{notice}</div>}

      <section className="composer-card">
        <div className="section-heading">
          <div>
            <span className="eyebrow">{form.referenceImagePath ? t('imageToVideo') : t('textToVideo')}</span>
            <h2>{t('ideaTitle')}</h2>
          </div>
          {form.draftID && <span className="draft-chip">{t('stateDraft')}</span>}
        </div>

        <div className="field-grid">
          <label className="field full">
            <span>{t('titleLabel')}</span>
            <input value={form.title} placeholder={t('titlePlaceholder')} onChange={(event) => setForm({ ...form, title: event.target.value })} />
          </label>
          <label className="field full">
            <span>{t('promptLabel')}</span>
            <textarea rows={5} value={form.prompt} placeholder={t('promptPlaceholder')} onChange={(event) => setForm({ ...form, prompt: event.target.value })} />
          </label>
          <label className="field full">
            <span>{t('negativeLabel')}</span>
            <textarea rows={2} value={form.negativePrompt} placeholder={t('negativePlaceholder')} onChange={(event) => setForm({ ...form, negativePrompt: event.target.value })} />
          </label>
          <label className="field reference-field">
            <span>{t('referenceLabel')}</span>
            <input value={form.referenceImagePath} placeholder={t('referencePlaceholder')} onChange={(event) => setForm({ ...form, referenceImagePath: event.target.value })} />
          </label>
          <div className="reference-actions">
            <button className="button secondary" onClick={() => void chooseReference()}>{t('choose')}</button>
            {form.referenceImagePath && <button className="button ghost" onClick={() => setForm({ ...form, referenceImagePath: '' })}>{t('clear')}</button>}
          </div>
        </div>

        <div className="composer-footer">
          <div className="parameter-summary">
            {t('modelAndSize', {
              model: settings.videoModel,
              width: settings.width,
              height: settings.height,
              duration: settings.duration,
            })}
          </div>
          <div className="composer-actions">
            <button className="button secondary" disabled={aiBusy || busy} onClick={() => void directWithAI()}>
              {aiBusy ? t('aiWorking') : t('aiDirect')}
            </button>
            <button className="button primary" disabled={busy || aiBusy || !provider.apiConfigured} onClick={() => void generate()}>
              {busy ? t('generating') : t('generate')}
            </button>
          </div>
        </div>
      </section>

      <nav className="filter-row" aria-label={t('filtersAll')}>
        {filters.map((item) => (
          <button key={item.id} className={filter === item.id ? 'filter active' : 'filter'} onClick={() => setFilter(item.id)}>
            <span>{item.label}</span>
            <b>{counts[item.id] ?? 0}</b>
          </button>
        ))}
        <button className="filter refresh-filter" onClick={() => void reload()}>{t('refresh')}</button>
      </nav>

      {visibleJobs.length === 0 ? (
        <section className="empty-state">
          <div className="empty-symbol">▶</div>
          <h2>{t('emptyTitle')}</h2>
          <p>{t('emptyBody')}</p>
        </section>
      ) : (
        <section className="job-grid">
          {visibleJobs.map((job) => (
            <article className="job-card" key={job.id}>
              <div className="job-card-top">
                <span className={`status status-${job.state}`}>{t(stateTranslationKey(job.state))}</span>
                <span className="mode">{job.mode === 'image_to_video' ? t('imageToVideo') : t('textToVideo')}</span>
              </div>
              <h3>{job.title}</h3>
              <p className="job-prompt">{job.prompt}</p>
              {activeStates.has(job.state) && (
                <progress className="progress-track" aria-label={t('progress', { value: job.progress ?? 0 })} max={100} value={Math.max(2, job.progress ?? 0)} />
              )}
              <dl>
                {job.remoteID && <><dt>{t('remoteTask')}</dt><dd>{job.remoteID}</dd></>}
                {job.outputPath && <><dt>{t('output')}</dt><dd title={job.outputPath}>{job.outputPath}</dd></>}
              </dl>
              {job.ambiguousSubmission && <p className="warning-text">{t('ambiguous')}</p>}
              {Boolean(job.error || job.lastPollError || job.downloadError) && (
                <p className="error-text">{errorSummary(job.error || job.lastPollError || job.downloadError)}</p>
              )}
              <div className="job-meta">
                <span>{job.model ?? settings.videoModel}</span>
                <span>{t('updatedAt', { value: new Date(job.updatedAt).toLocaleString(locale === 'zh-Hans' ? 'zh-CN' : 'en-US') })}</span>
              </div>
              <fieldset className="job-actions" disabled={jobBusy}>
                {job.state === 'draft' && <button onClick={() => editJob(job)}>{t('edit')}</button>}
                {activeStates.has(job.state) && <button onClick={() => void runJobCommand('video.refresh', job)}>{t('refresh')}</button>}
                {job.state === 'failed' && <button onClick={() => setConfirmation({ command: 'video.retry', job })}>{t('retry')}</button>}
                {job.state === 'completed' && !job.outputPath && <button onClick={() => void runJobCommand('video.download', job)}>{t('download')}</button>}
                {job.outputPath && <button onClick={() => void runJobCommand('video.revealOutput', job)}>{t('reveal')}</button>}
                <button className="danger-link" onClick={() => setConfirmation({ command: 'video.remove', job })}>{t('remove')}</button>
              </fieldset>
            </article>
          ))}
        </section>
      )}

      {confirmation && (
        <div className="modal-backdrop">
          <section className="settings-dialog" role="alertdialog" aria-modal="true" aria-labelledby="confirm-title">
            <h2 id="confirm-title">{t('confirmAction')}</h2>
            <p>{t(confirmation.command === 'video.retry' ? 'confirmRetry' : 'confirmRemove')}</p>
            <div className="dialog-actions">
              <button className="button secondary" onClick={() => setConfirmation(null)}>{t('cancel')}</button>
              <button className="button primary" onClick={() => void confirmJobCommand()}>{t('confirm')}</button>
            </div>
          </section>
        </div>
      )}

      {settingsOpen && (
        <SettingsDialog
          settings={settings}
          providers={providers}
          selectedProvider={selectedProvider}
          t={t}
          onCancel={() => setSettingsOpen(false)}
          onSave={saveSettings}
        />
      )}
    </main>
  );
}

type SettingsDialogProps = {
  settings: StudioSettings;
  providers: ProviderEntry[];
  selectedProvider?: ProviderEntry;
  t: ReturnType<typeof createTranslator>;
  onCancel: () => void;
  onSave: (settings: StudioSettings) => Promise<void>;
};

function SettingsDialog({ settings, providers, selectedProvider, t, onCancel, onSave }: SettingsDialogProps) {
  const [draft, setDraft] = useState(settings);
  const provider = providers.find((entry) => entry.providerID === draft.assistantProviderID) ?? selectedProvider;

  return (
    <div className="modal-backdrop" role="presentation" onMouseDown={(event) => event.target === event.currentTarget && onCancel()}>
      <section className="settings-dialog" role="dialog" aria-modal="true" aria-labelledby="settings-title">
        <h2 id="settings-title">{t('settingsTitle')}</h2>
        <label className="field">
          <span>{t('assistantProvider')}</span>
          <select
            value={draft.assistantProviderID ?? ''}
            onChange={(event) => setDraft({ ...draft, assistantProviderID: event.target.value || null, assistantModel: null })}
          >
            <option value="">{t('assistantDefault')}</option>
            {providers.map((entry) => <option key={entry.providerID} value={entry.providerID}>{entry.displayName}</option>)}
          </select>
        </label>
        <label className="field">
          <span>{t('assistantModel')}</span>
          <select
            value={draft.assistantModel ?? ''}
            disabled={!draft.assistantProviderID}
            onChange={(event) => setDraft({ ...draft, assistantModel: event.target.value || null })}
          >
            <option value="">{provider?.flashModel || t('assistantModelAuto')}</option>
            {(provider?.models ?? []).map((model) => <option key={model} value={model}>{model}</option>)}
          </select>
        </label>
        <label className="field">
          <span>{t('videoModel')}</span>
          <input value={draft.videoModel} onChange={(event) => setDraft({ ...draft, videoModel: event.target.value })} />
        </label>
        <div className="settings-grid">
          <label className="field">
            <span>{t('duration')}</span>
            <select value={draft.duration} onChange={(event) => setDraft({ ...draft, duration: Number(event.target.value) })}>
              {[2, 4, 6].map((value) => <option key={value} value={value}>{t('seconds', { value })}</option>)}
            </select>
          </label>
          <label className="field">
            <span>{t('steps')}</span>
            <input type="number" min={1} max={100} value={draft.inferenceSteps} onChange={(event) => setDraft({ ...draft, inferenceSteps: Number(event.target.value) })} />
          </label>
          <label className="field">
            <span>{t('width')}</span>
            <input type="number" min={32} max={4096} step={32} value={draft.width} onChange={(event) => setDraft({ ...draft, width: Number(event.target.value) })} />
          </label>
          <label className="field">
            <span>{t('height')}</span>
            <input type="number" min={32} max={4096} step={32} value={draft.height} onChange={(event) => setDraft({ ...draft, height: Number(event.target.value) })} />
          </label>
        </div>
        <label className="toggle-row">
          <input type="checkbox" checked={draft.autoDownload} onChange={(event) => setDraft({ ...draft, autoDownload: event.target.checked })} />
          <span>{t('autoDownload')}</span>
        </label>
        <div className="dialog-actions">
          <button className="button secondary" onClick={onCancel}>{t('cancel')}</button>
          <button className="button primary" onClick={() => void onSave(draft)}>{t('save')}</button>
        </div>
      </section>
    </div>
  );
}
