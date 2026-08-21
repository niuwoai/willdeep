import { renderHook } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { useKeyControls } from './input';

function pressKey(key: string, repeat = false): void {
  window.dispatchEvent(
    new KeyboardEvent('keydown', { key, bubbles: true, repeat }),
  );
}

describe('useKeyControls（输入清理契约）', () => {
  it('命中绑定键触发 onDown，未绑定键不触发', () => {
    const onDown = vi.fn();
    renderHook(() => useKeyControls([{ key: 'ArrowUp', onDown }], []));

    pressKey('ArrowUp');
    expect(onDown).toHaveBeenCalledTimes(1);
    pressKey('KeyX');
    expect(onDown).toHaveBeenCalledTimes(1);
  });

  it('默认过滤按住连发（e.repeat），allowRepeat 可放行', () => {
    const filtered = vi.fn();
    const repeated = vi.fn();
    renderHook(
      () =>
        useKeyControls(
          [
            { key: 'a', onDown: filtered },
            { key: 'b', onDown: repeated, allowRepeat: true },
          ],
          [],
        ),
    );

    pressKey('a', true);
    expect(filtered).not.toHaveBeenCalled();
    pressKey('b', true);
    expect(repeated).toHaveBeenCalledTimes(1);
  });

  it('preventDefault 命中时调用', () => {
    const onDown = vi.fn();
    const evt = new KeyboardEvent('keydown', { key: ' ', cancelable: true });
    renderHook(
      () => useKeyControls([{ key: ' ', onDown, preventDefault: true }], []),
    );
    window.dispatchEvent(evt);
    expect(onDown).toHaveBeenCalledTimes(1);
    expect(evt.defaultPrevented).toBe(true);
  });

  it('卸载后移除监听（无泄漏）', () => {
    const onDown = vi.fn();
    const { unmount } = renderHook(
      () => useKeyControls([{ key: 'ArrowDown', onDown }], []),
    );
    pressKey('ArrowDown');
    expect(onDown).toHaveBeenCalledTimes(1);

    unmount();
    pressKey('ArrowDown');
    expect(onDown).toHaveBeenCalledTimes(1);
  });

  it('bindings 依赖变化时重新绑定新回调', () => {
    const first = vi.fn();
    const second = vi.fn();
    const { rerender } = renderHook(
      ({ onDown }) => useKeyControls([{ key: 'p', onDown }], [onDown]),
      { initialProps: { onDown: first } },
    );

    pressKey('p');
    expect(first).toHaveBeenCalledTimes(1);

    rerender({ onDown: second });
    pressKey('p');
    expect(second).toHaveBeenCalledTimes(1);
    expect(first).toHaveBeenCalledTimes(1);
  });
});
