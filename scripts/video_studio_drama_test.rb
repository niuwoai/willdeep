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

  # ---- 策划带出的角色骨架 ----

  check.call("a confirmed plan creates the named cast as skeletons") do
    response = service.confirm_plan("plan" => {
      "title" => "月港追光", "episodeCount" => 1,
      "characters" => [
        { "name" => "沈青", "role" => "胶片修复师" },
        { "name" => "陆铭", "role" => "出资的旧同学" }
      ]
    })
    cast = response.dig("drama", "characters")
    raise "cast not created" unless cast.length == 2
    raise "name lost" unless cast.map { |entry| entry["name"] } == %w[沈青 陆铭]
    raise "role not stored as description" unless cast[0]["description"] == "胶片修复师"
    # 骨架就是骨架：视觉提示词留空，等角色阶段单独出第一稿。
    raise "visualPrompt should stay empty" unless cast[0]["visualPrompt"] == ""
    raise "revisions missing" unless cast[0]["rev"] == 0 && cast[0]["draftRev"] == 0
    raise "draft should be nil" unless cast[0]["draft"].nil?
    raise "id missing" if cast.any? { |entry| entry["id"].to_s.empty? }
  end

  check.call("a duplicate or nameless cast entry is dropped, not stacked") do
    response = service.confirm_plan("plan" => {
      "title" => "重名测试", "episodeCount" => 1,
      "characters" => [
        { "name" => "林晚", "role" => "护士" },
        { "name" => "林晚", "role" => "又写了一遍" },
        { "name" => "  ", "role" => "没名字" },
        { "role" => "只有定位" },
        "不是对象"
      ]
    })
    cast = response.dig("drama", "characters")
    raise "expected one usable character, got #{cast.length}" unless cast.length == 1
    raise "wrong survivor" unless cast[0]["name"] == "林晚" && cast[0]["description"] == "护士"
  end

  check.call("a plan without a cast still confirms") do
    response = service.confirm_plan("plan" => { "title" => "没有角色表", "episodeCount" => 1 })
    raise "confirm failed" unless response["ok"]
    raise "characters should be an empty array" unless response.dig("drama", "characters") == []
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

  # ---- 批量写多集草稿 ----

  check.call("a batch writes many episode drafts in one shot, matched by order") do
    created = service.confirm_plan("plan" => { "title" => "批量测试", "episodeCount" => 5 })
    batch_drama = created["drama"]
    response = service.save_episode_drafts(
      "dramaID" => batch_drama["id"],
      "episodes" => [
        { "order" => 1, "summary" => "第一集梗概" },
        { "order" => 3, "summary" => "第三集梗概", "title" => "第三集标题" },
        { "order" => 5, "summary" => "第五集梗概" }
      ]
    )
    raise "batch failed" unless response["ok"]
    raise "applied wrong set: #{response['applied']}" unless response["applied"] == [1, 3, 5]
    episodes = response.dig("drama", "episodes")
    raise "order 1 draft missing" unless episodes[0].dig("draft", "summary") == "第一集梗概"
    raise "order 3 title missing" unless episodes[2].dig("draft", "title") == "第三集标题"
    raise "order 5 draft missing" unless episodes[4].dig("draft", "summary") == "第五集梗概"
    # 没在这一批里的集不能被碰。
    raise "untouched episode was modified" unless episodes[1]["draft"].nil?
    raise "committed content changed" unless episodes[0]["summary"] == ""
    raise "draftRev did not advance" unless episodes[0]["draftRev"] == 1
  end

  check.call("an unknown order is reported, not silently dropped") do
    created = service.confirm_plan("plan" => { "title" => "集号对齐", "episodeCount" => 2 })
    response = service.save_episode_drafts(
      "dramaID" => created.dig("drama", "id"),
      "episodes" => [
        { "order" => 1, "summary" => "有这一集" },
        { "order" => 99, "summary" => "没有这一集" },
        { "order" => 2 },
        "不是对象"
      ]
    )
    raise "batch failed" unless response["ok"]
    raise "applied wrong set" unless response["applied"] == [1]
    reasons = response["skipped"].map { |entry| entry["reason"] }
    # 静默丢会让用户以为整批都写好了。
    raise "missing episode not reported" unless reasons.include?("episode_not_found")
    raise "fieldless entry not reported" unless reasons.include?("no_writable_field")
    raise "non-object not reported" unless reasons.include?("not_an_object")
  end

  check.call("a batch layers onto an existing draft instead of replacing it") do
    created = service.confirm_plan("plan" => { "title" => "叠加测试", "episodeCount" => 1 })
    id = created.dig("drama", "id")
    service.save_draft(
      "dramaID" => id, "scope" => "episode",
      "episodeID" => created.dig("drama", "episodes", 0, "id"),
      "draft" => { "title" => "先写的标题" }
    )
    response = service.save_episode_drafts(
      "dramaID" => id, "episodes" => [{ "order" => 1, "summary" => "后写的梗概" }]
    )
    draft = response.dig("drama", "episodes", 0, "draft")
    raise "earlier field lost" unless draft["title"] == "先写的标题"
    raise "new field missing" unless draft["summary"] == "后写的梗概"
  end

  check.call("a batch refuses a bad payload without touching anything") do
    created = service.confirm_plan("plan" => { "title" => "坏载荷", "episodeCount" => 1 })
    id = created.dig("drama", "id")
    %w[not_an_array].each do
      response = service.save_episode_drafts("dramaID" => id, "episodes" => "第一集")
      raise "string payload accepted" if response["ok"]
      raise "wrong code" unless response.dig("error", "code") == "invalid_episodes"
    end
    empty = service.save_episode_drafts("dramaID" => id, "episodes" => [])
    raise "empty payload accepted" if empty["ok"]
    raise "wrong code" unless empty.dig("error", "code") == "empty_episodes"
    raise "draft should still be nil" unless service.get("id" => id).dig("drama", "episodes", 0, "draft").nil?
  end

  check.call("a batch is capped so one call cannot rewrite an unbounded number of episodes") do
    created = service.confirm_plan("plan" => { "title" => "上限", "episodeCount" => 100 })
    entries = (1..60).map { |order| { "order" => order, "summary" => "第 #{order} 集" } }
    response = service.save_episode_drafts("dramaID" => created.dig("drama", "id"), "episodes" => entries)
    raise "cap not applied" unless response["applied"].length == DramaService::MAX_BATCH_EPISODES
  end

  # ---- 分镜清单与批量写入 ----

  check.call("the shot listing is trimmed for the model and hides candidate arrays") do
    created = service.confirm_plan("plan" => { "title" => "分镜清单", "episodeCount" => 1 })
    id = created.dig("drama", "id")
    episode_id = created.dig("drama", "episodes", 0, "id")
    service.save_shot("dramaID" => id, "episodeID" => episode_id, "order" => 2, "title" => "第二镜")
    service.save_shot("dramaID" => id, "episodeID" => episode_id, "order" => 1, "title" => "第一镜",
                      "dialogue" => [{ "speaker" => "林晚", "text" => "你走" }])
    shot_id = service.get("id" => id).dig("drama", "episodes", 0, "shots").find { |s| s["order"] == 1 }["id"]
    service.record_image(
      "dramaID" => id, "episodeID" => episode_id, "shotID" => shot_id, "kind" => "start",
      "model" => "gpt-image-2", "filePath" => File.join(media_root, "a.png"),
      "mediaURL" => "willdeep-plugin://bundle/__media__/a.png", "prompt" => "首帧"
    )

    listed = service.list_shots("dramaID" => id, "episodeID" => episode_id)
    raise "listing failed" unless listed["ok"]
    shots = listed["shots"]
    raise "expected two shots" unless shots.length == 2
    # 按镜号排序，模型才能按顺序理解这一集。
    raise "not sorted by order" unless shots.map { |shot| shot["order"] } == [1, 2]
    raise "dialogue lost" unless shots[0].dig("dialogue", 0, "text") == "你走"
    # 候选图数组不能进这份清单：一集二十镜就是几十条候选记录，整份丢给模型
    # 既撑爆预算，又让它以为那些是可以改的东西。
    raise "candidates leaked" if shots[0].key?("startCandidates") || shots[0].key?("endCandidates")
    raise "selection leaked" if shots[0].key?("selectedStartID")
    raise "candidate count missing" unless shots[0]["startCandidateCount"] == 1
    raise "revision missing" unless shots[0].key?("rev") && shots[0].key?("draftRev")
  end

  check.call("a shot batch writes many drafts matched by order") do
    created = service.confirm_plan("plan" => { "title" => "批量分镜", "episodeCount" => 1 })
    id = created.dig("drama", "id")
    episode_id = created.dig("drama", "episodes", 0, "id")
    (1..3).each { |order| service.save_shot("dramaID" => id, "episodeID" => episode_id, "order" => order, "title" => "第 #{order} 镜") }

    response = service.save_shot_drafts(
      "dramaID" => id, "episodeID" => episode_id,
      "shots" => [
        { "order" => 1, "summary" => "改第一镜", "duration" => 6 },
        { "order" => 3, "cameraIntent" => "固定", "dialogue" => [{ "speaker" => "周野", "text" => "别走" }] },
        { "order" => 9, "summary" => "没有这一镜" }
      ]
    )
    raise "batch failed" unless response["ok"]
    raise "applied wrong set: #{response['applied']}" unless response["applied"].sort == [1, 3]
    raise "missing shot not reported" unless response["skipped"].any? { |entry| entry["reason"] == "shot_not_found" }

    shots = service.get("id" => id).dig("drama", "episodes", 0, "shots").sort_by { |shot| shot["order"] }
    raise "draft missing" unless shots[0].dig("draft", "summary") == "改第一镜"
    raise "duration draft missing" unless shots[0].dig("draft", "duration") == 6
    raise "dialogue draft missing" unless shots[2].dig("draft", "dialogue", 0, "text") == "别走"
    # 正式内容不能被批量动到，它只写草稿。
    raise "committed title changed" unless shots[0]["title"] == "第 1 镜"
    raise "untouched shot modified" unless shots[1]["draft"].nil?
  end

  check.call("a shot batch refuses a bad payload and reports fieldless entries") do
    created = service.confirm_plan("plan" => { "title" => "分镜坏载荷", "episodeCount" => 1 })
    id = created.dig("drama", "id")
    episode_id = created.dig("drama", "episodes", 0, "id")
    service.save_shot("dramaID" => id, "episodeID" => episode_id, "order" => 1, "title" => "第一镜")

    bad = service.save_shot_drafts("dramaID" => id, "episodeID" => episode_id, "shots" => "第一镜")
    raise "string payload accepted" if bad["ok"]
    raise "wrong code" unless bad.dig("error", "code") == "invalid_shots"

    empty = service.save_shot_drafts("dramaID" => id, "episodeID" => episode_id, "shots" => [])
    raise "empty payload accepted" if empty["ok"]
    raise "wrong code" unless empty.dig("error", "code") == "empty_shots"

    fieldless = service.save_shot_drafts("dramaID" => id, "episodeID" => episode_id, "shots" => [{ "order" => 1 }])
    raise "fieldless entry not reported" unless fieldless["skipped"].any? { |entry| entry["reason"] == "no_writable_field" }
    raise "draft should stay nil" unless service.get("id" => id).dig("drama", "episodes", 0, "shots", 0, "draft").nil?
  end

  check.call("listing a missing episode or drama reports the right code") do
    created = service.confirm_plan("plan" => { "title" => "分镜找不到", "episodeCount" => 1 })
    id = created.dig("drama", "id")
    missing_episode = service.list_shots("dramaID" => id, "episodeID" => "nope")
    raise "wrong code" unless missing_episode.dig("error", "code") == "episode_not_found"
    missing_drama = service.list_shots("dramaID" => "nope", "episodeID" => "nope")
    raise "wrong code" unless missing_drama.dig("error", "code") == "drama_not_found"
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
    # 数量不写死：上面每加一条 confirm_plan 用例都会多一部剧，写死的期望
    # 会让这条无关的守卫跟着红，真正的问题（存档被抹）反而被噪声盖住。
    expected_count = service.list["dramas"].length
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
    raise "archive lost" unless service.list["dramas"].length == expected_count
  end
end

failed = results.count { |result| result[:status] == "failed" }
puts JSON.pretty_generate(summary: { total: results.length, passed: results.length - failed, failed: failed }, tests: results)
exit(failed.zero? ? 0 : 1)
