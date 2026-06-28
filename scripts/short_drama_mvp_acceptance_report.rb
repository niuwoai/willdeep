#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "time"

ROOT_DIR = File.expand_path("..", __dir__)
REPORT_MD = File.expand_path(ARGV[0] || "build/ci/short_drama_mvp_acceptance_report.md", ROOT_DIR)
REPORT_JSON = File.expand_path(ARGV[1] || "build/ci/short_drama_mvp_acceptance_report.json", ROOT_DIR)
REPORT_DIR = File.dirname(REPORT_JSON)

def read_text(relative)
  File.read(File.join(ROOT_DIR, relative), encoding: "UTF-8")
end

def read_json_file(path)
  JSON.parse(File.read(path, encoding: "UTF-8"))
rescue Errno::ENOENT, JSON::ParserError => e
  { "status" => "missing", "error" => e.message, "path" => path }
end

def semver_sort_key(version)
  core, rc = version.split("-rc", 2)
  major, minor, patch = core.split(".").map(&:to_i)
  [major, minor, patch, rc ? 0 : 1, rc.to_i]
end

def add_check(checks, name, ok, detail, path = nil)
  checks << {
    "name" => name,
    "ok" => ok,
    "detail" => detail,
    "path" => path
  }.compact
end

version_report_path = File.join(REPORT_DIR, "version_report.json")
tryout_report_path = File.join(REPORT_DIR, "short_drama_mvp_tryout_package_report.json")
version_report = read_json_file(version_report_path)
tryout_report = read_json_file(tryout_report_path)
cutoff = read_text("docs/SHORT_DRAMA_AI_MVP_CUTOFF.md")
tryout = read_text("docs/SHORT_DRAMA_AI_MVP_TRYOUT.md")
manual_queue = read_text("docs/MANUAL_TEST_QUEUE.md")

canonical_version = version_report["canonical_version"].to_s
manual_versions = manual_queue.scan(/^##\s+(\d+\.\d+\.\d+(?:-rc\d+)?)\s+—\s+短剧/m).flatten
latest_manual_version = manual_versions.max_by { |version| semver_sort_key(version) }
delivery_gate_names = Array(version_report["delivery_checks"]).map { |check| check["name"].to_s }
tryout_checks = Array(tryout_report["checks"])
manual_result_paths = [
  tryout_report["manual_smoke_results_md_path"],
  tryout_report["manual_smoke_results_json_path"]
].compact

checks = []
add_check(
  checks,
  "version report passes",
  version_report["failures"].is_a?(Array) && version_report["failures"].empty? && !canonical_version.empty?,
  "version_report.json should pass and expose canonical_version.",
  version_report_path
)
add_check(
  checks,
  "delivery gates include manual smoke result templates",
  delivery_gate_names.include?("Tryout package preserves manual smoke result templates"),
  "version consistency should guard the tryout package manual smoke result templates.",
  version_report_path
)
add_check(
  checks,
  "tryout package report passes",
  tryout_report["status"] == "pass" && tryout_checks.all? { |check| check["ok"] },
  "short_drama_mvp_tryout_package_report.json should pass all package checks.",
  tryout_report_path
)
add_check(
  checks,
  "tryout package exposes manual smoke result files",
  manual_result_paths.length == 2 && manual_result_paths.all? { |path| File.file?(path) },
  "tryout package should include Markdown and JSON manual smoke result templates.",
  manual_result_paths.join(", ")
)
add_check(
  checks,
  "cutoff documents manual smoke evidence path",
  cutoff.include?("manual-smoke-results-template.md/json"),
  "SHORT_DRAMA_AI_MVP_CUTOFF.md should tell handoff users where to record manual smoke evidence.",
  "docs/SHORT_DRAMA_AI_MVP_CUTOFF.md"
)
add_check(
  checks,
  "tryout points at latest manual queue section",
  !canonical_version.empty? &&
    tryout.include?("`#{canonical_version} —") &&
    latest_manual_version == canonical_version,
  "SHORT_DRAMA_AI_MVP_TRYOUT.md and MANUAL_TEST_QUEUE.md should agree on the current short-drama smoke section.",
  "docs/SHORT_DRAMA_AI_MVP_TRYOUT.md"
)
add_check(
  checks,
  "manual queue lists current acceptance report handoff",
  !canonical_version.empty? &&
    manual_queue.include?("## #{canonical_version} — 短剧交付验收摘要"),
  "MANUAL_TEST_QUEUE.md should include the current short-drama acceptance report handoff section.",
  "docs/MANUAL_TEST_QUEUE.md"
)

ok = checks.all? { |check| check.fetch("ok") }
evidence = [
  { "label" => "Version report", "path" => File.join(REPORT_DIR, "version_report.md") },
  { "label" => "Tryout package report", "path" => File.join(REPORT_DIR, "short_drama_mvp_tryout_package_report.md") },
  { "label" => "Tryout package", "path" => tryout_report["package_directory"] },
  { "label" => "Manual smoke checklist", "path" => tryout_report["manual_smoke_checklist_path"] },
  { "label" => "Manual smoke results Markdown", "path" => tryout_report["manual_smoke_results_md_path"] },
  { "label" => "Manual smoke results JSON", "path" => tryout_report["manual_smoke_results_json_path"] },
  { "label" => "Cutoff", "path" => File.join(ROOT_DIR, "docs", "SHORT_DRAMA_AI_MVP_CUTOFF.md") },
  { "label" => "Tryout guide", "path" => File.join(ROOT_DIR, "docs", "SHORT_DRAMA_AI_MVP_TRYOUT.md") },
  { "label" => "Manual queue", "path" => File.join(ROOT_DIR, "docs", "MANUAL_TEST_QUEUE.md") }
]

report = {
  "status" => ok ? "pass" : "fail",
  "generated_at" => Time.now.utc.iso8601,
  "version" => canonical_version,
  "checks" => checks,
  "evidence" => evidence
}

FileUtils.mkdir_p(File.dirname(REPORT_MD))
File.write(REPORT_JSON, "#{JSON.pretty_generate(report)}\n")
File.write(
  REPORT_MD,
  [
    "# Short Drama MVP Acceptance Report",
    "",
    "**Status:** #{ok ? "pass" : "fail"}",
    "",
    "- Version: `#{canonical_version}`",
    "- Generated at: `#{report.fetch("generated_at")}`",
    "- Evidence items: #{evidence.length}",
    "",
    "## Checks",
    "",
    *checks.map { |check| "- #{check.fetch("ok") ? "[x]" : "[ ]"} #{check.fetch("name")} — #{check.fetch("detail")}" },
    "",
    "## Evidence",
    "",
    *evidence.map { |item| "- #{item.fetch("label")}: `#{item["path"]}`" },
    ""
  ].join("\n")
)

puts "short_drama_mvp_acceptance_report: #{ok ? "pass" : "fail"} version=#{canonical_version} checks=#{checks.length}"
exit(ok ? 0 : 1)
