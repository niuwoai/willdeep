import { act, render, screen, waitFor } from '@testing-library/react';
import { describe, expect, it } from 'vitest';
import { HashRouter, Link, getRoute, navigate, parseHash, useRoute } from './hashRouter';

function RouteProbe({ label }: { label: string }) {
  const { route, navigate: go } = useRoute();
  return (
    <div data-testid={label}>
      <span data-testid={`${label}-path`}>{route.path}</span>
      <span data-testid={`${label}-seed`}>{route.seed ?? '(none)'}</span>
      <button type="button" onClick={() => go('/game/pong?seed=99')}>
        go-pong
      </button>
    </div>
  );
}

describe('parseHash（路由解析契约）', () => {
  it('空 hash 归一为根路径', () => {
    expect(parseHash('')).toEqual({
      path: '/',
      query: expect.any(URLSearchParams),
      seed: undefined,
    });
  });

  it('解析路径与 ?seed= 参数', () => {
    const route = parseHash('#/game/minesweeper?seed=abc42');
    expect(route.path).toBe('/game/minesweeper');
    expect(route.seed).toBe('abc42');
  });

  it('无 seed 时字段为 undefined', () => {
    expect(parseHash('#/game/tetris').seed).toBeUndefined();
  });
});

describe('navigate / HashRouter（hash 变化契约）', () => {
  it('navigate 改变当前 hash 且 useRoute 随之更新', async () => {
    render(
      <HashRouter>
        <RouteProbe label="p" />
      </HashRouter>,
    );
    expect(screen.getByTestId('p-path')).toHaveTextContent('/');

    act(() => navigate('/game/snake?seed=7'));
    await waitFor(() =>
      expect(screen.getByTestId('p-path')).toHaveTextContent('/game/snake'),
    );
    expect(screen.getByTestId('p-seed')).toHaveTextContent('7');
  });

  it('useRoute().navigate 跳转并携带 seed', async () => {
    render(
      <HashRouter>
        <RouteProbe label="q" />
      </HashRouter>,
    );
    act(() => {
      screen.getByText('go-pong').click();
    });
    await waitFor(() =>
      expect(screen.getByTestId('q-path')).toHaveTextContent('/game/pong'),
    );
    expect(screen.getByTestId('q-seed')).toHaveTextContent('99');
    expect(getRoute().seed).toBe('99');
  });

  it('Link 渲染 hash href', () => {
    render(
      <HashRouter>
        <Link to="/game/memory" data-testid="lnk">
          memory
        </Link>
      </HashRouter>,
    );
    expect(screen.getByTestId('lnk')).toHaveAttribute('href', '#/game/memory');
  });

  it('useRoute 在 Provider 外抛错', () => {
    expect(() => render(<RouteProbe label="x" />)).toThrow(/HashRouter/);
  });
});
