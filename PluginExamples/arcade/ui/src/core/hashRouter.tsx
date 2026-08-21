/**
 * HashRouter 契约（冻结）。
 *
 * 路由一律采用 URL hash（`#/game/snake?seed=42`）：
 *  - 无需服务端 rewrite，静态托管 / file 协议均可运行
 *  - 游戏种子通过查询参数 `?seed=` 传入，保证可复现
 *  - 任何游戏模块不得直接操作 location.hash，必须走 navigate / Link / useRoute
 */
import { createContext, useCallback, useContext, useMemo, useSyncExternalStore } from 'react';
import type { AnchorHTMLAttributes, ReactNode } from 'react';

export interface RouteInfo {
  /** hash 中的路径部分，如 '/game/snake'；空 hash 归一为 '/'。 */
  path: string;
  /** 查询参数（含 `?seed=`）。 */
  query: URLSearchParams;
  /** 路由种子（`?seed=`），游戏模块通过 GameProps.seed 接收。 */
  seed?: string;
}

export function parseHash(hash: string): RouteInfo {
  const raw = hash.replace(/^#/, '') || '/';
  const [pathPart = '/', queryPart] = raw.split('?');
  const query = new URLSearchParams(queryPart ?? '');
  return { path: pathPart, query, seed: query.get('seed') ?? undefined };
}

export function readHash(): string {
  return typeof window === 'undefined' ? '' : window.location.hash;
}

export function getRoute(): RouteInfo {
  return parseHash(readHash());
}

/** 跳转目标：接受 '/game/snake' 或 '#/game/snake' 两种写法。 */
export function navigate(to: string): void {
  const target = to.startsWith('#') ? to.slice(1) : to;
  const next = `#${target}`;
  if (readHash() !== next) window.location.hash = next;
}

function subscribeHashChange(onChange: () => void): () => void {
  window.addEventListener('hashchange', onChange);
  return () => window.removeEventListener('hashchange', onChange);
}

export interface RouterValue {
  route: RouteInfo;
  navigate: (to: string) => void;
}

const RouterContext = createContext<RouterValue | null>(null);

export function HashRouter({ children }: { children: ReactNode }) {
  const hash = useSyncExternalStore(subscribeHashChange, readHash, readHash);
  const route = useMemo(() => parseHash(hash), [hash]);
  const go = useCallback((to: string) => navigate(to), []);
  const value = useMemo(() => ({ route, navigate: go }), [route, go]);
  return <RouterContext.Provider value={value}>{children}</RouterContext.Provider>;
}

export function useRoute(): RouterValue {
  const ctx = useContext(RouterContext);
  if (!ctx) throw new Error('useRoute 必须在 <HashRouter> 内使用');
  return ctx;
}

export interface LinkProps extends Omit<AnchorHTMLAttributes<HTMLAnchorElement>, 'href'> {
  to: string;
  children: ReactNode;
  'data-testid'?: string;
}

export function Link({ to, children, ...rest }: LinkProps) {
  return (
    <a href={`#${to}`} {...rest}>
      {children}
    </a>
  );
}
