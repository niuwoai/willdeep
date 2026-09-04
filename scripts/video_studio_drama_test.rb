#!/usr/bin/env ruby
# frozen_string_literal: true

# 这个脚本必须能在 macOS 自带的 /usr/bin/ruby（2.6）下跑通：mcp.json 把插件的
# 解释器钉死成它，用 homebrew 的 3.x 跑绿了不代表用户机器上能用。
require "json"
require "tmpdir"
require_relative "../PluginExamples/video-studio/server/lib/drama_store"
require_relative "../PluginExamples/video-studio/server/lib/drama_service"

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
