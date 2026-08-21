#!/usr/bin/env ruby
# frozen_string_literal: true

# Session Vitality — MCP stdio server for the WillDeep plugin of the same name.
#
# Serves:
#   - willdeep-plugin://vitality/sidebar   declarative sidebar document
#   - ui://vitality/main                   MCP App dashboard (server/app.html)
#   - tools: vitality.snapshot, vitality.export
#
# Data source: WillDeep persists one JSON file per Agent session under the
# app's Application Support directory. This server scans those files
# tolerantly (camelCase and snake_case keys, missing fields) and aggregates
# per-project statistics. When the store is missing or unreadable it returns a
# clearly labeled demo dataset so the plugin stays navigable.
#
# Override the scan root with WD_VITALITY_SESSIONS_DIR (useful for sandboxes
# and test fixtures).

require "json"
require "date"

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
MAX_FILE_BYTES = 8 * 1024 * 1024

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

def workspace_name(data)
  path = pick(data, "workspaceRootPath", "workspace_root_path",
              "sidebarWorkspaceRootPath", "sidebar_workspace_root_path")
  return nil unless path.is_a?(String) && !path.empty?
  File.basename(path.sub(%r{/+\z}, ""))
end

def messages_count(data)
  messages = pick(data, "messages", "messageCount", "message_count")
  case messages
  when Array then messages.length
  when Integer then messages
  else 0
  end
end

def tokens_for(data, count)
  usage = pick(data, "tokenUsage", "token_usage", "tokens")
  return usage if usage.is_a?(Numeric)
  count * 500
end

def artifacts_count(data)
  paths = pick(data, "agentArtifactPaths", "agent_artifact_paths")
  paths.is_a?(Array) ? paths.length : 0
end

def edited?(data)
  pick(data, "didEditFiles", "did_edit_files") == true
end

def session_updated_at(data, path)
  raw = pick(data, "updatedAt", "updated_at", "lastModified", "last_modified")
  case raw
  when Numeric then return Time.at(raw)
  when String
    begin
      return DateTime.parse(raw).to_time
    rescue ArgumentError, Date::Error
      nil
    end
  end
  File.mtime(path)
rescue StandardError
  Time.now
end

def scan_sessions
  base = app_support_dir
  return [] unless File.directory?(base)

  dirs = [base]
  begin
    Dir.children(base).each do |entry|
      full = File.join(base, entry)
      dirs << full if File.directory?(full)
    end
  rescue Errno::EACCES
    return []
  end

  dirs.flat_map do |dir|
    Dir.children(dir).select { |name| name.end_with?(".json") }.map { |name| File.join(dir, name) }
  rescue Errno::EACCES
    []
  end
end

def format_number(value)
  value.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\1,').reverse
end

def collect_stats
  files = scan_sessions
  return demo_stats if files.empty?

  today = Date.today
  week_start = today - 6
  stats = {
    "demo" => false,
    "sessions" => 0, "messages" => 0,
    "tokensToday" => 0, "tokensWeek" => 0,
    "editedSessions" => 0, "artifacts" => 0,
    "projects" => {}
  }

  files.each do |path|
    next if File.size(path) > MAX_FILE_BYTES
    begin
      data = JSON.parse(File.read(path))
    rescue JSON::ParserError, Errno::EACCES, Errno::ENOENT
      next
    end
    next unless data.is_a?(Hash)
    title = pick(data, "title")
    next unless title.is_a?(String) && !title.empty?

    count = messages_count(data)
    tokens = tokens_for(data, count)
    edited = edited?(data)
    updated = session_updated_at(data, path)
    name = workspace_name(data) || "—"
    project = (stats["projects"][name] ||= {
      "name" => name, "sessions" => 0, "messages" => 0,
      "tokens" => 0, "edited" => 0, "updated" => nil
    })

    stats["sessions"] += 1
    stats["messages"] += count
    stats["editedSessions"] += 1 if edited
    stats["artifacts"] += artifacts_count(data)
    project["sessions"] += 1
    project["messages"] += count
    project["tokens"] += tokens
    project["edited"] += 1 if edited
    project["updated"] = updated if project["updated"].nil? || updated > project["updated"]

    day = updated.getlocal.to_date
    stats["tokensToday"] += tokens if day == today
    stats["tokensWeek"] += tokens if day >= week_start
  end

  projects = stats["projects"].values.sort_by { |p| p["updated"] || Time.at(0) }.reverse
  max_sessions = projects.map { |p| p["sessions"] }.max || 1
  projects.each { |p| p["share"] = (p["sessions"].to_f / max_sessions).round(2) }
  stats["projects"] = projects
  stats
end

def demo_stats
  {
    "demo" => true,
    "sessions" => 12, "messages" => 486,
    "tokensToday" => 42_000, "tokensWeek" => 318_000,
    "editedSessions" => 7, "artifacts" => 23,
    "projects" => [
      { "name" => "Xedit", "sessions" => 6, "messages" => 251, "tokens" => 152_000,
        "edited" => 4, "updated" => Time.now - 600, "share" => 1.0 },
      { "name" => "willdeep-agent", "sessions" => 4, "messages" => 173, "tokens" => 118_000,
        "edited" => 2, "updated" => Time.now - 3600, "share" => 0.67 },
      { "name" => "docs", "sessions" => 2, "messages" => 62, "tokens" => 48_000,
        "edited" => 1, "updated" => Time.now - 7200, "share" => 0.33 }
    ]
  }
end

def sidebar_document(stats)
  rows = [
    ["ov-sessions", "overview.sessions", stats["sessions"]],
    ["ov-messages", "overview.messages", stats["messages"]],
    ["ov-tokens-today", "overview.tokensToday", format_number(stats["tokensToday"])],
    ["ov-tokens-week", "overview.tokensWeek", format_number(stats["tokensWeek"])],
    ["ov-edited", "overview.edited", stats["editedSessions"]]
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
        "value" => "#{project['sessions']} · #{project['messages']}" },
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
  JSON.generate(stats.merge("source" => app_support_dir))
end

def export_markdown(stats)
  lines = ["# Session Vitality", ""]
  if stats["demo"]
    lines << "> Demo data: no session store found at #{app_support_dir}."
    lines << ""
  end
  lines.concat([
    "- Sessions: #{stats['sessions']}",
    "- Messages: #{stats['messages']}",
    "- Tokens today: #{stats['tokensToday']} (estimate)",
    "- Tokens last 7 days: #{stats['tokensWeek']} (estimate)",
    "- Edited sessions: #{stats['editedSessions']}",
    "- Artifact files: #{stats['artifacts']}",
    ""
  ])
  stats["projects"].each do |project|
    lines << "- **#{project['name']}**: #{project['sessions']} sessions, " \
             "#{project['messages']} messages, #{project['tokens']} tokens"
  end
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
               serverInfo: { name: "session-vitality", version: "1.0.0" } }
           when "resources/read"
             uri = request.dig("params", "uri")
             if uri == MAIN_URI
               { contents: [{ uri: uri, mimeType: "text/html;profile=mcp-app", text: app_html }] }
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
                 description: "Return a Markdown summary of session vitality statistics.",
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
