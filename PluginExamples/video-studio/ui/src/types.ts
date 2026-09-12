/// 一个「产出形状」。宿主不会执行它：schema 交给模型，模型填好的参数原样
/// 递回页面。围栏是口头约定，这个是协议——provider 那一侧强制字段名和类型。
export interface PluginAITool {
  name: string;
  description: string;
  parameters: Array<{ name: string; type: 'string' | 'integer' | 'boolean' | 'stringArray'; description: string; required?: boolean }>;
}

/// `arguments` 是 JSON 字符串，宿主不解读内容。
export interface PluginAIToolCall {
  name: string;
  arguments: string;
}

export type FrameCandidate = { id: string; mediaURL: string; filePath: string; prompt: string; model: ImageModel; createdAt: string };
export type DialogueLine = { id: string; speaker: string; text: string };
/** 共创的两个修订号加一份草稿。旧存档没有这几个字段，读出来按 0 / null 处理。 */
export type Revised = { rev?: number; draftRev?: number };
export type CharacterDraft = Partial<Pick<Character, 'name' | 'description' | 'visualPrompt'>>;
export type EpisodeDraftFields = Partial<Pick<Episode, 'title' | 'summary' | 'script'>>;
export type ShotDraftFields = Partial<Pick<Shot, 'title' | 'summary' | 'actionStart' | 'actionEnd' | 'cameraIntent' | 'startPrompt' | 'endPrompt' | 'dialogue' | 'duration'>>;
export type DraftScope = 'drama' | 'character' | 'episode' | 'shot';
export type ChatStage = 'planning' | 'characters' | 'script' | 'storyboard' | 'frames';
/// 创作技能。阶段技能每阶段固定用一份，通用技能由用户勾选后追加。
export type CreativeSkill = {
  id: string;
  kind: 'stage' | 'common';
  name: string;
  description: string;
  stage?: string | null;
  customized: boolean;
  updatedAt?: string | null;
  body?: string;
};
/// 技能拼装的阶段键。与后端 STAGE_SKILLS 的键一致。
export type SkillStage = 'planning' | 'characters' | 'episodes' | 'script' | 'passage' | 'storyboard' | 'shot' | 'frames';
export type ChatMessage = { id: string; role: 'user' | 'assistant'; content: string; objectID: string; draftRev: number; createdAt: string };
export type Shot = Revised & {
  draftOnly?: boolean;
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
export type Stage = 'library' | 'settings' | 'queue' | 'planning' | 'characters' | 'script' | 'storyboard' | 'frames' | 'video';
/** 服务端 jobs.json 里的一条视频任务。字段名与 lib/video_store.rb 的 add_job 对齐。 */
export type VideoJob = {
  id: string; title?: string; prompt?: string; provider?: string;
  state: 'draft' | 'submitting' | 'queued' | 'in_progress' | 'completed' | 'failed' | string;
  progress?: number; createdAt?: string; updatedAt?: string;
  error?: { code?: string; message?: string } | null;
  outputPath?: string | null; outputURL?: string | null; downloadError?: string | null;
};
export type VideoQueueFilter = 'all' | 'active' | 'completed' | 'failed' | 'draft';
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
        complete(request: { system: string; messages: Array<{ role: 'user' | 'assistant'; content: string }>; provider?: string; model?: string; skills?: string[]; streamID?: string; tools?: PluginAITool[] }): Promise<{ text: string; model: string; providerID: string; toolCalls?: PluginAIToolCall[] }>;
        /** 按 streamID 停一条在跑的对话。桥 2.3.0 起可用，旧宿主上是 undefined。 */
        cancel?(streamID: string): Promise<{ cancelled: boolean }>;
        providers(): Promise<{ providers: ProviderEntry[] }>;
        // referenceImagePaths：参照图的本地绝对路径，宿主负责钳制路径并上传
        // 换成公网 URL（网关只接 URL）。最多 9 张。省略或空数组即纯文生图。
        generateImage(request: { prompt: string; provider: 'some-im'; model: ImageModel; size: '1024x1024' | '1536x1024' | '1024x1536'; referenceImagePaths?: string[] }): Promise<ImageResult>;
      };
      skills?: {
        list(): Promise<{ skills: SkillEntry[] }>;
      };
    };
  }
}
