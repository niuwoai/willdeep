#!/usr/bin/env ruby
# frozen_string_literal: true

# Session Vitality — MCP stdio server for the WillDeep plugin of the same name.
#
# Serves:
#   - willdeep-plugin://vitality/sidebar   declarative sidebar document
#   - ui://vitality/main                   MCP App dashboard (server/app.html)
#   - willdeep-plugin://vitality/stats     aggregated statistics (JSON)
#   - tools: vitality.snapshot, vitality.export
#
# Data source: WillDeep persists one JSON file per Agent session under the
# app's Application Support directory (`agent-sessions/*.json`). Every
# assistant message carries real usage numbers (promptTokens /
# completionTokens / cachedPromptTokens / elapsedSeconds), so the dashboard
# reports measured usage instead of guessing from message counts. Files are
# read tolerantly (camelCase and snake_case keys, missing fields); when the
# store is missing or unreadable a clearly labeled demo dataset keeps the
# plugin navigable.
#
# Scanning 500+ sessions (~130MB) takes about a second, so per-file summaries
# are cached in-process keyed by (mtime, size): a refresh only re-reads the
# sessions that actually changed.
#
# Override the scan root with WD_VITALITY_SESSIONS_DIR (useful for sandboxes
# and test fixtures).
#
# 注意：宿主用系统 /usr/bin/ruby（2.6）启动本文件，只用 2.6 就有的语法与方法。

require "json"
require "date"
require "time"

$stdout.sync = true

# The plugin host launches this server via /usr/bin/ruby without a UTF-8
# locale, leaving Ruby's default external encoding at US-ASCII. Session titles
# and app.html contain CJK text, so pin every stream to UTF-8 up front.
Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8
$stdout.set_encoding(Encoding::UTF_8)
$stderr.set_encoding(Encoding::UTF_8)

SIDEBAR_URI = "willdeep-plugin://vitality/sidebar"
MAIN_URI = "ui://vitality/main"
STATS_URI = "willdeep-plugin://vitality/stats"
MAX_FILE_BYTES = 32 * 1024 * 1024
TREND_DAYS = 14
TOP_PROJECTS = 12
TOP_MODELS = 6
RECENT_SESSIONS = 8
APPLE_EPOCH_OFFSET = 978_307_200 # 2001-01-01 → 1970-01-01

def app_support_dir
  ENV["WD_VITALITY_SESSIONS_DIR"] || File.expand_path("~/Library/Application Support/WillDeep")
end

def pick(data, *keys)
  keys.each do |key|
    value = data[key] || data[key.to_sym]
    return value unless value.nil?
  end
  nil
end

# 会话与消息里的时间戳有两种写法：ISO8601 字符串，以及 Apple 纪元的秒数
# （2001-01-01 起算，落在 0..1e9 之间）。按 Unix 纪元直接 Time.at 会把
# 2026 年的会话算成 1995 年，这里按量级区分。
def parse_time(raw)
  case raw
  when Numeric
    seconds = raw.to_f
    return nil if seconds <= 0
    seconds < 1_000_000_000 ? Time.at(seconds + APPLE_EPOCH_OFFSET) : Time.at(seconds)
  when String
    return nil if raw.strip.empty?
    begin
      Time.parse(raw)
    rescue ArgumentError, TypeError
      nil
    end
  end
end

def workspace_name(data)
  path = workspace_path(data)
  return nil if path.nil?
  File.basename(path.sub(%r{/+\z}, ""))
end

def workspace_path(data)
  path = pick(data, "workspaceRootPath", "workspace_root_path",
              "sidebarWorkspaceRootPath", "sidebar_workspace_root_path")
  if path.nil?
    location = pick(data, "workspaceLocation", "workspace_location")
    path = location["path"] if location.is_a?(Hash)
  end
  path.is_a?(String) && !path.empty? ? path : nil
end

def integer_at(hash, *keys)
  value = pick(hash, *keys)
  value.is_a?(Numeric) ? value.to_i : 0
end

def scan_roots
  base = app_support_dir
  return [] unless File.directory?(base)

  roots = [File.join(base, "agent-sessions")]
  roots << base
  # 测试夹具与旧版落盘会把会话 JSON 放在一层子目录里，一并扫描。
  begin
    Dir.children(base).each do |entry|
      full = File.join(base, entry)
      roots << full if File.directory?(full)
    end
  rescue Errno::EACCES, Errno::ENOENT
    nil
  end
  roots.uniq.select { |path| File.directory?(path) }
end

def session_files
  files = []
  scan_roots.each do |dir|
    begin
      Dir.children(dir).each do |name|
        next unless name.end_with?(".json")
        files << File.join(dir, name)
      end
    rescue Errno::EACCES, Errno::ENOENT
      next
    end
  end
  files.uniq
end

# path → { "key" => "<mtime>:<size>", "summary" => {...} }
$summary_cache = {}

def summary_for(path)
  stat = File.stat(path)
  return nil if stat.size > MAX_FILE_BYTES

  key = "#{stat.mtime.to_i}:#{stat.size}"
  cached = $summary_cache[path]
  return cached["summary"] if cached && cached["key"] == key

  summary = summarize(path)
  $summary_cache[path] = { "key" => key, "summary" => summary }
  summary
rescue Errno::ENOENT, Errno::EACCES
  nil
end

def summarize(path)
  begin
    data = JSON.parse(File.read(path))
  rescue JSON::ParserError, Errno::EACCES, Errno::ENOENT, ArgumentError
    return nil
  end
  return nil unless data.is_a?(Hash)

  title = pick(data, "title")
  return nil unless title.is_a?(String) && !title.empty?

  messages = pick(data, "messages")
  messages = [] unless messages.is_a?(Array)

  summary = {
    "id" => pick(data, "id").to_s,
    "title" => title,
    "project" => workspace_name(data) || "—",
    "projectPath" => workspace_path(data),
    "model" => pick(data, "modelID", "model_id").to_s,
    "provider" => pick(data, "providerDisplayName", "provider_display_name").to_s,
    "messages" => 0,
    "userMessages" => 0,
    "assistantMessages" => 0,
    "toolCalls" => 0,
    "requests" => 0,
    "promptTokens" => 0,
    "completionTokens" => 0,
    "cachedTokens" => 0,
    "reasoningTokens" => 0,
    "billedTokens" => 0,
    "elapsedSeconds" => 0.0,
    "edited" => pick(data, "didEditFiles", "did_edit_files") == true,
    "editedPaths" => (pick(data, "agentEditedPaths", "agent_edited_paths") || []).length,
    "artifacts" => (pick(data, "agentArtifactPaths", "agent_artifact_paths") || []).length,
    "createdAt" => nil,
    "updatedAt" => nil,
    "daily" => {}
  }

  messages.each do |message|
    next unless message.is_a?(Hash)
    summary["messages"] += 1
    role = message["role"].to_s
    summary["userMessages"] += 1 if role == "user"
    summary["assistantMessages"] += 1 if role == "assistant"
    calls = message["toolCalls"] || message["tool_calls"]
    summary["toolCalls"] += calls.length if calls.is_a?(Array)

    prompt = integer_at(message, "promptTokens", "prompt_tokens")
    completion = integer_at(message, "completionTokens", "completion_tokens")
    cached = integer_at(message, "cachedPromptTokens", "cached_prompt_tokens")
    reasoning = integer_at(message, "reasoningTokens", "reasoning_tokens")
    billed = integer_at(message, "usageTokens", "usage_tokens")
    billed = prompt + completion if billed.zero?

    summary["promptTokens"] += prompt
    summary["completionTokens"] += completion
    summary["cachedTokens"] += cached
    summary["reasoningTokens"] += reasoning
    summary["billedTokens"] += billed
    if prompt > 0 || completion > 0
      summary["requests"] += 1
      elapsed = pick(message, "elapsedSeconds", "elapsed_seconds")
      summary["elapsedSeconds"] += elapsed.to_f if elapsed.is_a?(Numeric)
    end

    stamp = parse_time(pick(message, "createdAt", "created_at"))
    next if stamp.nil?
    day = stamp.getlocal.strftime("%Y-%m-%d")
    bucket = (summary["daily"][day] ||= { "output" => 0, "billed" => 0, "messages" => 0, "requests" => 0 })
    bucket["messages"] += 1
    bucket["output"] += completion
    bucket["billed"] += billed
    bucket["requests"] += 1 if prompt > 0 || completion > 0
  end

  created = parse_time(pick(data, "createdAt", "created_at"))
  updated = parse_time(pick(data, "updatedAt", "updated_at", "lastModified", "last_modified"))
  updated ||= begin
    File.mtime(path)
  rescue StandardError
    nil
  end
  summary["createdAt"] = created ? created.utc.iso8601 : nil
  summary["updatedAt"] = updated ? updated.utc.iso8601 : nil
  summary
end

def blank_totals
  {
    "sessions" => 0, "activeSessions" => 0, "messages" => 0, "userMessages" => 0, "toolCalls" => 0,
    "requests" => 0, "editedSessions" => 0, "artifacts" => 0,
    "promptTokens" => 0, "completionTokens" => 0, "cachedTokens" => 0,
    "reasoningTokens" => 0, "billedTokens" => 0, "elapsedSeconds" => 0.0
  }
end

def collect_stats
  started = Time.now
  files = session_files
  summaries = []
  files.each do |path|
    summary = summary_for(path)
    summaries << summary unless summary.nil?
  end
  return demo_stats if summaries.empty?

  totals = blank_totals
  projects = {}
  models = {}
  daily = {}

  summaries.each do |summary|
    totals["sessions"] += 1
    totals["messages"] += summary["messages"]
    totals["userMessages"] += summary["userMessages"]
    totals["toolCalls"] += summary["toolCalls"]
    totals["requests"] += summary["requests"]
    totals["editedSessions"] += 1 if summary["edited"]
    totals["artifacts"] += summary["artifacts"]
    totals["promptTokens"] += summary["promptTokens"]
    totals["completionTokens"] += summary["completionTokens"]
    totals["cachedTokens"] += summary["cachedTokens"]
    totals["reasoningTokens"] += summary["reasoningTokens"]
    totals["billedTokens"] += summary["billedTokens"]
    totals["elapsedSeconds"] += summary["elapsedSeconds"]

    name = summary["project"]
    project = (projects[name] ||= {
      "name" => name, "path" => summary["projectPath"], "sessions" => 0,
      "messages" => 0, "output" => 0, "billed" => 0, "edited" => 0,
      "artifacts" => 0, "updatedAt" => nil
    })
    project["sessions"] += 1
    project["messages"] += summary["messages"]
    project["output"] += summary["completionTokens"]
    project["billed"] += summary["billedTokens"]
    project["edited"] += 1 if summary["edited"]
    project["artifacts"] += summary["artifacts"]
    project["updatedAt"] = newer(project["updatedAt"], summary["updatedAt"])

    # 空会话（占位、开了没说话）不算进模型分布：它压根没用过模型。
    # 没记 modelID 的老会话退回按 provider 归类，好过一律堆进「—」。
    if summary["messages"] > 0
      totals["activeSessions"] += 1
      model_name = summary["model"]
      model_name = summary["provider"] if model_name.empty?
      model_name = "—" if model_name.empty?
      model = (models[model_name] ||= {
        "name" => model_name, "provider" => summary["provider"],
        "sessions" => 0, "messages" => 0, "output" => 0
      })
      model["sessions"] += 1
      model["messages"] += summary["messages"]
      model["output"] += summary["completionTokens"]
    end

    summary["daily"].each do |day, bucket|
      target = (daily[day] ||= { "output" => 0, "billed" => 0, "messages" => 0, "requests" => 0 })
      target["output"] += bucket["output"]
      target["billed"] += bucket["billed"]
      target["messages"] += bucket["messages"]
      target["requests"] += bucket["requests"]
    end
  end

  today = Date.today
  trend = (0...TREND_DAYS).map do |offset|
    date = today - (TREND_DAYS - 1 - offset)
    key = date.strftime("%Y-%m-%d")
    bucket = daily[key] || { "output" => 0, "billed" => 0, "messages" => 0, "requests" => 0 }
    {
      "date" => key,
      "weekday" => date.strftime("%a"),
      "output" => bucket["output"],
      "billed" => bucket["billed"],
      "messages" => bucket["messages"],
      "requests" => bucket["requests"]
    }
  end
  week = trend.last(7)

  ordered_projects = projects.values.sort_by { |project| -project["billed"] }
  max_billed = ordered_projects.map { |project| project["billed"] }.max || 0
  ordered_projects.each do |project|
    project["share"] = max_billed.zero? ? 0.0 : (project["billed"].to_f / max_billed).round(3)
  end

  ordered_models = models.values.sort_by { |model| -model["sessions"] }
  max_model_sessions = ordered_models.map { |model| model["sessions"] }.max || 0
  ordered_models.each do |model|
    model["share"] = max_model_sessions.zero? ? 0.0 : (model["sessions"].to_f / max_model_sessions).round(3)
  end

  # 「最近会话」要能看出干了什么，空壳会话排前面没有意义。
  recent = summaries.select { |summary| summary["messages"] > 0 }
                    .sort_by { |summary| summary["updatedAt"].to_s }.reverse.first(RECENT_SESSIONS)
  recent = recent.map do |summary|
    {
      "title" => summary["title"],
      "project" => summary["project"],
      "messages" => summary["messages"],
      "output" => summary["completionTokens"],
      "billed" => summary["billedTokens"],
      "model" => summary["model"],
      "updatedAt" => summary["updatedAt"]
    }
  end

  todays = trend.last
  {
    "demo" => false,
    "generatedAt" => Time.now.utc.iso8601,
    "source" => app_support_dir,
    "scannedFiles" => files.length,
    "scanMilliseconds" => ((Time.now - started) * 1000).round,
    "sessions" => totals["sessions"],
    "activeSessions" => totals["activeSessions"],
    "messages" => totals["messages"],
    "userMessages" => totals["userMessages"],
    "toolCalls" => totals["toolCalls"],
    "requests" => totals["requests"],
    "editedSessions" => totals["editedSessions"],
    "artifacts" => totals["artifacts"],
    "promptTokens" => totals["promptTokens"],
    "outputTokens" => totals["completionTokens"],
    "cachedTokens" => totals["cachedTokens"],
    "reasoningTokens" => totals["reasoningTokens"],
    "billedTokens" => totals["billedTokens"],
    "cacheRate" => ratio(totals["cachedTokens"], totals["promptTokens"]),
    "averageSeconds" => totals["requests"].zero? ? 0.0 : (totals["elapsedSeconds"] / totals["requests"]).round(2),
    "outputToday" => todays["output"],
    "outputWeek" => week.map { |day| day["output"] }.inject(0) { |sum, value| sum + value },
    "tokensToday" => todays["billed"],
    "tokensWeek" => week.map { |day| day["billed"] }.inject(0) { |sum, value| sum + value },
    "messagesToday" => todays["messages"],
    "trend" => trend,
    "projects" => ordered_projects.first(TOP_PROJECTS),
    "models" => ordered_models.first(TOP_MODELS),
    "recent" => recent
  }
end

def ratio(part, whole)
  return 0.0 if whole.nil? || whole.zero?
  (part.to_f / whole).round(4)
end

def newer(left, right)
  return right if left.nil?
  return left if right.nil?
  left > right ? left : right
end

def demo_stats
  today = Date.today
  trend = (0...TREND_DAYS).map do |offset|
    date = today - (TREND_DAYS - 1 - offset)
    weight = [1, (offset % 5) + 1].max
    {
      "date" => date.strftime("%Y-%m-%d"),
      "weekday" => date.strftime("%a"),
      "output" => 4_000 * weight,
      "billed" => 120_000 * weight,
      "messages" => 12 * weight,
      "requests" => 6 * weight
    }
  end
  {
    "demo" => true,
    "generatedAt" => Time.now.utc.iso8601,
    "source" => app_support_dir,
    "scannedFiles" => 0,
    "scanMilliseconds" => 0,
    "sessions" => 12, "activeSessions" => 11, "messages" => 486, "userMessages" => 96, "toolCalls" => 212,
    "requests" => 180, "editedSessions" => 7, "artifacts" => 23,
    "promptTokens" => 4_200_000, "outputTokens" => 128_000, "cachedTokens" => 2_100_000,
    "reasoningTokens" => 24_000, "billedTokens" => 4_328_000,
    "cacheRate" => 0.5, "averageSeconds" => 6.4,
    "outputToday" => trend.last["output"], "outputWeek" => trend.last(7).map { |d| d["output"] }.inject(0) { |s, v| s + v },
    "tokensToday" => trend.last["billed"], "tokensWeek" => trend.last(7).map { |d| d["billed"] }.inject(0) { |s, v| s + v },
    "messagesToday" => trend.last["messages"],
    "trend" => trend,
    "projects" => [
      { "name" => "Xedit", "path" => "/demo/Xedit", "sessions" => 6, "messages" => 251,
        "output" => 68_000, "billed" => 2_100_000, "edited" => 4, "artifacts" => 12,
        "updatedAt" => Time.now.utc.iso8601, "share" => 1.0 },
      { "name" => "willdeep-agent", "path" => "/demo/willdeep-agent", "sessions" => 4, "messages" => 173,
        "output" => 41_000, "billed" => 1_400_000, "edited" => 2, "artifacts" => 8,
        "updatedAt" => (Time.now - 3600).utc.iso8601, "share" => 0.67 },
      { "name" => "docs", "path" => "/demo/docs", "sessions" => 2, "messages" => 62,
        "output" => 19_000, "billed" => 828_000, "edited" => 1, "artifacts" => 3,
        "updatedAt" => (Time.now - 7200).utc.iso8601, "share" => 0.39 }
    ],
    "models" => [
      { "name" => "claude-opus-5", "provider" => "Anthropic", "sessions" => 7, "messages" => 300, "output" => 74_000, "share" => 1.0 },
      { "name" => "deepseek-v4-flash", "provider" => "some.im", "sessions" => 5, "messages" => 186, "output" => 54_000, "share" => 0.71 }
    ],
    "recent" => [
      { "title" => "Demo session", "project" => "Xedit", "messages" => 42, "output" => 9_800,
        "billed" => 320_000, "model" => "claude-opus-5", "updatedAt" => Time.now.utc.iso8601 }
    ]
  }
end

def format_number(value)
  value.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\1,').reverse
end

def sidebar_document(stats)
  rows = [
    ["ov-sessions", "overview.sessions", format_number(stats["sessions"])],
    ["ov-messages", "overview.messages", format_number(stats["messages"])],
    ["ov-tokens-today", "overview.tokensToday", format_number(stats["tokensToday"])],
    ["ov-tokens-week", "overview.tokensWeek", format_number(stats["tokensWeek"])],
    ["ov-output", "overview.output", format_number(stats["outputTokens"])],
    ["ov-tools", "overview.toolCalls", format_number(stats["toolCalls"])],
    ["ov-edited", "overview.edited", format_number(stats["editedSessions"])]
  ].map do |id, title_key, value|
    { "id" => id, "kind" => "row", "children" => [
      { "id" => "#{id}-label", "kind" => "label", "titleKey" => title_key },
      { "id" => "#{id}-value", "kind" => "badge", "value" => value.to_s }
    ] }
  end

  project_rows = stats["projects"].map.with_index do |project, index|
    { "id" => "project-#{index}", "kind" => "row", "children" => [
      { "id" => "project-name-#{index}", "kind" => "label", "value" => project["name"] },
      { "id" => "project-meta-#{index}", "kind" => "badge",
        "value" => "#{project['sessions']} · #{format_number(project['messages'])}" },
      { "id" => "project-progress-#{index}", "kind" => "progress", "progress" => project["share"] }
    ] }
  end
  project_rows = [{ "id" => "projects-empty", "kind" => "emptyState", "titleKey" => "projects.empty" }] if project_rows.empty?

  components = []
  components << { "id" => "demo-note", "kind" => "status", "titleKey" => "status.demo" } if stats["demo"]
  components << { "id" => "overview", "kind" => "section", "titleKey" => "section.overview", "children" => rows }
  components << { "id" => "projects", "kind" => "section", "titleKey" => "section.projects",
                  "children" => [{ "id" => "projects-list", "kind" => "list", "children" => project_rows }] }
  { "schemaVersion" => 1, "components" => components }
end

def snapshot_text(stats)
  JSON.generate(stats)
end

def percent(value)
  "#{(value.to_f * 100).round(1)}%"
end

def export_markdown(stats)
  lines = ["# Session Vitality", "", "> #{stats['generatedAt']} · #{stats['source']}", ""]
  if stats["demo"]
    lines << "**Demo data**: no session store found at #{stats['source']}."
    lines << ""
  end
  lines.concat([
    "## Overview",
    "",
    "| Metric | Value |",
    "| --- | --- |",
    "| Sessions | #{format_number(stats['sessions'])} |",
    "| Messages | #{format_number(stats['messages'])} |",
    "| Tool calls | #{format_number(stats['toolCalls'])} |",
    "| Model requests | #{format_number(stats['requests'])} |",
    "| Output tokens | #{format_number(stats['outputTokens'])} |",
    "| Prompt tokens (cumulative) | #{format_number(stats['promptTokens'])} |",
    "| Cached prompt tokens | #{format_number(stats['cachedTokens'])} (#{percent(stats['cacheRate'])}) |",
    "| Billed tokens | #{format_number(stats['billedTokens'])} |",
    "| Output today / 7d | #{format_number(stats['outputToday'])} / #{format_number(stats['outputWeek'])} |",
    "| Average response | #{stats['averageSeconds']}s |",
    "| Sessions that edited files | #{format_number(stats['editedSessions'])} |",
    "| Artifact files | #{format_number(stats['artifacts'])} |",
    ""
  ])

  lines.concat(["## Projects", "", "| Project | Sessions | Messages | Output | Billed | Last active |", "| --- | --- | --- | --- | --- | --- |"])
  stats["projects"].each do |project|
    lines << "| #{project['name']} | #{project['sessions']} | #{format_number(project['messages'])} | " \
             "#{format_number(project['output'])} | #{format_number(project['billed'])} | #{project['updatedAt']} |"
  end
  lines << ""

  lines.concat(["## Models", "", "| Model | Sessions | Output |", "| --- | --- | --- |"])
  stats["models"].each do |model|
    lines << "| #{model['name']} | #{model['sessions']} | #{format_number(model['output'])} |"
  end
  lines << ""

  lines.concat(["## Last #{TREND_DAYS} days", "", "| Day | Messages | Output | Billed |", "| --- | --- | --- | --- |"])
  stats["trend"].each do |day|
    lines << "| #{day['date']} | #{format_number(day['messages'])} | #{format_number(day['output'])} | #{format_number(day['billed'])} |"
  end
  lines << ""
  lines.join("\n")
end

def app_html
  @app_html ||= File.read(File.join(__dir__, "app.html"))
end

ARGF.each_line do |line|
  request = JSON.parse(line)
  next unless request["id"]

  result = case request["method"]
           when "initialize"
             { protocolVersion: "2025-06-18",
               capabilities: { resources: { subscribe: true }, tools: {} },
               serverInfo: { name: "session-vitality", version: "2.0.0" } }
           when "resources/read"
             uri = request.dig("params", "uri")
             if uri == MAIN_URI
               { contents: [{ uri: uri, mimeType: "text/html;profile=mcp-app", text: app_html }] }
             elsif uri == STATS_URI
               { contents: [{ uri: uri, mimeType: "application/json",
                              text: snapshot_text(collect_stats) }] }
             else
               { contents: [{ uri: uri, mimeType: "application/json",
                              text: JSON.generate(sidebar_document(collect_stats)) }] }
             end
           when "resources/subscribe"
             {}
           when "tools/list"
             { tools: [
               { name: "vitality.snapshot",
                 description: "Return aggregated session vitality statistics as JSON.",
                 inputSchema: { type: "object", properties: {} } },
               { name: "vitality.export",
                 description: "Return a Markdown report of session vitality statistics.",
                 inputSchema: { type: "object", properties: {} } }
             ] }
           when "tools/call"
             tool_name = request.dig("params", "name")
             text = tool_name == "vitality.export" ? export_markdown(collect_stats) : snapshot_text(collect_stats)
             { content: [{ type: "text", text: text }] }
           else
             {}
           end

  puts JSON.generate(jsonrpc: "2.0", id: request["id"], result: result)
rescue JSON::ParserError => error
  warn error.message
end
