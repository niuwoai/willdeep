#!/usr/bin/env ruby
# frozen_string_literal: true

# session_vitality_server_test.rb -- regression guard for the session-vitality
# plugin server and its dashboard page.
#
# Covers:
#   - the dashboard is served through the read-only MCP `resources/read`
#     method (which needs no confirmation dialog) and returns parseable JSON
#   - the aggregation math over a fixture session store: message counts, real
#     token accounting (prompt / output / cached / billed), tool calls, daily
#     trend buckets, per-project and per-model grouping, recent sessions
#   - Apple-epoch timestamps do not land in 1995
#   - the per-file summary cache is invalidated when a session file changes
#   - a missing store still yields the clearly labeled demo dataset
#   - two invariants of the page's MCP App handshake (see the comments there)
#
# Usage: ruby scripts/session_vitality_server_test.rb [report.md] [report.json]

require "json"
require "open3"
require "tmpdir"

# 这个测试进程也可能跑在没有 LANG 的 shell（本机与 CI 都会），默认外部编码
# 会是 US-ASCII，读中文标题就成了非法字节。先钉死 UTF-8。
Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

ROOT = File.expand_path("..", __dir__)
PLUGIN = File.join(ROOT, "PluginExamples", "session-vitality")
SERVER = File.join(PLUGIN, "server", "session_vitality.rb")
APP_HTML = File.join(PLUGIN, "server", "app.html")
STATS_URI = "willdeep-plugin://vitality/stats"
SIDEBAR_URI = "willdeep-plugin://vitality/sidebar"
MAIN_URI = "ui://vitality/main"
APPLE_EPOCH_OFFSET = 978_307_200

results = []

def check(condition, message, results)
  results << { "ok" => condition, "message" => message }
end

# 起一个服务端；复现宿主的启动方式：系统 Ruby、不带 UTF-8 locale。
def with_server(sessions_dir)
  env = { "WD_VITALITY_SESSIONS_DIR" => sessions_dir }
  env.delete("LANG")
  env.delete("LC_ALL")
  Open3.popen3(env, "/usr/bin/ruby", SERVER) do |stdin, stdout, _stderr, _wait|
    stdin.sync = true
    stdin.set_encoding(Encoding::UTF_8)
    stdout.set_encoding(Encoding::UTF_8)
    next_id = 0
    call = lambda do |method, params = {}|
      id = (next_id += 1)
      stdin.puts JSON.generate(jsonrpc: "2.0", id: id, method: method, params: params)
      loop do
        line = stdout.gets
        return nil if line.nil?
        begin
          message = JSON.parse(line)
        rescue JSON::ParserError
          next
        end
        return message if message["id"] == id
      end
    end
    stats = lambda do
      text = call.call("resources/read", { "uri" => STATS_URI })&.dig("result", "contents", 0, "text")
      text ? JSON.parse(text) : nil
    end
    yield call, stats
    stdin.close
  end
end

def assistant_message(created, prompt, completion, cached, options = {})
  {
    "role" => "assistant",
    "createdAt" => created,
    "promptTokens" => prompt,
    "completionTokens" => completion,
    "cachedPromptTokens" => cached,
    "elapsedSeconds" => options[:elapsed] || 2.0,
    "toolCalls" => options[:tool_calls] || []
  }.merge(options[:extra] || {})
end

def write_session(dir, name, payload)
  File.write(File.join(dir, name), JSON.pretty_generate(payload))
end

Dir.mktmpdir do |root|
  sessions_dir = File.join(root, "store")
  agent_sessions = File.join(sessions_dir, "agent-sessions")
  require "fileutils"
  FileUtils.mkdir_p(agent_sessions)

  today = Time.now
  today_iso = today.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
  yesterday_iso = (today - 86_400).utc.strftime("%Y-%m-%dT%H:%M:%SZ")

  write_session(agent_sessions, "alpha.json", {
    "id" => "alpha", "title" => "阿尔法会话",
    "workspaceRootPath" => "/tmp/workspaces/alpha",
    "modelID" => "model-one", "providerDisplayName" => "Provider A",
    "didEditFiles" => true,
    "agentArtifactPaths" => ["/tmp/a.png", "/tmp/b.png"],
    "createdAt" => yesterday_iso, "updatedAt" => today_iso,
    "messages" => [
      { "role" => "user", "createdAt" => today_iso },
      assistant_message(today_iso, 1_000, 100, 800,
                        tool_calls: [{ "id" => "t1" }], extra: { "usageTokens" => 1_100 }),
      assistant_message(today_iso, 2_000, 200, 1_000, elapsed: 4.0),
      { "role" => "tool", "createdAt" => today_iso, "toolCalls" => [] }
    ]
  })

  # 只有 provider、没有 modelID；updatedAt 用 Apple 纪元的秒数
  write_session(agent_sessions, "beta.json", {
    "id" => "beta", "title" => "Beta session",
    "workspaceLocation" => { "kind" => "local", "path" => "/tmp/workspaces/beta" },
    "modelID" => "", "providerDisplayName" => "Provider B",
    "createdAt" => yesterday_iso,
    "updatedAt" => (today.to_i - APPLE_EPOCH_OFFSET - 3_600),
    "messages" => [
      { "role" => "user", "createdAt" => yesterday_iso },
      assistant_message(yesterday_iso, 500, 50, 0, elapsed: 6.0)
    ]
  })

  # 空壳会话：计入会话总数，但不算「有对话的会话」，也不进最近列表与模型分布
  write_session(agent_sessions, "empty.json", {
    "id" => "empty", "title" => "空会话", "messages" => [],
    "createdAt" => yesterday_iso, "updatedAt" => yesterday_iso
  })
  # 没有标题的不是会话（草稿/其它数据），整份跳过
  write_session(agent_sessions, "untitled.json", { "id" => "untitled", "messages" => [] })
  # 坏文件不能把整次扫描带崩
  File.write(File.join(agent_sessions, "broken.json"), "{ not json")

  with_server(sessions_dir) do |call, stats|
    init = call.call("initialize", {})
    check(init && init.dig("result", "serverInfo", "name") == "session-vitality",
          "initialize 返回 session-vitality 服务端信息。", results)

    tools = (call.call("tools/list", {})&.dig("result", "tools") || []).map { |tool| tool["name"] }.sort
    check(tools == ["vitality.export", "vitality.snapshot"],
          "tools/list 暴露 snapshot 与 export 两个工具。", results)

    data = stats.call
    check(data.is_a?(Hash) && data["demo"] == false,
          "有真实会话时不再返回演示数据。", results)
    check(data["sessions"] == 3 && data["activeSessions"] == 2,
          "会话数只数有标题的，空壳会话不算「有对话的会话」。", results)
    check(data["messages"] == 6, "消息数把三种角色都算进来。", results)
    check(data["toolCalls"] == 1, "工具调用按消息里的 toolCalls 累加。", results)
    check(data["requests"] == 3, "模型请求数 = 带 token 用量的助手消息数。", results)

    check(data["outputTokens"] == 350, "输出 Token 累加 completionTokens。", results)
    check(data["promptTokens"] == 3_500, "prompt Token 累加 promptTokens。", results)
    check(data["cachedTokens"] == 1_800, "缓存 Token 累加 cachedPromptTokens。", results)
    check(data["billedTokens"] == 1_100 + 2_200 + 550,
          "计费 Token 优先用 usageTokens，缺失时退回 prompt + completion。", results)
    check((data["cacheRate"] - (1_800.0 / 3_500)).abs < 0.001,
          "缓存命中率 = 命中缓存的 prompt ÷ 全部 prompt。", results)
    check((data["averageSeconds"] - 4.0).abs < 0.01,
          "平均响应时间按带用量的请求平均。", results)
    check(data["editedSessions"] == 1 && data["artifacts"] == 2,
          "改过文件的会话数与产物文件数照实统计。", results)

    trend = data["trend"]
    check(trend.is_a?(Array) && trend.length == 14, "趋势固定给 14 天。", results)
    check(trend.last["output"] == 300 && trend.last["messages"] == 4,
          "今天这一格按消息时间戳落桶。", results)
    check(trend[-2]["output"] == 50, "昨天那一格也落对了。", results)
    check(data["outputToday"] == 300 && data["outputWeek"] == 350,
          "今日 / 近 7 天输出取自趋势桶。", results)

    projects = data["projects"]
    check(projects.map { |project| project["name"] }.first(2) == ["alpha", "beta"],
          "项目按计费 Token 倒序，名字取工作区目录名。", results)
    check(projects.any? { |project| project["name"] == "—" && project["sessions"] == 1 },
          "没有工作区的会话归到「—」，不会凭空消失。", results)
    check(projects[0]["sessions"] == 1 && projects[0]["messages"] == 4 && projects[0]["output"] == 300,
          "项目行统计到会话数、消息数与输出 Token。", results)
    check(projects[0]["share"] == 1.0 && projects[1]["share"] < 1.0,
          "项目占比按最大值归一化。", results)
    check(projects[1]["updatedAt"].to_s >= "2020",
          "Apple 纪元的时间戳没有被当成 Unix 纪元算到 1995 年。", results)

    models = data["models"]
    check(models.map { |model| model["name"] }.sort == ["Provider B", "model-one"],
          "模型分布按 modelID 归类，缺 modelID 时退回 provider。", results)
    check(models.map { |model| model["sessions"] }.inject(0) { |sum, value| sum + value } == 2,
          "空壳会话不进模型分布。", results)

    recent = data["recent"]
    check(recent.map { |session| session["title"] } == ["阿尔法会话", "Beta session"],
          "最近会话按更新时间倒序，且跳过空壳会话。", results)
    check(recent[0]["project"] == "alpha" && recent[0]["output"] == 300,
          "最近会话带上项目与输出 Token。", results)

    check(data["scannedFiles"] >= 5, "扫描计数包含跳过的坏文件。", results)
    check(data["source"] == sessions_dir, "统计里带上扫描根目录。", results)

    repeated = stats.call
    check(repeated["messages"] == data["messages"] && repeated["outputTokens"] == data["outputTokens"],
          "同一份数据重复读结果一致（命中每文件缓存）。", results)

    # 缓存以 (mtime, size) 为键：文件变了必须重新解析，否则面板会永远停在旧数字
    payload = JSON.parse(File.read(File.join(agent_sessions, "beta.json")))
    payload["messages"] << assistant_message(today_iso, 100, 7, 0, elapsed: 1.0)
    File.write(File.join(agent_sessions, "beta.json"), JSON.pretty_generate(payload))
    File.utime(Time.now + 2, Time.now + 2, File.join(agent_sessions, "beta.json"))
    updated = stats.call
    check(updated["messages"] == data["messages"] + 1 && updated["outputTokens"] == 357,
          "会话文件改动后缓存失效，统计跟着变。", results)

    sidebar = call.call("resources/read", { "uri" => SIDEBAR_URI })
    sidebar_text = sidebar&.dig("result", "contents", 0, "text").to_s
    check(!sidebar_text.empty? && JSON.parse(sidebar_text)["components"].is_a?(Array),
          "侧栏资源返回声明式文档。", results)

    main = call.call("resources/read", { "uri" => MAIN_URI })
    check(main&.dig("result", "contents", 0, "text").to_s.include?("<html"),
          "主页面资源返回 HTML。", results)

    export = call.call("tools/call", { "name" => "vitality.export", "arguments" => {} })
    markdown = export&.dig("result", "content", 0, "text").to_s
    check(markdown.start_with?("# Session Vitality"), "export 工具返回 Markdown 报告。", results)
    check(markdown.include?("| Output tokens | 357 |"),
          "Markdown 报告里的数字与统计一致。", results)
    check(markdown.include?("alpha"), "Markdown 报告列出项目。", results)
  end

  # 没有会话存储时退回演示数据，页面仍然可用
  with_server(File.join(root, "missing")) do |_call, stats|
    demo = stats.call
    check(demo && demo["demo"] == true, "缺少会话存储时返回带标记的演示数据。", results)
    check(demo["projects"].is_a?(Array) && demo["trend"].length == 14,
          "演示数据的结构与真实数据一致。", results)
  end
end

# 页面握手的两条不变量。改动 app.html 的消息处理时请连同这里一起更新：
# 这两条守的是那个「点刷新报 undefined is not an object (evaluating 'res.contents')」
# 的真正病根 —— 页面是 WKWebView 的顶层文档，parent === window，自己发出去的
# 请求会原样回到自己的 message 监听器。
app_source = File.read(APP_HTML)
check(app_source.match?(/typeof\s+message\.method\s*===\s*'string'/),
      "页面把「带 method 的消息」挡在响应分支之外，不会被自己的回声解决。", results)
handshake_at = app_source.index("request('ui/initialize'")
handshake = handshake_at ? app_source[handshake_at..-1] : ""
initialized_at = handshake.index("ui/notifications/initialized")
load_at = handshake.index("return load()")
check(!initialized_at.nil? && !load_at.nil? && initialized_at < load_at,
      "ui/initialize 回来后先声明 initialized 再取数（宿主在这之前会顶回 -32002）。", results)

failed = results.reject { |result| result["ok"] }
markdown_path = ARGV[0]
json_path = ARGV[1]
if json_path
  File.write(json_path, JSON.pretty_generate("ok" => failed.empty?, "checks" => results))
end
if markdown_path
  lines = ["# Session Vitality Server Contract", "", "- Status: #{failed.empty? ? "pass" : "fail"}", "", "## Checks", ""]
  results.each { |result| lines << "- #{result["ok"] ? "PASS" : "FAIL"}: #{result["message"]}" }
  File.write(markdown_path, "#{lines.join("\n")}\n")
end

abort failed.map { |result| result["message"] }.join("\n") unless failed.empty?
puts "session_vitality_server_test: pass checks=#{results.length}"
