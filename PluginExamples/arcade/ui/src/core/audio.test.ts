/**
 * 音效契约回归。
 *
 * 音效全部现场合成（不打包素材），所以这里验的是：开关持久化、订阅广播、
 * 没有 AudioContext 时静默降级，以及有 AudioContext 时确实按 cue 表排了音。
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  CUE_NAMES,
  SOUND_STORAGE_KEY,
  isSoundEnabled,
  playCue,
  resetAudioForTesting,
  setSoundEnabled,
  subscribeSound,
} from './audio';

interface FakeOscillator {
  type: string;
  frequency: { setValueAtTime: ReturnType<typeof vi.fn>; exponentialRampToValueAtTime: ReturnType<typeof vi.fn> };
  connect: ReturnType<typeof vi.fn>;
  start: ReturnType<typeof vi.fn>;
  stop: ReturnType<typeof vi.fn>;
}

const oscillators: FakeOscillator[] = [];

class FakeAudioContext {
  state = 'running';
  currentTime = 0;
  destination = {};

  resume = vi.fn();

  createOscillator(): FakeOscillator {
    const oscillator: FakeOscillator = {
      type: 'sine',
      frequency: { setValueAtTime: vi.fn(), exponentialRampToValueAtTime: vi.fn() },
      connect: vi.fn(),
      start: vi.fn(),
      stop: vi.fn(),
    };
    oscillators.push(oscillator);
    return oscillator;
  }

  createGain() {
    return {
      gain: { setValueAtTime: vi.fn(), exponentialRampToValueAtTime: vi.fn() },
      connect: vi.fn(),
    };
  }
}

function installFakeAudio(): void {
  (window as unknown as { AudioContext: unknown }).AudioContext = FakeAudioContext;
  resetAudioForTesting();
}

beforeEach(() => {
  oscillators.length = 0;
  window.localStorage.clear();
  resetAudioForTesting();
});

afterEach(() => {
  delete (window as unknown as { AudioContext?: unknown }).AudioContext;
  resetAudioForTesting();
});

describe('音效开关', () => {
  it('默认开启，关闭后写入 localStorage 并可读回', () => {
    expect(isSoundEnabled()).toBe(true);
    setSoundEnabled(false);
    expect(window.localStorage.getItem(SOUND_STORAGE_KEY)).toBe('off');
    expect(isSoundEnabled()).toBe(false);
    setSoundEnabled(true);
    expect(isSoundEnabled()).toBe(true);
  });

  it('切换会广播给订阅者，退订后不再收到', () => {
    const listener = vi.fn();
    const unsubscribe = subscribeSound(listener);
    setSoundEnabled(false);
    expect(listener).toHaveBeenCalledTimes(1);
    unsubscribe();
    setSoundEnabled(true);
    expect(listener).toHaveBeenCalledTimes(1);
  });
});

describe('音效播放', () => {
  it('没有 AudioContext 时静默跳过，不抛异常', () => {
    expect(() => playCue('win')).not.toThrow();
  });

  it('有 AudioContext 时按 cue 排音，挂起状态会先 resume', () => {
    installFakeAudio();
    playCue('flip');
    expect(oscillators).toHaveLength(1);
    expect(oscillators[0]?.start).toHaveBeenCalled();
    expect(oscillators[0]?.stop).toHaveBeenCalled();

    // win 是四个音符的小旋律
    oscillators.length = 0;
    playCue('win');
    expect(oscillators).toHaveLength(4);
  });

  it('静音时不产生任何声音节点', () => {
    installFakeAudio();
    setSoundEnabled(false);
    playCue('win');
    expect(oscillators).toHaveLength(0);
  });

  it('每个 cue 都能播且互不相同', () => {
    installFakeAudio();
    for (const cue of CUE_NAMES) {
      oscillators.length = 0;
      expect(() => playCue(cue)).not.toThrow();
      expect(oscillators.length).toBeGreaterThan(0);
    }
  });

  it('创建 AudioContext 抛异常时只降级不影响调用方', () => {
    (window as unknown as { AudioContext: unknown }).AudioContext = class {
      constructor() {
        throw new Error('blocked by policy');
      }
    };
    resetAudioForTesting();
    expect(() => playCue('win')).not.toThrow();
  });
});
