export type FrameCandidate = { id: string; mediaURL: string; filePath: string; prompt: string; model: ImageModel; createdAt: string };
export type DialogueLine = { id: string; speaker: string; text: string };
/** 共创的两个修订号加一份草稿。旧存档没有这几个字段，读出来按 0 / null 处理。 */
export type Revised = { rev?: number; draftRev?: number };
export type CharacterDraft = Partial<Pick<Character, 'name' | 'description' | 'visualPrompt'>>;
export type EpisodeDraftFields = Partial<Pick<Episode, 'title' | 'summary' | 'script'>>;
export type ShotDraftFields = Partial<Pick<Shot, 'title' | 'summary' | 'actionStart' | 'actionEnd' | 'cameraIntent' | 'startPrompt' | 'endPrompt' | 'dialogue' | 'duration'>>;
export type DraftScope = 'drama' | 'character' | 'episode' | 'shot';
export type ChatStage = 'planning' | 'characters' | 'script' | 'storyboard' | 'frames';
export type ChatMessage = { id: string; role: 'user' | 'assistant'; content: string; objectID: string; draftRev: number; createdAt: string };
export type Shot = Revised & {
  id: string; order: number; title: string; summary: string; dialogue: DialogueLine[];
  actionStart: string; actionEnd: string; cameraIntent: string; duration: number;
  startPrompt: string; endPrompt: string; startCandidates: FrameCandidate[]; endCandidates: FrameCandidate[];
  selectedStartID?: string | null; selectedEndID?: string | null;
  draft?: ShotDraftFields | null;
};
export type Episode = Revised & { id: string; order: number; title: string; summary: string; script: string; status: string; shots: Shot[]; draft?: EpisodeDraftFields | null };
export type Character = Revised & { id: string; name: string; description: string; visualPrompt: string; identityVersion: number; candidates: FrameCandidate[]; selectedCandidateID?: string | null; draft?: CharacterDraft | null };
export type DramaPlan = {
  title: string; genre: string; format: string; episodeCount: number; episodeDurationSeconds: number;
  logline: string; coreConflict: string; audience: string; tone: string; arc: string;
  episodes?: Array<{ title?: string; summary?: string; script?: string }>;
  /// 策划带出来的角色骨架：名字加一句话定位。小传与视觉提示词留空，
  /// 等角色阶段单独出第一稿。
  characters?: Array<{ name?: string; role?: string }>;
};
// characters 与 episodes 都要去掉：策划里它们是骨架（名字加一句话），
// 落库后是完整对象，两者同名但结构不同。
export type Drama = Omit<DramaPlan, 'episodes' | 'characters'> & Revised & {
  id: string; status: string; draft?: Partial<Omit<DramaPlan, 'episodes'>> | null; coverURL?: string | null; characters: Character[]; episodes: Episode[];
  createdAt: string; updatedAt: string;
};
export type ImageModel = 'gpt-image-2' | 'nano-banana-2';
export type ImageResult = { mediaURL: string; filePath: string; model: ImageModel; providerID: 'some-im' };
export type ProviderEntry = { providerID: string; displayName: string; isActive: boolean; isLocal: boolean; models: string[]; flashModel?: string };
export type Stage = 'library' | 'settings' | 'planning' | 'characters' | 'script' | 'storyboard' | 'frames' | 'video';
/** 宿主给的技能条目。刻意没有正文和路径：引用时只回传 identifier。 */
export type SkillEntry = { identifier: string; name: string; description: string; source: 'bundled' | 'user' | 'plugin'; tier?: 'worker' | 'standard' | 'deep' };

declare global {
  interface Window {
    willdeep?: {
      getContext(): { locale?: string; colorScheme?: string };
      storage?: {
        get(key: string): Promise<{ value: unknown }>;
        set(key: string, value: unknown): Promise<unknown>;
      };
      executeCommand(command: string, arguments?: Record<string, unknown>): Promise<string | undefined>;
      ai?: {
        complete(request: { system: string; messages: Array<{ role: 'user' | 'assistant'; content: string }>; provider?: string; model?: string; skills?: string[]; streamID?: string }): Promise<{ text: string; model: string; providerID: string }>;
        /** 按 streamID 停一条在跑的对话。桥 2.3.0 起可用，旧宿主上是 undefined。 */
        cancel?(streamID: string): Promise<{ cancelled: boolean }>;
        providers(): Promise<{ providers: ProviderEntry[] }>;
        generateImage(request: { prompt: string; provider: 'some-im'; model: ImageModel; size: '1024x1024' | '1536x1024' | '1024x1536' }): Promise<ImageResult>;
      };
      skills?: {
        list(): Promise<{ skills: SkillEntry[] }>;
      };
    };
  }
}
