import type { ListResponse, ProviderEntry, VideoPlan } from './types';

export async function callCommand<T>(command: string, argumentsValue: Record<string, unknown> = {}): Promise<T> {
  const bridge = window.willdeep;
  if (!bridge) throw new Error('willdeep_bridge_unavailable');
  const raw = await bridge.executeCommand(command, argumentsValue);
  if (!raw) throw new Error('empty_command_response');
  return JSON.parse(raw) as T;
}

export async function loadStudio(): Promise<ListResponse> {
  return callCommand<ListResponse>('video.list', { status: 'all' });
}

export async function loadProviders(): Promise<ProviderEntry[]> {
  const payload = await window.willdeep?.ai?.providers();
  return payload?.providers ?? [];
}

export function parseVideoPlan(raw: string): VideoPlan | null {
  const trimmed = raw.trim();
  const withoutFence = trimmed.replace(/^```(?:json)?\s*/i, '').replace(/\s*```$/, '');
  const start = withoutFence.indexOf('{');
  const end = withoutFence.lastIndexOf('}');
  if (start < 0 || end <= start) return null;
  try {
    const parsed = JSON.parse(withoutFence.slice(start, end + 1)) as Partial<VideoPlan>;
    if (!parsed.prompt || typeof parsed.prompt !== 'string') return null;
    return {
      title: typeof parsed.title === 'string' ? parsed.title.trim() : '',
      prompt: parsed.prompt.trim(),
      negativePrompt: typeof parsed.negativePrompt === 'string' ? parsed.negativePrompt.trim() : '',
    };
  } catch {
    return null;
  }
}

export const activeStates = new Set(['submitting', 'queued', 'in_progress']);
