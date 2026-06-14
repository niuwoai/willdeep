#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "time"

ROOT_DIR = File.expand_path("..", __dir__)
DEFAULT_ANDROID_DIR = File.expand_path("../willdeep-android", ROOT_DIR)
ANDROID_DIR = ENV.fetch("WILLDEEP_ANDROID_DIR", DEFAULT_ANDROID_DIR)
READINESS_SCRIPT = File.join(ROOT_DIR, "scripts", "mobile_gateway_live_readiness.rb")
READINESS_REPORT_JSON = File.join(ROOT_DIR, "build", "mobile_gateway_live_readiness", "report.json")
ANDROID_ACCEPTANCE_SCRIPT = File.join(ANDROID_DIR, "scripts", "mobile_gateway_live_acceptance.rb")
ANDROID_ACCEPTANCE_REPORT_JSON = File.join(ANDROID_DIR, "build", "mobile_gateway_live_acceptance", "report.json")
OUT_DIR = File.join(ROOT_DIR, "build", "mobile_gateway_end_to_end_acceptance")
REPORT_JSON = File.join(OUT_DIR, "report.json")
REPORT_MD = File.join(OUT_DIR, "report.md")

def run_command(*command, chdir:)
  stdout, stderr, status = Open3.capture3(*command, chdir: chdir)
  {
    command: command.join(" "),
    cwd: chdir,
    exit_code: status.exitstatus,
    stdout: stdout.strip,
    stderr: stderr.strip,
  }
end

def read_json(path)
  JSON.parse(File.read(path))
rescue Errno::ENOENT
  {
    "status" => "failed",
    "error" => "report not generated: #{path}",
    "acceptance_evidence" => [],
    "next_actions" => [],
  }
end

def evidence_status(report)
  report.fetch("acceptance_evidence", []).map { |item| item["status"] }.uniq
end

def build_acceptance_evidence(readiness, android, android_ran)
  evidence = []
  readiness.fetch("acceptance_evidence", []).each do |item|
    key = item.fetch("key")
    evidence << item.merge("key" => key.start_with?("mac_") ? key : "mac_#{key}")
  end
  if android_ran
    android.fetch("acceptance_evidence", []).each do |item|
      evidence << item.merge("key" => "android_#{item.fetch("key")}")
    end
  else
    evidence << {
      "key" => "android_live_acceptance",
      "status" => "skipped",
      "evidence" => "Mac readiness did not pass, so Android live acceptance was not run.",
    }
  end
  evidence
end

def merged_next_actions(readiness, android, android_ran)
  actions = readiness.fetch("next_actions", [])
  actions += android.fetch("next_actions", []) if android_ran
  actions.uniq
end

def write_reports(report)
  FileUtils.mkdir_p(OUT_DIR)
  File.write(REPORT_JSON, JSON.pretty_generate(report) + "\n")
  lines = [
    "# Mobile Gateway End-to-End Acceptance",
    "",
    "- Generated at: `#{report[:generated_at]}`",
    "- Status: `#{report[:status]}`",
    "- Mac readiness: `#{report[:mac_readiness_status]}`",
    "- Android live acceptance: `#{report[:android_live_acceptance_status]}`",
    "- Android repo: `#{report[:android_dir]}`",
    "",
    "## Acceptance Evidence",
    "",
    "| Requirement | Status | Evidence |",
    "| --- | --- | --- |",
  ]
  report[:acceptance_evidence].each do |item|
    lines << "| `#{item.fetch("key")}` | `#{item.fetch("status")}` | #{item.fetch("evidence").to_s.gsub("|", "\\|")} |"
  end
  unless report[:next_actions].empty?
    lines << ""
    lines << "## Next Actions"
    lines << ""
    report[:next_actions].each { |action| lines << "- #{action}" }
  end
  lines << ""
  File.write(REPORT_MD, lines.join("\n"))
end

readiness_run = run_command("ruby", READINESS_SCRIPT, chdir: ROOT_DIR)
readiness_report = read_json(READINESS_REPORT_JSON)
android_ran = readiness_report["status"] == "passed"
android_run = nil
android_report = nil

if android_ran
  unless File.file?(ANDROID_ACCEPTANCE_SCRIPT)
    android_run = {
      command: "ruby #{ANDROID_ACCEPTANCE_SCRIPT}",
      cwd: ANDROID_DIR,
      exit_code: 127,
      stdout: "",
      stderr: "Android live acceptance script not found.",
    }
    android_report = {
      "status" => "failed",
      "error" => "Android live acceptance script not found.",
      "acceptance_evidence" => [],
      "next_actions" => ["Set WILLDEEP_ANDROID_DIR to the willdeep-android repository path."],
    }
  else
    android_run = run_command("ruby", ANDROID_ACCEPTANCE_SCRIPT, chdir: ANDROID_DIR)
    android_report = read_json(ANDROID_ACCEPTANCE_REPORT_JSON)
  end
else
  android_report = {
    "status" => "skipped",
    "acceptance_evidence" => [],
    "next_actions" => [],
  }
end

acceptance_evidence = build_acceptance_evidence(readiness_report, android_report, android_ran)
status = acceptance_evidence.all? { |item| item["status"] == "passed" } ? "passed" : "failed"
report = {
  generated_at: Time.now.utc.iso8601,
  status: status,
  android_dir: ANDROID_DIR,
  mac_readiness_status: readiness_report["status"],
  android_live_acceptance_status: android_report["status"],
  mac_readiness_report_json: READINESS_REPORT_JSON,
  android_live_acceptance_report_json: android_ran ? ANDROID_ACCEPTANCE_REPORT_JSON : nil,
  command_runs: {
    mac_readiness: readiness_run,
    android_live_acceptance: android_run,
  },
  mac_readiness_evidence_statuses: evidence_status(readiness_report),
  android_evidence_statuses: android_ran ? evidence_status(android_report) : ["skipped"],
  acceptance_evidence: acceptance_evidence,
  next_actions: merged_next_actions(readiness_report, android_report, android_ran),
}

write_reports(report)
puts "Wrote #{REPORT_JSON}"
puts "Wrote #{REPORT_MD}"
exit(status == "passed" ? 0 : 1)
