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

def parse_adb_devices(output)
  output.lines.drop(1).filter_map do |line|
    serial, state = line.strip.split(/\s+/, 2)
    next if serial.to_s.empty?

    {
      "serial" => serial,
      "state" => state.to_s,
    }
  end
end

def android_preflight
  repo_present = Dir.exist?(ANDROID_DIR)
  script_present = File.file?(ANDROID_ACCEPTANCE_SCRIPT)
  adb_run = run_command("adb", "devices", chdir: repo_present ? ANDROID_DIR : ROOT_DIR)
  devices = adb_run[:exit_code].zero? ? parse_adb_devices(adb_run[:stdout]) : []
  ready_devices = devices.select { |device| device["state"] == "device" }
  status = repo_present && script_present && ready_devices.any? ? "passed" : "failed"

  {
    "status" => status,
    "repo_present" => repo_present,
    "acceptance_script_present" => script_present,
    "adb_exit_code" => adb_run[:exit_code],
    "ready_device_count" => ready_devices.size,
    "devices" => devices,
    "command_run" => adb_run,
  }
rescue Errno::ENOENT => e
  {
    "status" => "failed",
    "repo_present" => Dir.exist?(ANDROID_DIR),
    "acceptance_script_present" => File.file?(ANDROID_ACCEPTANCE_SCRIPT),
    "adb_exit_code" => 127,
    "ready_device_count" => 0,
    "devices" => [],
    "error" => e.message,
    "command_run" => {
      command: "adb devices",
      cwd: Dir.exist?(ANDROID_DIR) ? ANDROID_DIR : ROOT_DIR,
      exit_code: 127,
      stdout: "",
      stderr: e.message,
    },
  }
end

def android_preflight_evidence(preflight)
  repo_status = preflight.fetch("repo_present") && preflight.fetch("acceptance_script_present") ? "passed" : "failed"
  device_count = preflight.fetch("ready_device_count")

  [
    {
      "key" => "android_repo",
      "status" => repo_status,
      "evidence" => repo_status == "passed" ? "Android repo and live acceptance script found at #{ANDROID_DIR}." : "Android repo or live acceptance script is missing at #{ANDROID_DIR}.",
    },
    {
      "key" => "android_device",
      "status" => device_count.positive? ? "passed" : "failed",
      "evidence" => "#{device_count} ready Android device(s) reported by adb.",
    },
  ]
end

def build_acceptance_evidence(readiness, android, android_ran, android_preflight_report)
  evidence = []
  readiness.fetch("acceptance_evidence", []).each do |item|
    key = item.fetch("key")
    evidence << item.merge("key" => key.start_with?("mac_") ? key : "mac_#{key}")
  end
  evidence.concat(android_preflight_evidence(android_preflight_report))
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
    "- Android preflight: `#{report[:android_preflight_status]}`",
    "- Android live acceptance: `#{report[:android_live_acceptance_status]}`",
    "- Android ready devices: `#{report[:android_ready_device_count]}`",
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
android_preflight_report = android_preflight
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

acceptance_evidence = build_acceptance_evidence(readiness_report, android_report, android_ran, android_preflight_report)
status = acceptance_evidence.all? { |item| item["status"] == "passed" } ? "passed" : "failed"
report = {
  generated_at: Time.now.utc.iso8601,
  status: status,
  android_dir: ANDROID_DIR,
  mac_readiness_status: readiness_report["status"],
  android_preflight_status: android_preflight_report["status"],
  android_ready_device_count: android_preflight_report["ready_device_count"],
  android_live_acceptance_status: android_report["status"],
  mac_readiness_report_json: READINESS_REPORT_JSON,
  android_live_acceptance_report_json: android_ran ? ANDROID_ACCEPTANCE_REPORT_JSON : nil,
  android_preflight: android_preflight_report,
  command_runs: {
    mac_readiness: readiness_run,
    android_preflight: android_preflight_report["command_run"],
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
