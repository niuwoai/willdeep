#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8
$stdout.sync = true
$stdout.set_encoding(Encoding::UTF_8)
$stderr.set_encoding(Encoding::UTF_8)

require_relative "adapters/openai_videos_async"
require_relative "lib/video_store"
require_relative "lib/video_service"
require_relative "lib/drama_store"
require_relative "lib/drama_service"
require_relative "lib/chat_store"
require_relative "lib/creative_skill_store"

# 宿主按 pluginID 给每个插件分一个目录，本插件的 pluginID 是
# willdeep-video-studio，生成的图片也由宿主写进这个目录。任务存档早先落在
# plugin-data/video-studio/，同一个插件占两个目录，卸载清理和备份会漏掉一半。
def plugin_data_directory
  File.expand_path("~/Library/Application Support/WillDeep/plugin-data/willdeep-video-studio")
end

def legacy_video_store_path
  File.expand_path("~/Library/Application Support/WillDeep/plugin-data/video-studio/jobs.json")
end

def video_store_path
  ENV["VIDEO_STUDIO_STORE"] || File.join(plugin_data_directory, "jobs.json")
end

# 只在新路径还没有存档时把旧存档搬过来，且不删旧文件——万一搬错了，用户的
# 任务记录还在原处。
def migrate_legacy_video_store
  return if ENV["VIDEO_STUDIO_STORE"]
  return if File.exist?(video_store_path)
  return unless File.exist?(legacy_video_store_path)

  FileUtils.mkdir_p(File.dirname(video_store_path))
  FileUtils.cp(legacy_video_store_path, video_store_path)
  warn "video-studio: copied legacy job store into #{File.dirname(video_store_path)}"
rescue SystemCallError => error
  warn "video-studio: legacy job store migration skipped (#{error.class}: #{error.message})"
end

def generated_media_directory
  File.join(plugin_data_directory, "generated-images")
end

def video_output_directory
  value = ENV["VIDEO_STUDIO_OUTPUT_DIRECTORY"].to_s.strip
  value = "~/Movies/WillDeep Video Studio" if value.empty?
  File.expand_path(value)
end

def drama_store_path
  ENV["VIDEO_STUDIO_DRAMA_STORE"] || File.join(plugin_data_directory, "dramas.json")
end

# 共创聊天一部剧一个文件。放在 dramas.json 旁边的子目录里，卸载清理仍然
# 只需要删这一个插件目录。
def chat_store_directory
  ENV["VIDEO_STUDIO_CHAT_STORE"] || File.join(plugin_data_directory, "chats")
end

# 创作技能：插件包里那份是只读模板，用户编辑的副本落在数据目录。技能是
# 全局一份，改了对所有短剧生效。
def creative_skill_template_root
  File.join(__dir__, "..", "skills", "creative")
end

def creative_skill_user_root
  ENV["VIDEO_STUDIO_SKILL_STORE"] || File.join(plugin_data_directory, "creative-skills")
end

migrate_legacy_video_store
STORE = VideoStore.new(video_store_path)
# 选定 provider 就用它自己的地址，选「自定义」才回落到手填的 API Base。
# 三家走的是同一套 OpenAI 兼容异步视频接口，所以只换地址、不换适配器。
PROVIDER_BASE_URLS = {
  "tsingfly" => "https://hub.tsingfly.com",
  "openai" => "https://api.openai.com"
}.freeze
DEFAULT_API_BASE = PROVIDER_BASE_URLS.fetch("tsingfly")

# 没有 VIDEO_STUDIO_PROVIDER 的老装机（设置里还没有这一项）继续按
# VIDEO_STUDIO_API_BASE 走，行为与加这个设置之前一致。
def resolved_api_base
  provider = ENV["VIDEO_STUDIO_PROVIDER"].to_s.strip
  known = PROVIDER_BASE_URLS[provider]
  return known if known

  base = ENV["VIDEO_STUDIO_API_BASE"].to_s.strip
  base.empty? ? DEFAULT_API_BASE : base
end

ADAPTER_FACTORY = lambda do
  OpenAIVideosAsyncAdapter.new(
    base_url: resolved_api_base,
    api_key: ENV["VIDEO_STUDIO_API_KEY"],
    output_directory: video_output_directory,
    open_timeout: (ENV["VIDEO_STUDIO_OPEN_TIMEOUT"] || 20).to_i,
    read_timeout: (ENV["VIDEO_STUDIO_READ_TIMEOUT"] || 90).to_i
  )
end
SERVICE = VideoService.new(store: STORE, adapter_factory: ADAPTER_FACTORY)
DRAMA_SERVICE = DramaService.new(
  store: DramaStore.new(drama_store_path),
  media_root: ENV["VIDEO_STUDIO_MEDIA_ROOT"] || generated_media_directory
)
CHAT_STORE = ChatStore.new(chat_store_directory)
CREATIVE_SKILLS = CreativeSkillStore.new(
  template_root: creative_skill_template_root,
  user_root: creative_skill_user_root
)

def creative_skill_list
  CREATIVE_SKILLS.list.merge("ok" => true)
end

def creative_skill_get(arguments)
  entry = CREATIVE_SKILLS.get(arguments["id"])
  entry ? { "ok" => true, "skill" => entry } : failure_payload("skill_not_found", "Creative skill was not found.")
end

def creative_skill_save(arguments)
  entry = CREATIVE_SKILLS.save(arguments["id"], arguments["body"])
  { "ok" => true, "skill" => entry }
rescue ArgumentError => error
  failure_payload("invalid_skill", error.message)
end

def creative_skill_reset(arguments)
  entry = CREATIVE_SKILLS.reset(arguments["id"])
  { "ok" => true, "skill" => entry }
rescue ArgumentError => error
  failure_payload("invalid_skill", error.message)
end

def creative_skill_compose(arguments)
  CREATIVE_SKILLS.compose(stage: arguments["stage"], common: arguments["common"])
end

def failure_payload(code, message)
  { "ok" => false, "error" => { "code" => code, "message" => message } }
end

def chat_append(arguments)
  entry = CHAT_STORE.append(arguments["dramaID"], arguments["stage"], arguments["message"])
  { "ok" => true, "message" => entry }
rescue ArgumentError
  { "ok" => false, "error" => { "code" => "invalid_stage", "message" => "Unknown co-creation stage." } }
end

def chat_list(arguments)
  { "ok" => true, "messages" => CHAT_STORE.list(arguments["dramaID"], arguments["stage"]) }
end

def chat_clear(arguments)
  CHAT_STORE.clear(arguments["dramaID"], arguments["stage"])
  { "ok" => true }
rescue ArgumentError
  { "ok" => false, "error" => { "code" => "invalid_stage", "message" => "Unknown co-creation stage." } }
end

TOOLS = [
  {
    name: "drama.list",
    description: "List local short-drama projects.",
    inputSchema: { type: "object", properties: {} }
  },
  {
    name: "drama.get",
    description: "Get one short-drama project with characters, episodes, shots, and frame candidates.",
    inputSchema: { type: "object", properties: { id: { type: "string" } }, required: ["id"] }
  },
  {
    name: "drama.confirm_plan",
    description: "Persist a structured short-drama planning card only after the user confirms it. Pass a stable requestID so a retry after a timeout returns the same drama instead of creating a duplicate.",
    inputSchema: { type: "object", properties: { plan: { type: "object" }, requestID: { type: "string" } }, required: ["plan"] }
  },
  {
    name: "drama.save_character",
    description: "Create or update a character identity specification.",
    inputSchema: { type: "object", properties: { dramaID: { type: "string" }, characterID: { type: "string" }, name: { type: "string" }, description: { type: "string" }, visualPrompt: { type: "string" }, identityVersion: { type: "integer" } }, required: ["dramaID", "name"] }
  },
  {
    name: "drama.save_episode",
    description: "Update an episode outline or script.",
    inputSchema: { type: "object", properties: { dramaID: { type: "string" }, episodeID: { type: "string" }, title: { type: "string" }, summary: { type: "string" }, script: { type: "string" } }, required: ["dramaID", "episodeID"] }
  },
  {
    name: "drama.save_shot",
    description: "Create or update a storyboard shot, including editable dialogue and separate start/end frame prompts.",
    inputSchema: { type: "object", properties: { dramaID: { type: "string" }, episodeID: { type: "string" }, shotID: { type: "string" }, order: { type: "integer" }, title: { type: "string" }, summary: { type: "string" }, dialogue: { type: "array", items: { type: "object" } }, actionStart: { type: "string" }, actionEnd: { type: "string" }, cameraIntent: { type: "string" }, duration: { type: "integer" }, startPrompt: { type: "string" }, endPrompt: { type: "string" } }, required: ["dramaID", "episodeID"] }
  },
  {
    name: "drama.save_draft",
    description: "Write the working draft of one object without touching its committed content. Pass expectedDraftRev to detect edits made since the draft was loaded; fields outside the per-scope whitelist are dropped.",
    inputSchema: { type: "object", properties: { dramaID: { type: "string" }, scope: { type: "string", enum: DramaService::DRAFT_SCOPES }, characterID: { type: "string" }, episodeID: { type: "string" }, shotID: { type: "string" }, draft: { type: "object" }, expectedDraftRev: { type: "integer" } }, required: %w[dramaID scope draft] }
  },
  {
    name: "drama.list_shots",
    description: "List one episode's storyboard shots in a model-facing shape: the fields it needs to reason about and reference, without the frame-candidate arrays or selection state.",
    inputSchema: { type: "object", properties: { dramaID: { type: "string" }, episodeID: { type: "string" } }, required: %w[dramaID episodeID] }
  },
  {
    name: "drama.save_shot_drafts",
    description: "Write drafts for many shots at once, matched by shot order. Atomic: either every listed shot is written or none is. Shots whose order is not found are reported in `skipped` rather than dropped silently.",
    inputSchema: { type: "object", properties: { dramaID: { type: "string" }, episodeID: { type: "string" }, create: { type: "boolean" }, expectedEpisodeRev: { type: "integer" }, expectedEpisodeDraftRev: { type: "integer" }, expectedShots: { type: "array", items: { type: "object", properties: { id: { type: "string" }, rev: { type: "integer" }, draftRev: { type: "integer" } }, required: %w[id rev draftRev] } }, shots: { type: "array", items: { type: "object", properties: { order: { type: "integer" }, title: { type: "string" }, summary: { type: "string" }, actionStart: { type: "string" }, actionEnd: { type: "string" }, cameraIntent: { type: "string" }, startPrompt: { type: "string" }, endPrompt: { type: "string" }, dialogue: { type: "array", items: { type: "object" } }, duration: { type: "integer" } }, required: ["order"] } } }, required: %w[dramaID episodeID shots] }
  },
  {
    name: "drama.save_episode_drafts",
    description: "Write drafts for many episodes at once, matched by episode order. Atomic: either every listed episode is written or none is. Episodes whose order is not found are reported in `skipped` rather than dropped silently.",
    inputSchema: { type: "object", properties: { dramaID: { type: "string" }, episodes: { type: "array", items: { type: "object", properties: { order: { type: "integer" }, title: { type: "string" }, summary: { type: "string" }, script: { type: "string" } }, required: ["order"] } } }, required: %w[dramaID episodes] }
  },
  {
    name: "drama.commit_episode_drafts",
    description: "Adopt the working drafts of many episodes at once. Atomic: one write for the whole batch. Episodes whose script would still be empty after adopting are left untouched, draft included, and reported in `skipped`. Episodes without a draft are neither touched nor reported. Pass `orders` to limit the batch to those episode numbers.",
    inputSchema: { type: "object", properties: { dramaID: { type: "string" }, orders: { type: "array", items: { type: "integer" } } }, required: %w[dramaID] }
  },
  {
    name: "drama.commit_draft",
    description: "Adopt the working draft into committed content, clear the draft, and bump rev. A second call with the same expectedRev returns revision_conflict, which callers should read as 'already committed'.",
    inputSchema: { type: "object", properties: { dramaID: { type: "string" }, scope: { type: "string", enum: DramaService::DRAFT_SCOPES }, characterID: { type: "string" }, episodeID: { type: "string" }, shotID: { type: "string" }, expectedRev: { type: "integer" }, expectedDraftRev: { type: "integer" } }, required: %w[dramaID scope] }
  },
  {
    name: "drama.discard_draft",
    description: "Throw away the working draft of one object and leave committed content untouched.",
    inputSchema: { type: "object", properties: { dramaID: { type: "string" }, scope: { type: "string", enum: DramaService::DRAFT_SCOPES }, characterID: { type: "string" }, episodeID: { type: "string" }, shotID: { type: "string" }, expectedDraftRev: { type: "integer" } }, required: %w[dramaID scope] }
  },
  {
    name: "skill.list",
    description: "List the creative skills that drive each stage's system prompt, plus the optional common skills a user can attach. Returns metadata only; body comes from skill.get.",
    inputSchema: { type: "object", properties: {} }
  },
  {
    name: "skill.get",
    description: "Read one creative skill's markdown body. Falls back to the bundled template and materialises a user copy on first read.",
    inputSchema: { type: "object", properties: { id: { type: "string" } }, required: ["id"] }
  },
  {
    name: "skill.save",
    description: "Overwrite one creative skill's markdown body. The bundled template is never touched, so skill.reset can always restore it.",
    inputSchema: { type: "object", properties: { id: { type: "string" }, body: { type: "string" } }, required: %w[id body] }
  },
  {
    name: "skill.reset",
    description: "Drop the user copy of one creative skill and fall back to the bundled template.",
    inputSchema: { type: "object", properties: { id: { type: "string" } }, required: ["id"] }
  },
  {
    name: "skill.compose",
    description: "Build the system prompt for one stage: the stage skill first, then the selected common skills appended in order.",
    inputSchema: { type: "object", properties: { stage: { type: "string", enum: CreativeSkillStore::STAGE_SKILLS.keys }, common: { type: "array", items: { type: "string" } } }, required: ["stage"] }
  },
  {
    name: "chat.append",
    description: "Append one co-creation chat message for a drama stage. Messages carry the object they were about and the draft revision they were sent against.",
    inputSchema: { type: "object", properties: { dramaID: { type: "string" }, stage: { type: "string", enum: ChatStore::STAGES }, message: { type: "object" } }, required: %w[dramaID stage message] }
  },
  {
    name: "chat.list",
    description: "Read the persisted co-creation chat for a drama stage.",
    inputSchema: { type: "object", properties: { dramaID: { type: "string" }, stage: { type: "string", enum: ChatStore::STAGES } }, required: %w[dramaID stage] }
  },
  {
    name: "chat.clear",
    description: "Clear the persisted co-creation chat for a drama stage.",
    inputSchema: { type: "object", properties: { dramaID: { type: "string" }, stage: { type: "string", enum: ChatStore::STAGES } }, required: %w[dramaID stage] }
  },
  {
    name: "drama.record_image",
    description: "Record an image returned by the host some.im image bridge as a frame candidate.",
    inputSchema: { type: "object", properties: { dramaID: { type: "string" }, episodeID: { type: "string" }, shotID: { type: "string" }, kind: { type: "string", enum: %w[start end] }, mediaURL: { type: "string" }, filePath: { type: "string" }, prompt: { type: "string" }, model: { type: "string", enum: DramaService::IMAGE_MODELS } }, required: %w[dramaID episodeID shotID kind mediaURL filePath prompt model] }
  },
  {
    name: "drama.record_character_image",
    description: "Record a some.im image as a character identity candidate.",
    inputSchema: { type: "object", properties: { dramaID: { type: "string" }, characterID: { type: "string" }, mediaURL: { type: "string" }, filePath: { type: "string" }, prompt: { type: "string" }, model: { type: "string", enum: DramaService::IMAGE_MODELS } }, required: %w[dramaID characterID mediaURL filePath prompt model] }
  },
  {
    name: "drama.select_character_image",
    description: "Select the canonical identity image for a character.",
    inputSchema: { type: "object", properties: { dramaID: { type: "string" }, characterID: { type: "string" }, candidateID: { type: "string" } }, required: %w[dramaID characterID candidateID] }
  },
  {
    name: "drama.select_image",
    description: "Select a start or end frame candidate for a storyboard shot.",
    inputSchema: { type: "object", properties: { dramaID: { type: "string" }, episodeID: { type: "string" }, shotID: { type: "string" }, kind: { type: "string", enum: %w[start end] }, candidateID: { type: "string" } }, required: %w[dramaID episodeID shotID kind candidateID] }
  },
  {
    name: "video.status",
    description: "Return the safe Video Studio provider configuration and local job counts. Never returns credentials.",
    inputSchema: { type: "object", properties: {} }
  },
  {
    name: "video.create_draft",
    description: "Save a video idea as a draft. Use this for chat-selection capture before generation.",
    inputSchema: {
      type: "object",
      properties: {
        text: { type: "string", description: "Video idea or prompt." },
        title: { type: "string" },
        referenceImagePath: { type: "string" },
        source: { type: "string" }
      },
      required: ["text"]
    }
  },
  {
    name: "video.list",
    description: "List locally persisted video drafts and asynchronous jobs.",
    inputSchema: {
      type: "object",
      properties: {
        status: { type: "string", enum: %w[all draft active completed failed] },
        query: { type: "string" }
      }
    }
  },
  {
    name: "video.generate",
    description: "Submit an asynchronous text-to-video or first-frame image-to-video job. Omitting referenceImagePath uses t2va; providing it uses fl2va.",
    inputSchema: {
      type: "object",
      properties: {
        draftID: { type: "string" },
        title: { type: "string" },
        prompt: { type: "string" },
        negativePrompt: { type: "string" },
        referenceImagePath: { type: "string", description: "Readable local PNG, JPEG, or WebP path." },
        model: { type: "string", description: "Defaults to MiniMax-H3." },
        duration: { type: "integer", enum: [2, 4, 6] },
        width: { type: "integer", description: "Multiple of 32." },
        height: { type: "integer", description: "Multiple of 32." },
        inferenceSteps: { type: "integer", minimum: 1, maximum: 100 },
        seed: { type: "integer" },
        source: { type: "string" }
      },
      required: ["prompt"]
    }
  },
  {
    name: "video.refresh",
    description: "Poll one remote video task and download the MP4 when completed and auto-download is enabled.",
    inputSchema: { type: "object", properties: { id: { type: "string" } }, required: ["id"] }
  },
  {
    name: "video.refresh_active",
    description: "Poll up to twenty active video jobs once. It does not create background or scheduled work.",
    inputSchema: { type: "object", properties: {} }
  },
  {
    name: "video.retry",
    description: "Explicitly submit a new attempt using a finished job's stored request. The original job is preserved.",
    inputSchema: { type: "object", properties: { id: { type: "string" } }, required: ["id"] }
  },
  {
    name: "video.download",
    description: "Download a completed video or retry a failed download without creating a new paid generation task.",
    inputSchema: { type: "object", properties: { id: { type: "string" } }, required: ["id"] }
  },
  {
    name: "video.remove",
    description: "Remove a local job record without deleting its downloaded video file.",
    inputSchema: { type: "object", properties: { id: { type: "string" } }, required: ["id"] }
  },
  {
    name: "video.settings",
    description: "Read or update creative-assistant routing and default video parameters. API credentials remain in plugin settings and are never returned.",
    inputSchema: {
      type: "object",
      properties: {
        assistantProviderID: { type: ["string", "null"] },
        assistantModel: { type: ["string", "null"] },
        videoModel: { type: "string" },
        duration: { type: "integer", enum: [2, 4, 6] },
        width: { type: "integer" },
        height: { type: "integer" },
        inferenceSteps: { type: "integer" },
        autoDownload: { type: "boolean" }
      }
    }
  },
  {
    name: "video.pick_reference",
    description: "Open the macOS file picker and return a local PNG, JPEG, or WebP path.",
    inputSchema: { type: "object", properties: {} }
  },
  {
    name: "video.reveal_output",
    description: "Reveal a completed job's downloaded MP4 in Finder.",
    inputSchema: { type: "object", properties: { id: { type: "string" } }, required: ["id"] }
  }
].freeze

def call_tool(name, arguments)
  case name
  when "drama.list" then DRAMA_SERVICE.list
  when "drama.get" then DRAMA_SERVICE.get(arguments)
  when "drama.confirm_plan" then DRAMA_SERVICE.confirm_plan(arguments)
  when "drama.save_character" then DRAMA_SERVICE.save_character(arguments)
  when "drama.save_episode" then DRAMA_SERVICE.save_episode(arguments)
  when "drama.save_shot" then DRAMA_SERVICE.save_shot(arguments)
  when "drama.save_draft" then DRAMA_SERVICE.save_draft(arguments)
  when "drama.list_shots" then DRAMA_SERVICE.list_shots(arguments)
  when "drama.save_shot_drafts" then DRAMA_SERVICE.save_shot_drafts(arguments)
  when "drama.save_episode_drafts" then DRAMA_SERVICE.save_episode_drafts(arguments)
  when "drama.commit_episode_drafts" then DRAMA_SERVICE.commit_episode_drafts(arguments)
  when "drama.commit_draft" then DRAMA_SERVICE.commit_draft(arguments)
  when "drama.discard_draft" then DRAMA_SERVICE.discard_draft(arguments)
  when "skill.list" then creative_skill_list
  when "skill.get" then creative_skill_get(arguments)
  when "skill.save" then creative_skill_save(arguments)
  when "skill.reset" then creative_skill_reset(arguments)
  when "skill.compose" then creative_skill_compose(arguments)
  when "chat.append" then chat_append(arguments)
  when "chat.list" then chat_list(arguments)
  when "chat.clear" then chat_clear(arguments)
  when "drama.record_image" then DRAMA_SERVICE.record_image(arguments)
  when "drama.select_image" then DRAMA_SERVICE.select_image(arguments)
  when "drama.record_character_image" then DRAMA_SERVICE.record_character_image(arguments)
  when "drama.select_character_image" then DRAMA_SERVICE.select_character_image(arguments)
  when "video.status" then SERVICE.status
  when "video.create_draft" then SERVICE.create_draft(arguments)
  when "video.list" then SERVICE.list(arguments)
  when "video.generate" then SERVICE.generate(arguments)
  when "video.refresh" then SERVICE.refresh(arguments)
  when "video.refresh_active" then SERVICE.refresh_active
  when "video.retry" then SERVICE.retry(arguments)
  when "video.download" then SERVICE.download(arguments)
  when "video.remove" then SERVICE.remove(arguments)
  when "video.settings" then SERVICE.settings(arguments)
  when "video.pick_reference" then SERVICE.pick_reference
  when "video.reveal_output" then SERVICE.reveal_output(arguments)
  else { "ok" => false, "error" => { "code" => "unknown_tool", "message" => "Unknown tool #{name}" } }
  end
end

UnknownMethod = Class.new(StandardError)

def respond_error(request, code, message)
  return unless request.is_a?(Hash) && request["id"]

  puts JSON.generate(jsonrpc: "2.0", id: request["id"], error: { code: code, message: message })
end

ARGF.each_line do |line|
  request = JSON.parse(line)
  next unless request["id"]

  result = case request["method"]
           when "initialize"
             {
               protocolVersion: "2025-06-18",
               capabilities: { tools: {} },
               serverInfo: { name: "video-studio", version: "0.16.0" }
             }
           when "tools/list"
             { tools: TOOLS }
           when "tools/call"
             arguments = request.dig("params", "arguments") || {}
             payload = call_tool(request.dig("params", "name"), arguments)
             { content: [{ type: "text", text: JSON.generate(payload) }] }
           else
             raise UnknownMethod, request["method"].to_s
           end

  puts JSON.generate(jsonrpc: "2.0", id: request["id"], result: result)
rescue JSON::ParserError
  warn "video-studio: invalid JSON-RPC request"
rescue UnknownMethod => error
  respond_error(defined?(request) ? request : nil, -32_601, "Method not found: #{error.message}")
rescue VideoStore::Unavailable, DramaStore::Unavailable, ChatStore::Unavailable, CreativeSkillStore::Unavailable => error
  # 存档读不出来时刻意不静默重建：写入是全量覆写，一次误判就会把用户的
  # 短剧和任务记录抹平。把原因如实告诉调用方，让人去看那个文件。
  warn "video-studio: #{error.class}: #{error.message}"
  respond_error(
    defined?(request) ? request : nil,
    -32_002,
    "Local Video Studio archive could not be read; it was left untouched. #{error.message}"
  )
rescue StandardError => error
  # 只打 error.class 的话，线上报障时 stderr 全部内容就是一行
  # "video-studio: NoMethodError"，没有文件也没有行号。
  warn "video-studio: #{error.class}: #{error.message}"
  Array(error.backtrace).first(5).each { |line| warn "video-studio:   #{line}" }
  respond_error(defined?(request) ? request : nil, -32_000, "Video Studio internal error")
end
