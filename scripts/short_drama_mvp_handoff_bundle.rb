#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "time"

ROOT_DIR = File.expand_path("..", __dir__)
ACCEPTANCE_JSON = File.expand_path(ARGV[0] || "build/ci/short_drama_mvp_acceptance_report.json", ROOT_DIR)
OUT_MD = File.expand_path(ARGV[1] || "build/ci/short_drama_mvp_handoff_bundle.md", ROOT_DIR)
OUT_JSON = File.expand_path(ARGV[2] || "build/ci/short_drama_mvp_handoff_bundle.json", ROOT_DIR)

def read_json(path)
  JSON.parse(File.read(path, encoding: "UTF-8"))
rescue Errno::ENOENT, JSON::ParserError => e
  {
    "status" => "missing",
    "error" => e.message,
    "path" => path
  }
end

def array_values(value)
  value.is_a?(Array) ? value : []
end

def hash_value(value)
  value.is_a?(Hash) ? value : {}
end

def relative_path(path)
  path.to_s.sub(%r{\A#{Regexp.escape(ROOT_DIR)}/?}, "")
end

acceptance = read_json(ACCEPTANCE_JSON)
handoff_readiness = hash_value(acceptance["handoff_readiness"])
pending_reasons = array_values(acceptance["handoff_pending_reasons"])
remaining_risks = array_values(acceptance["remaining_risks"])
evidence = array_values(acceptance["evidence"])
checks = array_values(acceptance["checks"])
smoke_next_actions = array_values(acceptance["smoke_evidence_next_actions"])
handoff_index = hash_value(acceptance["handoff_index"])
acceptance_runbook = hash_value(acceptance["acceptance_runbook"])

machine_status = handoff_readiness["machine_status"].to_s
manual_status = handoff_readiness["manual_status"].to_s
overall = handoff_readiness["overall"].to_s
machine_passed = acceptance["status"].to_s == "pass" && checks.all? { |check| check["ok"] }
ready_for_release = machine_passed && overall == "ready"
trial_package = machine_passed && %w[manual_pending manual_failed blocked].include?(overall)
handoff_mode =
  if ready_for_release
    "ready_release_candidate"
  elsif trial_package
    "trial_package_with_explicit_pending_reasons"
  else
    "blocked_machine_handoff"
  end

required_evidence_labels = [
  "Tryout package",
  "Handoff index Markdown",
  "Handoff index JSON",
  "Acceptance runbook Markdown",
  "Acceptance runbook JSON",
  "Manual smoke results JSON",
  "Provider API smoke JSON",
  "Smoke evidence report JSON",
  "Smoke evidence contract JSON",
  "Cutoff",
  "Tryout guide",
  "Manual queue"
]

evidence_by_label = evidence.to_h { |item| [item["label"].to_s, item["path"].to_s] }
missing_evidence_labels = required_evidence_labels.reject do |label|
  path = evidence_by_label[label].to_s
  !path.empty? && File.exist?(path)
end

handoff_files = required_evidence_labels.filter_map do |label|
  path = evidence_by_label[label].to_s
  next if path.empty?

  {
    "label" => label,
    "path" => path,
    "relative_path" => relative_path(path),
    "exists" => File.exist?(path)
  }
end

blocking_items = []
unless machine_passed
  failed_checks = checks.reject { |check| check["ok"] }.map { |check| check["name"].to_s }
  blocking_items << {
    "severity" => "high",
    "kind" => "machine_checks_failed",
    "title" => "Fix failing machine checks",
    "items" => failed_checks.empty? ? [acceptance["error"].to_s].reject(&:empty?) : failed_checks
  }
end
unless missing_evidence_labels.empty?
  blocking_items << {
    "severity" => "high",
    "kind" => "handoff_evidence_missing",
    "title" => "Regenerate missing handoff evidence files",
    "items" => missing_evidence_labels
  }
end
if %w[manual_failed blocked].include?(overall)
  blocking_items << {
    "severity" => "high",
    "kind" => "handoff_not_release_ready",
    "title" => "Resolve non-ready handoff state",
    "items" => pending_reasons.map { |reason| reason["title"].to_s }.reject(&:empty?)
  }
end

next_actions = []
if ready_for_release
  next_actions << {
    "priority" => "low",
    "kind" => "release_candidate_ready",
    "title" => "Release candidate can be handed off as ready",
    "detail" => "Machine gates passed, manual/provider smoke evidence is complete, and no blocking risk is reported."
  }
elsif machine_passed
  pending_reasons.each do |reason|
    next_actions << {
      "priority" => reason["severity"].to_s.empty? ? "medium" : reason["severity"].to_s,
      "kind" => reason["kind"].to_s,
      "title" => reason["title"].to_s,
      "detail" => reason["detail"].to_s,
      "items" => array_values(reason["items"])
    }
  end
else
  next_actions << {
    "priority" => "high",
    "kind" => "rerun_acceptance",
    "title" => "Fix acceptance report before handoff",
    "detail" => "The acceptance report is missing or failed; run scripts/run_tests.sh or regenerate the short-drama reports.",
    "items" => [ACCEPTANCE_JSON]
  }
end

next_actions.concat(
  smoke_next_actions.map do |action|
    {
      "priority" => action["priority"].to_s,
      "kind" => "smoke_evidence_#{action["kind"]}",
      "title" => action["title"].to_s,
      "detail" => action["detail"].to_s,
      "items" => array_values(action["items"])
    }
  end
)

checks_for_bundle = [
  {
    "name" => "acceptance report is readable",
    "ok" => acceptance["status"].to_s != "missing",
    "detail" => "short_drama_mvp_handoff_bundle reads the acceptance JSON."
  },
  {
    "name" => "acceptance machine checks passed",
    "ok" => machine_passed,
    "detail" => "Acceptance report status is pass and every embedded check is ok."
  },
  {
    "name" => "handoff readiness is explicit",
    "ok" => %w[ready manual_pending manual_failed blocked].include?(overall),
    "detail" => "Handoff bundle must not hide readiness behind a generic pass/fail."
  },
  {
    "name" => "handoff evidence files exist",
    "ok" => missing_evidence_labels.empty?,
    "detail" => "Required handoff files should exist before uploading CI artifacts."
  },
  {
    "name" => "remaining risks are preserved",
    "ok" => remaining_risks.any?,
    "detail" => "The bundle should keep external API/manual smoke risks visible."
  },
  {
    "name" => "runbook and handoff index are included",
    "ok" => array_values(handoff_index["start_here"]).any? &&
            array_values(acceptance_runbook["commands"]).any?,
    "detail" => "The bundle should point at the package-local handoff index and acceptance runbook."
  }
]

bundle_pass = checks_for_bundle.all? { |check| check["ok"] }
report = {
  "status" => bundle_pass ? "pass" : "fail",
  "generated_at" => Time.now.utc.iso8601,
  "version" => acceptance["version"].to_s,
  "acceptance_report_path" => ACCEPTANCE_JSON,
  "handoff_mode" => handoff_mode,
  "ready_for_release" => ready_for_release,
  "machine_passed" => machine_passed,
  "readiness" => {
    "machine_status" => machine_status,
    "manual_status" => manual_status,
    "overall" => overall,
    "note" => handoff_readiness["note"].to_s
  },
  "checks" => checks_for_bundle,
  "blocking_items" => blocking_items,
  "next_actions" => next_actions,
  "handoff_files" => handoff_files,
  "remaining_risks" => remaining_risks
}

FileUtils.mkdir_p(File.dirname(OUT_JSON))
FileUtils.mkdir_p(File.dirname(OUT_MD))
File.write(OUT_JSON, "#{JSON.pretty_generate(report)}\n")
File.write(
  OUT_MD,
  [
    "# Short Drama MVP Handoff Bundle",
    "",
    "**Status:** #{report.fetch("status")}",
    "",
    "- Version: `#{report.fetch("version")}`",
    "- Handoff mode: #{handoff_mode}",
    "- Ready for release: #{ready_for_release}",
    "- Machine passed: #{machine_passed}",
    "- Overall readiness: #{overall}",
    "- Acceptance report: `#{ACCEPTANCE_JSON}`",
    "",
    "## Checks",
    "",
    *checks_for_bundle.map { |check| "- #{check.fetch("ok") ? "[x]" : "[ ]"} #{check.fetch("name")} — #{check.fetch("detail")}" },
    "",
    "## Blocking Items",
    "",
    *(blocking_items.empty? ? ["- No blocking machine items."] : blocking_items.flat_map do |item|
      [
        "- [#{item.fetch("severity")}] #{item.fetch("title")} (#{item.fetch("kind")})",
        *array_values(item["items"]).map { |entry| "  - #{entry}" }
      ]
    end),
    "",
    "## Next Actions",
    "",
    *next_actions.flat_map do |action|
      [
        "- [#{action.fetch("priority")}] #{action.fetch("title")} — #{action.fetch("detail")}",
        *array_values(action["items"]).map { |item| "  - #{item}" }
      ]
    end,
    "",
    "## Handoff Files",
    "",
    *handoff_files.map { |item| "- #{item.fetch("label")}: `#{item.fetch("path")}` #{item.fetch("exists") ? "" : "(missing)"}" },
    "",
    "## Remaining Risks",
    "",
    *remaining_risks.map { |risk| "- #{risk}" },
    ""
  ].join("\n")
)

puts "short_drama_mvp_handoff_bundle: #{report.fetch("status")} mode=#{handoff_mode} ready=#{ready_for_release}"
exit(bundle_pass ? 0 : 1)
