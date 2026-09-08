#!/usr/bin/env ruby
# frozen_string_literal: true

# 这个脚本必须能在 macOS 自带的 /usr/bin/ruby（2.6）下跑通：mcp.json 把插件的
# 解释器钉死成它，用 homebrew 的 3.x 跑绿了不代表用户机器上能用。
require "json"
require "tmpdir"
require_relative "../PluginExamples/video-studio/server/lib/drama_store"
require_relative "../PluginExamples/video-studio/server/lib/drama_service"
require_relative "../PluginExamples/video-studio/server/lib/chat_store"

results = []
check = lambda do |name, &block|
  block.call
  results << { name: name, status: "passed" }
rescue StandardError => error
  results << { name: name, status: "failed", error: "#{error.class}: #{error.message}" }
end

Dir.mktmpdir("willdeep-drama-test-") do |directory|
  path = File.join(directory, "dramas.json")
  media_root = File.join(directory, "generated-images")
  outside = File.join(directory, "outside.png")
  Dir.mkdir(media_root)
  File.write(File.join(media_root, "a.png"), "png")
  File.write(outside, "png")
  service = DramaService.new(store: DramaStore.new(path), media_root: media_root)
  plan = {
    "title" => "错时来信", "genre" => "悬疑", "format" => "竖屏短剧",
    "episodeCount" => 2, "episodeDurationSeconds" => 90, "logline" => "未来短信改变今天"
  }
  created = service.confirm_plan("plan" => plan)
  drama = created["drama"]

  check.call("confirmed planning card persists named drama") do
    raise "not persisted" unless service.list.dig("dramas", 0, "title") == "错时来信"
  end
  check.call("episode count and switchable IDs are created") do
    raise "bad episodes" unless drama["episodes"].length == 2 && drama["episodes"].all? { |episode| !episode["id"].empty? }
  end
  check.call("a repeated confirm with the same requestID does not duplicate the drama") do
    first = service.confirm_plan("requestID" => "req-1", "plan" => plan)
    second = service.confirm_plan("requestID" => "req-1", "plan" => plan)
    raise "not deduplicated" unless second["deduplicated"]
    raise "different drama" unless first.dig("drama", "id") == second.dig("drama", "id")
  end

  character = service.save_character(
    "dramaID" => drama["id"], "name" => "林默", "description" => "落魄程序员",
    "visualPrompt" => "二十八岁，窄脸，黑色短发，灰色风衣", "identityVersion" => 3
  ).dig("drama", "characters", 0)
  check.call("character identity image model is allowlisted") do
    rejected = service.record_character_image(
      "dramaID" => drama["id"], "characterID" => character["id"], "model" => "other"
    )
    raise "model escaped allowlist" if rejected["ok"]
  end
  check.call("a name-only save keeps the identity prompt and version") do
    saved = service.save_character(
      "dramaID" => drama["id"], "characterID" => character["id"], "name" => "林默（改名）"
    ).dig("drama", "characters", 0)
    raise "description wiped" unless saved["description"] == "落魄程序员"
    raise "identity prompt wiped" unless saved["visualPrompt"].include?("灰色风衣")
    raise "identity version reset" unless saved["identityVersion"] == 3
  end
  check.call("a stale character ID is reported instead of silently creating a twin") do
    response = service.save_character(
      "dramaID" => drama["id"], "characterID" => "00000000-0000-0000-0000-000000000000", "name" => "幽灵"
    )
    raise "stale ID accepted" if response["ok"]
    raise "wrong code #{response.dig('error', 'code')}" unless response.dig("error", "code") == "character_not_found"
    raise "twin created" unless service.get("id" => drama["id"]).dig("drama", "characters").length == 1
  end

  episode = drama["episodes"][0]
  updated = service.save_shot(
    "dramaID" => drama["id"], "episodeID" => episode["id"], "order" => 1,
    "title" => "手机亮起", "summary" => "屏幕显示未来短信",
    "dialogue" => [{ "speaker" => "林默", "text" => "这不可能。" }],
    "startPrompt" => "暗室中的手机", "endPrompt" => "惊愕的脸", "duration" => 4
  )
  shot = updated.dig("drama", "episodes", 0, "shots", 0)
  check.call("storyboard keeps editable dialogue and separate frame prompts") do
    raise "save_shot failed: #{updated.dig('error', 'code')}" unless updated["ok"]
    raise "dialogue missing" unless shot.dig("dialogue", 0, "text") == "这不可能。"
    raise "prompts collapsed" unless shot["startPrompt"] != shot["endPrompt"]
  end
  check.call("a duration-only save keeps the script, dialogue and frame prompts") do
    saved = service.save_shot(
      "dramaID" => drama["id"], "episodeID" => episode["id"], "shotID" => shot["id"], "duration" => 6
    ).dig("drama", "episodes", 0, "shots", 0)
    raise "title wiped" unless saved["title"] == "手机亮起"
    raise "summary wiped" unless saved["summary"] == "屏幕显示未来短信"
    raise "dialogue wiped" unless saved["dialogue"].length == 1
    raise "start prompt wiped" unless saved["startPrompt"] == "暗室中的手机"
    raise "duration not applied" unless saved["duration"] == 6
  end
  check.call("the first saved shot moves the drama from planning into production") do
    raise "status did not advance" unless service.get("id" => drama["id"]).dig("drama", "status") == "production"
  end
  check.call("a stale shot ID is reported instead of stacking empty shots") do
    response = service.save_shot(
      "dramaID" => drama["id"], "episodeID" => episode["id"],
      "shotID" => "00000000-0000-0000-0000-000000000000", "title" => "幽灵分镜"
    )
    raise "stale ID accepted" if response["ok"]
    raise "wrong code #{response.dig('error', 'code')}" unless response.dig("error", "code") == "shot_not_found"
  end

  recorded = service.record_image(
    "dramaID" => drama["id"], "episodeID" => episode["id"], "shotID" => shot["id"],
    "kind" => "start", "mediaURL" => "willdeep-plugin://bundle/__media__/a.png",
    "filePath" => File.join(media_root, "a.png"), "prompt" => shot["startPrompt"], "model" => "gpt-image-2"
  )
  check.call("frame candidate records host media URL without credentials") do
    candidate = recorded.dig("drama", "episodes", 0, "shots", 0, "startCandidates", 0)
    raise "candidate missing" unless candidate && candidate["model"] == "gpt-image-2"
    raise "credential leaked" if File.read(path, encoding: "UTF-8").match?(/api[_-]?key|bearer/i)
  end
  check.call("image paths outside the generated-images directory are refused") do
    [outside, File.join(media_root, "..", "outside.png"), ""].each do |candidate_path|
      response = service.record_image(
        "dramaID" => drama["id"], "episodeID" => episode["id"], "shotID" => shot["id"],
        "kind" => "start", "mediaURL" => "x", "filePath" => candidate_path, "model" => "gpt-image-2"
      )
      raise "escaped media root: #{candidate_path}" if response["ok"]
      raise "wrong code" unless response.dig("error", "code") == "invalid_media_path"
    end
  end
  check.call("a symlink inside the media root does not become a second door") do
    link = File.join(media_root, "link.png")
    File.symlink(outside, link)
    response = service.record_image(
      "dramaID" => drama["id"], "episodeID" => episode["id"], "shotID" => shot["id"],
      "kind" => "start", "mediaURL" => "x", "filePath" => link, "model" => "gpt-image-2"
    )
    raise "symlink accepted" if response["ok"]
  end
  check.call("a missing candidate is reported as candidate_not_found, not not_found") do
    response = service.select_image(
      "dramaID" => drama["id"], "episodeID" => episode["id"], "shotID" => shot["id"],
      "kind" => "start", "candidateID" => "00000000-0000-0000-0000-000000000000"
    )
    raise "wrong code #{response.dig('error', 'code')}" unless response.dig("error", "code") == "candidate_not_found"
  end

  # ---- 共创草稿：手改与 AI 结果都写这里，正式内容一步不动 ----

  # 这部剧前面的用例已经塞过角色和分镜，固定索引会拿错对象，一律按 ID 定位。
  character_id = nil
  fetch_character = lambda do |response|
    response.dig("drama", "characters").find { |entry| entry["id"] == character_id }
  end
  check.call("a draft never touches committed content") do
    known = service.get("id" => drama["id"]).dig("drama", "characters").map { |entry| entry["id"] }
    saved = service.save_character("dramaID" => drama["id"], "name" => "林晚")
    character_id = (saved.dig("drama", "characters").map { |entry| entry["id"] } - known).first
    response = service.save_draft(
      "dramaID" => drama["id"], "scope" => "character", "characterID" => character_id,
      "draft" => { "name" => "林晚·改", "description" => "夜班护士" }
    )
    character = fetch_character.call(response)
    raise "committed name changed" unless character["name"] == "林晚"
    raise "draft missing" unless character.dig("draft", "description") == "夜班护士"
    raise "draftRev did not advance" unless character["draftRev"] == 1
    raise "rev moved on a draft write" unless character["rev"] == 0
  end

  check.call("a second draft write layers onto the first instead of replacing it") do
    response = service.save_draft(
      "dramaID" => drama["id"], "scope" => "character", "characterID" => character_id,
      "draft" => { "visualPrompt" => "冷色调" }, "expectedDraftRev" => 1
    )
    draft = fetch_character.call(response)["draft"]
    raise "earlier field lost" unless draft["description"] == "夜班护士"
    raise "new field missing" unless draft["visualPrompt"] == "冷色调"
  end

  check.call("fields outside the whitelist are dropped from a draft") do
    response = service.save_draft(
      "dramaID" => drama["id"], "scope" => "character", "characterID" => character_id,
      "draft" => { "id" => "被顶替的 id", "candidates" => [{ "id" => "x" }], "identityVersion" => 99 }
    )
    character = fetch_character.call(response)
    raise "id leaked into the draft" if character["draft"].key?("id")
    raise "candidates leaked into the draft" if character["draft"].key?("candidates")
    raise "committed id was rewritten" unless character["id"] == character_id
  end

  check.call("a stale draft revision is refused instead of overwriting a manual edit") do
    response = service.save_draft(
      "dramaID" => drama["id"], "scope" => "character", "characterID" => character_id,
      "draft" => { "description" => "迟到的模型结果" }, "expectedDraftRev" => 1
    )
    raise "stale write accepted" if response["ok"]
    raise "wrong code" unless response.dig("error", "code") == "revision_conflict"
    current = fetch_character.call(service.get("id" => drama["id"]))
    raise "draft was overwritten anyway" unless current.dig("draft", "description") == "夜班护士"
  end

  check.call("adopting a draft merges it, clears it, and bumps rev") do
    current = fetch_character.call(service.get("id" => drama["id"]))
    response = service.commit_draft(
      "dramaID" => drama["id"], "scope" => "character", "characterID" => character_id,
      "expectedRev" => current["rev"]
    )
    character = fetch_character.call(response)
    raise "draft not applied" unless character["name"] == "林晚·改" && character["description"] == "夜班护士"
    raise "draft not cleared" unless character["draft"].nil?
    raise "rev did not advance" unless character["rev"] == 1
  end

  check.call("confirming twice reports a conflict instead of writing again") do
    response = service.commit_draft(
      "dramaID" => drama["id"], "scope" => "character", "characterID" => character_id,
      "expectedRev" => 0
    )
    raise "double commit accepted" if response["ok"]
    raise "wrong code" unless response.dig("error", "code") == "revision_conflict"
    raise "actual rev not reported" unless response.dig("error", "actual") == 1
  end

  check.call("committing an empty draft fails without disturbing content") do
    response = service.commit_draft(
      "dramaID" => drama["id"], "scope" => "character", "characterID" => character_id
    )
    raise "empty commit accepted" if response["ok"]
    raise "wrong code" unless response.dig("error", "code") == "empty_draft"
    raise "content changed" unless fetch_character.call(service.get("id" => drama["id"]))["name"] == "林晚·改"
  end

  check.call("discarding a draft leaves committed content alone") do
    service.save_draft(
      "dramaID" => drama["id"], "scope" => "character", "characterID" => character_id,
      "draft" => { "name" => "要丢掉的名字" }
    )
    response = service.discard_draft(
      "dramaID" => drama["id"], "scope" => "character", "characterID" => character_id
    )
    character = fetch_character.call(response)
    raise "draft not discarded" unless character["draft"].nil?
    raise "committed name changed" unless character["name"] == "林晚·改"
  end

  check.call("drafts work on the drama, episode, and shot scopes too") do
    episode_id = drama["episodes"].first["id"]
    shots_of = lambda do |response|
      response.dig("drama", "episodes").find { |entry| entry["id"] == episode_id }["shots"]
    end
    known_shots = shots_of.call(service.get("id" => drama["id"])).map { |entry| entry["id"] }
    saved_shot = service.save_shot("dramaID" => drama["id"], "episodeID" => episode_id, "title" => "开场")
    shot_id = (shots_of.call(saved_shot).map { |entry| entry["id"] } - known_shots).first

    service.save_draft("dramaID" => drama["id"], "scope" => "drama", "draft" => { "logline" => "改过的一句话" })
    service.save_draft("dramaID" => drama["id"], "scope" => "episode", "episodeID" => episode_id,
                       "draft" => { "summary" => "本集梗概" })
    service.save_draft("dramaID" => drama["id"], "scope" => "shot", "episodeID" => episode_id, "shotID" => shot_id,
                       "draft" => { "dialogue" => [{ "speaker" => "林晚", "text" => "你终于来了" }], "duration" => 6 })

    latest = service.get("id" => drama["id"])["drama"]
    episode = latest["episodes"].find { |entry| entry["id"] == episode_id }
    shot = episode["shots"].find { |entry| entry["id"] == shot_id }
    raise "drama draft missing" unless latest.dig("draft", "logline") == "改过的一句话"
    raise "drama committed logline changed" unless latest["logline"] == "未来短信改变今天"
    raise "episode draft missing" unless episode.dig("draft", "summary") == "本集梗概"
    shot_draft = shot["draft"]
    raise "shot dialogue draft missing" unless shot_draft.dig("dialogue", 0, "text") == "你终于来了"
    raise "shot duration draft missing" unless shot_draft["duration"] == 6

    service.commit_draft("dramaID" => drama["id"], "scope" => "shot", "episodeID" => episode_id, "shotID" => shot_id)
    committed = service.get("id" => drama["id"])["drama"]["episodes"]
                       .find { |entry| entry["id"] == episode_id }["shots"]
                       .find { |entry| entry["id"] == shot_id }
    raise "dialogue not adopted" unless committed.dig("dialogue", 0, "text") == "你终于来了"
    raise "duration not adopted" unless committed["duration"] == 6
  end

  check.call("an unknown draft scope is rejected") do
    response = service.save_draft("dramaID" => drama["id"], "scope" => "episodes", "draft" => {})
    raise "unknown scope accepted" if response["ok"]
    raise "wrong code" unless response.dig("error", "code") == "invalid_scope"
  end

  check.call("a direct save refuses a stale expectedRev") do
    response = service.save_character(
      "dramaID" => drama["id"], "characterID" => character_id, "name" => "越过版本检查", "expectedRev" => 0
    )
    raise "stale direct save accepted" if response["ok"]
    raise "wrong code" unless response.dig("error", "code") == "revision_conflict"
    raise "name changed anyway" unless fetch_character.call(service.get("id" => drama["id"]))["name"] == "林晚·改"
  end

  check.call("legacy objects without a rev are treated as rev 0") do
    legacy = JSON.parse(File.read(path, encoding: "UTF-8"))
    target = legacy["dramas"].find { |entry| entry["id"] == drama["id"] }["characters"]
                             .find { |entry| entry["id"] == character_id }
    %w[rev draftRev draft].each { |key| target.delete(key) }
    File.write(path, JSON.pretty_generate(legacy), encoding: "UTF-8")
    response = service.save_draft(
      "dramaID" => drama["id"], "scope" => "character", "characterID" => character_id,
      "draft" => { "description" => "旧档也能共创" }, "expectedDraftRev" => 0
    )
    raise "legacy object refused" unless response["ok"]
    raise "draft missing" unless fetch_character.call(response).dig("draft", "description") == "旧档也能共创"
  end

  # ---- 共创聊天：一部剧一个文件 ----

  chat = ChatStore.new(File.join(directory, "chats"))

  check.call("chat is stored per drama and per stage") do
    chat.append(drama["id"], "characters", "role" => "user", "content" => "把她写得更冷一点",
                "objectID" => character_id, "draftRev" => 3)
    chat.append(drama["id"], "planning", "role" => "assistant", "content" => "策划那边的话")
    stage = chat.list(drama["id"], "characters")
    raise "message not stored" unless stage.length == 1
    raise "object scope lost" unless stage[0]["objectID"] == character_id
    raise "draftRev lost" unless stage[0]["draftRev"] == 3
    raise "stages leaked into each other" unless chat.list(drama["id"], "planning").length == 1
    raise "another drama saw these messages" unless chat.list("some-other-drama", "characters").empty?
  end

  check.call("chat files are owner-only and named after the drama") do
    file = chat.path_for(drama["id"])
    raise "chat file missing" unless File.exist?(file)
    raise "unsafe mode" unless (File.stat(file).mode & 0o777) == 0o600
  end

  check.call("a drama ID cannot escape the chat directory") do
    chat.append("../../escape", "planning", "role" => "user", "content" => "试图越界")
    raise "path escaped" unless File.expand_path(chat.path_for("../../escape")).start_with?(File.join(directory, "chats"))
  end

  check.call("an unknown chat stage is refused") do
    begin
      chat.append(drama["id"], "montage", "role" => "user", "content" => "没有这个阶段")
      raise "unknown stage accepted"
    rescue ArgumentError
      # 预期
    end
  end

  check.call("an unreadable chat file refuses to write instead of wiping it") do
    file = chat.path_for(drama["id"])
    File.write(file, '{"version":1,"stages":{"characters":[', encoding: "UTF-8")
    begin
      chat.append(drama["id"], "characters", "role" => "user", "content" => "会不会覆盖")
      raise "corrupt chat silently accepted a write"
    rescue ChatStore::Unavailable
      # 预期：和短剧存档同样的规矩，读不出来就停手。
    end
    raise "corrupt chat was rewritten" unless File.read(file, encoding: "UTF-8") == '{"version":1,"stages":{"characters":['
  end

  check.call("store file is owner-only") do
    raise "unsafe mode" unless (File.stat(path).mode & 0o777) == 0o600
  end
  check.call("an unreadable store refuses to write instead of wiping the archive") do
    before = File.read(path, encoding: "UTF-8")
    File.write(path, '{"version":1,"dramas":[{"id":"a","ti', encoding: "UTF-8")
    begin
      service.confirm_plan("plan" => { "title" => "会不会覆盖旧档" })
      raise "corrupt store silently accepted a write"
    rescue DramaStore::Unavailable
      # 预期：读不出来就停手，让上层把原因如实报出去。
    end
    raise "corrupt file was rewritten" unless File.read(path, encoding: "UTF-8") == '{"version":1,"dramas":[{"id":"a","ti'
    File.write(path, before, encoding: "UTF-8")
    raise "archive lost" unless service.list["dramas"].length == 2
  end
end

failed = results.count { |result| result[:status] == "failed" }
puts JSON.pretty_generate(summary: { total: results.length, passed: results.length - failed, failed: failed }, tests: results)
exit(failed.zero? ? 0 : 1)
