export type FrameCandidate = { id: string; mediaURL: string; filePath: string; prompt: string; model: ImageModel; createdAt: string };
export type DialogueLine = { id: string; speaker: string; text: string };
export type Shot = {
  id: string; order: number; title: string; summary: string; dialogue: DialogueLine[];
  actionStart: string; actionEnd: string; cameraIntent: string; duration: number;
  startPrompt: string; endPrompt: string; startCandidates: FrameCandidate[]; endCandidates: FrameCandidate[];
  selectedStartID?: string | null; selectedEndID?: string | null;
};
export type Episode = { id: string; order: number; title: string; summary: string; script: string; status: string; shots: Shot[] };
export type Character = { id: string; name: string; description: string; visualPrompt: string; identityVersion: number; candidates: FrameCandidate[]; selectedCandidateID?: string | null };
export type DramaPlan = {
  title: string; genre: string; format: string; episodeCount: number; episodeDurationSeconds: number;
  logline: string; coreConflict: string; audience: string; tone: string; arc: string;
  episodes?: Array<{ title?: string; summary?: string; script?: string }>;
};
export type Drama = Omit<DramaPlan, 'episodes'> & {
  id: string; status: string; coverURL?: string | null; characters: Character[]; episodes: Episode[];
  createdAt: string; updatedAt: string;
};
export type ImageModel = 'gpt-image-2' | 'nano-banana-2';
export type ImageResult = { mediaURL: string; filePath: string; model: ImageModel; providerID: 'some-im' };
export type ProviderEntry = { providerID: string; displayName: string; isActive: boolean; isLocal: boolean; models: string[]; flashModel?: string };
export type Stage = 'library' | 'planning' | 'characters' | 'script' | 'storyboard' | 'frames' | 'video';

declare global {
  interface Window {
    willdeep?: {
      getContext(): { locale?: string; colorScheme?: string };
      executeCommand(command: string, arguments?: Record<string, unknown>): Promise<string | undefined>;
      ai?: {
        complete(request: { system: string; messages: Array<{ role: 'user' | 'assistant'; content: string }>; provider?: string; model?: string; maxOutputTokens?: number }): Promise<{ text: string; model: string; providerID: string }>;
        providers(): Promise<{ providers: ProviderEntry[] }>;
        generateImage(request: { prompt: string; provider: 'some-im'; model: ImageModel; size: '1024x1024' | '1536x1024' | '1024x1536' }): Promise<ImageResult>;
      };
    };
  }
}
