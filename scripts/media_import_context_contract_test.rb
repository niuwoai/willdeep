#!/usr/bin/env ruby
# frozen_string_literal: true

# media_import_context_contract_test.rb -- guard manifest/package import runtime
# context. Ruby/Skill/third-party API package imports should remain visible to
# the next chat turn as latest-media-import.
#
# Usage:
#   ruby scripts/media_import_context_contract_test.rb
#   ruby scripts/media_import_context_contract_test.rb build/ci/media_import_context_report.md build/ci/media_import_context_report.json

require "json"
require "fileutils"
require "time"

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

repo_root = File.expand_path("..", __dir__)
markdown_path = ARGV[0] || "build/media_import_context_contract/report.md"
json_path = ARGV[1] || "build/media_import_context_contract/report.json"

def read_file(repo_root, relative)
  File.read(File.join(repo_root, relative), encoding: "UTF-8")
end

def includes_all?(source, tokens)
  tokens.all? { |token| source.include?(token) }
end

context_source = read_file(repo_root, "Xedit/AgentMediaImportContext.swift")
import_source = read_file(repo_root, "Xedit/AgentMediaImportTools.swift")
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
  "media import context exposes latest-media-import prompt block",
  includes_all?(
    context_source,
    [
      "struct AgentMediaImportContext",
      "=== Latest Media Import ===",
      "<latest-media-import>",
      "manifest_path:",
      "pending_remote_task_count:",
      "failed_manifest_task_count:",
      "imported_tasks:",
      "follow_up: if pending_task_ids is non-empty"
    ]
  ),
  "Manifest import should produce a compact runtime block for the next model turn."
)

add_check.call(
  "manifest import records runtime context after creating tasks",
  includes_all?(
    import_source,
    [
      "recordAgentMediaImport(",
      "manifestPath: manifestURL.path",
      "baseDirectory: baseURL.path",
      "packageDirectory: manifestURL.deletingLastPathComponent().path",
      "widgetPreviewPath: widgetPreviewURL?.path",
      "gapReportPath: gapReportURL?.path",
      "pendingRemoteTaskCount: pendingItems.count",
      "failedManifestTaskCount: failedItems.count",
      "tasks: tasks"
    ]
  ),
  "The successful import path must record completed, pending, and failed task summaries."
)

add_check.call(
  "latest media import reaches agent runtime prompt",
  includes_all?(
    runtime_source + loop_source + context_source,
    [
      "@Published var latestMediaImport: AgentMediaImportContext?",
      "func recordAgentMediaImport(",
      "if let latestMediaImport = runtime.latestMediaImport",
      "latestMediaImport.systemPromptBlock"
    ]
  ),
  "The recorded manifest import context must be visible in the next agent request."
)

add_check.call(
  "local and CI runners execute media import context contract",
  includes_all?(
    run_tests_source + workflow_source,
    [
      "scripts/media_import_context_contract_test.rb",
      "media_import_context_report.md",
      "media_import_context_report.json"
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
md = +"# Media Import Context Contract Report\n\n"
md << "**Status:** #{status}\n\n"
md << "- Checks: #{checks.length}\n"
md << "- Failures: #{failures.length}\n\n"

if failures.empty?
  md << "All media-import context handoff checks passed.\n\n"
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

puts "media_import_context_contract: #{status.downcase} checks=#{checks.length} failures=#{failures.length}"
exit(ok ? 0 : 1)
