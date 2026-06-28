#!/usr/bin/env ruby
# frozen_string_literal: true

# production_gap_actions_contract_test.rb -- guard the short-drama production
# gap action strip. Missing-image/video/review buttons should hand precise
# tool arguments to chat instead of only dumping the broad project context.
#
# Usage:
#   ruby scripts/production_gap_actions_contract_test.rb
#   ruby scripts/production_gap_actions_contract_test.rb build/ci/production_gap_actions_report.md build/ci/production_gap_actions_report.json

require "json"
require "fileutils"
require "time"

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

repo_root = File.expand_path("..", __dir__)
markdown_path = ARGV[0] || "build/production_gap_actions_contract/report.md"
json_path = ARGV[1] || "build/production_gap_actions_contract/report.json"

def read_file(repo_root, relative)
  File.read(File.join(repo_root, relative), encoding: "UTF-8")
end

def includes_all?(source, tokens)
  tokens.all? { |token| source.include?(token) }
end

gap_actions_source = read_file(repo_root, "Xedit/AgentShortDramaProductionGapActions.swift")
short_drama_source = read_file(repo_root, "Xedit/AgentShortDrama.swift")
chat_context_source = read_file(repo_root, "Xedit/AgentShortDramaChatContext.swift")
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
  "gap strip exposes separate image video review callbacks",
  includes_all?(
    gap_actions_source,
    [
      "sendImageContext: @escaping () -> Void",
      "sendVideoContext: @escaping () -> Void",
      "sendReviewContext: @escaping () -> Void",
      "action: sendImageContext",
      "action: sendVideoContext",
      "action: sendReviewContext"
    ]
  ),
  "The production-gap buttons must not all share a broad project-context action."
)

add_check.call(
  "project and episode cards wire precise production gap actions",
  includes_all?(
    short_drama_source,
    [
      "appendProductionGapActionToChat(project: project, episode: nil, action: .missingImages)",
      "appendProductionGapActionToChat(project: project, episode: nil, action: .missingVideos)",
      "appendProductionGapActionToChat(project: project, episode: nil, action: .openReviews)",
      "appendProductionGapActionToChat(project: project, episode: episode, action: .missingImages)",
      "appendProductionGapActionToChat(project: project, episode: episode, action: .missingVideos)",
      "appendProductionGapActionToChat(project: project, episode: episode, action: .openReviews)"
    ]
  ),
  "Both project-level and episode-level gap actions should feed exact chat handoff blocks."
)

add_check.call(
  "gap chat handoff carries dry-run and submit arguments",
  includes_all?(
    chat_context_source,
    [
      "enum AgentShortDramaProductionGapAction",
      "<short-drama-production-gap-action>",
      "action: \\(productionGapActionName(action))",
      "dry_run_arguments: \\(batchArguments), kind=image_generation, target_filter=missing, dry_run=true",
      "submit_arguments: \\(batchArguments), kind=image_generation, target_filter=missing, dry_run=false",
      "dry_run_arguments: \\(batchArguments), kind=video_generation, target_filter=missing, dry_run=true",
      "submit_arguments: \\(batchArguments), kind=video_generation, target_filter=missing, dry_run=false",
      "resolve_tool: short_drama_resolve_review_item",
      "reviewQueueLines(project: project, episodes: episodes, limit: 16)"
    ]
  ),
  "Chat should receive the ready-to-run tool arguments for each selected production gap."
)

add_check.call(
  "local and CI runners execute production gap action contract",
  includes_all?(
    run_tests_source + workflow_source,
    [
      "scripts/production_gap_actions_contract_test.rb",
      "production_gap_actions_report.md",
      "production_gap_actions_report.json"
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
md = +"# Production Gap Actions Contract Report\n\n"
md << "**Status:** #{status}\n\n"
md << "- Checks: #{checks.length}\n"
md << "- Failures: #{failures.length}\n\n"

if failures.empty?
  md << "All production-gap action handoff checks passed.\n\n"
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

puts "production_gap_actions_contract: #{status.downcase} checks=#{checks.length} failures=#{failures.length}"
exit(ok ? 0 : 1)
