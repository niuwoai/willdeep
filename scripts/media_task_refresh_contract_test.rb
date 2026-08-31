#!/usr/bin/env ruby
# frozen_string_literal: true

# media_task_refresh_contract_test.rb -- guard the media-task refresh to chat
# context contract. Manual side-panel refreshes should not silently disappear;
# the next model turn needs a compact latest-media-task-refresh block.
#
# Usage:
#   ruby scripts/media_task_refresh_contract_test.rb
#   ruby scripts/media_task_refresh_contract_test.rb build/ci/media_task_refresh_report.md build/ci/media_task_refresh_report.json

require "json"
require "fileutils"
require "time"

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

repo_root = File.expand_path("..", __dir__)
markdown_path = ARGV[0] || "build/media_task_refresh_contract/report.md"
json_path = ARGV[1] || "build/media_task_refresh_contract/report.json"

def read_file(repo_root, relative)
  File.read(File.join(repo_root, relative), encoding: "UTF-8")
end

def includes_all?(source, tokens)
  tokens.all? { |token| source.include?(token) }
end

refresh_source = read_file(repo_root, "Xedit/AgentMediaTaskRefreshContext.swift")
tasks_source = read_file(repo_root, "Xedit/AgentMediaTasks.swift")
runtime_source = read_file(repo_root, "Xedit/AgentRuntime.swift")
loop_source = read_file(repo_root, "Xedit/AppStateAgentLoop.swift")
run_tests_source = read_file(repo_root, "scripts/run_tests.sh")
workflow_source = read_file(repo_root, ".github/workflows/test.yml")

checks = []

add_check = lambda do |name, status, detail|
  checks << {
    name: name,
    ok: status == true,
    detail: detail
  }
end

add_check.call(
  "media refresh context exposes system prompt block",
  includes_all?(
    refresh_source,
    [
      "struct AgentMediaTaskRefreshContext",
      "=== Latest Media Task Refresh ===",
      "<latest-media-task-refresh>",
      "refreshed_task_count:",
      "completed_count:",
      "refreshed_tasks:",
      "follow_up: use list_media_tasks or short_drama_open_media_tasks"
    ]
  ),
  "The refresh batch must produce a compact block for the next model turn."
)

add_check.call(
  "side panel refresh buttons record refreshed tasks",
  includes_all?(
    tasks_source,
    [
      "refreshTaskIDs(refreshableScopedTasks.map(\\.id), reason: \"refresh_visible_active_tasks\")",
      "refreshTaskIDs(staleRefreshableScopedTasks.map(\\.id), reason: \"refresh_stale_active_tasks\")",
      "let refreshedIDSet = Set(taskIDs)",
      "appState.recordAgentMediaTaskRefresh(",
      "scopeLabel: scope?.label ?? \"全部媒体任务\""
    ]
  ),
  "Manual active/stale refreshes should record the refreshed task batch after polling."
)

add_check.call(
  "refresh context reaches agent runtime prompt",
  includes_all?(
    runtime_source + loop_source + refresh_source,
    [
      "@Published var latestMediaTaskRefresh: AgentMediaTaskRefreshContext?",
      "func recordAgentMediaTaskRefresh(reason: String, scopeLabel: String, tasks: [AgentMediaTask], runtime: AgentRuntime? = nil)",
      "(runtime ?? activeRuntime)?.latestMediaTaskRefresh",
      "if let latestMediaTaskRefresh = runtime.latestMediaTaskRefresh",
      "latestMediaTaskRefresh.systemPromptBlock"
    ]
  ),
  "The recorded refresh batch must be visible in the next agent request."
)

add_check.call(
  "local and CI runners execute media task refresh contract",
  includes_all?(
    run_tests_source + workflow_source,
    [
      "scripts/media_task_refresh_contract_test.rb",
      "media_task_refresh_report.md",
      "media_task_refresh_report.json"
    ]
  ),
  "Both local run_tests.sh and GitHub Actions should run and publish this contract."
)

failures = checks.reject { |check| check[:ok] }
ok = failures.empty?
report = {
  ok: ok,
  generated_at: Time.now.utc.iso8601,
  checks: checks,
  failures: failures
}

[markdown_path, json_path].each do |path|
  directory = File.dirname(File.expand_path(path, repo_root))
  FileUtils.mkdir_p(directory) unless Dir.exist?(directory)
end

File.write(File.expand_path(json_path, repo_root), JSON.pretty_generate(report))

status = ok ? "PASS" : "FAIL"
md = +"# Media Task Refresh Contract Report\n\n"
md << "**Status:** #{status}\n\n"
md << "- Checks: #{checks.length}\n"
md << "- Failures: #{failures.length}\n\n"

if failures.empty?
  md << "All media-task refresh handoff checks passed.\n\n"
else
  md << "## Failures\n\n"
  failures.each { |failure| md << "- #{failure[:name]}: #{failure[:detail]}\n" }
  md << "\n"
end

md << "## Checks\n\n"
md << "| Check | Status | Detail |\n"
md << "| --- | --- | --- |\n"
checks.each do |check|
  md << "| #{check[:name]} | #{check[:ok] ? "PASS" : "FAIL"} | #{check[:detail]} |\n"
end

File.write(File.expand_path(markdown_path, repo_root), md)

puts "media_task_refresh_contract: #{status.downcase} checks=#{checks.length} failures=#{failures.length}"
exit(ok ? 0 : 1)
