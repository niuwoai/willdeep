#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "digest"
require "json"
require "open3"
require "tmpdir"

ROOT = File.expand_path("..", __dir__)
GUARD = File.join(ROOT, "scripts", "project_build_guard.rb")

def run_guard(workspace, *args)
  stdout, status = Open3.capture2e("ruby", GUARD, "--workspace", workspace, *args)
  [stdout, status.exitstatus]
end

Dir.mktmpdir("project-build-guard-") do |workspace|
  artifact = File.join(workspace, "artifact.txt")
  counter = File.join(workspace, "counter.txt")
  report_json = File.join(workspace, "guard.json")
  report_md = File.join(workspace, "guard.md")
  command = [
    "ruby",
    "-e",
    "count = File.file?('counter.txt') ? File.read('counter.txt').to_i : 0; File.write('counter.txt', (count + 1).to_s); File.write('artifact.txt', 'ok')"
  ]

  first_stdout, first_status = run_guard(
    workspace,
    "--name", "contract-smoke",
    "--kind", "smoke",
    "--artifact", artifact,
    "--json-report", report_json,
    "--markdown-report", report_md,
    "--",
    *command
  )
  abort "first run failed:\n#{first_stdout}" unless first_status.zero?
  abort "artifact was not created" unless File.read(artifact) == "ok"
  abort "counter after first run was not 1" unless File.read(counter) == "1"

  second_stdout, second_status = run_guard(
    workspace,
    "--name", "contract-smoke",
    "--kind", "smoke",
    "--artifact", artifact,
    "--json-report", report_json,
    "--markdown-report", report_md,
    "--",
    *command
  )
  abort "second run failed:\n#{second_stdout}" unless second_status.zero?
  abort "cache did not prevent rerun" unless File.read(counter) == "1"

  report = JSON.parse(File.read(report_json, encoding: "UTF-8"))
  abort "expected cache-hit-after-wait report, got #{report["status"]}" unless report["status"] == "cache-hit-after-wait"
  abort "markdown report missing" unless File.file?(report_md)

  source = File.join(workspace, "source.txt")
  waiting_artifact = File.join(workspace, "waiting-artifact.txt")
  waiting_report = File.join(workspace, "waiting-guard.json")
  state_dir = File.join(workspace, ".codex-build")
  lock_path = File.join(state_dir, "workspace.lock")
  File.write(source, "before-wait")
  FileUtils.mkdir_p(state_dir)

  File.open(lock_path, File::RDWR | File::CREAT, 0o644) do |lock_file|
    lock_file.flock(File::LOCK_EX)
    guard_args = [
      "ruby", GUARD,
      "--workspace", workspace,
      "--name", "refresh-after-wait",
      "--kind", "smoke",
      "--artifact", waiting_artifact,
      "--fingerprint-file", source,
      "--json-report", waiting_report,
      "--",
      "ruby", "-e", "File.write('waiting-artifact.txt', File.read('source.txt'))"
    ]
    Open3.popen2e(*guard_args) do |_stdin, stdout_err, wait_thread|
      queue_pattern = File.join(state_dir, "queue", "*.json")
      deadline = Time.now + 10
      sleep 0.05 while Dir.glob(queue_pattern).empty? && Time.now < deadline
      abort "waiting guard did not enter the queue" if Dir.glob(queue_pattern).empty?

      File.write(source, "after-wait!")
      lock_file.flock(File::LOCK_UN)
      waiting_output = stdout_err.read
      waiting_status = wait_thread.value.exitstatus
      abort "waiting run failed:\n#{waiting_output}" unless waiting_status.zero?
    end
  end

  waiting_result = JSON.parse(File.read(waiting_report, encoding: "UTF-8"))
  source_entry = waiting_result.fetch("fingerprint_input").fetch("fingerprint_files").first
  expected_source_digest = Digest::SHA256.file(source).hexdigest
  abort "waiting run used stale source content" unless File.read(waiting_artifact) == "after-wait!"
  abort "fingerprint was not refreshed after waiting" unless waiting_result["fingerprint_refreshed_after_wait"]
  abort "fingerprint file digest is stale" unless source_entry["sha256"] == expected_source_digest

  puts JSON.pretty_generate(
    ok: true,
    report_status: report["status"],
    waiting_report_status: waiting_result["status"],
    fingerprint_refreshed_after_wait: waiting_result["fingerprint_refreshed_after_wait"],
    artifact: artifact,
    counter: File.read(counter)
  )
end
