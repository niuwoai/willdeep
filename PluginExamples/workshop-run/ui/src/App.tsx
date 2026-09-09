import { useEffect, useState } from 'react';
import { ArrowRight, ChevronRight, Clock3, Gamepad2, HelpCircle, Play, Settings, ShieldCheck, Trophy, X } from 'lucide-react';
import { assetURL, loadAssets } from './assets';
import { unlockAudio } from './audio';
import { formatTime, RULES, type State } from './engine';
import { Game } from './Game';
import { useModalFocus } from './dialog';
import type { Assets } from './render';
import { readPreferences, writePreferences, type Preferences } from './storage';
import { stringsFor } from './strings';
import pkg from '../package.json';

export function App() {
  const [prefs, setPrefs] = useState(readPreferences);
  const [screen, setScreen] = useState<'lobby' | 'game' | 'result'>('lobby');
  const [modal, setModal] = useState<'settings' | 'how' | null>(null);
  const [assets, setAssets] = useState<Assets | null>(null);
  const [error, setError] = useState(false);
  const [round, setRound] = useState(0);
  const [result, setResult] = useState<State | null>(null);
  const t = stringsFor(prefs.locale);
  useModalFocus(Boolean(modal) || screen === 'result');
  useEffect(() => { let active = true; loadAssets().then(a => { if (active) setAssets(a); }).catch(() => { if (active) setError(true); }); return () => { active = false; }; }, []);
  useEffect(() => { writePreferences(prefs); document.documentElement.lang = prefs.locale; document.title = t.title; }, [prefs, t]);
  const change = (values: Partial<Preferences>) => setPrefs(p => ({ ...p, ...values }));
  const start = () => { unlockAudio(); setRound(r => r + 1); setScreen('game'); };
  const finish = (s: State) => {
    setResult({ ...s }); setScreen('result');
    if (s.status === 'won') setPrefs(p => ({ ...p, best: Math.min(p.best ?? RULES.duration, RULES.duration - s.time) }));
  };
  return <div className={`app ${prefs.reduced ? 'reduced' : ''}`}>
    {screen === 'game' && assets ? <Game key={round} t={t} assets={assets} prefs={prefs} onBack={() => setScreen('lobby')} onFinish={finish} /> : <main className="lobby" inert={Boolean(modal) || screen === 'result'}>
      <div className="lobby-art" />
      <section className="lobby-menu">
        <div className="brand"><b>{t.brand}</b><span>{t.englishTitle}</span></div>
        <h1 className={prefs.locale === 'zh-Hans' ? 'graphic-title' : 'english-title'}>{prefs.locale === 'zh-Hans' ? <><span className="sr-only">{t.title}</span><img src={assetURL('title.png')} alt="" /></> : <><span>{t.titleTop}</span><strong>{t.titleBottom}</strong></>}</h1>
        <p className="tagline">{t.tagline}</p>
        <div className="character-list">
          <div className="character selected"><img src={assetURL('runner.png')} alt="" /><div><strong>{t.runner}</strong><span>{t.runnerSub}</span></div><ChevronRight /></div>
          <div className="character locked" aria-disabled="true"><img src={assetURL('guard.png')} alt="" /><div><strong>{t.guard}</strong><span>{t.guardSub}</span></div><ShieldCheck /></div>
        </div>
        <button className="start-button" disabled={!assets} onClick={start}><Play fill="currentColor" /><span>{t.start}</span><ArrowRight /></button>
        {!assets && <p className="loading" role="status">{error ? t.loadError : t.loading}{error && <button onClick={() => window.location.reload()}>{t.retry}</button>}</p>}
        <div className="lobby-links"><button onClick={() => setModal('settings')}><Settings size={20} />{t.settings}</button><button onClick={() => setModal('how')}><HelpCircle size={20} />{t.how}</button></div>
      </section>
      <footer className="lobby-footer"><span>{t.version} {pkg.version}</span><div><span><ShieldCheck />{t.fictional}</span><span><Gamepad2 />{t.offline}</span><span><Clock3 />{t.duration}</span></div></footer>
    </main>}
    {screen === 'result' && result && <div className="overlay"><section className="dialog result" role="dialog" aria-modal="true" aria-label={t[result.status === 'won' ? 'win' : result.status === 'caught' ? 'caught' : 'timeout']}>
      <Trophy className="result-trophy" size={52} /><span className="eyebrow">{t.englishTitle}</span><h2>{t[result.status === 'won' ? 'win' : result.status === 'caught' ? 'caught' : 'timeout']}</h2>
      <p>{t[result.status === 'won' ? 'winSub' : result.status === 'caught' ? 'caughtSub' : 'timeoutSub']}</p>
      <div className="result-stats"><div><b>{formatTime(RULES.duration - result.time)}</b><span>{t.elapsed}</span></div><div><b>{result.hits}</b><span>{t.hits}</span></div><div><b>{result.stamps.filter(Boolean).length}/3</b><span>{t.stamps}</span></div></div>
      <p className="best">{t.best} · {prefs.best ? formatTime(prefs.best) : t.noBest}</p>
      <button className="primary" onClick={start} autoFocus>{t.restart}<ArrowRight /></button><button className="secondary" onClick={() => setScreen('lobby')}>{t.back}</button>
    </section></div>}
    {modal && <div className="overlay" onKeyDown={e => { if (e.key === 'Escape') setModal(null); }}><section className="dialog" role="dialog" aria-modal="true" aria-label={modal === 'settings' ? t.settings : t.howTitle}>
      <button className="close icon-button" autoFocus onClick={() => setModal(null)} aria-label={t.close}><X /></button><span className="eyebrow">{t.brand}</span><h2>{modal === 'settings' ? t.settings : t.howTitle}</h2>
      {modal === 'settings' ? <div className="settings-form">
        <label><span>{t.language}</span><select value={prefs.locale} onChange={e => change({ locale: e.target.value === 'en' ? 'en' : 'zh-Hans' })}><option value="zh-Hans">{t.zh}</option><option value="en">{t.en}</option></select></label>
        <label><span>{t.sound}</span><input type="checkbox" checked={prefs.sound} onChange={e => change({ sound: e.target.checked })} /></label>
        <label><span>{t.motion}</span><input type="checkbox" checked={prefs.reduced} onChange={e => change({ reduced: e.target.checked })} /></label>
        <p>{t.settingsNote}</p>
      </div> : <ol className="instructions">{(['howMove', 'howThrow', 'howDash', 'howInteract', 'howWin'] as const).map(key => <li key={key}>{t[key]}</li>)}</ol>}
      <button className="primary" onClick={() => setModal(null)}>{t.close}<ArrowRight /></button>
    </section></div>}
  </div>;
}
