/**
 * 音效契约：全部用 Web Audio 现场合成，不打包任何音频素材。
 *
 * 为什么不下载音效文件：
 *  - 插件随 App 发行，外部素材要逐个核对授权，合成音零版权风险
 *  - 插件页跑在 CSP 收紧的 WKWebView 里，不依赖外链更稳，也不占发行包体积
 *  - 一段 8-bit 风格的方波/三角波 blip 就够用，参数化后每个游戏各取所需
 *
 * 约束：
 *  - 浏览器要求首次用户手势后才能出声：AudioContext 懒创建，每次播放前尝试 resume
 *  - 任何异常（无 AudioContext、被策略拦截）一律吞掉，绝不打断游戏
 *  - 开关状态走 safeLocalStorage（`arcade.sound`），默认开启
 */
import { STORAGE_PREFIX, safeLocalStorage } from './safeLocalStorage';

export const SOUND_STORAGE_KEY = `${STORAGE_PREFIX}.sound`;

/** 一段单音：频率、时长、音色与可选滑音终点。 */
interface Tone {
  /** 起始频率（Hz）。 */
  freq: number;
  /** 时长（秒）。 */
  duration: number;
  /** 相对本次播放起点的延迟（秒）。 */
  delay?: number;
  /** 滑音终点频率（Hz），省略则不滑音。 */
  sweepTo?: number;
  type?: OscillatorType;
  gain?: number;
}

/** 全部音效名（各游戏按需取用）。 */
export type CueName =
  | 'flip'
  | 'match'
  | 'miss'
  | 'select'
  | 'clear'
  | 'shuffle'
  | 'shoot'
  | 'blast'
  | 'reverse'
  | 'alarm'
  | 'eat'
  | 'rotate'
  | 'lock'
  | 'line'
  | 'bounce'
  | 'point'
  | 'reveal'
  | 'flag'
  | 'boom'
  | 'win'
  | 'lose';

/** 音效表：每个 cue 是一串定时的单音。 */
const CUES: Record<CueName, readonly Tone[]> = {
  // 通用交互
  flip: [{ freq: 520, duration: 0.07, type: 'triangle', gain: 0.16 }],
  select: [{ freq: 660, duration: 0.06, type: 'square', gain: 0.1 }],
  match: [
    { freq: 660, duration: 0.09, type: 'triangle', gain: 0.16 },
    { freq: 880, duration: 0.12, delay: 0.08, type: 'triangle', gain: 0.16 },
  ],
  miss: [{ freq: 200, duration: 0.14, sweepTo: 130, type: 'sawtooth', gain: 0.1 }],
  // 连连看
  clear: [
    { freq: 780, duration: 0.08, type: 'square', gain: 0.12 },
    { freq: 1040, duration: 0.12, delay: 0.07, type: 'square', gain: 0.12 },
  ],
  shuffle: [{ freq: 300, duration: 0.22, sweepTo: 620, type: 'triangle', gain: 0.12 }],
  // 印加弹珠
  shoot: [{ freq: 900, duration: 0.07, sweepTo: 460, type: 'square', gain: 0.1 }],
  blast: [
    { freq: 160, duration: 0.28, sweepTo: 48, type: 'sawtooth', gain: 0.2 },
    { freq: 320, duration: 0.16, sweepTo: 90, type: 'square', gain: 0.12 },
  ],
  reverse: [{ freq: 880, duration: 0.3, sweepTo: 300, type: 'sine', gain: 0.16 }],
  // 弹珠冲到洞口边上：两声急促下滑的警报
  alarm: [
    { freq: 920, duration: 0.13, sweepTo: 520, type: 'square', gain: 0.17 },
    { freq: 920, duration: 0.18, delay: 0.15, sweepTo: 400, type: 'square', gain: 0.17 },
  ],
  // 贪吃蛇 / 俄罗斯方块 / 乒乓 / 扫雷
  eat: [{ freq: 720, duration: 0.07, sweepTo: 980, type: 'square', gain: 0.12 }],
  rotate: [{ freq: 420, duration: 0.05, type: 'square', gain: 0.08 }],
  lock: [{ freq: 240, duration: 0.07, type: 'square', gain: 0.1 }],
  line: [
    { freq: 620, duration: 0.08, type: 'square', gain: 0.14 },
    { freq: 820, duration: 0.08, delay: 0.07, type: 'square', gain: 0.14 },
    { freq: 1080, duration: 0.14, delay: 0.14, type: 'square', gain: 0.14 },
  ],
  bounce: [{ freq: 480, duration: 0.05, type: 'square', gain: 0.1 }],
  point: [{ freq: 880, duration: 0.12, type: 'triangle', gain: 0.14 }],
  reveal: [{ freq: 560, duration: 0.05, type: 'triangle', gain: 0.09 }],
  flag: [{ freq: 760, duration: 0.06, type: 'square', gain: 0.09 }],
  boom: [{ freq: 180, duration: 0.34, sweepTo: 40, type: 'sawtooth', gain: 0.2 }],
  // 终局
  win: [
    { freq: 523, duration: 0.12, type: 'triangle', gain: 0.16 },
    { freq: 659, duration: 0.12, delay: 0.11, type: 'triangle', gain: 0.16 },
    { freq: 784, duration: 0.12, delay: 0.22, type: 'triangle', gain: 0.16 },
    { freq: 1046, duration: 0.26, delay: 0.33, type: 'triangle', gain: 0.18 },
  ],
  lose: [
    { freq: 392, duration: 0.16, type: 'sawtooth', gain: 0.14 },
    { freq: 262, duration: 0.3, delay: 0.15, sweepTo: 160, type: 'sawtooth', gain: 0.14 },
  ],
};

export const CUE_NAMES = Object.keys(CUES) as CueName[];

type AudioContextCtor = new () => AudioContext;

let cached: AudioContext | null | undefined;
const listeners = new Set<() => void>();

function contextCtor(): AudioContextCtor | undefined {
  if (typeof window === 'undefined') return undefined;
  const scope = window as unknown as {
    AudioContext?: AudioContextCtor;
    webkitAudioContext?: AudioContextCtor;
  };
  return scope.AudioContext ?? scope.webkitAudioContext;
}

function ensureContext(): AudioContext | null {
  if (cached !== undefined) return cached;
  try {
    const Ctor = contextCtor();
    cached = Ctor ? new Ctor() : null;
  } catch {
    cached = null;
  }
  return cached;
}

/** 音效是否开启（默认开）。 */
export function isSoundEnabled(): boolean {
  return safeLocalStorage.getItem(SOUND_STORAGE_KEY) !== 'off';
}

/** 设置开关并广播给订阅者。 */
export function setSoundEnabled(enabled: boolean): void {
  safeLocalStorage.setItem(SOUND_STORAGE_KEY, enabled ? 'on' : 'off');
  for (const listener of listeners) listener();
}

export function subscribeSound(onChange: () => void): () => void {
  listeners.add(onChange);
  return () => {
    listeners.delete(onChange);
  };
}

/** 播放一个音效；关闭、无 AudioContext 或任何异常都静默跳过。 */
export function playCue(name: CueName): void {
  if (!isSoundEnabled()) return;
  const tones = CUES[name];
  if (!tones) return;
  const context = ensureContext();
  if (!context) return;
  try {
    if (context.state === 'suspended') void context.resume();
    const start = context.currentTime;
    for (const tone of tones) {
      const at = start + (tone.delay ?? 0);
      const oscillator = context.createOscillator();
      const amp = context.createGain();
      oscillator.type = tone.type ?? 'square';
      oscillator.frequency.setValueAtTime(tone.freq, at);
      if (tone.sweepTo !== undefined) {
        oscillator.frequency.exponentialRampToValueAtTime(
          Math.max(1, tone.sweepTo),
          at + tone.duration,
        );
      }
      const peak = tone.gain ?? 0.12;
      amp.gain.setValueAtTime(0.0001, at);
      amp.gain.exponentialRampToValueAtTime(peak, at + 0.012);
      amp.gain.exponentialRampToValueAtTime(0.0001, at + tone.duration);
      oscillator.connect(amp);
      amp.connect(context.destination);
      oscillator.start(at);
      oscillator.stop(at + tone.duration + 0.02);
    }
  } catch {
    /* 出声失败不该影响玩法 */
  }
}

/** 仅供测试：丢弃已创建的 AudioContext 缓存。 */
export function resetAudioForTesting(): void {
  cached = undefined;
}
