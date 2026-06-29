#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "time"

ROOT_DIR = File.expand_path("..", __dir__)
OUT_MD = File.expand_path(ARGV[0] || "build/ci/short_drama_mvp_handoff_bundle_contract_report.md", ROOT_DIR)
OUT_JSON = File.expand_path(ARGV[1] || "build/ci/short_drama_mvp_handoff_bundle_contract_report.json", ROOT_DIR)
WORK_DIR = File.expand_path("build/ci/short_drama_mvp_handoff_bundle_contract", ROOT_DIR)
TRYOUT_SCRIPT = File.join(ROOT_DIR, "scripts", "short_drama_mvp_tryout_package.rb")
VERSION_SCRIPT = File.join(ROOT_DIR, "scripts", "version_consistency.rb")
SMOKE_SCRIPT = File.join(ROOT_DIR, "scripts", "short_drama_mvp_smoke_evidence_report.rb")
SMOKE_CONTRACT_SCRIPT = File.join(ROOT_DIR, "scripts", "short_drama_mvp_smoke_evidence_contract_test.rb")
ACCEPTANCE_SCRIPT = File.join(ROOT_DIR, "scripts", "short_drama_mvp_acceptance_report.rb")
HANDOFF_SCRIPT = File.join(ROOT_DIR, "scripts", "short_drama_mvp_handoff_bundle.rb")

def read_json(path)
  JSON.parse(File.read(path, encoding: "UTF-8"))
end

def write_json(path, value)
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, "#{JSON.pretty_generate(value)}\n")
end

def run_command(*args, allow_failure: false)
  stdout, stderr, status = Open3.capture3(*args)
  if !allow_failure && !status.success?
    raise "command failed: #{args.join(" ")}\nstdout:\n#{stdout}\nstderr:\n#{stderr}"
  end
  [stdout, stderr, status.exitstatus]
end

def prepare_base_acceptance(base_dir)
  package_dir = File.join(base_dir, "package")
  reports_dir = File.join(base_dir, "reports")
  FileUtils.rm_rf(base_dir)
  FileUtils.mkdir_p(reports_dir)

  run_command(
    "ruby",
    VERSION_SCRIPT,
    File.join(reports_dir, "version_report.md"),
    File.join(reports_dir, "version_report.json")
  )
  run_command(
    "ruby",
    TRYOUT_SCRIPT,
    package_dir,
    File.join(reports_dir, "short_drama_mvp_tryout_package_report.md"),
    File.join(reports_dir, "short_drama_mvp_tryout_package_report.json")
  )
  run_command(
    "ruby",
    SMOKE_SCRIPT,
    package_dir,
    File.join(reports_dir, "short_drama_mvp_smoke_evidence_report.md"),
    File.join(reports_dir, "short_drama_mvp_smoke_evidence_report.json")
  )
  run_command(
    "ruby",
    SMOKE_CONTRACT_SCRIPT,
    File.join(reports_dir, "short_drama_mvp_smoke_evidence_contract_report.md"),
    File.join(reports_dir, "short_drama_mvp_smoke_evidence_contract_report.json")
  )
  run_command(
    "ruby",
    ACCEPTANCE_SCRIPT,
    File.join(reports_dir, "short_drama_mvp_acceptance_report.md"),
    File.join(reports_dir, "short_drama_mvp_acceptance_report.json")
  )

  File.join(reports_dir, "short_drama_mvp_acceptance_report.json")
end

def run_handoff(acceptance_path, scenario_dir)
  md_path = File.join(scenario_dir, "handoff.md")
  json_path = File.join(scenario_dir, "handoff.json")
  _stdout, _stderr, exit_status = run_command(
    "ruby",
    HANDOFF_SCRIPT,
    acceptance_path,
    md_path,
    json_path,
    allow_failure: true
  )
  [read_json(json_path), md_path, json_path, exit_status]
end

def action_kinds(report)
  Array(report["next_actions"]).map { |action| action["kind"].to_s }
end

def blocking_kinds(report)
  Array(report["blocking_items"]).map { |item| item["kind"].to_s }
end

def handoff_files(report)
  Array(report["handoff_files"])
end

def handoff_todos(report)
  Array(report["handoff_todos"])
end

def todo_phases(report)
  handoff_todos(report).map { |todo| todo["phase"].to_s }
end

def todo_evidence_labels(report)
  handoff_todos(report).flat_map do |todo|
    Array(todo["evidence_paths"]).map { |item| item["label"].to_s }
  end
end

def scenario(name, description, base_acceptance_path)
  scenario_dir = File.join(WORK_DIR, name)
  FileUtils.rm_rf(scenario_dir)
  FileUtils.mkdir_p(scenario_dir)
  acceptance_path = File.join(scenario_dir, "acceptance.json")
  data = read_json(base_acceptance_path)
  yield(data)
  write_json(acceptance_path, data)
  report, md_path, json_path, exit_status = run_handoff(acceptance_path, scenario_dir)
  {
    "name" => name,
    "description" => description,
    "acceptance_path" => acceptance_path,
    "report_md_path" => md_path,
    "report_json_path" => json_path,
    "exit_status" => exit_status,
    "status" => report["status"].to_s,
    "handoff_mode" => report["handoff_mode"].to_s,
    "ready_for_release" => report["ready_for_release"] == true,
    "action_kinds" => action_kinds(report),
    "blocking_kinds" => blocking_kinds(report),
    "checks" => []
  }
end

def build_default_trial(base_acceptance_path)
  scenario(
    "default_trial",
    "Default unfilled package stays a trial package with explicit pending reasons.",
    base_acceptance_path
  ) do |_data|
    # Keep the default acceptance report generated from unfilled manual/provider templates.
  end.tap do |result|
    result.fetch("checks") << {
      "name" => "command exits zero",
      "ok" => result.fetch("exit_status").zero?,
      "detail" => "Manual pending handoff should still produce a usable bundle."
    }
    result.fetch("checks") << {
      "name" => "mode is trial package",
      "ok" => result.fetch("handoff_mode") == "trial_package_with_explicit_pending_reasons",
      "detail" => "Default package should not be mistaken for ready."
    }
    result.fetch("checks") << {
      "name" => "ready flag is false",
      "ok" => result.fetch("ready_for_release") == false,
      "detail" => "Unfilled smoke evidence cannot be release-ready."
    }
    report = read_json(result.fetch("report_json_path"))
    file_entries = handoff_files(report).select { |item| item["kind"].to_s == "file" }
    directory_entries = handoff_files(report).select { |item| item["kind"].to_s == "directory" }
    result.fetch("checks") << {
      "name" => "handoff files include fingerprints",
      "ok" => file_entries.any? &&
              file_entries.all? do |item|
                item["size_bytes"].is_a?(Integer) && item["size_bytes"].positive? &&
                  item["sha256"].to_s.match?(/\A[0-9a-f]{64}\z/)
              end &&
              directory_entries.any? &&
              directory_entries.all? { |item| item["file_count"].is_a?(Integer) && item["file_count"].positive? },
      "detail" => "Bundle should include SHA-256 fingerprints for files and file counts for package directories."
    }
    result.fetch("checks") << {
      "name" => "handoff todos include manual provider and verify phases",
      "ok" => handoff_todos(report).any? &&
              handoff_todos(report).all? do |todo|
                todo["order"].is_a?(Integer) &&
                  !todo["kind"].to_s.empty? &&
                  !todo["title"].to_s.empty? &&
                  !todo["command"].to_s.empty? &&
                  !todo["verification_command"].to_s.empty? &&
                  Array(todo["evidence_paths"]).any?
              end &&
              todo_phases(report).include?("manual_smoke") &&
              todo_phases(report).include?("provider_smoke") &&
              todo_phases(report).include?("verify"),
      "detail" => "Default trial bundle should give operators ordered manual smoke, provider smoke, and regeneration todos."
    }
    result.fetch("checks") << {
      "name" => "handoff todos point at evidence files",
      "ok" => todo_evidence_labels(report).include?("Manual smoke results JSON") &&
              todo_evidence_labels(report).include?("Provider API smoke JSON") &&
              todo_evidence_labels(report).include?("Smoke evidence report JSON") &&
              handoff_todos(report).any? do |todo|
                todo["verification_command"].to_s.include?("short_drama_mvp_smoke_evidence_report.rb")
              end,
      "detail" => "Default trial todos should point at the manual/provider evidence JSON files and smoke evidence verification command."
    }
  end
end

def build_ready_release(base_acceptance_path)
  scenario(
    "ready_release",
    "Ready acceptance report becomes a release-candidate handoff.",
    base_acceptance_path
  ) do |data|
    data["handoff_readiness"] = data.fetch("handoff_readiness").merge(
      "manual_status" => "pass",
      "overall" => "ready"
    )
    data["handoff_pending_reasons"] = [
      {
        "severity" => "low",
        "kind" => "ready_to_handoff",
        "title" => "No pending handoff reasons",
        "detail" => "All handoff evidence is complete.",
        "items" => []
      }
    ]
  end.tap do |result|
    result.fetch("checks") << {
      "name" => "mode is ready release candidate",
      "ok" => result.fetch("handoff_mode") == "ready_release_candidate",
      "detail" => "Ready acceptance should become a ready release candidate."
    }
    result.fetch("checks") << {
      "name" => "ready flag is true",
      "ok" => result.fetch("ready_for_release") == true,
      "detail" => "Ready acceptance should set ready_for_release=true."
    }
    result.fetch("checks") << {
      "name" => "release action is present",
      "ok" => result.fetch("action_kinds").include?("release_candidate_ready"),
      "detail" => "Ready bundle should tell handoff users it can be released."
    }
    report = read_json(result.fetch("report_json_path"))
    result.fetch("checks") << {
      "name" => "release todo is present",
      "ok" => todo_phases(report).include?("release") &&
              handoff_todos(report).any? do |todo|
                todo["kind"].to_s == "release_candidate_handoff" &&
                  todo["verification_command"].to_s.include?("short_drama_mvp_handoff_bundle_contract_test.rb") &&
                  Array(todo["evidence_paths"]).any?
              end,
      "detail" => "Ready bundle should expose a release-phase handoff todo."
    }
  end
end

def build_manual_failed(base_acceptance_path)
  scenario(
    "manual_failed",
    "Manual failed acceptance remains a trial bundle and lists the blocking handoff state.",
    base_acceptance_path
  ) do |data|
    data["handoff_readiness"] = data.fetch("handoff_readiness").merge(
      "manual_status" => "failed",
      "overall" => "manual_failed"
    )
    data["handoff_pending_reasons"] = [
      {
        "severity" => "high",
        "kind" => "package_manual_failed",
        "title" => "Resolve failed manual smoke",
        "detail" => "A manual smoke row failed.",
        "items" => ["Dry-run import"]
      }
    ]
  end.tap do |result|
    result.fetch("checks") << {
      "name" => "manual failed keeps trial mode",
      "ok" => result.fetch("handoff_mode") == "trial_package_with_explicit_pending_reasons",
      "detail" => "Manual failures are explicit handoff work, not machine acceptance failure."
    }
    result.fetch("checks") << {
      "name" => "non-ready blocking item is present",
      "ok" => result.fetch("blocking_kinds").include?("handoff_not_release_ready"),
      "detail" => "Manual failures should be visible in blocking_items."
    }
  end
end

def build_machine_failed(base_acceptance_path)
  scenario(
    "machine_failed",
    "Failed machine checks block the handoff bundle.",
    base_acceptance_path
  ) do |data|
    data["status"] = "fail"
    data["checks"] = Array(data["checks"]).map.with_index do |check, index|
      index.zero? ? check.merge("ok" => false, "name" => "forced failing acceptance check") : check
    end
  end.tap do |result|
    result.fetch("checks") << {
      "name" => "command exits nonzero",
      "ok" => !result.fetch("exit_status").zero?,
      "detail" => "Machine acceptance failure should fail the bundle command."
    }
    result.fetch("checks") << {
      "name" => "mode is blocked machine handoff",
      "ok" => result.fetch("handoff_mode") == "blocked_machine_handoff",
      "detail" => "Machine failures should not be emitted as trial package."
    }
    result.fetch("checks") << {
      "name" => "machine blocking item is present",
      "ok" => result.fetch("blocking_kinds").include?("machine_checks_failed"),
      "detail" => "Failed checks should be visible in blocking_items."
    }
  end
end

def build_missing_evidence(base_acceptance_path)
  scenario(
    "missing_handoff_evidence",
    "Missing required handoff files fail the bundle command.",
    base_acceptance_path
  ) do |data|
    data["evidence"] = Array(data["evidence"]).map do |item|
      item["label"].to_s == "Tryout guide" ? item.merge("path" => File.join(WORK_DIR, "missing-tryout-guide.md")) : item
    end
  end.tap do |result|
    result.fetch("checks") << {
      "name" => "command exits nonzero",
      "ok" => !result.fetch("exit_status").zero?,
      "detail" => "Missing required evidence files should fail the bundle command."
    }
    result.fetch("checks") << {
      "name" => "missing evidence blocking item is present",
      "ok" => result.fetch("blocking_kinds").include?("handoff_evidence_missing"),
      "detail" => "Missing handoff evidence should be visible in blocking_items."
    }
  end
end

FileUtils.rm_rf(WORK_DIR)
FileUtils.mkdir_p(WORK_DIR)
base_acceptance_path = prepare_base_acceptance(File.join(WORK_DIR, "base"))

scenarios = [
  build_default_trial(base_acceptance_path),
  build_ready_release(base_acceptance_path),
  build_manual_failed(base_acceptance_path),
  build_machine_failed(base_acceptance_path),
  build_missing_evidence(base_acceptance_path)
]

checks = scenarios.flat_map do |item|
  item.fetch("checks").map { |check| check.merge("scenario" => item.fetch("name")) }
end
ok = checks.all? { |check| check.fetch("ok") }
report = {
  "status" => ok ? "pass" : "fail",
  "generated_at" => Time.now.utc.iso8601,
  "base_acceptance_path" => base_acceptance_path,
  "scenario_count" => scenarios.length,
  "scenarios" => scenarios,
  "checks" => checks
}

FileUtils.mkdir_p(File.dirname(OUT_JSON))
FileUtils.mkdir_p(File.dirname(OUT_MD))
write_json(OUT_JSON, report)
File.write(
  OUT_MD,
  [
    "# Short Drama MVP Handoff Bundle Contract",
    "",
    "**Status:** #{report.fetch("status")}",
    "",
    "- Scenarios: #{scenarios.length}",
    "- Checks: #{checks.length}",
    "",
    "## Scenarios",
    "",
    *scenarios.map do |item|
      "- #{item.fetch("name")}: #{item.fetch("handoff_mode")} / ready=#{item.fetch("ready_for_release")} / status=#{item.fetch("status")} / exit #{item.fetch("exit_status")}"
    end,
    "",
    "## Checks",
    "",
    *checks.map { |check| "- #{check.fetch("ok") ? "[x]" : "[ ]"} #{check.fetch("scenario")} — #{check.fetch("name")}: #{check.fetch("detail")}" },
    ""
  ].join("\n")
)

puts "short_drama_mvp_handoff_bundle_contract: #{report.fetch("status")} scenarios=#{scenarios.length} checks=#{checks.length}"
exit(ok ? 0 : 1)
