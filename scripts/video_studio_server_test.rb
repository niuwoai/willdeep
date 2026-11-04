#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"
require "tmpdir"
require "webrick"
require_relative "../PluginExamples/video-studio/server/lib/video_store"

ROOT = File.expand_path("..", __dir__)
SERVER = File.join(ROOT, "PluginExamples", "video-studio", "server", "video_studio.rb")
results = []

# Usage: ruby scripts/video_studio_server_test.rb [report.md] [report.json]

def check(condition, message, results)
  results << { "ok" => !!condition, "message" => message }
end

def with_mcp(environment)
  Open3.popen3(environment, "/usr/bin/ruby", SERVER) do |stdin, stdout, stderr, _wait|
    stdin.sync = true
    stdout.set_encoding(Encoding::UTF_8)
    next_id = 0
    call = lambda do |method, params = {}|
      next_id += 1
      stdin.puts JSON.generate(jsonrpc: "2.0", id: next_id, method: method, params: params)
      loop do
        line = stdout.gets
        raise "MCP server exited: #{stderr.read}" if line.nil?
        message = JSON.parse(line) rescue nil
        return message if message && message["id"] == next_id
      end
    end
    tool = lambda do |name, arguments = {}|
      response = call.call("tools/call", { "name" => name, "arguments" => arguments })
      JSON.parse(response.dig("result", "content", 0, "text"))
    end
    yield call, tool
  ensure
    stdin.close unless stdin.closed?
  end
end

def start_mock_gateway(requests)
  poll_counts = Hash.new(0)
  sequence = 0
  server = WEBrick::HTTPServer.new(
    Port: 0,
    BindAddress: "127.0.0.1",
    Logger: WEBrick::Log.new(File::NULL),
    AccessLog: []
  )
  port = server.listeners.first.addr[1]
  server.mount_proc("/v1/videos") do |request, response|
    if request.request_method == "POST"
      sequence += 1
      body = request.body.to_s
      requests << {
        "authorization" => request["Authorization"],
        "contentType" => request["Content-Type"],
        "body" => body
      }
      if body.include?("invalid response") || body.include?("missing identifier")
        response.status = 202
        response["Content-Type"] = "application/json"
        response.body = body.include?("invalid response") ? "not-json" : JSON.generate(status: "queued")
        next
      end
      id = if body.include?("rate limit")
             "task_rate"
           elsif body.include?("force failure")
             "task_failure"
           else
             format("task_%03d", sequence)
           end
      response.status = 202
      response["Content-Type"] = "application/json"
      response.body = JSON.generate(id: id, object: "video", status: "queued", model: "MiniMax-H3", progress: 0, error: nil)
      next
    end

    id = request.path.split("/").last
    if id == "task_rate"
      response.status = 429
      response["Retry-After"] = "7"
      response["Content-Type"] = "application/json"
      response.body = JSON.generate(error: { code: "rate_limit", message: "slow down" })
      next
    end
    if id == "task_failure"
      response.status = 200
      response["Content-Type"] = "application/json"
      response.body = JSON.generate(id: id, status: "failed", progress: 0, error: { code: "backend_request_rejected", message: "forced" })
      next
    end
    poll_counts[id] += 1
    completed = poll_counts[id] >= 2
    response.status = 200
    response["Content-Type"] = "application/json"
    response.body = JSON.generate(
      id: id,
      object: "video",
      status: completed ? "completed" : "in_progress",
      model: "MiniMax-H3",
      progress: completed ? 100 : 0,
      url: completed ? "http://127.0.0.1:#{port}/outputs/#{id}.mp4" : nil,
      error: nil
    )
  end
  server.mount_proc("/outputs") do |_request, response|
    response.status = 200
    response["Content-Type"] = "video/mp4"
    response.body = "\x00\x00\x00\x18ftypmp42mock-video".b
  end
  thread = Thread.new { server.start }
  sleep(0.02) until server.status == :Running
  [server, thread]
end

def write_reports(results, markdown_path, json_path)
  ok = results.all? { |result| result["ok"] }
  report = { "ok" => ok, "checks" => results, "passed" => results.count { |item| item["ok"] }, "total" => results.length }
  File.write(json_path, "#{JSON.pretty_generate(report)}\n") if json_path
  if markdown_path
    lines = ["# Video Studio Server Test", "", "- Status: **#{ok ? 'PASS' : 'FAIL'}**", "- Checks: #{report['passed']}/#{report['total']}", ""]
    results.each { |result| lines << "- #{result['ok'] ? 'PASS' : 'FAIL'}: #{result['message']}" }
    File.write(markdown_path, "#{lines.join("\n")}\n")
  end
  puts(ok ? "Video Studio server test: PASS (#{report['passed']}/#{report['total']})" : "Video Studio server test: FAIL")
  results.reject { |result| result["ok"] }.each { |result| warn "FAIL: #{result['message']}" }
  exit(ok ? 0 : 1)
end

Dir.mktmpdir do |directory|
  requests = []
  gateway, gateway_thread = start_mock_gateway(requests)
  store = File.join(directory, "data", "jobs.json")
  output = File.join(directory, "outputs")
  reference = File.join(directory, "first-frame.png")
  File.binwrite(reference, "\x89PNG\r\n\x1a\nmock".b)
  environment = {
    "VIDEO_STUDIO_STORE" => store,
    "VIDEO_STUDIO_API_BASE" => "http://127.0.0.1:#{gateway.listeners.first.addr[1]}",
    "VIDEO_STUDIO_API_KEY" => "test-only-token",
    "VIDEO_STUDIO_OUTPUT_DIRECTORY" => output,
    "VIDEO_STUDIO_PICK_REFERENCE" => reference
  }

  begin
    with_mcp(environment) do |call, tool|
      initialized = call.call("initialize")
      check(initialized.dig("result", "serverInfo", "name") == "video-studio", "MCP initialize advertises video-studio.", results)
      names = call.call("tools/list").dig("result", "tools").map { |entry| entry["name"] }
      check(names.include?("video.generate") && names.include?("video.refresh_active"), "MCP exposes generation and polling tools.", results)

      status = tool.call("video.status")
      check(status["apiConfigured"] == true && !JSON.generate(status).include?("test-only-token"), "Safe status reports readiness without exposing the API key.", results)

      settings = tool.call("video.settings", { "width" => 850, "height" => 500, "assistantProviderID" => "ollama", "assistantModel" => "gemma4" })
      check(settings.dig("settings", "width") == 832 && settings.dig("settings", "height") == 480, "Settings normalize canvas dimensions to multiples of 32.", results)
      check(settings.dig("settings", "assistantProviderID") == "ollama", "Creative assistant provider and model persist.", results)

      draft = tool.call("video.create_draft", { "text" => "海边女孩，镜头缓慢推进", "source" => "chat.selection" })
      check(draft["ok"] && draft.dig("job", "state") == "draft", "Chat selection creates an editable draft.", results)

      generated = tool.call("video.generate", { "draftID" => draft.dig("job", "id"), "prompt" => "海边女孩，镜头缓慢推进" })
      text_job = generated["job"]
      check(generated["ok"] && text_job["remoteID"] == "task_001", "Text-to-video submission persists the returned remote task id.", results)
      first_request = requests.first || {}
      check(first_request["authorization"] == "Bearer test-only-token", "Submission uses Bearer authentication.", results)
      check(first_request["contentType"].to_s.start_with?("multipart/form-data; boundary="), "Submission is multipart/form-data rather than JSON.", results)
      check(first_request["body"].include?("t2va") && !first_request["body"].include?("input_reference"), "Text-to-video selects t2va without a reference file.", results)
      check(first_request["body"].include?("name=\"fps\"") && first_request["body"].include?("\r\n24\r\n"), "Submission pins FPS to 24.", results)

      first_poll = tool.call("video.refresh", { "id" => text_job["id"] })
      check(first_poll.dig("job", "state") == "in_progress", "First poll maps in_progress without pretending completion.", results)
      completed = tool.call("video.refresh", { "id" => text_job["id"] })
      check(completed.dig("job", "state") == "completed", "Second poll reaches completed.", results)
      downloaded = completed.dig("job", "outputPath")
      check(downloaded && File.file?(downloaded), "Completed task downloads an MP4 locally.", results)
      check(downloaded && File.binread(downloaded).include?("ftypmp42"), "Downloaded artifact contains the mock MP4 signature.", results)

      picked = tool.call("video.pick_reference")
      check(picked["path"] == reference, "Reference-image picker returns a validated local path.", results)
      image_job = tool.call("video.generate", { "prompt" => "让人物回头", "referenceImagePath" => reference })
      check(image_job["ok"] && image_job.dig("job", "mode") == "image_to_video", "Reference path switches the job to image-to-video.", results)
      second_request = requests[1] || {}
      check(second_request["body"].include?("fl2va") && second_request["body"].include?("name=\"input_reference\""), "Image-to-video sends fl2va and multipart input_reference.", results)

      tool.call("video.settings", { "autoDownload" => false })
      tool.call("video.refresh", { "id" => image_job.dig("job", "id") })
      ready = tool.call("video.refresh", { "id" => image_job.dig("job", "id") })
      check(ready.dig("job", "state") == "completed" && ready.dig("job", "outputPath").nil?, "Disabling auto-download preserves completed tasks without a local file.", results)
      submission_count = requests.length
      manual = tool.call("video.download", { "id" => image_job.dig("job", "id") })
      check(manual["ok"] && File.file?(manual.dig("job", "outputPath")), "Manual download works when auto-download is disabled.", results)
      check(requests.length == submission_count, "Manual download never submits another paid generation.", results)

      rate_job = tool.call("video.generate", { "prompt" => "rate limit" })["job"]
      limited = tool.call("video.refresh", { "id" => rate_job["id"] })
      check(!limited["ok"] && limited.dig("job", "state") == "queued", "HTTP 429 keeps the job active instead of marking generation failed.", results)
      check(limited.dig("error", "retryAfter") == "7", "HTTP 429 preserves Retry-After for the caller.", results)
      check(Time.parse(limited.dig("job", "nextPollAt")) > Time.now, "HTTP 429 schedules a future poll rather than hammering the provider.", results)

      failed_job = tool.call("video.generate", { "prompt" => "force failure" })["job"]
      failed = tool.call("video.refresh", { "id" => failed_job["id"] })
      check(failed.dig("job", "state") == "failed", "Provider terminal failure maps to failed.", results)
      retried = tool.call("video.retry", { "id" => failed_job["id"] })
      check(retried.dig("job", "retryOf") == failed_job["id"], "Explicit retry creates a linked new attempt and preserves the original.", results)

      invalid = tool.call("video.generate", { "prompt" => "bad duration", "duration" => 3 })
      check(!invalid["ok"] && invalid.dig("error", "code") == "invalid_duration", "Invalid duration is rejected before submission.", results)

      ["invalid response", "missing identifier"].each do |prompt|
        before = requests.length
        uncertain = tool.call("video.generate", { "prompt" => prompt })
        check(!uncertain["ok"] && uncertain.dig("job", "ambiguousSubmission"), "Accepted #{prompt} is marked ambiguous to prevent accidental duplicate billing.", results)
        tool.call("video.refresh_active")
        check(requests.length == before + 1, "Polling never resubmits an ambiguous #{prompt} task.", results)
      end

      listed = tool.call("video.list")
      check(listed["jobs"].any? { |job| job["id"] == text_job["id"] && job["outputPath"] }, "Downloaded task survives a fresh list read.", results)
      removed = tool.call("video.remove", { "id" => text_job["id"] })
      check(removed["ok"] && File.file?(downloaded), "Removing a record does not delete its downloaded artifact.", results)
    end

    stored_text = File.read(store)
    check(!stored_text.include?("test-only-token"), "Persistent store never contains the API key.", results)
    check(Dir.glob("#{store}.*.tmp").empty?, "Atomic store writes leave no temporary files.", results)
    check((File.stat(store).mode & 0o777) == 0o600, "Task records and signed output URLs are private to the local user.", results)

    interrupted = VideoStore.new(store).add_job("state" => "submitting", "request" => { "prompt" => "interrupted" })
    before_restart = requests.length
    with_mcp(environment) do |_call, tool|
      recovered = tool.call("video.list")["jobs"].find { |entry| entry["id"] == interrupted["id"] }
      check(recovered["state"] == "failed" && recovered["ambiguousSubmission"], "Restart recovers interrupted submissions as ambiguous, not permanently active.", results)
      check(requests.length == before_restart, "Restart does not automatically repeat a paid submission.", results)
    end

    missing_key_environment = environment.merge(
      "VIDEO_STUDIO_STORE" => File.join(directory, "missing-key.json"),
      "VIDEO_STUDIO_API_KEY" => ""
    )
    with_mcp(missing_key_environment) do |_call, tool|
      check(tool.call("video.status")["apiConfigured"] == false, "Missing API key is reported without crashing the plugin.", results)
      rejected = tool.call("video.generate", { "prompt" => "must not submit" })
      check(!rejected["ok"] && rejected.dig("error", "message").include?("not configured"), "Generation is blocked when no API key is configured.", results)
    end

    # 短剧共创的工具此前一条都没走过 MCP 层：schema 写错、分发漏一行，
    # 存储层的测试全绿也照样在页面上炸。
    drama_environment = environment.merge(
      "VIDEO_STUDIO_DRAMA_STORE" => File.join(directory, "dramas.json"),
      "VIDEO_STUDIO_CHAT_STORE" => File.join(directory, "chats"),
      "VIDEO_STUDIO_MEDIA_ROOT" => File.join(directory, "generated-images")
    )
    with_mcp(drama_environment) do |call, tool|
      listed = call.call("tools/list").dig("result", "tools").map { |entry| entry["name"] }
      %w[drama.save_draft drama.commit_draft drama.discard_draft chat.append chat.list chat.clear].each do |name|
        check(listed.include?(name), "#{name} is advertised by tools/list.", results)
      end

      created = tool.call("drama.confirm_plan", { "plan" => { "title" => "端到端短剧", "episodeCount" => 1 } })
      drama_id = created.dig("drama", "id")
      check(created.dig("drama", "rev") == 0, "A new drama starts at rev 0.", results)

      saved = tool.call("drama.save_character", { "dramaID" => drama_id, "name" => "林晚" })
      character_id = saved.dig("drama", "characters", 0, "id")

      drafted = tool.call("drama.save_draft", {
        "dramaID" => drama_id, "scope" => "character", "characterID" => character_id,
        "draft" => { "description" => "夜班护士" }
      })
      character = drafted.dig("drama", "characters", 0)
      check(character.dig("draft", "description") == "夜班护士", "save_draft stores a working draft over MCP.", results)
      check(character["name"] == "林晚" && character["rev"] == 0, "save_draft leaves committed content and rev alone.", results)

      stale = tool.call("drama.save_draft", {
        "dramaID" => drama_id, "scope" => "character", "characterID" => character_id,
        "draft" => { "description" => "迟到的结果" }, "expectedDraftRev" => 0
      })
      check(stale.dig("error", "code") == "revision_conflict", "A stale draft revision is refused over MCP.", results)

      committed = tool.call("drama.commit_draft", {
        "dramaID" => drama_id, "scope" => "character", "characterID" => character_id, "expectedRev" => 0
      })
      adopted = committed.dig("drama", "characters", 0)
      check(adopted["description"] == "夜班护士" && adopted["draft"].nil?, "commit_draft adopts and clears the draft.", results)
      check(adopted["rev"] == 1, "commit_draft bumps rev.", results)

      repeated = tool.call("drama.commit_draft", {
        "dramaID" => drama_id, "scope" => "character", "characterID" => character_id, "expectedRev" => 0
      })
      check(repeated.dig("error", "code") == "revision_conflict", "Confirming twice reports a conflict instead of writing again.", results)

      tool.call("chat.append", {
        "dramaID" => drama_id, "stage" => "characters",
        "message" => { "role" => "user", "content" => "再冷一点", "objectID" => character_id, "draftRev" => 1 }
      })
      messages = tool.call("chat.list", { "dramaID" => drama_id, "stage" => "characters" })["messages"]
      check(messages.length == 1 && messages[0]["objectID"] == character_id, "Chat round-trips through MCP with its object scope.", results)
      check(tool.call("chat.list", { "dramaID" => drama_id, "stage" => "planning" })["messages"].empty?, "Chat stages stay separate.", results)

      bad_stage = tool.call("chat.append", { "dramaID" => drama_id, "stage" => "montage", "message" => { "content" => "x" } })
      check(bad_stage.dig("error", "code") == "invalid_stage", "An unknown chat stage is refused over MCP.", results)

      tool.call("chat.clear", { "dramaID" => drama_id, "stage" => "characters" })
      check(tool.call("chat.list", { "dramaID" => drama_id, "stage" => "characters" })["messages"].empty?, "chat.clear empties one stage.", results)

      chat_file = File.join(directory, "chats", "#{drama_id}.json")
      check(File.exist?(chat_file), "Chat is stored in a per-drama file, not in dramas.json.", results)
      check(!File.read(File.join(directory, "dramas.json"), encoding: "UTF-8").include?("再冷一点"), "Chat text never lands in the drama archive.", results)
    end

  ensure
    gateway.shutdown
    gateway_thread.join
  end
end

markdown_path = ARGV[0] && File.expand_path(ARGV[0])
json_path = ARGV[1] && File.expand_path(ARGV[1])
write_reports(results, markdown_path, json_path)
