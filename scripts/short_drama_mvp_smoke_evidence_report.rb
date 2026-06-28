#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "time"

ROOT_DIR = File.expand_path("..", __dir__)
PACKAGE_DIR = File.expand_path(ARGV[0] || "build/ci/short_drama_mvp_tryout_package", ROOT_DIR)
REPORT_MD = File.expand_path(ARGV[1] || "build/ci/short_drama_mvp_smoke_evidence_report.md", ROOT_DIR)
REPORT_JSON = File.expand_path(ARGV[2] || "build/ci/short_drama_mvp_smoke_evidence_report.json", ROOT_DIR)

MANUAL_RESULTS_FILE = "manual-smoke-results-template.json"
PROVIDER_RESULTS_FILE = "provider-api-smoke-template.json"

def normalize_status(status)
  normalized = status.to_s.strip.downcase
  return "pass" if %w[pass passed ok success].include?(normalized)
  return "fail" if %w[fail failed error].include?(normalized)
  return "pending" if %w[pending blocked].include?(normalized)

  "untested"
end

def read_json(path)
  [JSON.parse(File.read(path, encoding: "UTF-8")), nil]
rescue Errno::ENOENT, JSON::ParserError => e
  [nil, e.message]
end

def label_for(step)
  title = step["title"].to_s.strip
  return title unless title.empty?

  id = step["id"].to_s.strip
  id.empty? ? "(untitled step)" : id
end

def summarize_step_file(path, expected_schema)
  data, error = read_json(path)
  unless data
    return {
      "path" => path,
      "schema" => "",
      "expected_schema" => expected_schema,
      "parse_error" => error.to_s,
      "step_count" => 0,
      "passed_count" => 0,
      "pending_count" => 0,
      "failed_count" => 0,
      "evidence_required_count" => 0,
      "evidence_present_count" => 0,
      "evidence_missing_count" => 0,
      "pending_items" => [],
      "failed_items" => [],
      "evidence_missing_items" => []
    }
  end

  steps = Array(data["steps"])
  statuses = steps.map { |step| normalize_status(step["status"]) }
  evidence_required_steps = steps.select { |step| %w[pass fail].include?(normalize_status(step["status"])) }
  evidence_present_steps = evidence_required_steps.select { |step| !step["evidence"].to_s.strip.empty? }
  evidence_missing_steps = evidence_required_steps - evidence_present_steps

  {
    "path" => path,
    "schema" => data["schema"].to_s,
    "expected_schema" => expected_schema,
    "parse_error" => "",
    "overall_status" => normalize_status(data["overall_status"]),
    "step_count" => steps.length,
    "passed_count" => statuses.count("pass"),
    "pending_count" => statuses.count("pending") + statuses.count("untested"),
    "failed_count" => statuses.count("fail"),
    "evidence_required_count" => evidence_required_steps.length,
    "evidence_present_count" => evidence_present_steps.length,
    "evidence_missing_count" => evidence_missing_steps.length,
    "pending_items" => steps.select { |step| %w[pending untested].include?(normalize_status(step["status"])) }
                            .map { |step| label_for(step) },
    "failed_items" => steps.select { |step| normalize_status(step["status"]) == "fail" }
                           .map { |step| label_for(step) },
    "evidence_missing_items" => evidence_missing_steps.map { |step| label_for(step) }
  }
end

manual_summary = summarize_step_file(
  File.join(PACKAGE_DIR, MANUAL_RESULTS_FILE),
  "willdeep.short_drama.manual_smoke_results.v1"
)
provider_summary = summarize_step_file(
  File.join(PACKAGE_DIR, PROVIDER_RESULTS_FILE),
  "willdeep.short_drama.provider_api_smoke.v1"
)

summaries = [manual_summary, provider_summary]
schema_errors = summaries.select do |summary|
  summary.fetch("parse_error").empty? && summary.fetch("schema") != summary.fetch("expected_schema")
end
parse_errors = summaries.reject { |summary| summary.fetch("parse_error").empty? }
failed_items = summaries.flat_map { |summary| summary.fetch("failed_items") }
missing_evidence_items = summaries.flat_map { |summary| summary.fetch("evidence_missing_items") }
pending_items = summaries.flat_map { |summary| summary.fetch("pending_items") }

readiness_overall =
  if parse_errors.any? || schema_errors.any?
    "blocked"
  elsif failed_items.any?
    "manual_failed"
  elsif missing_evidence_items.any? || pending_items.any? ||
        summaries.any? { |summary| summary.fetch("overall_status", "untested") != "pass" }
    "manual_pending"
  else
    "ready"
  end

def build_next_actions(manual_summary, provider_summary, parse_errors, schema_errors, failed_items, missing_evidence_items)
  actions = []
  unless parse_errors.empty?
    actions << {
      "priority" => "high",
      "kind" => "fix_json",
      "title" => "Fix malformed smoke result JSON",
      "detail" => "One or more smoke result files could not be parsed; repair the JSON before judging handoff readiness.",
      "items" => parse_errors.map { |summary| summary.fetch("path") }
    }
  end
  unless schema_errors.empty?
    actions << {
      "priority" => "high",
      "kind" => "fix_schema",
      "title" => "Restore expected smoke result schemas",
      "detail" => "Smoke result files must keep the expected schema values so automated handoff checks can read them.",
      "items" => schema_errors.map { |summary| "#{summary.fetch("path")} expected #{summary.fetch("expected_schema")}" }
    }
  end
  unless failed_items.empty?
    actions << {
      "priority" => "high",
      "kind" => "resolve_failed_smoke",
      "title" => "Resolve failed smoke steps before handoff",
      "detail" => "Failed manual or provider smoke rows make the MVP handoff manual_failed until the issue is fixed or explicitly re-tested.",
      "items" => failed_items
    }
  end
  unless missing_evidence_items.empty?
    actions << {
      "priority" => "medium",
      "kind" => "add_evidence",
      "title" => "Add evidence for pass/fail smoke rows",
      "detail" => "Rows marked pass or fail need screenshots, redacted task IDs, artifact paths, or copied chat context.",
      "items" => missing_evidence_items
    }
  end
  unless manual_summary.fetch("pending_items").empty?
    actions << {
      "priority" => "medium",
      "kind" => "finish_manual_smoke",
      "title" => "Finish local manual smoke rows",
      "detail" => "Complete the local dry-run/import/Widget/review queue smoke rows in manual-smoke-results-template.json.",
      "items" => manual_summary.fetch("pending_items")
    }
  end
  unless provider_summary.fetch("pending_items").empty?
    actions << {
      "priority" => "low",
      "kind" => "record_provider_smoke_or_keep_risk",
      "title" => "Record optional provider smoke or keep the external API risk visible",
      "detail" => "If real some.im/Replicate credentials, quota, and network are available, fill provider-api-smoke-template.json; otherwise keep these rows untested as explicit remaining risk.",
      "items" => provider_summary.fetch("pending_items")
    }
  end
  if actions.empty?
    actions << {
      "priority" => "low",
      "kind" => "ready_to_handoff",
      "title" => "Smoke evidence is complete",
      "detail" => "No failed, pending, or evidence-missing smoke rows were found.",
      "items" => []
    }
  end
  actions
end

next_actions = build_next_actions(
  manual_summary,
  provider_summary,
  parse_errors,
  schema_errors,
  failed_items,
  missing_evidence_items
)

readiness = {
  "overall" => readiness_overall,
  "parse_error_count" => parse_errors.length,
  "schema_error_count" => schema_errors.length,
  "failed_count" => failed_items.length,
  "missing_evidence_count" => missing_evidence_items.length,
  "pending_count" => pending_items.length,
  "note" => "This report validates filled smoke result files only; it does not call some.im, Replicate, or any external provider."
}

report = {
  "status" => parse_errors.empty? && schema_errors.empty? ? "pass" : "fail",
  "generated_at" => Time.now.utc.iso8601,
  "package_directory" => PACKAGE_DIR,
  "manual_results_summary" => manual_summary,
  "provider_api_smoke_summary" => provider_summary,
  "readiness" => readiness,
  "next_actions" => next_actions
}

FileUtils.mkdir_p(File.dirname(REPORT_MD))
File.write(REPORT_JSON, "#{JSON.pretty_generate(report)}\n")
File.write(
  REPORT_MD,
  [
    "# Short Drama MVP Smoke Evidence Report",
    "",
    "**Status:** #{report.fetch("status")}",
    "",
    "- Package: `#{PACKAGE_DIR}`",
    "- Generated at: `#{report.fetch("generated_at")}`",
    "- Overall readiness: #{readiness.fetch("overall")}",
    "- Note: #{readiness.fetch("note")}",
    "",
    "## Manual Smoke Results",
    "",
    "- Path: `#{manual_summary.fetch("path")}`",
    "- Schema: #{manual_summary.fetch("schema")}",
    "- Steps: #{manual_summary.fetch("step_count")}",
    "- Passed: #{manual_summary.fetch("passed_count")}",
    "- Pending or untested: #{manual_summary.fetch("pending_count")}",
    "- Failed: #{manual_summary.fetch("failed_count")}",
    "- Evidence required: #{manual_summary.fetch("evidence_required_count")}",
    "- Evidence missing: #{manual_summary.fetch("evidence_missing_count")}",
    "",
    *manual_summary.fetch("failed_items").map { |item| "- Failed manual smoke: #{item}" },
    *manual_summary.fetch("evidence_missing_items").map { |item| "- Missing manual evidence: #{item}" },
    "",
    "## Provider API Smoke Results",
    "",
    "- Path: `#{provider_summary.fetch("path")}`",
    "- Schema: #{provider_summary.fetch("schema")}",
    "- Steps: #{provider_summary.fetch("step_count")}",
    "- Passed: #{provider_summary.fetch("passed_count")}",
    "- Pending or untested: #{provider_summary.fetch("pending_count")}",
    "- Failed: #{provider_summary.fetch("failed_count")}",
    "- Evidence required: #{provider_summary.fetch("evidence_required_count")}",
    "- Evidence missing: #{provider_summary.fetch("evidence_missing_count")}",
    "",
    *provider_summary.fetch("failed_items").map { |item| "- Failed provider smoke: #{item}" },
    *provider_summary.fetch("evidence_missing_items").map { |item| "- Missing provider evidence: #{item}" },
    "",
    "## Next Actions",
    "",
    *next_actions.flat_map do |action|
      [
        "- [#{action.fetch("priority")}] #{action.fetch("title")} — #{action.fetch("detail")}",
        *action.fetch("items").map { |item| "  - #{item}" }
      ]
    end,
    "",
    "## Readiness",
    "",
    "- Parse errors: #{readiness.fetch("parse_error_count")}",
    "- Schema errors: #{readiness.fetch("schema_error_count")}",
    "- Failed steps: #{readiness.fetch("failed_count")}",
    "- Missing evidence: #{readiness.fetch("missing_evidence_count")}",
    "- Pending or untested steps: #{readiness.fetch("pending_count")}",
    ""
  ].join("\n")
)

puts "short_drama_mvp_smoke_evidence_report: #{report.fetch("status")} readiness=#{readiness.fetch("overall")}"
exit(report.fetch("status") == "pass" ? 0 : 1)
