#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "time"

ROOT_DIR = File.expand_path("..", __dir__)
OUT_MD = File.expand_path(ARGV[0] || "build/ci/short_drama_mvp_smoke_evidence_contract_report.md", ROOT_DIR)
OUT_JSON = File.expand_path(ARGV[1] || "build/ci/short_drama_mvp_smoke_evidence_contract_report.json", ROOT_DIR)
WORK_DIR = File.expand_path("build/ci/short_drama_mvp_smoke_evidence_contract", ROOT_DIR)
TRYOUT_SCRIPT = File.join(ROOT_DIR, "scripts", "short_drama_mvp_tryout_package.rb")
SMOKE_SCRIPT = File.join(ROOT_DIR, "scripts", "short_drama_mvp_smoke_evidence_report.rb")
MANUAL_FILE = "manual-smoke-results-template.json"
PROVIDER_FILE = "provider-api-smoke-template.json"
FAKE_BEARER = ["Bearer", ["fake", "token", "for", "redaction", "12345"].join("-")].join(" ")

def read_json(path)
  JSON.parse(File.read(path, encoding: "UTF-8"))
end

def write_json(path, value)
  File.write(path, "#{JSON.pretty_generate(value)}\n")
end

def run_command(*args, allow_failure: false)
  stdout, stderr, status = Open3.capture3(*args)
  if !allow_failure && !status.success?
    raise "command failed: #{args.join(" ")}\nstdout:\n#{stdout}\nstderr:\n#{stderr}"
  end
  [stdout, stderr, status.exitstatus]
end

def generate_package(package_dir, report_dir)
  FileUtils.rm_rf(package_dir)
  FileUtils.mkdir_p(report_dir)
  run_command(
    "ruby",
    TRYOUT_SCRIPT,
    package_dir,
    File.join(report_dir, "tryout-report.md"),
    File.join(report_dir, "tryout-report.json")
  )
end

def update_steps(path)
  data = read_json(path)
  data["steps"] = Array(data["steps"]).each_with_index.map do |step, index|
    yield(step, index)
  end
  write_json(path, data)
end

def mark_all_steps(path, status:, evidence:)
  data = read_json(path)
  data["overall_status"] = status
  data["steps"] = Array(data["steps"]).each_with_index.map do |step, index|
    step.merge(
      "status" => status,
      "evidence" => "#{evidence} step=#{step["id"] || index}"
    )
  end
  write_json(path, data)
end

def run_smoke_report(package_dir, report_dir)
  report_md = File.join(report_dir, "smoke-evidence.md")
  report_json = File.join(report_dir, "smoke-evidence.json")
  _stdout, _stderr, exit_status = run_command(
    "ruby",
    SMOKE_SCRIPT,
    package_dir,
    report_md,
    report_json,
    allow_failure: true
  )
  [read_json(report_json), File.read(report_md, encoding: "UTF-8"), exit_status]
end

def action_kinds(report)
  Array(report["next_actions"]).map { |action| action["kind"].to_s }
end

def scenario_result(name, description)
  package_dir = File.join(WORK_DIR, name, "package")
  report_dir = File.join(WORK_DIR, name, "reports")
  generate_package(package_dir, report_dir)
  yield(package_dir)
  report, markdown, exit_status = run_smoke_report(package_dir, report_dir)
  {
    "name" => name,
    "description" => description,
    "package_dir" => package_dir,
    "report_json_path" => File.join(report_dir, "smoke-evidence.json"),
    "report_md_path" => File.join(report_dir, "smoke-evidence.md"),
    "exit_status" => exit_status,
    "readiness" => report.fetch("readiness", {}).fetch("overall", ""),
    "status" => report.fetch("status", ""),
    "action_kinds" => action_kinds(report),
    "checks" => []
  }
end

def build_default_pending
  scenario_result("default_pending", "Generated template remains manual_pending until rows are filled.") do |_package_dir|
    # No mutation: generated templates should start untested.
  end.tap do |result|
    report = read_json(result.fetch("report_json_path"))
    result.fetch("checks") << {
      "name" => "exit status is zero",
      "ok" => result.fetch("exit_status").zero?,
      "detail" => "Default unfilled templates are valid JSON and should not fail the report command."
    }
    result.fetch("checks") << {
      "name" => "readiness is manual_pending",
      "ok" => report.fetch("readiness").fetch("overall") == "manual_pending",
      "detail" => "Unfilled manual/provider smoke rows should keep handoff pending."
    }
    result.fetch("checks") << {
      "name" => "manual action is present",
      "ok" => action_kinds(report).include?("finish_manual_smoke"),
      "detail" => "Report should tell users to finish local manual smoke rows."
    }
    result.fetch("checks") << {
      "name" => "provider risk action is present",
      "ok" => action_kinds(report).include?("record_provider_smoke_or_keep_risk"),
      "detail" => "Report should keep optional real provider smoke risk visible."
    }
  end
end

def build_ready
  scenario_result("ready", "Filled manual and provider rows with sanitized evidence become ready.") do |package_dir|
    mark_all_steps(File.join(package_dir, MANUAL_FILE), status: "pass", evidence: "local artifact outputs/shot-001-main.png")
    mark_all_steps(File.join(package_dir, PROVIDER_FILE), status: "pass", evidence: "sanitized provider task id redacted-task-123")
  end.tap do |result|
    report = read_json(result.fetch("report_json_path"))
    result.fetch("checks") << {
      "name" => "readiness is ready",
      "ok" => report.fetch("readiness").fetch("overall") == "ready",
      "detail" => "All pass rows with evidence should be ready."
    }
    result.fetch("checks") << {
      "name" => "ready action is present",
      "ok" => action_kinds(report).include?("ready_to_handoff"),
      "detail" => "Ready report should emit the ready_to_handoff action."
    }
  end
end

def build_missing_evidence
  scenario_result("missing_evidence", "Pass rows without evidence stay manual_pending.") do |package_dir|
    mark_all_steps(File.join(package_dir, MANUAL_FILE), status: "pass", evidence: "local artifact outputs/shot-001-main.png")
    mark_all_steps(File.join(package_dir, PROVIDER_FILE), status: "pass", evidence: "sanitized provider task id redacted-task-123")
    update_steps(File.join(package_dir, MANUAL_FILE)) do |step, index|
      index.zero? ? step.merge("evidence" => "") : step
    end
  end.tap do |result|
    report = read_json(result.fetch("report_json_path"))
    result.fetch("checks") << {
      "name" => "missing evidence stays pending",
      "ok" => report.fetch("readiness").fetch("overall") == "manual_pending",
      "detail" => "Pass/fail rows without evidence must not be ready."
    }
    result.fetch("checks") << {
      "name" => "add evidence action is present",
      "ok" => action_kinds(report).include?("add_evidence"),
      "detail" => "Missing evidence should produce an add_evidence next action."
    }
  end
end

def build_manual_failed
  scenario_result("manual_failed", "Failed rows become manual_failed and keep evidence requirements visible.") do |package_dir|
    mark_all_steps(File.join(package_dir, MANUAL_FILE), status: "pass", evidence: "local artifact outputs/shot-001-main.png")
    mark_all_steps(File.join(package_dir, PROVIDER_FILE), status: "pass", evidence: "sanitized provider task id redacted-task-123")
    update_steps(File.join(package_dir, MANUAL_FILE)) do |step, index|
      index.zero? ? step.merge("status" => "fail", "evidence" => "screenshot local-failure-redacted.png") : step
    end
  end.tap do |result|
    report = read_json(result.fetch("report_json_path"))
    result.fetch("checks") << {
      "name" => "failure becomes manual_failed",
      "ok" => report.fetch("readiness").fetch("overall") == "manual_failed",
      "detail" => "Any failed manual/provider smoke row should block ready handoff."
    }
    result.fetch("checks") << {
      "name" => "failure action is present",
      "ok" => action_kinds(report).include?("resolve_failed_smoke"),
      "detail" => "Failed rows should produce resolve_failed_smoke next action."
    }
  end
end

def build_sensitive_blocked
  scenario_result("sensitive_blocked", "Sensitive evidence blocks handoff and redacts raw values.") do |package_dir|
    mark_all_steps(File.join(package_dir, MANUAL_FILE), status: "pass", evidence: "local artifact outputs/shot-001-main.png")
    mark_all_steps(File.join(package_dir, PROVIDER_FILE), status: "pass", evidence: "sanitized provider task id redacted-task-123")
    update_steps(File.join(package_dir, PROVIDER_FILE)) do |step, index|
      index.zero? ? step.merge("evidence" => "provider request #{FAKE_BEARER}") : step
    end
  end.tap do |result|
    report = read_json(result.fetch("report_json_path"))
    markdown = File.read(result.fetch("report_md_path"), encoding: "UTF-8")
    serialized_report = JSON.pretty_generate(report)
    result.fetch("checks") << {
      "name" => "sensitive evidence exits nonzero",
      "ok" => !result.fetch("exit_status").zero?,
      "detail" => "Sensitive evidence should fail the smoke evidence command."
    }
    result.fetch("checks") << {
      "name" => "sensitive evidence blocks readiness",
      "ok" => report.fetch("readiness").fetch("overall") == "blocked",
      "detail" => "Sensitive evidence should block handoff readiness."
    }
    result.fetch("checks") << {
      "name" => "redaction action is present",
      "ok" => action_kinds(report).include?("redact_sensitive_evidence"),
      "detail" => "Sensitive findings should produce redact_sensitive_evidence next action."
    }
    result.fetch("checks") << {
      "name" => "raw sensitive value is not emitted",
      "ok" => !markdown.include?(FAKE_BEARER) && !serialized_report.include?(FAKE_BEARER),
      "detail" => "Reports should include only field, step, and pattern kind."
    }
  end
end

FileUtils.rm_rf(WORK_DIR)
FileUtils.mkdir_p(WORK_DIR)

scenarios = [
  build_default_pending,
  build_ready,
  build_missing_evidence,
  build_manual_failed,
  build_sensitive_blocked
]

checks = scenarios.flat_map do |scenario|
  scenario.fetch("checks").map do |check|
    check.merge("scenario" => scenario.fetch("name"))
  end
end
ok = checks.all? { |check| check.fetch("ok") }
report = {
  "status" => ok ? "pass" : "fail",
  "generated_at" => Time.now.utc.iso8601,
  "scenario_count" => scenarios.length,
  "scenarios" => scenarios,
  "checks" => checks
}

FileUtils.mkdir_p(File.dirname(OUT_MD))
write_json(OUT_JSON, report)
File.write(
  OUT_MD,
  [
    "# Short Drama MVP Smoke Evidence Contract",
    "",
    "**Status:** #{report.fetch("status")}",
    "",
    "- Scenarios: #{scenarios.length}",
    "- Checks: #{checks.length}",
    "",
    "## Scenarios",
    "",
    *scenarios.map do |scenario|
      "- #{scenario.fetch("name")}: #{scenario.fetch("readiness")} / #{scenario.fetch("status")} / exit #{scenario.fetch("exit_status")}"
    end,
    "",
    "## Checks",
    "",
    *checks.map { |check| "- #{check.fetch("ok") ? "[x]" : "[ ]"} #{check.fetch("scenario")} — #{check.fetch("name")}: #{check.fetch("detail")}" },
    ""
  ].join("\n")
)

puts "short_drama_mvp_smoke_evidence_contract: #{report.fetch("status")} scenarios=#{scenarios.length} checks=#{checks.length}"
exit(ok ? 0 : 1)
