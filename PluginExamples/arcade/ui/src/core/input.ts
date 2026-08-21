/**
 * 输入处理契约（冻结）。
 *
 * 键盘：全局监听必须经 useKeyControls 注册；该 hook 在卸载时强制移除监听，
 * 并默认过滤按住连发（e.repeat）。需要防滚动的键自行声明 preventDefault。
 *
 * 触屏/指针：优先使用 React 合成事件（onPointerDown 等），无需全局监听；
 * 组件卸载时不得残留任何全局监听器（触屏场景由 useKeyControls 覆盖的
 * 键盘路径同样生效于外接键盘）。见 docs/contracts.md。
 */
import { useEffect } from 'react';
import type { DependencyList } from 'react';

export interface KeyBinding {
  /** KeyboardEvent.key 的值，如 'ArrowUp'、' '、'p'、'Escape'。 */
  key: string;
  onDown?: (event: KeyboardEvent) => void;
  onUp?: (event: KeyboardEvent) => void;
  /** 命中该键时调用 event.preventDefault()（默认 false）。 */
  preventDefault?: boolean;
  /** 允许按住连发（默认 false，过滤 e.repeat）。 */
  allowRepeat?: boolean;
}

/**
 * 注册键盘绑定并保证卸载清理。bindings 变化时重新绑定，
 * 传入 deps 控制重建时机（一般传 [bindings] 或闭包依赖）。
 */
export function useKeyControls(bindings: KeyBinding[], deps: DependencyList = []): void {
  useEffect(() => {
    const find = (event: KeyboardEvent) =>
      bindings.find((binding) => binding.key === event.key);

    const handleKeyDown = (event: KeyboardEvent) => {
      const binding = find(event);
      if (!binding || !binding.onDown) return;
      if (event.repeat && !binding.allowRepeat) return;
      if (binding.preventDefault) event.preventDefault();
      binding.onDown(event);
    };

    const handleKeyUp = (event: KeyboardEvent) => {
      const binding = find(event);
      if (!binding?.onUp) return;
      binding.onUp(event);
    };

    window.addEventListener('keydown', handleKeyDown);
    window.addEventListener('keyup', handleKeyUp);
    return () => {
      window.removeEventListener('keydown', handleKeyDown);
      window.removeEventListener('keyup', handleKeyUp);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, deps);
}
