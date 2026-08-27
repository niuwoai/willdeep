/**
 * 撒花组件回归。
 *
 * jsdom 没有 canvas 2D 上下文，所以这里验的是「挂载、触发、清理」这条契约：
 * trigger 为 0 时不动画、自增时申请动画帧、卸载时取消，且减少动效偏好下直接不放。
 */
import { render, screen } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { Confetti } from './Confetti';

function stubCanvas(): { clearRect: ReturnType<typeof vi.fn> } {
  const context = {
    clearRect: vi.fn(),
    setTransform: vi.fn(),
    save: vi.fn(),
    restore: vi.fn(),
    translate: vi.fn(),
    rotate: vi.fn(),
    fillRect: vi.fn(),
    globalAlpha: 1,
    fillStyle: '',
  };
  vi.spyOn(HTMLCanvasElement.prototype, 'getContext').mockReturnValue(
    context as unknown as CanvasRenderingContext2D,
  );
  return context;
}

function stubReducedMotion(reduce: boolean): void {
  vi.spyOn(window, 'matchMedia').mockImplementation(
    (query: string) =>
      ({
        matches: reduce,
        media: query,
        onchange: null,
        addListener: vi.fn(),
        removeListener: vi.fn(),
        addEventListener: vi.fn(),
        removeEventListener: vi.fn(),
        dispatchEvent: vi.fn(),
      }) as unknown as MediaQueryList,
  );
}

beforeEach(() => {
  stubReducedMotion(false);
});

afterEach(() => {
  vi.restoreAllMocks();
});

describe('通关撒花', () => {
  it('trigger 为 0 时只挂画布、不申请动画帧', () => {
    stubCanvas();
    const raf = vi.spyOn(window, 'requestAnimationFrame');
    render(<Confetti trigger={0} />);
    expect(screen.getByTestId('confetti')).toBeInTheDocument();
    expect(raf).not.toHaveBeenCalled();
  });

  it('trigger 自增就放一次，卸载时取消动画帧', () => {
    stubCanvas();
    const raf = vi.spyOn(window, 'requestAnimationFrame');
    const cancel = vi.spyOn(window, 'cancelAnimationFrame');
    const view = render(<Confetti trigger={1} />);
    expect(raf).toHaveBeenCalled();

    view.rerender(<Confetti trigger={2} />);
    expect(raf.mock.calls.length).toBeGreaterThan(1);

    view.unmount();
    expect(cancel).toHaveBeenCalled();
  });

  it('用户要求减少动效时不放动画', () => {
    stubCanvas();
    stubReducedMotion(true);
    const raf = vi.spyOn(window, 'requestAnimationFrame');
    render(<Confetti trigger={3} />);
    expect(raf).not.toHaveBeenCalled();
  });

  it('拿不到 2D 上下文时安静降级', () => {
    vi.spyOn(HTMLCanvasElement.prototype, 'getContext').mockImplementation(() => {
      throw new Error('not implemented');
    });
    expect(() => render(<Confetti trigger={1} />)).not.toThrow();
  });
});
