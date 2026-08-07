#!/usr/bin/env ruby
# frozen_string_literal: true

# xcresult_report_contract_test.rb — guard scripts/xcresult_report.rb against
# false-green reports.
#
# Background: scripts/xcodebuild_ci.rb terminates xcodebuild when it hangs after
# the test phase (a known macOS behaviour). A bundle killed mid-finalization has
# no Info.plist, every xcresulttool invocation fails, and the old reporter kept
# its zeroed counters while still writing `ok: true` and "✅ … total=0". Callers
# that pipe the runner through `tail` lose the exit code, so that green check was
# the only signal they had — a broken run looked exactly like a passing one.
#
# These checks pin the contract: a result we could not verify is never ok/green,
# and the raw xcodebuild log is used to recover real data when the bundle is
# unreadable.
#
# Usage: ruby scripts/xcresult_report_contract_test.rb [report.md] [report.json]

require "fileutils"
require "json"
require "open3"
require "tmpdir"
require "time"

# Pinned like the sibling guards: these read UTF-8 repo files, and a shell
# without LANG leaves Ruby on US-ASCII, which turns any non-ASCII byte into
# an Encoding::InvalidByteSequenceError instead of a real check result.
Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

ROOT = File.expand_path("..", __dir__)
REPORTER = File.join(ROOT, "scripts", "xcresult_report.rb")

EXIT_PASSED = 0
EXIT_FAILED = 1
EXIT_UNKNOWN = 2

PASSING_LOG = <<~LOG
  ◇ Test "agent tool runner refuses paths outside the workspace" started.
  ✔ Test "agent tool runner refuses paths outside the workspace" passed after 0.001 seconds.
  ✔ Suite WillDeepTests passed after 34.946 seconds.
  ✔ Test run with 1748 tests in 150 suites passed after 34.952 seconds.

  Test session results, code coverage, and logs:
  \t/tmp/XeditFastTests.xcresult

  ** TEST SUCCEEDED **
LOG

FAILING_LOG = <<~LOG
  ◇ Test "agent tool runner refuses paths outside the workspace" started.
  ✘ Test "agent tool runner refuses paths outside the workspace" failed after 0.004 seconds.
  ✘ Suite WillDeepTests failed after 34.946 seconds.
  ✘ Test run with 1748 tests in 150 suites failed after 34.952 seconds with 1 issue.

  ** TEST FAILED **
LOG

results = []

def check(condition, message, results)
  results << { "ok" => !!condition, "message" => message }
end

# Build an .xcresult directory shaped like one xcodebuild was killed while
# finalizing: payload directories present, Info.plist absent.
def corrupt_bundle(directory)
  bundle = File.join(directory, "XeditFastTests.xcresult")
  FileUtils.mkdir_p(File.join(bundle, "Data"))
  FileUtils.mkdir_p(File.join(bundle, "Staging"))
  bundle
end

def run_reporter(bundle, directory, *extra)
  md_path = File.join(directory, "report.md")
  json_path = File.join(directory, "report.json")
  _out, _err, status = Open3.capture3(
    "ruby", REPORTER, bundle, md_path, json_path, *extra, chdir: ROOT
  )
  {
    exit_status: status.exitstatus,
    markdown: File.file?(md_path) ? File.read(md_path, encoding: "UTF-8") : "",
    json: File.file?(json_path) ? JSON.parse(File.read(json_path, encoding: "UTF-8")) : {}
  }
end

check(File.file?(REPORTER), "scripts/xcresult_report.rb exists.", results)

Dir.mktmpdir("xcresult-report-contract") do |workspace|
  # 1. Unreadable bundle, nothing to fall back on → unknown, never green.
  Dir.mktmpdir("no-log", workspace) do |directory|
    report = run_reporter(corrupt_bundle(directory), directory)
    check(report[:json]["ok"] == false, "Unreadable bundle without a log reports ok=false.", results)
    check(report[:json]["status"] == "unknown", "Unreadable bundle without a log reports status=unknown.", results)
    check(report[:exit_status] == EXIT_UNKNOWN, "Unreadable bundle without a log exits #{EXIT_UNKNOWN}.", results)
    check(!report[:markdown].include?("✅"), "Unverifiable markdown report carries no green check.", results)
    check(report[:markdown].include?("UNKNOWN"), "Unverifiable markdown report says UNKNOWN.", results)
    check(
      report[:json]["reasons"].to_a.any? { |reason| reason.include?("Info.plist") },
      "Unreadable bundle explains the xcresulttool failure.",
      results
    )
  end

  # 2. Unreadable bundle plus a passing log → real data recovered from the log.
  Dir.mktmpdir("passing-log", workspace) do |directory|
    bundle = corrupt_bundle(directory)
    File.write(File.join(directory, "xcodebuild.log"), PASSING_LOG)
    report = run_reporter(bundle, directory)
    check(report[:json]["status"] == "passed", "Passing xcodebuild log recovers status=passed.", results)
    check(report[:json]["source"] == "xcodebuild-log", "Recovered report records source=xcodebuild-log.", results)
    check(report[:json].dig("stats", "total") == 1748, "Recovered report keeps the real test total.", results)
    check(report[:exit_status] == EXIT_PASSED, "Recovered passing report exits #{EXIT_PASSED}.", results)
  end

  # 3. Unreadable bundle plus a failing log → failure, never green.
  Dir.mktmpdir("failing-log", workspace) do |directory|
    bundle = corrupt_bundle(directory)
    File.write(File.join(directory, "xcodebuild.log"), FAILING_LOG)
    report = run_reporter(bundle, directory)
    check(report[:json]["status"] == "failed", "Failing xcodebuild log recovers status=failed.", results)
    check(report[:json]["ok"] == false, "Failing xcodebuild log reports ok=false.", results)
    check(report[:exit_status] == EXIT_FAILED, "Failing recovered report exits #{EXIT_FAILED}.", results)
    check(!report[:markdown].include?("✅"), "Failing markdown report carries no green check.", results)
  end

  # 4. An explicit --log path is honoured even when it is not a sibling.
  Dir.mktmpdir("explicit-log", workspace) do |directory|
    bundle = corrupt_bundle(directory)
    log_path = File.join(workspace, "elsewhere.log")
    File.write(log_path, PASSING_LOG)
    report = run_reporter(bundle, directory, "--log", log_path)
    check(report[:json]["status"] == "passed", "--log overrides the default sibling log path.", results)
  end

  # 5. A missing bundle is unknown, not a pass.
  Dir.mktmpdir("missing", workspace) do |directory|
    report = run_reporter(File.join(directory, "absent.xcresult"), directory)
    check(report[:json]["status"] == "unknown", "Missing bundle reports status=unknown.", results)
    check(report[:exit_status] == EXIT_UNKNOWN, "Missing bundle exits #{EXIT_UNKNOWN}.", results)
  end

  # 6. Zero parsed tests only counts as a pass when the caller opts in.
  Dir.mktmpdir("allow-empty", workspace) do |directory|
    bundle = corrupt_bundle(directory)
    File.write(File.join(directory, "xcodebuild.log"), "** TEST SUCCEEDED **\n")
    strict = run_reporter(bundle, directory)
    check(strict[:json]["status"] != "passed", "Zero parsed tests is not a pass by default.", results)
    permissive = run_reporter(bundle, directory, "--allow-empty")
    check(permissive[:json]["status"] == "passed", "--allow-empty accepts a deliberately empty run.", results)
  end
end

# 7. Callers must hand the reporter a log so the fallback can actually fire.
fast_runner = File.read(File.join(ROOT, "scripts", "run_tests_fast.rb"), encoding: "UTF-8")
full_runner = File.read(File.join(ROOT, "scripts", "run_tests.sh"), encoding: "UTF-8")
workflow = File.read(File.join(ROOT, ".github", "workflows", "test.yml"), encoding: "UTF-8")

check(fast_runner.include?('"--log", LOG'), "Fast runner passes the xcodebuild log to the reporter.", results)
check(full_runner.include?("--log \"${LOG}\""), "Full local runner passes the xcodebuild log to the reporter.", results)
check(
  workflow.include?("xcresult_report.rb build/ci/XeditTests.xcresult build/ci/report.md build/ci/report.json --log build/ci/xcodebuild-test.log"),
  "CI passes the xcodebuild log to the reporter.",
  results
)

failed = results.reject { |result| result["ok"] }
report = {
  "ok" => failed.empty?,
  "checked_at" => Time.now.utc.iso8601,
  "checks" => results
}

json_path = ARGV[1]
markdown_path = ARGV[0]
File.write(json_path, "#{JSON.pretty_generate(report)}\n") if json_path
if markdown_path
  lines = ["# xcresult Report Contract", "", "- Status: #{report["ok"] ? "pass" : "fail"}", "", "## Checks", ""]
  results.each { |result| lines << "- #{result["ok"] ? "PASS" : "FAIL"}: #{result["message"]}" }
  File.write(markdown_path, "#{lines.join("\n")}\n")
end

abort failed.map { |result| result["message"] }.join("\n") unless failed.empty?

puts "xcresult_report_contract: pass checks=#{results.length}"
