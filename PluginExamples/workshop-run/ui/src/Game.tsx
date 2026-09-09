import { useEffect, useRef, useState } from 'react';
import { ArrowDown, ArrowLeft, ArrowRight, ArrowUp, BadgeCheck, Box, Clock3, Droplets, Pause, Zap } from 'lucide-react';
import { createState, EMPTY_INPUT, formatTime, interaction, RULES, step, type Input, type State } from './engine';
import { draw, type Assets } from './render';
import { beep } from './audio';
import { useModalFocus } from './dialog';
import type { Preferences } from './storage';
import type { Strings } from './strings';

type Props = { t: Strings; assets: Assets; prefs: Preferences; onBack: () => void; onFinish: (s: State) => void };
const ACTION_KEYS: Record<string, keyof Pick<Input, 'throw' | 'dash' | 'interact'>> = { j: 'throw', k: 'dash', shift: 'dash', e: 'interact' };
const MOVE_KEYS = new Set(['w', 'a', 's', 'd', 'arrowup', 'arrowdown', 'arrowleft', 'arrowright']);
export function Game({ t, assets, prefs, onBack, onFinish }: Props) {
  const state = useRef(createState());
  const canvas = useRef<HTMLCanvasElement>(null);
  const host = useRef<HTMLElement>(null);
  const keys = useRef(new Set<string>());
  const actions = useRef({ throw: false, dash: false, interact: false });
  const aim = useRef<Input['aim']>(undefined);
  const [hud, setHud] = useState(() => ({ ...state.current }));
  const current = useRef({ t, prefs, onFinish }); current.current = { t, prefs, onFinish };
  const pause = () => {
    const s = state.current;
    if (s.status === 'playing') { s.status = 'paused'; keys.current.clear(); actions.current = { throw: false, dash: false, interact: false }; setHud({ ...s }); }
  };
  const resume = () => { state.current.status = 'playing'; setHud({ ...state.current }); host.current?.focus(); };
  const action = (key: 'throw' | 'dash' | 'interact') => { if (state.current.status === 'playing') actions.current[key] = true; host.current?.focus(); };
  useEffect(() => {
    host.current?.focus();
    const visibility = () => { if (document.hidden) pause(); };
    window.addEventListener('blur', pause); document.addEventListener('visibilitychange', visibility);
    let frame = 0, last = 0, accumulator = 0, uiClock = 0, finished = false;
    const render = (now: number) => {
      const elapsed = last ? Math.min((now - last) / 1000, .1) : 0; last = now;
      const s = state.current;
      if (s.status === 'playing') {
        accumulator += elapsed;
        while (accumulator >= 1 / 60) {
          const held = keys.current;
          const input: Input = { ...EMPTY_INPUT,
            x: Number(held.has('d') || held.has('arrowright')) - Number(held.has('a') || held.has('arrowleft')),
            y: Number(held.has('s') || held.has('arrowdown')) - Number(held.has('w') || held.has('arrowup')),
            ...actions.current, aim: aim.current,
          };
          const passes = s.stamps.filter(Boolean).length, ammo = s.ammo, hits = s.hits;
          step(s, input, 1 / 60);
          if (s.stamps.filter(Boolean).length > passes || s.hits > hits) beep('collect', current.current.prefs.sound);
          else if (s.ammo < ammo) beep('action', current.current.prefs.sound);
          actions.current = { throw: false, dash: false, interact: false }; accumulator -= 1 / 60;
        }
      } else accumulator = 0;
      const context = canvas.current?.getContext('2d');
      if (context) draw(context, s, assets, current.current.t, current.current.prefs.reduced);
      uiClock += elapsed;
      if (uiClock >= .08) { setHud({ ...s, stamps: [...s.stamps] }); uiClock = 0; }
      if (!finished && ['won', 'caught', 'timeout'].includes(s.status)) {
        finished = true; beep('finish', current.current.prefs.sound); current.current.onFinish(s); return;
      }
      frame = requestAnimationFrame(render);
    };
    frame = requestAnimationFrame(render);
    return () => { cancelAnimationFrame(frame); keys.current.clear(); window.removeEventListener('blur', pause); document.removeEventListener('visibilitychange', visibility); };
  }, [assets]);
  const prompt = interaction(hud);
  const paused = hud.status === 'paused';
  useModalFocus(paused);
  const control = (key: string, down: boolean) => { if (down) keys.current.add(key); else keys.current.delete(key); };
  return <main className="game" ref={host} tabIndex={0} aria-label={t.title}
    onKeyDown={event => {
      if (event.target instanceof HTMLElement && ['INPUT', 'SELECT', 'TEXTAREA'].includes(event.target.tagName)) return;
      const key = event.key.toLowerCase();
      if (key === 'escape') { event.preventDefault(); if (state.current.status === 'playing') pause(); else if (state.current.status === 'paused') resume(); return; }
      if (state.current.status !== 'playing') return;
      if (MOVE_KEYS.has(key)) { event.preventDefault(); keys.current.add(key); }
      if (ACTION_KEYS[key]) { event.preventDefault(); if (!event.repeat) actions.current[ACTION_KEYS[key]] = true; }
    }} onKeyUp={event => keys.current.delete(event.key.toLowerCase())}>
    <header className="game-header">
      <strong className="small-logo">{t.title}</strong>
      <div className={`timer ${hud.time < 30 ? 'urgent' : ''}`}><Clock3 size={21} /><span>{formatTime(Math.ceil(hud.time))}</span></div>
      <label className="stamina"><span><Zap size={16} />{t.stamina}</span><progress max={100} value={hud.stamina} /></label>
      <div className="passes"><BadgeCheck size={23} /><span>{t.stamps}</span><b>{hud.stamps.filter(Boolean).length}<em>/3</em></b></div>
      <button className="icon-button" onClick={pause} aria-label={t.pause}><Pause size={23} /></button>
    </header>
    <div className="mission-strip"><span>{t.mission}</span><span>{t.tip}</span></div>
    <section className="arena">
      <canvas ref={canvas} width={1600} height={1000} aria-label={t.mission} onPointerDown={() => host.current?.focus()}
        onPointerMove={e => { if (e.pointerType === 'mouse') { const r = e.currentTarget.getBoundingClientRect(); aim.current = { x: (e.clientX - r.left) / r.width * RULES.width, y: (e.clientY - r.top) / r.height * RULES.height }; } }}
        onPointerLeave={() => { aim.current = undefined; }} />
      <div className="arena-caption">{hud.hidden ? t.hidden : hud.safeTime > 0 ? t.protected : prompt ? t[prompt] : t.focus}</div>
      {hud.toastTime > 0 && hud.toast && <div className="game-toast" role="status">{t[hud.toast]}</div>}
      {hud.capture > 0 && <div className="capture"><strong>{t.danger}</strong><progress aria-label={t.caughtMeter} value={hud.capture} max={RULES.captureTime} /></div>}
    </section>
    <footer className="controls">
      <div className="movement-controls" aria-label={t.move}>
        {[['w', ArrowUp], ['a', ArrowLeft], ['s', ArrowDown], ['d', ArrowRight]].map(([key, Icon]) => {
          const Direction = Icon as typeof ArrowUp; const value = key as string;
          return <button key={value} className={`direction direction-${value}`} aria-label={`${t.move} ${value.toUpperCase()}`}
            onPointerDown={e => { e.currentTarget.setPointerCapture(e.pointerId); control(value, true); }}
            onPointerUp={() => control(value, false)} onPointerCancel={() => control(value, false)} onLostPointerCapture={() => control(value, false)}><Direction size={18} /></button>;
        })}
      </div>
      <span className="keyboard-hint"><b>{t.move}</b><small>{t.howMove.split('.')[0]}</small></span>
      <button className="ability" disabled={hud.ammo === 0 || hud.shotCooldown > 0 || paused} onClick={() => action('throw')}><kbd>J</kbd><Droplets /><span>{t.throw}<small>{hud.ammo} / {RULES.ammo}</small></span></button>
      <button className="ability" disabled={hud.stamina < RULES.dashCost || hud.dashCooldown > 0 || paused} onClick={() => action('dash')}><kbd>K</kbd><Zap /><span>{t.dash}<small>Shift</small></span></button>
      <button className="ability" disabled={!prompt || ['locked', 'exhausted', 'supplyWait'].includes(prompt) || paused} onClick={() => action('interact')}><kbd>E</kbd><Box /><span>{t.interact}</span></button>
    </footer>
    {paused && <div className="overlay"><section className="dialog pause-dialog" role="dialog" aria-modal="true" aria-label={t.pauseTitle}><span className="eyebrow">{t.brand}</span><h2>{t.pauseTitle}</h2><p>{t.pauseSub}</p><button autoFocus className="primary" onClick={resume}>{t.resume}<ArrowRight /></button><button className="secondary" onClick={onBack}>{t.back}</button></section></div>}
  </main>;
}
