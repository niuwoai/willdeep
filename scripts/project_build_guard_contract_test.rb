#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
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
  abort "expected cache-hit report, got #{report["status"]}" unless report["status"] == "cache-hit"
  abort "markdown report missing" unless File.file?(report_md)

  puts JSON.pretty_generate(
    ok: true,
    report_status: report["status"],
    artifact: artifact,
    counter: File.read(counter)
  )
end
