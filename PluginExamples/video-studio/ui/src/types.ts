export type JobState = 'draft' | 'submitting' | 'queued' | 'in_progress' | 'completed' | 'failed';

export type VideoJob = {
  id: string;
  remoteID?: string | null;
  provider: string;
  state: JobState;
  progress: number;
  title: string;
  prompt: string;
  negativePrompt?: string | null;
  referenceImagePath?: string | null;
  mode: 'text_to_video' | 'image_to_video';
  model?: string;
  duration?: number;
  width?: number;
  height?: number;
  inferenceSteps?: number;
  seed?: number | null;
  createdAt: string;
  updatedAt: string;
  outputURL?: string | null;
  outputPath?: string | null;
  error?: unknown;
  lastPollError?: unknown;
  downloadError?: unknown;
  ambiguousSubmission?: boolean;
  retryOf?: string;
};

export type StudioSettings = {
  assistantProviderID: string | null;
  assistantModel: string | null;
  videoModel: string;
  duration: number;
  width: number;
  height: number;
  inferenceSteps: number;
  autoDownload: boolean;
};

export type ProviderEntry = {
  providerID: string;
  displayName: string;
  isActive: boolean;
  isLocal: boolean;
  models: string[];
  flashModel?: string;
};

export type ProviderStatus = {
  id: string;
  apiBase?: string;
  apiConfigured: boolean;
  outputDirectory?: string;
  error?: unknown;
};

export type ListResponse = {
  ok: boolean;
  jobs: VideoJob[];
  counts: Record<string, number>;
  settings: StudioSettings;
  provider: ProviderStatus;
  error?: { code?: string; message?: string };
};

export type VideoPlan = {
  title: string;
  prompt: string;
  negativePrompt: string;
};

declare global {
  interface Window {
    willdeep?: {
      getContext(): { locale?: string; colorScheme?: string };
      executeCommand(command: string, arguments?: Record<string, unknown>): Promise<string | undefined>;
      ai?: {
        complete(request: {
          system: string;
          messages: Array<{ role: 'user' | 'assistant'; content: string }>;
          provider?: string;
          model?: string;
          maxOutputTokens?: number;
        }): Promise<{ text: string; model: string; providerID: string }>;
        providers(): Promise<{ providers: ProviderEntry[] }>;
      };
    };
  }
}
