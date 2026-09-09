import { renderToStaticMarkup } from 'react-dom/server';
import { BadgeCheck, Box, PackagePlus, DoorOpen, ArrowRight } from 'lucide-react';
import type { Assets } from './render';

export const assetURL = (name: string) => `${import.meta.env.BASE_URL}assets/${name}`;
export async function loadAssets(): Promise<Assets> {
  const svg = (element: React.ReactElement) => `data:image/svg+xml;charset=utf-8,${encodeURIComponent(renderToStaticMarkup(element))}`;
  const sources = {
    runner: assetURL('runner.png'), guard: assetURL('guard.png'), rack: assetURL('rack.png'),
    pass: svg(<BadgeCheck color="#142b42" strokeWidth={2.8} size={64} />),
    box: svg(<Box color="#704827" fill="#d6a56c" strokeWidth={1.6} size={64} />),
    supply: svg(<PackagePlus color="#ffffff" strokeWidth={2} size={64} />),
    rest: svg(<DoorOpen color="#ffffff" strokeWidth={2} size={64} />),
    arrow: svg(<ArrowRight color="#ffffff" strokeWidth={3} size={64} />),
    shot: assetURL('prank.png'),
  };
  const pairs = await Promise.all(Object.entries(sources).map(([key, src]) => new Promise<[string, HTMLImageElement]>((resolve, reject) => {
    const img = new Image(); img.onload = () => resolve([key, img]); img.onerror = () => reject(new Error(`Asset failed: ${key}`)); img.src = src;
  })));
  return Object.fromEntries(pairs) as Assets;
}
