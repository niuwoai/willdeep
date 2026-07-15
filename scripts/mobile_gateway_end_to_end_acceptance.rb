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
ANDROID_CONNECTED_SMOKE_SCRIPT = File.join(ANDROID_DIR, "scripts", "android_connected_smoke_test.rb")
ANDROID_AGENT_ACTIVITY_EVIDENCE = File.join(ANDROID_DIR, "app", "src", "main", "java", "com", "willdeep", "android", "ui", "AgentActivityEvidence.kt")
ANDROID_AGENT_ACTIVITY_EVIDENCE_TEST = File.join(ANDROID_DIR, "app", "src", "test", "java", "com", "willdeep", "android", "ui", "AgentActivityEvidenceTest.kt")
ANDROID_ACCEPTANCE_REPORT_JSON = File.join(ANDROID_DIR, "build", "mobile_gateway_live_acceptance", "report.json")
OUT_DIR = File.join(ROOT_DIR, "build", "mobile_gateway_end_to_end_acceptance")
REPORT_JSON = File.join(OUT_DIR, "report.json")
REPORT_MD = File.join(OUT_DIR, "report.md")
ANDROID_REQUIRED_FINAL_EVIDENCE = %w[
  live_pairing_payload
  mac_gateway_health
  android_device
  device_gateway_reachability
  instrumented_pair_and_ws
  mobile_message_send_ack
  mac_agent_activity_after_send
  mac_code_activity_after_send
  mac_target_file_after_send
].freeze
EXPECTED_ANDROID_LIVE_REQUEST_PROFILE = "default_workspace_file_edit"
EXPECTED_ANDROID_LIVE_TARGET_FILE = "WILLDEEP_ANDROID_LIVE_ACCEPTANCE.md"
ANDROID_CODE_ACTIVITY_CONTRACT_CHECKS = %w[
  live_acceptance_script_present
  connected_smoke_script_present
  wrapper_enables_code_activity
  smoke_requires_code_activity_evidence
  smoke_requires_code_activity_marker
].freeze
ANDROID_WORKSPACE_EDIT_CONTRACT_CHECKS = %w[
  wrapper_defines_workspace_edit_target
  wrapper_uses_default_workspace_edit_profile
  wrapper_reports_live_request_profile
  wrapper_reports_live_target_file
].freeze
ANDROID_TARGET_FILE_CONTRACT_CHECKS = %w[
  wrapper_sets_expected_target_file
  smoke_requires_target_file_evidence
  smoke_requires_target_file_marker
  activity_captures_worktree_file_signatures
  target_file_allows_existing_worktree_signature_change
  target_file_update_test_present
].freeze
ANDROID_DEFAULT_PORT_CONTRACT_CHECKS = %w[
  live_acceptance_defaults_to_8877
  connected_smoke_defaults_to_8877
].freeze

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
  output.lines.drop(1).map do |line|
    serial, state = line.strip.split(/\s+/, 2)
    next if serial.to_s.empty?

    {
      "serial" => serial,
      "state" => state.to_s,
    }
  end.compact
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

def read_text(path)
  File.read(path)
rescue Errno::ENOENT
  ""
end

def android_acceptance_contract
  live_script = read_text(ANDROID_ACCEPTANCE_SCRIPT)
  smoke_script = read_text(ANDROID_CONNECTED_SMOKE_SCRIPT)
  activity_source = read_text(ANDROID_AGENT_ACTIVITY_EVIDENCE)
  activity_test_source = read_text(ANDROID_AGENT_ACTIVITY_EVIDENCE_TEST)
  checks = {
    "live_acceptance_script_present" => File.file?(ANDROID_ACCEPTANCE_SCRIPT),
    "connected_smoke_script_present" => File.file?(ANDROID_CONNECTED_SMOKE_SCRIPT),
    "wrapper_enables_code_activity" => live_script.include?("\"MOBILE_GATEWAY_EXPECT_CODE_ACTIVITY\" => \"1\""),
    "smoke_requires_code_activity_evidence" => smoke_script.include?("mac_code_activity_after_send"),
    "smoke_requires_code_activity_marker" => smoke_script.include?("Mac code activity signal marker is required"),
    "wrapper_defines_workspace_edit_target" => live_script.include?("LIVE_ACCEPTANCE_TARGET_FILE = \"#{EXPECTED_ANDROID_LIVE_TARGET_FILE}\""),
    "wrapper_uses_default_workspace_edit_profile" => live_script.include?("\"#{EXPECTED_ANDROID_LIVE_REQUEST_PROFILE}\""),
    "wrapper_reports_live_request_profile" => live_script.include?("live_request_profile: live_request_profile") && live_script.include?("Live request profile"),
    "wrapper_reports_live_target_file" => live_script.include?("live_acceptance_target_file: LIVE_ACCEPTANCE_TARGET_FILE") && live_script.include?("Live acceptance target file"),
    "wrapper_sets_expected_target_file" => live_script.include?("\"MOBILE_GATEWAY_EXPECTED_TARGET_FILE\" => LIVE_ACCEPTANCE_TARGET_FILE"),
    "smoke_requires_target_file_evidence" => smoke_script.include?("mac_target_file_after_send"),
    "smoke_requires_target_file_marker" => smoke_script.include?("Mac target file signal marker is required"),
    "activity_captures_worktree_file_signatures" => activity_source.include?("worktreeFileSignatures") && activity_source.include?("activitySignature()"),
    "target_file_allows_existing_worktree_signature_change" => activity_source.include?("file.activitySignature() !in baseline.worktreeFileSignatures"),
    "target_file_update_test_present" => activity_test_source.include?("targetFileActivityCountsExistingWorktreeFileWhenStatsChange"),
    "live_acceptance_defaults_to_8877" => live_script.include?("MOBILE_GATEWAY_DESKTOP_PORT\", \"8877\""),
    "connected_smoke_defaults_to_8877" => smoke_script.include?("MOBILE_GATEWAY_DESKTOP_PORT\", \"8877\""),
  }

  {
    "status" => checks.values.all? ? "passed" : "failed",
    "code_activity_status" => contract_status(checks, ANDROID_CODE_ACTIVITY_CONTRACT_CHECKS),
    "workspace_edit_status" => contract_status(checks, ANDROID_WORKSPACE_EDIT_CONTRACT_CHECKS),
    "target_file_status" => contract_status(checks, ANDROID_TARGET_FILE_CONTRACT_CHECKS),
    "default_port_status" => contract_status(checks, ANDROID_DEFAULT_PORT_CONTRACT_CHECKS),
    "checks" => checks,
  }
end

def contract_status(checks, keys)
  keys.all? { |key| checks[key] == true } ? "passed" : "failed"
end

def android_contract_evidence(contract)
  failed = contract.fetch("checks").slice(*ANDROID_CODE_ACTIVITY_CONTRACT_CHECKS).select { |_key, value| value != true }.keys
  {
    "key" => "android_final_code_activity_gate",
    "status" => failed.empty? ? "passed" : "failed",
    "evidence" => if failed.empty?
                    "Android final live acceptance requires MOBILE_GATEWAY_EXPECT_CODE_ACTIVITY=1 and mac_code_activity_after_send evidence."
                  else
                    "Android final live acceptance is missing required code-activity contract checks: #{failed.join(", ")}."
                  end,
  }
end

def android_workspace_edit_contract_evidence(contract)
  failed = contract.fetch("checks").slice(*ANDROID_WORKSPACE_EDIT_CONTRACT_CHECKS).select { |_key, value| value != true }.keys
  {
    "key" => "android_default_workspace_edit_request",
    "status" => failed.empty? ? "passed" : "failed",
    "evidence" => if failed.empty?
                    "Android final live acceptance defaults to #{EXPECTED_ANDROID_LIVE_REQUEST_PROFILE} targeting #{EXPECTED_ANDROID_LIVE_TARGET_FILE}."
                  else
                    "Android final live acceptance is missing required workspace-edit request checks: #{failed.join(", ")}."
                  end,
  }
end

def android_target_file_contract_evidence(contract)
  failed = contract.fetch("checks").slice(*ANDROID_TARGET_FILE_CONTRACT_CHECKS).select { |_key, value| value != true }.keys
  {
    "key" => "android_target_file_gate",
    "status" => failed.empty? ? "passed" : "failed",
    "evidence" => if failed.empty?
                    "Android final live acceptance requires #{EXPECTED_ANDROID_LIVE_TARGET_FILE} to appear in Mac patch/worktree activity, including updates to an existing target path."
                  else
                    "Android final live acceptance is missing required target-file checks: #{failed.join(", ")}."
                  end,
  }
end

def android_default_port_contract_evidence(contract)
  failed = contract.fetch("checks").slice(*ANDROID_DEFAULT_PORT_CONTRACT_CHECKS).select { |_key, value| value != true }.keys
  {
    "key" => "android_default_desktop_port",
    "status" => failed.empty? ? "passed" : "failed",
    "evidence" => if failed.empty?
                    "Android live acceptance and connected smoke default to the Mac Mobile Gateway port 8877."
                  else
                    "Android live acceptance is missing required default-port checks: #{failed.join(", ")}."
                  end,
  }
end

def android_live_request_metadata_evidence(android)
  profile = android["live_request_profile"]
  target_file = android["live_acceptance_target_file"]
  [
    {
      "key" => "android_live_request_profile",
      "status" => profile == EXPECTED_ANDROID_LIVE_REQUEST_PROFILE ? "passed" : "failed",
      "evidence" => "Expected #{EXPECTED_ANDROID_LIVE_REQUEST_PROFILE}, observed #{profile || "missing"}.",
    },
    {
      "key" => "android_live_acceptance_target_file",
      "status" => target_file == EXPECTED_ANDROID_LIVE_TARGET_FILE ? "passed" : "failed",
      "evidence" => "Expected #{EXPECTED_ANDROID_LIVE_TARGET_FILE}, observed #{target_file || "missing"}.",
    },
  ]
end

def missing_android_required_evidence(android)
  keys = android.fetch("acceptance_evidence", []).map { |item| item.fetch("key", nil) }.compact
  ANDROID_REQUIRED_FINAL_EVIDENCE.reject { |key| keys.include?(key) }
end

def build_acceptance_evidence(readiness, android, android_ran, android_preflight_report, android_contract)
  evidence = []
  readiness.fetch("acceptance_evidence", []).each do |item|
    key = item.fetch("key")
    evidence << item.merge("key" => key.start_with?("mac_") ? key : "mac_#{key}")
  end
  evidence.concat(android_preflight_evidence(android_preflight_report))
  evidence << android_contract_evidence(android_contract)
  evidence << android_workspace_edit_contract_evidence(android_contract)
  evidence << android_target_file_contract_evidence(android_contract)
  evidence << android_default_port_contract_evidence(android_contract)
  if android_ran
    evidence.concat(android_live_request_metadata_evidence(android))
    android.fetch("acceptance_evidence", []).each do |item|
      evidence << item.merge("key" => "android_#{item.fetch("key")}")
    end
    missing_android_required_evidence(android).each do |key|
      evidence << {
        "key" => "android_#{key}",
        "status" => "failed",
        "evidence" => "Android live acceptance report did not include required final evidence key `#{key}`.",
      }
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
    "- Android final code activity gate: `#{report[:android_final_code_activity_gate_status]}`",
    "- Android default workspace edit request: `#{report[:android_default_workspace_edit_request_status]}`",
    "- Android target file gate: `#{report[:android_target_file_gate_status]}`",
    "- Android default desktop port: `#{report[:android_default_desktop_port_status]}`",
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
android_contract_report = android_acceptance_contract
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

acceptance_evidence = build_acceptance_evidence(
  readiness_report,
  android_report,
  android_ran,
  android_preflight_report,
  android_contract_report,
)
status = acceptance_evidence.all? { |item| item["status"] == "passed" } ? "passed" : "failed"
report = {
  generated_at: Time.now.utc.iso8601,
  status: status,
  android_dir: ANDROID_DIR,
  mac_readiness_status: readiness_report["status"],
  android_preflight_status: android_preflight_report["status"],
  android_final_code_activity_gate_status: android_contract_report["code_activity_status"],
  android_default_workspace_edit_request_status: android_contract_report["workspace_edit_status"],
  android_target_file_gate_status: android_contract_report["target_file_status"],
  android_default_desktop_port_status: android_contract_report["default_port_status"],
  android_ready_device_count: android_preflight_report["ready_device_count"],
  android_live_acceptance_status: android_report["status"],
  mac_readiness_report_json: READINESS_REPORT_JSON,
  android_live_acceptance_report_json: android_ran ? ANDROID_ACCEPTANCE_REPORT_JSON : nil,
  android_preflight: android_preflight_report,
  android_acceptance_contract: android_contract_report,
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
