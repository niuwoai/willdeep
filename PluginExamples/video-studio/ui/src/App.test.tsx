import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import App from './App';
import type { ListResponse, VideoJob } from './types';

const settings = {
  assistantProviderID: null, assistantModel: null, videoModel: 'MiniMax-H3',
  duration: 4, width: 832, height: 480, inferenceSteps: 20, autoDownload: true,
};
let snapshot: ListResponse;
const executeCommand = vi.fn();
const complete = vi.fn();

function job(state: VideoJob['state']): VideoJob {
  return {
    id: 'local-1', remoteID: state === 'draft' ? null : 'remote-1', provider: 'openai-videos-async',
    state, progress: 0, title: 'Fixture shot', prompt: 'A quiet beach', mode: 'text_to_video',
    createdAt: '2026-09-03T10:00:00Z', updatedAt: '2026-09-03T10:00:00Z',
  };
}

beforeEach(() => {
  snapshot = {
    ok: true, jobs: [], counts: {}, settings: { ...settings },
    provider: { id: 'openai-videos-async', apiConfigured: true },
  };
  executeCommand.mockReset().mockImplementation(async (command: string, args: Record<string, unknown>) => {
    if (command === 'video.list') return JSON.stringify(snapshot);
    if (command === 'video.settings') {
      snapshot.settings = { ...snapshot.settings, ...args };
      return JSON.stringify({ ok: true, settings: snapshot.settings });
    }
    return JSON.stringify({ ok: true });
  });
  complete.mockReset().mockResolvedValue({ text: '{"title":"Directed","prompt":"Slow camera move","negativePrompt":"blur"}' });
  window.willdeep = {
    getContext: () => ({ locale: 'en' }), executeCommand,
    ai: { complete, providers: async () => ({ providers: [
      { providerID: 'chat-a', displayName: 'Chat A', isActive: true, isLocal: false, models: ['fast', 'pro'], flashModel: 'fast' },
    ] }) },
  };
  vi.spyOn(window, 'scrollTo').mockImplementation(() => undefined);
});

afterEach(() => {
  cleanup();
  delete window.willdeep;
  vi.restoreAllMocks();
  vi.useRealTimers();
});

async function ready() {
  render(<App />);
  await waitFor(() => expect(screen.getByRole('button', { name: 'Submit generation' })).toBeEnabled());
}

describe('Video Studio user workflows', () => {
  it('routes the AI director to the saved host provider/model without submitting video', async () => {
    await ready();
    fireEvent.click(screen.getByRole('button', { name: 'Settings' }));
    fireEvent.change(screen.getByLabelText('AI director provider'), { target: { value: 'chat-a' } });
    fireEvent.change(screen.getByLabelText('AI director model'), { target: { value: 'pro' } });
    fireEvent.click(screen.getByRole('button', { name: 'Save' }));
    await screen.findByText('Settings saved');
    fireEvent.change(screen.getByLabelText('Video prompt'), { target: { value: 'A beach' } });
    fireEvent.click(screen.getByRole('button', { name: 'AI director' }));
    await waitFor(() => expect(screen.getByLabelText('Video prompt')).toHaveValue('Slow camera move'));
    expect(complete).toHaveBeenCalledWith(expect.objectContaining({ provider: 'chat-a', model: 'pro' }));
    expect(executeCommand.mock.calls.some(([command]) => command === 'video.generate')).toBe(false);
  });

  it('preserves manual input when the AI provider fails', async () => {
    complete.mockRejectedValue(new Error('unavailable'));
    await ready();
    fireEvent.change(screen.getByLabelText('Video prompt'), { target: { value: 'Keep this idea' } });
    fireEvent.click(screen.getByRole('button', { name: 'AI director' }));
    await screen.findByRole('alert');
    expect(screen.getByLabelText('Video prompt')).toHaveValue('Keep this idea');
  });

  it('edits a chat draft and submits its ID and reference frame', async () => {
    snapshot.jobs = [job('draft')];
    await ready();
    fireEvent.click(await screen.findByRole('button', { name: 'Edit' }));
    fireEvent.change(screen.getByLabelText('First-frame reference'), { target: { value: '/tmp/frame.png' } });
    fireEvent.click(screen.getByRole('button', { name: 'Submit generation' }));
    await waitFor(() => expect(executeCommand).toHaveBeenCalledWith('video.generate', expect.objectContaining({
      draftID: 'local-1', prompt: 'A quiet beach', referenceImagePath: '/tmp/frame.png', model: 'MiniMax-H3',
    })));
  });

  it('requires an in-page confirmation before a paid retry', async () => {
    snapshot.jobs = [{ ...job('failed'), ambiguousSubmission: true }];
    await ready();
    fireEvent.click(await screen.findByRole('button', { name: 'Retry' }));
    const dialog = screen.getByRole('alertdialog');
    expect(within(dialog).getByText(/new paid generation/)).toBeInTheDocument();
    expect(executeCommand.mock.calls.some(([command]) => command === 'video.retry')).toBe(false);
    fireEvent.click(within(dialog).getByRole('button', { name: 'Confirm' }));
    await waitFor(() => expect(executeCommand).toHaveBeenCalledWith('video.retry', { id: 'local-1' }));
  });

  it('downloads completed jobs without creating a new generation', async () => {
    snapshot.jobs = [job('completed')];
    await ready();
    fireEvent.click(await screen.findByRole('button', { name: 'Download MP4' }));
    await waitFor(() => expect(executeCommand).toHaveBeenCalledWith('video.download', { id: 'local-1' }));
    expect(executeCommand.mock.calls.some(([command]) => command === 'video.generate')).toBe(false);
  });

  it('can cancel record removal without invoking a command', async () => {
    snapshot.jobs = [job('completed')];
    await ready();
    fireEvent.click(await screen.findByRole('button', { name: 'Remove record' }));
    fireEvent.click(within(screen.getByRole('alertdialog')).getByRole('button', { name: 'Cancel' }));
    expect(screen.queryByRole('alertdialog')).not.toBeInTheDocument();
    expect(executeCommand.mock.calls.some(([command]) => command === 'video.remove')).toBe(false);
  });

  it('does not overlap slow polling requests and stops when unmounted', async () => {
    snapshot.jobs = [job('queued')];
    vi.useFakeTimers();
    let finishPoll: (value: string) => void = () => undefined;
    executeCommand.mockImplementation(async (command: string) => {
      if (command === 'video.list') return JSON.stringify(snapshot);
      return new Promise<string>((resolve) => { finishPoll = resolve; });
    });
    const view = render(<App />);
    await act(async () => { await Promise.resolve(); });
    await act(async () => { await vi.advanceTimersByTimeAsync(20_000); });
    expect(executeCommand.mock.calls.filter(([command]) => command === 'video.refreshActive')).toHaveLength(1);
    view.unmount();
    await act(async () => { finishPoll('{"ok":true}'); await vi.advanceTimersByTimeAsync(20_000); });
    expect(executeCommand.mock.calls.filter(([command]) => command === 'video.refreshActive')).toHaveLength(1);
  });
});
