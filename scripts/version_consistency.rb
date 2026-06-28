#!/usr/bin/env ruby
# frozen_string_literal: true

# version_consistency.rb — verify every product-facing version source agrees.
#
# Usage:
#   ruby scripts/version_consistency.rb
#   ruby scripts/version_consistency.rb build/ci/version_report.md build/ci/version_report.json

require "json"
require "fileutils"
require "time"

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

repo_root = File.expand_path("..", __dir__)
markdown_path = ARGV[0] || "build/ci/version_report.md"
json_path = ARGV[1] || "build/ci/version_report.json"
version_pattern = /\d+\.\d+\.\d+(?:-rc\d+)?/
semver_pattern = /\A#{version_pattern.source}\z/

def read_file(repo_root, relative)
  File.read(File.join(repo_root, relative), encoding: "UTF-8")
end

def badge_to_version(value)
  value.tr("_", "-").gsub("--", "-")
end

def semver_sort_key(version)
  core, rc = version.split("-rc", 2)
  major, minor, patch = core.split(".").map(&:to_i)
  release_rank = rc ? 0 : 1
  [major, minor, patch, release_rank, rc.to_i]
end

checks = []
delivery_checks = []

add_check = lambda do |name, path, versions, expected_count: nil, allow_empty: false|
  versions = Array(versions).compact
  versions = versions.map(&:strip).reject(&:empty?)
  checks << {
    name: name,
    path: path,
    versions: versions,
    expected_count: expected_count,
    allow_empty: allow_empty
  }
end

add_delivery_check = lambda do |name, path, ok, detail|
  delivery_checks << {
    name: name,
    path: path,
    ok: ok,
    detail: detail
  }
end

pbxproj = read_file(repo_root, "Xedit.xcodeproj/project.pbxproj")
add_check.call(
  "Xcode MARKETING_VERSION",
  "Xedit.xcodeproj/project.pbxproj",
  pbxproj.scan(/MARKETING_VERSION = "?([^";]+)"?;/).flatten,
  expected_count: 6
)

go_version = read_file(repo_root, "willdeep-agent/internal/agent/version.go")
add_check.call(
  "Go agent Version",
  "willdeep-agent/internal/agent/version.go",
  go_version[/const Version = "([^"]+)"/, 1],
  expected_count: 1
)

help_plist = read_file(repo_root, "Help/WillDeep.help/Contents/Info.plist")
add_check.call(
  "Help bundle CFBundleShortVersionString",
  "Help/WillDeep.help/Contents/Info.plist",
  help_plist[/<key>CFBundleShortVersionString<\/key>\s*<string>([^<]+)<\/string>/m, 1],
  expected_count: 1
)

readme = read_file(repo_root, "README.md")
add_check.call(
  "README version badges",
  "README.md",
  readme.scan(%r{badge/version-([0-9][0-9A-Za-z_.-]*?)-blue}).flatten.map { |value| badge_to_version(value) }
)

product_overview = read_file(repo_root, "product-overview.md")
add_check.call(
  "Product overview current version",
  "product-overview.md",
  product_overview[/Current version:\s*v?(#{version_pattern})/, 1],
  expected_count: 1
)

mobile_requirements = read_file(repo_root, "docs/MOBILE_GATEWAY_REQUIREMENTS.md")
add_check.call(
  "Mobile Gateway target/header versions",
  "docs/MOBILE_GATEWAY_REQUIREMENTS.md",
  mobile_requirements.scan(/(?:Target version:\s*v?|X-(?:App|Server)-Version:\s*`?|\"version\":\s*\")(#{version_pattern})/).flatten,
  expected_count: 4
)

harness_priorities = read_file(repo_root, "docs/AGENT_HARNESS_IMPROVEMENT_PRIORITIES.md")
add_check.call(
  "Agent harness priorities current version",
  "docs/AGENT_HARNESS_IMPROVEMENT_PRIORITIES.md",
  harness_priorities[/Current version:\s*v?(#{version_pattern})/, 1],
  expected_count: 1
)

short_drama_cutoff = read_file(repo_root, "docs/SHORT_DRAMA_AI_MVP_CUTOFF.md")
add_check.call(
  "Short drama cutoff baseline versions",
  "docs/SHORT_DRAMA_AI_MVP_CUTOFF.md",
  short_drama_cutoff.scan(/(?:Baseline version:\s*v?|基线 `v?)(#{version_pattern})/).flatten,
  expected_count: 2
)

short_drama_tryout = read_file(repo_root, "docs/SHORT_DRAMA_AI_MVP_TRYOUT.md")
add_check.call(
  "Short drama tryout baseline/manual queue versions",
  "docs/SHORT_DRAMA_AI_MVP_TRYOUT.md",
  [
    short_drama_tryout[/Baseline version:\s*v?(#{version_pattern})/, 1],
    short_drama_tryout[/人工 smoke 结果请记录到 .*?`(#{version_pattern})\s+—/m, 1]
  ],
  expected_count: 2
)

manual_test_queue = read_file(repo_root, "docs/MANUAL_TEST_QUEUE.md")
short_drama_manual_versions = manual_test_queue.scan(/^##\s+(#{version_pattern})\s+—\s+短剧/m).flatten
pending_short_drama_pointer_versions = manual_test_queue
  .scan(/^- ⏳(?:.*\n(?:  .*\n?)*)/)
  .select do |block|
    block.include?("SHORT_DRAMA_AI_MVP_TRYOUT.md") ||
      block.include?("最新短剧 smoke") ||
      block.include?("phase 2 之前最后一个短剧") ||
      block.include?("底部“验收记录”") ||
      block.include?("都指向")
  end
  .flat_map { |block| block.scan(version_pattern).flatten }
add_check.call(
  "Manual smoke latest short drama section",
  "docs/MANUAL_TEST_QUEUE.md",
  short_drama_manual_versions.max_by { |version| semver_sort_key(version) },
  expected_count: 1
)
add_check.call(
  "Manual smoke last short drama section",
  "docs/MANUAL_TEST_QUEUE.md",
  short_drama_manual_versions.last,
  expected_count: 1
)
add_check.call(
  "Manual smoke pending short drama pointer versions",
  "docs/MANUAL_TEST_QUEUE.md",
  pending_short_drama_pointer_versions,
  allow_empty: true
)

run_tests = read_file(repo_root, "scripts/run_tests.sh")
workflow = read_file(repo_root, ".github/workflows/test.yml")
short_drama_tryout_package = read_file(repo_root, "scripts/short_drama_mvp_tryout_package.rb")
short_drama_acceptance_report = read_file(repo_root, "scripts/short_drama_mvp_acceptance_report.rb")
short_drama_remaining_risks = short_drama_cutoff
  .match(/^##\s+当前剩余风险\n\n(?<body>.*?)(?=^##\s|\z)/m)
  &.[](:body)
  .to_s
  .scan(/^- (.+)$/)
  .flatten
add_delivery_check.call(
  "Short drama cutoff documents one-shot local acceptance",
  "docs/SHORT_DRAMA_AI_MVP_CUTOFF.md",
  short_drama_cutoff.include?("`scripts/run_tests.sh`"),
  "Cutoff should name the local one-shot acceptance command."
)
add_delivery_check.call(
  "Short drama cutoff documents remote Go acceptance",
  "docs/SHORT_DRAMA_AI_MVP_CUTOFF.md",
  short_drama_cutoff.include?("`go test ./...`") && short_drama_cutoff.include?("willdeep-agent"),
  "Cutoff should name the remote Go agent test command and working directory."
)
add_delivery_check.call(
  "Short drama cutoff documents remote Xedit acceptance",
  "docs/SHORT_DRAMA_AI_MVP_CUTOFF.md",
  short_drama_cutoff.include?("GitHub Actions `Tests`") && short_drama_cutoff.include?("Run XeditTests"),
  "Cutoff should name the GitHub Actions Tests workflow and Xedit test gate."
)
add_delivery_check.call(
  "Local acceptance still runs short-drama tryout package",
  "scripts/run_tests.sh",
  run_tests.include?("scripts/short_drama_mvp_tryout_package.rb") &&
    run_tests.include?("short_drama_mvp_tryout_package_report.md"),
  "scripts/run_tests.sh should generate the local short-drama MVP tryout package report."
)
add_delivery_check.call(
  "Remote acceptance still runs Go and Xedit gates",
  ".github/workflows/test.yml",
  workflow.include?("Run Go agent tests") &&
    workflow.include?("go test ./...") &&
    workflow.include?("Run XeditTests"),
  "GitHub Actions should run Go agent tests and XeditTests."
)
add_delivery_check.call(
  "Tryout package preserves manual smoke result templates",
  "scripts/short_drama_mvp_tryout_package.rb",
  short_drama_tryout_package.include?("manual-smoke-results-template.md") &&
    short_drama_tryout_package.include?("manual-smoke-results-template.json") &&
    short_drama_tryout_package.include?("manual_smoke_results_md_path") &&
    short_drama_tryout_package.include?("manual_smoke_results_json_path"),
  "Tryout package report should expose Markdown and JSON manual smoke result templates."
)
add_delivery_check.call(
  "Short drama acceptance report is wired into local and remote acceptance",
  "scripts/short_drama_mvp_acceptance_report.rb",
  File.file?(File.join(repo_root, "scripts/short_drama_mvp_acceptance_report.rb")) &&
    run_tests.include?("scripts/short_drama_mvp_acceptance_report.rb") &&
    workflow.include?("Generate short-drama MVP acceptance report") &&
    workflow.include?("short_drama_mvp_acceptance_report.md"),
  "Local and GitHub acceptance should generate the short-drama MVP acceptance report."
)
add_delivery_check.call(
  "Short drama acceptance report preserves handoff readiness summary",
  "scripts/short_drama_mvp_acceptance_report.rb",
  short_drama_acceptance_report.include?('"handoff_readiness"') &&
    short_drama_acceptance_report.include?('"remaining_risks"') &&
    short_drama_acceptance_report.include?('"manual_results_summary"') &&
    short_drama_acceptance_report.include?("## Handoff Readiness") &&
    short_drama_acceptance_report.include?("## Manual Results File") &&
    short_drama_acceptance_report.include?("## Remaining Risks") &&
    short_drama_acceptance_report.include?("cutoff keeps explicit remaining risks") &&
    short_drama_cutoff.include?("交付就绪状态") &&
    short_drama_cutoff.include?("剩余风险"),
  "Acceptance report should keep machine/manual readiness and remaining-risk evidence visible."
)
add_delivery_check.call(
  "Short drama cutoff preserves explicit remaining risks",
  "docs/SHORT_DRAMA_AI_MVP_CUTOFF.md",
  short_drama_remaining_risks.any?,
  "Cutoff should keep at least one remaining-risk bullet instead of implying the MVP has no external or manual smoke risk."
)
add_delivery_check.call(
  "Short drama acceptance report summarizes manual smoke result file",
  "scripts/short_drama_mvp_acceptance_report.rb",
  short_drama_acceptance_report.include?("manual_results_summary") &&
    short_drama_acceptance_report.include?("manual smoke results JSON is summarized") &&
    short_drama_acceptance_report.include?("normalize_manual_result_status") &&
    short_drama_acceptance_report.include?("Manual Results File"),
  "Acceptance report should parse the tryout package manual smoke results JSON so filled pass/fail evidence is visible."
)

changelog = read_file(repo_root, "CHANGELOG.md")
add_check.call(
  "CHANGELOG top entry",
  "CHANGELOG.md",
  changelog[/^##\s+([0-9]+\.[0-9]+\.[0-9]+(?:-rc\d+)?)\s+-/m, 1],
  expected_count: 1
)

all_versions = checks.flat_map { |check| check[:versions] }
canonical_version = all_versions.group_by(&:itself).max_by { |_version, values| values.length }&.first
failures = []

checks.each do |check|
  unique_versions = check[:versions].uniq
  if check[:versions].empty?
    failures << "#{check[:name]} did not expose a version" unless check[:allow_empty]
    next
  end
  if check[:expected_count] && check[:versions].length != check[:expected_count]
    failures << "#{check[:name]} expected #{check[:expected_count]} occurrence(s), found #{check[:versions].length}"
  end
  invalid_versions = unique_versions.reject { |version| version.match?(semver_pattern) }
  unless invalid_versions.empty?
    failures << "#{check[:name]} has invalid semver value(s): #{invalid_versions.join(", ")}"
  end
  if unique_versions.length != 1
    failures << "#{check[:name]} has multiple versions: #{unique_versions.join(", ")}"
  elsif canonical_version && unique_versions.first != canonical_version
    failures << "#{check[:name]} is #{unique_versions.first}, expected #{canonical_version}"
  end
end

if all_versions.uniq.length > 1
  failures << "Version sources disagree: #{all_versions.uniq.sort.join(", ")}"
end
delivery_checks.each do |check|
  failures << "#{check[:name]} missing: #{check[:detail]}" unless check[:ok]
end

ok = failures.empty?
report = {
  ok: ok,
  generated_at: Time.now.utc.iso8601,
  canonical_version: canonical_version,
  checks: checks,
  delivery_checks: delivery_checks,
  failures: failures
}

[markdown_path, json_path].each do |path|
  directory = File.dirname(File.expand_path(path, repo_root))
  FileUtils.mkdir_p(directory) unless Dir.exist?(directory)
end

File.write(File.expand_path(json_path, repo_root), JSON.pretty_generate(report))

status = ok ? "PASS" : "FAIL"
md = +"# Version Consistency Report\n\n"
md << "**Status:** #{status}\n\n"
md << "- Canonical version: #{canonical_version || "unknown"}\n"
md << "- Checked sources: #{checks.length}\n"
md << "- Delivery gates: #{delivery_checks.length}\n"
md << "- Failures: #{failures.length}\n\n"

if failures.empty?
  md << "All version sources agree.\n\n"
else
  md << "## Failures\n\n"
  failures.each { |failure| md << "- #{failure}\n" }
  md << "\n"
end

md << "## Sources\n\n"
md << "| Source | Path | Versions |\n"
md << "| --- | --- | --- |\n"
checks.each do |check|
  versions = check[:versions].empty? ? (check[:allow_empty] ? "_none_" : "_missing_") : check[:versions].uniq.join(", ")
  md << "| #{check[:name]} | `#{check[:path]}` | `#{versions}` |\n"
end

md << "\n## Delivery Gates\n\n"
md << "| Gate | Path | Status | Detail |\n"
md << "| --- | --- | --- | --- |\n"
delivery_checks.each do |check|
  md << "| #{check[:name]} | `#{check[:path]}` | #{check[:ok] ? "PASS" : "FAIL"} | #{check[:detail]} |\n"
end

File.write(File.expand_path(markdown_path, repo_root), md)

puts "version_consistency: #{status.downcase} version=#{canonical_version || "unknown"} failures=#{failures.length}"
exit(ok ? 0 : 1)
