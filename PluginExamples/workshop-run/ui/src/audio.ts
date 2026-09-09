let audio: AudioContext | null = null;
export function unlockAudio() {
  try { audio ??= new AudioContext(); void audio.resume().catch(() => {}); } catch { /* Audio is optional. */ }
}
export function beep(kind: 'action' | 'collect' | 'finish', enabled: boolean) {
  if (!enabled || !audio || audio.state !== 'running') return;
  const oscillator = audio.createOscillator(), gain = audio.createGain();
  oscillator.type = 'triangle'; oscillator.frequency.setValueAtTime(kind === 'collect' ? 740 : kind === 'finish' ? 520 : 220, audio.currentTime);
  gain.gain.setValueAtTime(.035, audio.currentTime); gain.gain.exponentialRampToValueAtTime(.001, audio.currentTime + .16);
  oscillator.connect(gain); gain.connect(audio.destination); oscillator.start(); oscillator.stop(audio.currentTime + .17);
  oscillator.onended = () => { oscillator.disconnect(); gain.disconnect(); };
}
