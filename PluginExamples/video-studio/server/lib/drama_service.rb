# frozen_string_literal: true

require "json"
require "securerandom"
require "time"

class DramaService
  IMAGE_MODELS = %w[gpt-image-2 nano-banana-2].freeze
  FRAME_KINDS = %w[start end].freeze

  # 找不到目标时抛出，message 即对外错误码。刻意不复用 ArgumentError：
  # positive / integer 这类转换也会抛 ArgumentError，混在一起会把
  # "参数格式不对" 误报成 "找不到对象"。
  NotFound = Class.new(StandardError)

  # 版本对不上。跨调用（先 get 再 save）没有锁能拦，只能靠对象自己的修订号。
  # 带上当前值，前端才好告诉用户「你手上这版已经旧了」而不是干抛一句失败。
  class Conflict < StandardError
    attr_reader :expected, :actual, :field

    def initialize(field, expected, actual)
      @field = field
      @expected = expected
      @actual = actual
      super("revision_conflict")
    end
  end

  # 允许走草稿的字段，以及各自的长度上限。白名单在这里而不是靠提示词：
  # 模型返回整个对象，超出这张表的键一律丢掉，它就改不动候选图、ID 和
  # 状态这些不该由文字生成来动的东西。
  DRAFT_TEXT_FIELDS = {
    "drama" => {
      "title" => 160, "genre" => 80, "format" => 80, "logline" => 1_200,
      "coreConflict" => 1_200, "audience" => 300, "tone" => 300, "arc" => 4_000
    }.freeze,
    "character" => { "name" => 120, "description" => 2_000, "visualPrompt" => 8_000 }.freeze,
    "episode" => { "title" => 160, "summary" => 2_000, "script" => 20_000 }.freeze,
    "shot" => {
      "title" => 160, "summary" => 2_000, "actionStart" => 2_000, "actionEnd" => 2_000,
      "cameraIntent" => 1_000, "startPrompt" => 8_000, "endPrompt" => 8_000
    }.freeze
  }.freeze

  DRAFT_SCOPES = DRAFT_TEXT_FIELDS.keys.freeze

  NOT_FOUND_MESSAGES = {
    "drama_not_found" => "Short drama was not found.",
    "episode_not_found" => "Episode was not found.",
    "shot_not_found" => "Storyboard shot was not found.",
    "character_not_found" => "Character was not found.",
    "candidate_not_found" => "Image candidate was not found."
  }.freeze

  CONFLICT_MESSAGE = "This object changed since you loaded it. Reload and review before saving again."


  CHARACTER_DEFAULTS = {
    "name" => "", "description" => "", "visualPrompt" => "",
    "identityVersion" => 1, "candidates" => [], "selectedCandidateID" => nil,
    "rev" => 0, "draftRev" => 0, "draft" => nil
  }.freeze

  SHOT_DEFAULTS = {
    "order" => 1, "title" => "", "summary" => "", "dialogue" => [],
    "actionStart" => "", "actionEnd" => "", "cameraIntent" => "", "duration" => 4,
    "startPrompt" => "", "endPrompt" => "", "startCandidates" => [], "endCandidates" => [],
    "selectedStartID" => nil, "selectedEndID" => nil,
    "rev" => 0, "draftRev" => 0, "draft" => nil
  }.freeze

  # 宿主生成的图片只会落在这个目录里（AgentPluginGeneratedMediaResolver）。
  # 模型递上来的 filePath 一律收敛到这里，否则它可以把用户任意一张本地
  # 图片当作 referenceImagePath 送去第三方视频接口。
  def initialize(store:, media_root:)
    @store = store
    @media_root = File.expand_path(media_root)
  end

  attr_reader :media_root

  def list
    { "ok" => true, "dramas" => @store.list }
  end

  def get(arguments)
    drama = @store.find(arguments["id"])
    drama ? { "ok" => true, "drama" => drama } : failure("drama_not_found")
  end

  def confirm_plan(arguments)
    plan = arguments["plan"]
    return failure("invalid_plan", "A structured short-drama plan is required.") unless plan.is_a?(Hash)
    return failure("missing_title", "The short drama title is required.") if plan["title"].to_s.strip.empty?
    # 模型超时重试不该多出一部一模一样的短剧。requestID 由调用方给，
    # 没给就退回原来的「每次都新建」。
    request_id = clipped(arguments["requestID"], 200)
    unless request_id.empty?
      existing = @store.find_by_request_id(request_id)
      return { "ok" => true, "drama" => existing, "deduplicated" => true } if existing
    end
    { "ok" => true, "drama" => @store.create(plan, request_id: request_id) }
  end

  def save_character(arguments)
    guarded do
      drama = mutate_drama(arguments) do |item|
        character = find_or_build(item["characters"], arguments["characterID"],
                                  CHARACTER_DEFAULTS, "character_not_found")
        check_revision(character, arguments["expectedRev"])
        assign(character, "name", arguments["name"], 120)
        assign(character, "description", arguments["description"], 2_000)
        assign(character, "visualPrompt", arguments["visualPrompt"], 8_000)
        unless arguments["identityVersion"].nil?
          character["identityVersion"] = [arguments["identityVersion"].to_i, 1].max
        end
      end
      { "ok" => true, "drama" => drama }
    end
  end

  def save_episode(arguments)
    guarded do
      drama = mutate_episode(arguments) do |episode|
        check_revision(episode, arguments["expectedRev"])
        assign(episode, "title", arguments["title"], 160)
        assign(episode, "summary", arguments["summary"], 2_000)
        assign(episode, "script", arguments["script"], 20_000)
      end
      { "ok" => true, "drama" => drama }
    end
  end

  def save_shot(arguments)
    guarded do
      drama = mutate_episode(arguments) do |episode, item|
        # 第一个分镜落库就算进入制作。早先 status 只会是 planning，首页那两个
        # 状态筛选点了必然是空的。
        item["status"] = "production" if item["status"] == "planning"
        shot = find_or_build(episode["shots"], arguments["shotID"], SHOT_DEFAULTS, "shot_not_found")
        check_revision(shot, arguments["expectedRev"])
        shot["order"] = positive(arguments["order"], episode["shots"].length) unless arguments["order"].nil?
        assign(shot, "title", arguments["title"], 160)
        assign(shot, "summary", arguments["summary"], 2_000)
        assign(shot, "actionStart", arguments["actionStart"], 2_000)
        assign(shot, "actionEnd", arguments["actionEnd"], 2_000)
        assign(shot, "cameraIntent", arguments["cameraIntent"], 1_000)
        assign(shot, "startPrompt", arguments["startPrompt"], 8_000)
        assign(shot, "endPrompt", arguments["endPrompt"], 8_000)
        shot["dialogue"] = normalize_dialogue(arguments["dialogue"]) unless arguments["dialogue"].nil?
        shot["duration"] = positive(arguments["duration"], 4) unless arguments["duration"].nil?
        episode["shots"].sort_by! { |entry| entry["order"].to_i }
      end
      { "ok" => true, "drama" => drama }
    end
  end

  # 写工作草稿。手改和 AI 结果都走这条路：正式内容一步不动，用户随时
  # 可以反悔。合并是局部的——只认调用方真的传了的键，其余保持原样，
  # 这样「AI 只改一个字段」不会把别的字段抹成空串。
  def save_draft(arguments)
    guarded do
      scope = draft_scope(arguments["scope"])
      return failure("invalid_scope", "Unknown draft scope.") unless scope

      drama = mutate_scope(scope, arguments) do |node|
        check_revision(node, arguments["expectedDraftRev"], "draftRev")
        patch = arguments["draft"]
        raise NotFound, "invalid_draft" unless patch.is_a?(Hash)

        node["draft"] = merge_draft(scope, node, patch)
        node["draftRev"] = node["draftRev"].to_i + 1
      end
      { "ok" => true, "drama" => drama }
    end
  end

  # 定稿。把草稿并进正式内容，清空草稿，rev 自增。
  #
  # 重复点确认靠 expectedRev 天然挡住：第二次进来时 rev 已经变了，返回的是
  # 冲突而不是又写一遍——前端把这个冲突当成「刚才那次已经成了」就行，
  # 不必再单独存一份请求 ID 去重。
  def commit_draft(arguments)
    guarded do
      scope = draft_scope(arguments["scope"])
      return failure("invalid_scope", "Unknown draft scope.") unless scope

      drama = mutate_scope(scope, arguments) do |node|
        check_revision(node, arguments["expectedRev"])
        draft = node["draft"]
        raise NotFound, "empty_draft" unless draft.is_a?(Hash) && !draft.empty?

        apply_draft(scope, node, draft)
        node["draft"] = nil
        node["rev"] = node["rev"].to_i + 1
        # 草稿清空本身也是一次草稿变更。draftRev 继续往前走，在跑的那条
        # 请求回来时才认得出「基准已经不是你出发时那份了」。
        node["draftRev"] = node["draftRev"].to_i + 1
      end
      { "ok" => true, "drama" => drama }
    end
  end

  def discard_draft(arguments)
    guarded do
      scope = draft_scope(arguments["scope"])
      return failure("invalid_scope", "Unknown draft scope.") unless scope

      drama = mutate_scope(scope, arguments) do |node|
        check_revision(node, arguments["expectedDraftRev"], "draftRev")
        node["draft"] = nil
        node["draftRev"] = node["draftRev"].to_i + 1
      end
      { "ok" => true, "drama" => drama }
    end
  end

  def record_image(arguments)
    kind = arguments["kind"].to_s
    return failure("invalid_frame_kind", "Frame kind must be start or end.") unless FRAME_KINDS.include?(kind)
    model = arguments["model"].to_s
    return failure("invalid_image_model", "Unsupported image model.") unless IMAGE_MODELS.include?(model)
    file_path = generated_media_path(arguments["filePath"])
    return failure("invalid_media_path", media_path_message) unless file_path

    guarded do
      drama = mutate_shot(arguments) do |shot|
        key = kind == "start" ? "startCandidates" : "endCandidates"
        shot[key] ||= []
        shot[key] << candidate(arguments, model, file_path)
      end
      { "ok" => true, "drama" => drama }
    end
  end

  def record_character_image(arguments)
    model = arguments["model"].to_s
    return failure("invalid_image_model", "Unsupported image model.") unless IMAGE_MODELS.include?(model)
    file_path = generated_media_path(arguments["filePath"])
    return failure("invalid_media_path", media_path_message) unless file_path

    guarded do
      drama = mutate_character(arguments) do |character|
        character["candidates"] ||= []
        character["candidates"] << candidate(arguments, model, file_path)
      end
      { "ok" => true, "drama" => drama }
    end
  end

  def select_character_image(arguments)
    guarded do
      drama = mutate_character(arguments) do |character|
        candidates = character["candidates"] || []
        selected = candidates.find { |entry| entry["id"] == arguments["candidateID"].to_s }
        raise NotFound, "candidate_not_found" unless selected
        character["selectedCandidateID"] = selected["id"]
      end
      { "ok" => true, "drama" => drama }
    end
  end

  def select_image(arguments)
    kind = arguments["kind"].to_s
    return failure("invalid_frame_kind", "Frame kind must be start or end.") unless FRAME_KINDS.include?(kind)
    guarded do
      drama = mutate_shot(arguments) do |shot|
        candidates = shot[kind == "start" ? "startCandidates" : "endCandidates"] || []
        selected = candidates.find { |entry| entry["id"] == arguments["candidateID"].to_s }
        raise NotFound, "candidate_not_found" unless selected
        shot[kind == "start" ? "selectedStartID" : "selectedEndID"] = selected["id"]
      end
      { "ok" => true, "drama" => drama }
    end
  end

  private

  def guarded
    yield
  rescue NotFound => error
    failure(error.message)
  rescue Conflict => error
    {
      "ok" => false,
      "error" => {
        "code" => "revision_conflict", "message" => CONFLICT_MESSAGE,
        "field" => error.field, "expected" => error.expected, "actual" => error.actual
      }
    }
  end

  # expectedRev 没传就当调用方不关心版本——旧插件和图片候选那几条路径都
  # 这样。传了就必须对上，对不上宁可让这次保存失败：静默覆盖丢的是用户
  # 刚敲进去的字。
  def check_revision(node, expected, field = "rev")
    return if expected.nil?
    actual = node[field].to_i
    raise Conflict.new(field, Integer(expected), actual) unless Integer(expected) == actual
  rescue ArgumentError, TypeError
    raise Conflict.new(field, expected, node[field].to_i)
  end

  def draft_scope(value)
    token = value.to_s.strip
    DRAFT_SCOPES.include?(token) ? token : nil
  end

  # 四种作用域共用一条定位路径，省得每个方法各写一遍找对象的代码。
  def mutate_scope(scope, arguments, &block)
    case scope
    when "drama" then mutate_drama(arguments, &block)
    when "character" then mutate_character(arguments, &block)
    when "episode" then mutate_episode(arguments) { |episode, _drama| block.call(episode) }
    when "shot" then mutate_shot(arguments, &block)
    end
  end

  # 已有草稿上叠新的一层，而不是整份替换：模型这轮只回了三个字段时，
  # 上一轮生成、用户已经看过的其他字段不该跟着消失。
  def merge_draft(scope, node, patch)
    merged = node["draft"].is_a?(Hash) ? deep_copy(node["draft"]) : {}
    DRAFT_TEXT_FIELDS.fetch(scope).each do |key, limit|
      next unless patch.key?(key)
      merged[key] = clipped(patch[key], limit)
    end
    if scope == "shot"
      merged["dialogue"] = normalize_dialogue(patch["dialogue"]) if patch.key?("dialogue")
      merged["duration"] = positive(patch["duration"], node["duration"].to_i) if patch.key?("duration")
    end
    merged
  end

  def apply_draft(scope, node, draft)
    DRAFT_TEXT_FIELDS.fetch(scope).each do |key, limit|
      next unless draft.key?(key)
      node[key] = clipped(draft[key], limit)
    end
    return unless scope == "shot"
    node["dialogue"] = normalize_dialogue(draft["dialogue"]) if draft.key?("dialogue")
    node["duration"] = positive(draft["duration"], node["duration"].to_i) if draft.key?("duration")
  end

  def mutate_drama(arguments)
    drama = @store.update(arguments["dramaID"]) { |item| yield item }
    raise NotFound, "drama_not_found" unless drama
    drama
  end

  def mutate_episode(arguments)
    mutate_drama(arguments) do |drama|
      episode = drama["episodes"].find { |entry| entry["id"] == arguments["episodeID"].to_s }
      raise NotFound, "episode_not_found" unless episode
      yield episode, drama
    end
  end

  def mutate_shot(arguments)
    mutate_episode(arguments) do |episode|
      shot = episode["shots"].find { |entry| entry["id"] == arguments["shotID"].to_s }
      raise NotFound, "shot_not_found" unless shot
      yield shot
    end
  end

  def mutate_character(arguments)
    mutate_drama(arguments) do |drama|
      character = drama["characters"].find { |entry| entry["id"] == arguments["characterID"].to_s }
      raise NotFound, "character_not_found" unless character
      yield character
    end
  end

  def candidate(arguments, model, file_path)
    {
      "id" => SecureRandom.uuid,
      "mediaURL" => clipped(arguments["mediaURL"], 2_000),
      "filePath" => file_path,
      "prompt" => clipped(arguments["prompt"], 8_000),
      "model" => model,
      "createdAt" => Time.now.utc.iso8601
    }
  end

  # 收敛到宿主的生成目录内，并拒绝符号链接——否则目录里放一个指向别处的
  # 链接就能把收敛绕过去。返回 nil 表示这个路径不可信。
  def generated_media_path(value)
    raw = value.to_s.strip
    return nil if raw.empty? || raw.length > 4_000
    expanded = File.expand_path(raw)
    return nil unless expanded.start_with?("#{@media_root}#{File::SEPARATOR}")
    return nil if File.symlink?(expanded)
    expanded
  end

  def media_path_message
    "Image files must live in the plugin's generated-images directory."
  end

  # 只有调用方真的传了这个字段才改。模型常常只带想改的那一项，
  # 无条件 merge 会把人物小传、台词、首尾帧提示词一起清成空串。
  def assign(target, key, value, limit)
    return if value.nil?
    target[key] = clipped(value, limit)
  end

  def find_or_build(collection, id, defaults, missing_code)
    token = id.to_s
    unless token.empty?
      found = collection.find { |entry| entry["id"] == token }
      # 传了 ID 却找不到，多半是模型拿着上一轮的旧 ID 重试。静默新建
      # 会让用户的分镜列表里堆出一串空壳。
      raise NotFound, missing_code unless found
      return found
    end
    created = deep_copy(defaults).merge("id" => SecureRandom.uuid)
    collection << created
    created
  end

  # macOS 自带的 /usr/bin/ruby 是 2.6，没有 filter_map；mcp.json 钉死了这个
  # 解释器，所以这里只用 2.6 就有的 API。
  def normalize_dialogue(value)
    Array(value).map do |entry|
      next nil unless entry.is_a?(Hash)
      text = clipped(entry["text"], 2_000)
      next nil if text.empty?
      { "id" => entry["id"].to_s.empty? ? SecureRandom.uuid : entry["id"].to_s,
        "speaker" => clipped(entry["speaker"], 120), "text" => text }
    end.compact.first(50)
  end

  def deep_copy(value)
    JSON.parse(JSON.generate(value))
  end

  def clipped(value, limit)
    value.to_s.strip[0, limit]
  end

  def positive(value, fallback)
    number = Integer(value)
    number.positive? ? number : fallback
  rescue ArgumentError, TypeError
    fallback
  end

  def failure(code, message = nil)
    { "ok" => false, "error" => { "code" => code, "message" => message || NOT_FOUND_MESSAGES.fetch(code, code) } }
  end
end
