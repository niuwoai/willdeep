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

# A run whose xcresult bundle knows about fewer tests than the log did. This is
# the 2026-08-14 false green: 2340 tests in the bundle, all "passed"; 2355 Swift
# Testing tests plus 7 XCTest ones in the log, three of them failed. The missing
# tail is where the failures were, so the bundle alone reads as a clean sweep.
TRUNCATED_BUNDLE_LOG = <<~LOG
  ✘ Test "sandbox policy blocks outbound curl" failed after 0.004 seconds.
  ✘ Test "sandbox policy blocks outbound nc" failed after 0.002 seconds.
  ✘ Test "sandbox policy keeps loopback reachable" failed after 0.003 seconds.
  ✘ Suite AgentSandboxNetworkPolicyTests failed after 0.012 seconds.
  \t Executed 7 tests, with 0 failures (0 unexpected) in 0.377 (0.379) seconds
  ✘ Test run with 2355 tests in 201 suites failed after 201.3 seconds with 3 issues.

  ** TEST FAILED **
LOG

# Same under-count, but nothing in the log flags a failure. Silent divergence:
# the bundle cannot be trusted, yet there is no failure to report either.
UNDERCOUNTING_PASSING_LOG = <<~LOG
  ✔ Suite WillDeepTests passed after 200.9 seconds.
  \t Executed 7 tests, with 0 failures (0 unexpected) in 0.377 (0.379) seconds
  ✔ Test run with 2355 tests in 201 suites passed after 201.3 seconds.

  ** TEST SUCCEEDED **
LOG

# The healthy case the guards must not break: 2355 + 7 = 2362, exactly what the
# bundle counted.
AGREEING_PASSING_LOG = UNDERCOUNTING_PASSING_LOG

# URLProtocol callbacks can lose Swift Testing's task-local ownership. Xcode
# may exit zero while the framework records failures outside a named test.
UNASSOCIATED_ISSUE_LOG = [
  "✘ Test «unknown» recorded an issue at Fixture.swift:1:1: Expectation failed: false",
  "✘ Test run with 35 tests in 4 suites failed after 29.168 seconds with 4 issues.",
  "** TEST SUCCEEDED **"
].join("\n")

results = []

def check(condition, message, results)
  results << { "ok" => !!condition, "message" => message }
end

# Build a bundle whose xcresulttool output the test controls. The directory has
# to exist because the reporter refuses to parse a missing bundle.
def recorded_bundle(directory, total:, failed: 0, result: "Passed", failing_tests: [])
  bundle = File.join(directory, "XeditTests.xcresult")
  FileUtils.mkdir_p(File.join(bundle, "Data"))

  File.write(File.join(directory, "summary.json"), JSON.generate({
    "result" => result,
    "totalTestCount" => total,
    "passedTests" => total - failed,
    "failedTests" => failed,
    "skippedTests" => 0,
    "startTime" => 0,
    "finishTime" => 201.3
  }))
  File.write(File.join(directory, "tests.json"), JSON.generate({
    "testNodes" => [{
      "nodeType" => "Test Plan",
      "name" => "XeditUnitTests",
      "children" => failing_tests.map do |name|
        { "nodeType" => "Test Case", "name" => name, "result" => "Failed", "children" => [] }
      end
    }]
  }))

  bundle
end

def run_recorded_reporter(directory, log:, extra: [])
  md_path = File.join(directory, "report.md")
  json_path = File.join(directory, "report.json")
  bundle = File.join(directory, "XeditTests.xcresult")
  File.write(File.join(directory, "xcodebuild.log"), log)

  environment = {
    "WILLDEEP_XCRESULTTOOL" => "ruby #{File.join(ROOT, "scripts", "fixtures", "fake_xcresulttool.rb")}",
    "FAKE_XCRESULT_DIR" => directory
  }
  _out, _err, status = Open3.capture3(
    environment, "ruby", REPORTER, bundle, md_path, json_path, *extra, chdir: ROOT
  )
  {
    exit_status: status.exitstatus,
    markdown: File.file?(md_path) ? File.read(md_path, encoding: "UTF-8") : "",
    json: File.file?(json_path) ? JSON.parse(File.read(json_path, encoding: "UTF-8")) : {}
  }
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

  # Formatting-only prefixes must not silently reclassify skipped cases as
  # passed. Suite-level skips are not an additional test and must not double count.
  ["", "\u200B", "\uFEFF", " \u200B\uFEFF"].each do |prefix|
    Dir.mktmpdir("formatted-skip", workspace) do |directory|
      bundle = corrupt_bundle(directory)
      log = "#{prefix}➜ Suite fixture skipped.\n#{prefix}➜ Test fixture skipped.\n" \
            "✔ Test run with 3 tests in 1 suite passed after 0.1 seconds.\n** TEST SUCCEEDED **\n"
      File.write(File.join(directory, "xcodebuild.log"), log)
      report = run_reporter(bundle, directory)
      check(report[:json].dig("stats", "skipped") == 1, "Formatting prefixes preserve one skipped case, not its suite.", results)
      check(report[:json].dig("stats", "passed") == 2, "A skipped test is not reported as passed.", results)
      check(report[:exit_status] == EXIT_PASSED, "A permitted skip does not become a failure.", results)
    end
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
    check(report[:json].dig("stats", "failed") == 1, "Swift Testing failures are counted even when XCTest reports zero.", results)
    check(report[:json].dig("stats", "passed") == 1747, "Failed Swift tests are not counted as passed.", results)
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

  # 7. A readable-but-truncated bundle that missed the failing suite. The bundle
  #    says 2340/2340 passed; the log says 2362 tests ran and three failed. The
  #    log wins — this is the exact shape of the 2026-08-14 false green.
  Dir.mktmpdir("truncated-bundle", workspace) do |directory|
    recorded_bundle(directory, total: 2340, failed: 0, result: "Passed")
    report = run_recorded_reporter(directory, log: TRUNCATED_BUNDLE_LOG)
    check(report[:json]["status"] == "failed", "A bundle missing the failing suite still reports status=failed.", results)
    check(report[:json]["ok"] == false, "A bundle missing the failing suite reports ok=false.", results)
    check(report[:exit_status] == EXIT_FAILED, "A bundle missing the failing suite exits #{EXIT_FAILED}.", results)
    check(!report[:markdown].include?("✅"), "A bundle missing the failing suite renders no green check.", results)
    check(
      report[:json]["failures"].to_a.length == 3,
      "The three log failures are carried into the report's failures array.",
      results
    )
    check(
      report[:json]["failures"].to_a.any? { |failure| failure["name"].to_s.include?("blocks outbound curl") },
      "The report names the failing tests the bundle omitted.",
      results
    )
    check(report[:json]["total_mismatch"] == true, "The truncated bundle is flagged with total_mismatch.", results)
    check(report[:json].dig("log_stats", "failed") == 3, "Log statistics include all three Swift Testing failures.", results)
    check(report[:json].dig("stats", "failed") == 3, "A stale bundle cannot erase log-observed failed-test counts.", results)
    check(
      report[:json]["reasons"].to_a.any? { |reason| reason.include?("report=2340") && reason.include?("log=2362") },
      "The report spells out the 2340 vs 2362 total disagreement.",
      results
    )
  end

  # Extra bundle entries are also a mismatch, but not missing tests.
  Dir.mktmpdir("overcount-bundle", workspace) do |directory|
    recorded_bundle(directory, total: 2363, failed: 0, result: "Passed")
    report = run_recorded_reporter(directory, log: UNDERCOUNTING_PASSING_LOG)
    check(report[:json]["status"] == "unknown", "An over-counting bundle cannot report passed.", results)
    check(report[:exit_status] == EXIT_UNKNOWN, "An over-counting bundle exits unknown.", results)
    reasons = report[:json]["reasons"].to_a.join(" ")
    check(reasons.include?("1 extra test entries") && !reasons.include?("bundle is missing"),
          "An over-count is described as extra entries, not missing tests.", results)
  end

  [false, true].each do |synthetic_entry|
    Dir.mktmpdir("unassociated-issue", workspace) do |directory|
      recorded_bundle(directory, total: synthetic_entry ? 36 : 35,
                      failed: synthetic_entry ? 1 : 0,
                      result: synthetic_entry ? "Failed" : "Passed",
                      failing_tests: synthetic_entry ? ["Issues recorded without an associated test or suite"] : [])
      report = run_recorded_reporter(directory, log: UNASSOCIATED_ISSUE_LOG,
                                     extra: ["--test-exit", "0"])
      label = synthetic_entry ? "synthetic bundle entry" : "stale passing bundle"
      check(report[:json]["status"] == "failed", "Unassociated issues with #{label} report failed.", results)
      check(report[:exit_status] == EXIT_FAILED, "Unassociated issues with #{label} override exit zero.", results)
      check(report[:json]["ok"] == false && !report[:markdown].include?("✅"),
            "Unassociated issues with #{label} cannot produce a green report.", results)
      check(report[:json].dig("stats", "failed").to_i.positive?,
            "Unassociated issues with #{label} remain visible in failure counts.", results)
    end
  end

  # 8. Same under-count with a log that flags nothing. There is no failure to
  #    report, but the bundle cannot be trusted either — that is `unknown`.
  Dir.mktmpdir("undercount-bundle", workspace) do |directory|
    recorded_bundle(directory, total: 2340, failed: 0, result: "Passed")
    report = run_recorded_reporter(directory, log: UNDERCOUNTING_PASSING_LOG)
    check(report[:json]["status"] == "unknown", "An under-counting bundle reports status=unknown, never passed.", results)
    check(report[:exit_status] == EXIT_UNKNOWN, "An under-counting bundle exits #{EXIT_UNKNOWN}.", results)
    check(
      report[:json]["reasons"].to_a.any? { |reason| reason.include?("delta +22") },
      "The unknown verdict states the missing-test delta.",
      results
    )
  end

  # 9. Control: bundle and log agree, so the guards must still let a pass through.
  Dir.mktmpdir("agreeing-bundle", workspace) do |directory|
    recorded_bundle(directory, total: 2362, failed: 0, result: "Passed")
    report = run_recorded_reporter(directory, log: AGREEING_PASSING_LOG)
    check(report[:json]["status"] == "passed", "A bundle that agrees with the log still reports status=passed.", results)
    check(report[:exit_status] == EXIT_PASSED, "An agreeing bundle exits #{EXIT_PASSED}.", results)
    check(report[:json]["total_mismatch"] == false, "An agreeing bundle sets total_mismatch=false.", results)
    check(report[:json]["source"] == "xcresult", "An agreeing bundle keeps source=xcresult.", results)
  end

  # 10. A bundle that says the run failed outranks its own zeroed counters.
  Dir.mktmpdir("failed-result-bundle", workspace) do |directory|
    recorded_bundle(directory, total: 2362, failed: 0, result: "Failed")
    report = run_recorded_reporter(directory, log: AGREEING_PASSING_LOG)
    check(
      report[:json]["status"] == "failed",
      "A bundle whose own result is Failed is never reported as a pass.",
      results
    )
  end

  Dir.mktmpdir("duplicate-issues", workspace) do |directory|
    bundle = corrupt_bundle(directory)
    log = "✘ Test \"same test\" recorded an issue at source.swift:1\n" + FAILING_LOG.sub('"agent tool runner refuses paths outside the workspace" failed', '"same test" failed')
    File.write(File.join(directory, "xcodebuild.log"), log)
    report = run_reporter(bundle, directory)
    check(report[:json].dig("stats", "failed") == 1, "Multiple issues in one Swift test are counted once.", results)
  end

  # 11. A non-zero xcodebuild exit can never come back green, whatever the
  #     bundle and log say.
  Dir.mktmpdir("nonzero-exit", workspace) do |directory|
    recorded_bundle(directory, total: 2362, failed: 0, result: "Passed")
    report = run_recorded_reporter(directory, log: AGREEING_PASSING_LOG, extra: ["--test-exit", "65"])
    check(report[:json]["status"] == "unknown", "A non-zero --test-exit blocks a passed verdict.", results)
    check(report[:json]["test_exit"] == 65, "The report records the xcodebuild exit code.", results)
    check(
      report[:json]["reasons"].to_a.any? { |reason| reason.include?("exited 65") },
      "The report explains that xcodebuild exited non-zero.",
      results
    )
    green = run_recorded_reporter(directory, log: AGREEING_PASSING_LOG, extra: ["--test-exit", "0"])
    check(green[:json]["status"] == "passed", "--test-exit 0 leaves an otherwise clean run green.", results)
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

# 8. Callers must also hand over xcodebuild's exit code, and the full runner has
#    to clear the previous verdict before it starts — everything between the
#    `rm` and the reporter can abort under `set -e`, and a leftover green
#    report.json is indistinguishable from this run's result.
check(
  full_runner.include?('--test-exit "${TEST_EXIT}"'),
  "Full local runner passes xcodebuild's exit code to the reporter.",
  results
)
check(
  full_runner.match?(/rm -f "\$\{REPORT_JSON\}" "\$\{REPORT_MD\}"/),
  "Full local runner deletes the previous report before running.",
  results
)
check(fast_runner.include?("test_exit:"), "Fast runner passes xcodebuild's exit code to the reporter.", results)
check(workflow.include?("--test-exit"), "CI passes the test step's outcome to the reporter.", results)

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
