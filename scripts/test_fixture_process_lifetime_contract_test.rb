#!/usr/bin/env ruby
# frozen_string_literal: true

# test_fixture_process_lifetime_contract_test.rb -- guard against test fixtures
# that spawn a shell able to outlive the test host.
#
# Background: the background-task panel's visual-QA test spawned
# `trap 'exit 143' TERM; while true; do sleep 1; done` and relied on a `defer`
# to signal it. When the test host dies abnormally (a watchdog SIGKILL on a
# hung xcodebuild, a crashed harness) no defer runs, the shell is reparented to
# launchd and idles forever. Two such orphans were found on a dev machine on
# 2026-09-12, one of them six days old.
#
# The contract: every idle shell fixture goes through AgentJobFixtureCommand,
# whose loop is deadline-bounded, so an abandoned fixture reaps itself.
#
# Usage:
#   ruby scripts/test_fixture_process_lifetime_contract_test.rb
#   ruby scripts/test_fixture_process_lifetime_contract_test.rb report.md report.json

require "json"
require "fileutils"

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

repo_root = File.expand_path("..", __dir__)
markdown_path = ARGV[0] || "build/test_fixture_process_lifetime/report.md"
json_path = ARGV[1] || "build/test_fixture_process_lifetime/report.json"

FIXTURE_RELATIVE = "XeditTests/AgentJobFixtureCommands.swift"
# Any spelling of "sleep forever" a fixture might reach for. `while true` on
# its own is fine — plenty of tests poll in Swift — it is only the shell that
# strands a process.
UNBOUNDED_SHELL_LOOPS = [
  "while true; do sleep",
  "while :; do sleep",
  "while true ; do sleep",
  "sleep infinity",
  "tail -f /dev/null"
].freeze

checks = []

add_check = lambda do |name, ok, detail|
  checks << { name: name, ok: ok == true, detail: detail }
end

fixture_path = File.join(repo_root, FIXTURE_RELATIVE)
fixture_source = File.exist?(fixture_path) ? File.read(fixture_path, encoding: "UTF-8") : ""

add_check.call(
  "shared idle fixture exists",
  !fixture_source.empty?,
  "#{FIXTURE_RELATIVE} must define the one blessed long-running shell fixture."
)

add_check.call(
  "idle fixture is deadline-bounded",
  [
    "enum AgentJobFixtureCommand",
    "maximumIdleSeconds",
    "boundedSleepLoop",
    "-lt \\(maximumIdleSeconds)"
  ].all? { |token| fixture_source.include?(token) },
  "The fixture loop must count up to a hard ceiling instead of looping forever."
)

swift_tests = Dir.glob(File.join(repo_root, "XeditTests", "**", "*.swift")).sort
offenders = swift_tests.each_with_object([]) do |path, found|
  source = File.read(path, encoding: "UTF-8")
  source.each_line.with_index(1) do |line, number|
    next unless UNBOUNDED_SHELL_LOOPS.any? { |pattern| line.include?(pattern) }
    # Command-classification tests quote shell text as data, never spawn it.
    next if line.include?("SafeCommand.classify")

    found << "#{path.sub("#{repo_root}/", "")}:#{number}"
  end
end

add_check.call(
  "no test spawns an unbounded idle shell",
  offenders.empty?,
  offenders.empty? ? "All idle fixtures go through AgentJobFixtureCommand." : "Use AgentJobFixtureCommand.idle() instead at: #{offenders.join(", ")}"
)

visual_qa_path = File.join(repo_root, "XeditTests/AgentBackgroundJobsTests.swift")
visual_qa_source = File.exist?(visual_qa_path) ? File.read(visual_qa_path, encoding: "UTF-8") : ""
visual_qa_body = visual_qa_source[
  /func rendersBackgroundTaskManagerForVisualQA.*?\n    \}\n/m
].to_s

add_check.call(
  "background task visual QA reaps its fixture",
  visual_qa_body.include?("defer { _ = appState.agentJobRegistry.kill(id: runningJob.id) }") &&
    visual_qa_body.include?("waitUntilFinished("),
  "The heaviest rendering test must register its kill before the first await and wait for the exit."
)

failures = checks.reject { |check| check[:ok] }
ok = failures.empty?

FileUtils.mkdir_p(File.dirname(File.expand_path(json_path, repo_root)))
FileUtils.mkdir_p(File.dirname(File.expand_path(markdown_path, repo_root)))

File.write(
  File.expand_path(json_path, repo_root),
  JSON.pretty_generate(
    status: ok ? "pass" : "fail",
    checks: checks,
    offenders: offenders
  )
)

status = ok ? "PASS" : "FAIL"
md = +"# Test Fixture Process Lifetime Contract Report\n\n"
md << "**Status:** #{status}\n\n"
md << "- Checks: #{checks.length}\n"
md << "- Failures: #{failures.length}\n\n"

if failures.empty?
  md << "No test fixture can strand a shell process past its host.\n\n"
else
  md << "## Failures\n\n"
  failures.each { |failure| md << "- #{failure[:name]}: #{failure[:detail]}\n" }
  md << "\n"
end

md << "## Checks\n\n"
md << "| Check | Status | Detail |\n"
md << "| --- | --- | --- |\n"
checks.each do |check|
  md << "| #{check[:name]} | #{check[:ok] ? "PASS" : "FAIL"} | #{check[:detail]} |\n"
end

File.write(File.expand_path(markdown_path, repo_root), md)

puts "test_fixture_process_lifetime: #{status.downcase} checks=#{checks.length} failures=#{failures.length}"
exit(ok ? 0 : 1)
