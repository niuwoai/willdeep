#!/usr/bin/env ruby
# frozen_string_literal: true

# xcresult_report.rb — parse xcodebuild's xcresult bundle into markdown + json.
#
# Usage:
#   scripts/xcresult_report.rb <xcresult-path> <out.md> <out.json> [options]
#
# Options:
#   --log PATH        Raw xcodebuild log. Used both to cross-check the bundle and
#                     to fall back on when the bundle is unreadable. Defaults to
#                     xcodebuild.log next to the bundle.
#   --allow-empty     Treat a parsed run of zero tests as a pass (only correct
#                     when the caller deliberately selected no tests).
#   --test-exit CODE  xcodebuild's exit status. A non-zero code can never end up
#                     as a pass, whatever the bundle claims.
#
# Environment:
#   WILLDEEP_XCRESULTTOOL  Override the `xcrun xcresulttool` invocation. Exists so
#                          the contract test can feed the parser recorded JSON.
#
# Implementation note: macOS 15 + Xcode 16's xcresulttool requires
# `--legacy` to keep the old `get --format json` interface. We try the
# modern `get test-results` subcommand first and fall back to legacy.
#
# Never report a green run we could not actually verify. scripts/xcodebuild_ci.rb
# kills xcodebuild when it hangs after the test phase (a known macOS behaviour),
# and a bundle killed mid-finalization has no Info.plist, so every xcresulttool
# invocation fails. The old version silently kept its zeroed counters and still
# wrote `ok: true` + "✅ … total=0", which made a broken run look identical to a
# passing one — especially for callers that pipe us through `tail` and lose the
# exit code. Now an unparseable bundle falls back to the raw xcodebuild log, and
# if that fails too the report is explicitly `unknown` and the exit code is
# non-zero.
#
# A readable bundle is not proof either. A bundle that was reused from an earlier
# run, or written by a run that died before finalizing its last suites, parses
# perfectly and reports its own truncated counters as a clean sweep — that is how
# a run whose log carried three ✘ failures and whose xcodebuild exited 65 still
# produced `"status": "passed", "failed": 0`: the bundle knew about 2340 of the
# 2362 tests the log had actually run, and the missing tail held the failures.
# So the raw log is now consulted on *every* run, not just when the bundle is
# unreadable: any failure the log saw makes the verdict `failed`, and a test
# total that disagrees with the log's makes it `unknown` with the delta spelled
# out in `reasons`. The verdict is only `passed` when the exit code, the log and
# the bundle all agree.
#
# Exit codes: 0 = passed, 1 = failed, 2 = unknown (nothing could be verified).

require "json"
require "open3"
require "shellwords"

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

USAGE = <<~TEXT
  usage: xcresult_report.rb <xcresult> <out.md> <out.json> [--log PATH] [--allow-empty] [--test-exit CODE]
TEXT

STATUS_PASSED  = "passed"
STATUS_FAILED  = "failed"
STATUS_UNKNOWN = "unknown"

EXIT_PASSED  = 0
EXIT_FAILED  = 1
EXIT_UNKNOWN = 2

SOURCE_XCRESULT = "xcresult"
SOURCE_LOG      = "xcodebuild-log"
SOURCE_NONE     = "none"

# The contract test swaps this for a stub that replays recorded xcresulttool
# output; nothing else has a reason to set it.
XCRESULTTOOL =
  if (override = ENV["WILLDEEP_XCRESULTTOOL"].to_s.strip).empty?
    ["xcrun", "xcresulttool"]
  else
    Shellwords.split(override)
  end

# --- argument parsing -------------------------------------------------------

positional = []
log_override = nil
allow_empty = false
test_exit = nil

arguments = ARGV.dup
until arguments.empty?
  argument = arguments.shift
  case argument
  when "--log"
    log_override = arguments.shift
  when "--allow-empty"
    allow_empty = true
  when "--test-exit"
    test_exit = arguments.shift.to_s.strip
  when "--help", "-h"
    puts USAGE
    exit 0
  else
    if argument.start_with?("--log=")
      log_override = argument.split("=", 2).last
    elsif argument.start_with?("--test-exit=")
      test_exit = argument.split("=", 2).last.to_s.strip
    else
      positional << argument
    end
  end
end

# An empty or non-numeric --test-exit means "the caller did not know", which must
# not silently read as zero.
test_exit = test_exit&.match?(/\A-?\d+\z/) ? test_exit.to_i : nil

xcresult_path, md_path, json_path = positional
abort(USAGE) unless xcresult_path && md_path && json_path

log_path = log_override || File.join(File.dirname(xcresult_path), "xcodebuild.log")

# --- helpers ----------------------------------------------------------------

def utf8(text)
  text = text.dup.force_encoding(Encoding::UTF_8)
  text.valid_encoding? ? text : text.scrub("?")
end

# Returns [parsed_json_or_nil, error_description_or_nil].
def run_json(command)
  out, err, status = Open3.capture3(*command)
  unless status.success?
    detail = utf8(err.to_s).strip.lines.first&.strip
    return [nil, detail.to_s.empty? ? "exit #{status.exitstatus}" : detail]
  end

  [JSON.parse(utf8(out)), nil]
rescue JSON::ParserError, Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError => error
  [nil, error.class.name]
end

def empty_stats
  { total: 0, passed: 0, failed: 0, skipped: 0, duration: nil }
end

# Parse the xcresult bundle. Returns nil when nothing at all could be read, so
# the caller can tell "no data" apart from "genuinely zero tests".
def parse_xcresult(path, reasons)
  summary, summary_error = run_json([*XCRESULTTOOL, "get", "test-results", "summary",
                                     "--path", path, "--format", "json"])
  tests_json, tests_error = run_json([*XCRESULTTOOL, "get", "test-results", "tests",
                                      "--path", path, "--format", "json"])

  legacy = nil
  if summary.nil? && tests_json.nil?
    legacy, legacy_error = run_json([*XCRESULTTOOL, "get", "--legacy",
                                     "--path", path, "--format", "json"])
    if legacy.nil?
      reasons << "xcresulttool could not read #{path}: #{summary_error || tests_error || legacy_error}"
      return nil
    end
  end

  stats = empty_stats
  failures = []
  # The bundle's own headline verdict. Counters can be truncated; when this says
  # the run failed we believe it regardless of what the counters add up to.
  bundle_verdict = nil

  if summary
    bundle_verdict  = STATUS_FAILED if summary["result"].to_s.casecmp?("failed")
    stats[:total]   = (summary["totalTestCount"] || summary["totalTests"] || 0).to_i
    stats[:failed]  = (summary["failedTests"] || 0).to_i
    stats[:skipped] = (summary["skippedTests"] || 0).to_i
    stats[:passed]  = (summary["passedTests"] || 0).to_i
    if summary["finishTime"] && summary["startTime"]
      stats[:duration] = (summary["finishTime"].to_f - summary["startTime"].to_f).round(2)
    end
  end

  if tests_json
    walk = lambda do |node|
      return unless node.is_a?(Hash)

      if node["nodeType"] == "Test Case" || node["nodeType"] == "Test"
        name = node["name"] || node["nodeIdentifier"]
        result = node["result"] || node["testResult"]
        if result == "Failed" || result == "failed"
          # `map { }.compact`, not `filter_map`: the latter needs Ruby 2.7+ and
          # macOS still ships 2.6 as `/usr/bin/ruby`. CI pins 3.3 so this never
          # showed up there — but locally it raised NoMethodError on the one
          # path that only runs when a test FAILS, burying the actual failure
          # under a parser stack trace exactly when it was needed.
          details = Array(node["children"]).map do |child|
            next unless child.is_a?(Hash)
            next unless (child["nodeType"] || "").downcase.include?("failure")

            child["name"] || child["nodeIdentifier"] || "failure"
          end
          failures << { name: name, details: details }
        end
      end
      Array(node["children"]).each { |child| walk.call(child) }
    end

    Array(tests_json["testNodes"]).each { |node| walk.call(node) }
    Array(tests_json["devicesAndConfigurations"]).each do |configuration|
      Array(configuration.dig("testPlanRunSummaries", "testPlanRunSummaries")).each { |node| walk.call(node) }
    end
  end

  if legacy && stats[:total].zero?
    metrics = legacy.dig("metrics", "_value") || legacy["metrics"] || {}
    stats[:total]  = (metrics.dig("testsCount", "_value") || metrics["testsCount"] || 0).to_i
    stats[:failed] = (metrics.dig("testsFailedCount", "_value") || metrics["testsFailedCount"] || 0).to_i
    stats[:passed] = 0
  end

  stats[:passed] = [stats[:total] - stats[:failed] - stats[:skipped], 0].max if stats[:passed].zero?
  { stats: stats, failures: failures, verdict: bundle_verdict }
end

# Recover pass/fail data from the raw xcodebuild log. Counts are approximate —
# Swift Testing and XCTest report separately and the log has no skip total — but
# a verified verdict beats a fabricated zero. Returns nil when the log carries no
# recognizable test-run summary.
def parse_log(path)
  return nil unless File.file?(path)

  text = File.read(path, mode: "rb")
  text = utf8(text)

  verdict = nil
  total = 0
  failed = 0
  duration = nil

  # Swift Testing: "✔ Test run with 1748 tests in 150 suites passed after 34.952 seconds."
  if (match = text.scan(/Test run with (\d+) tests?(?: in \d+ suites?)? (passed|failed)(?: after ([\d.]+) seconds)?/).last)
    total = match[0].to_i
    verdict = match[1] == "passed" ? STATUS_PASSED : STATUS_FAILED
    duration = match[2]&.to_f
  end

  # XCTest aggregate: "Executed 7 tests, with 1 failure (0 unexpected) in 0.4 seconds".
  # The last occurrence is the whole-bundle total; Swift Testing tests are not
  # included in it, so the two are additive.
  xctest = text.scan(/Executed (\d+) tests?, with (\d+) failures?/).last
  if xctest
    total += xctest[0].to_i
    failed += xctest[1].to_i
  end

  failures = text.scan(/✘ Test (.+?) (?:failed|recorded an issue)/).flatten
  # "✘ Test run with 5 tests in 2 suites failed" is the aggregate line, not a case.
  failures.reject! { |name| name.start_with?("run with ") }
  # Swift Testing does not contribute to XCTest's aggregate failure count.
  # Multiple issues from one test still represent one failed test.
  failed += failures.uniq.length
  failures.concat(text.scan(/Test Case '(.+?)' failed/).flatten)
  failures.uniq!

  # Swift Testing's progress output can prefix its arrow with a zero-width
  # space/BOM. Do not let a formatting character turn a skipped test into a pass.
  skipped = text.each_line.count { |line| line.match?(/^[\s\u200B\uFEFF]*\S?[\s\u200B\uFEFF]*Test .+ skipped\b/) }

  # An explicit overall verdict in the log outranks the per-framework lines.
  verdict = STATUS_FAILED if text.include?("** TEST FAILED **")
  verdict = STATUS_PASSED if verdict.nil? && text.include?("** TEST SUCCEEDED **")
  verdict = STATUS_FAILED if failed.positive? || !failures.empty?

  return nil if verdict.nil? && total.zero?

  {
    verdict: verdict,
    stats: {
      total: total,
      passed: [total - failed - skipped, 0].max,
      failed: failed,
      skipped: skipped,
      duration: duration
    },
    failures: failures.map { |name| { name: name, details: [] } }
  }
end

# --- gather -----------------------------------------------------------------

reasons = []
stats = nil
failures = []
source = SOURCE_NONE
verdict = nil
total_mismatch = false

if File.directory?(xcresult_path)
  parsed = parse_xcresult(xcresult_path, reasons)
  if parsed
    stats = parsed[:stats]
    failures = parsed[:failures]
    verdict = parsed[:verdict]
    source = SOURCE_XCRESULT
  end
else
  reasons << "xcresult bundle not found at #{xcresult_path}."
end

# The log is read on every run, not only when the bundle is unreadable: it is the
# only independent witness of what xcodebuild actually executed.
log_view = parse_log(log_path)
log_stats = log_view&.fetch(:stats, nil)

# Fall back to the raw log when the bundle gave us nothing usable. A parsed
# bundle reporting zero tests is also treated as "nothing usable": that is what a
# bundle killed mid-write looks like, and it is exactly the case that used to
# render as a green check.
if stats.nil? || stats[:total].to_i.zero?
  if log_view
    reasons << "Recovered pass/fail data from #{log_path} (counts are approximate)."
    stats = log_view[:stats]
    failures = log_view[:failures]
    verdict = log_view[:verdict]
    source = SOURCE_LOG
  elsif File.file?(log_path)
    reasons << "#{log_path} carries no recognizable test-run summary line."
  else
    reasons << "No xcodebuild log at #{log_path} to fall back on."
  end
elsif log_view
  # Bundle and log both have data — cross-check them. A bundle that is stale or
  # was truncated mid-run parses cleanly and under-reports, so the log wins on
  # any disagreement about whether tests failed.
  if log_view[:verdict] == STATUS_FAILED
    verdict = STATUS_FAILED
    if failures.empty? && !log_view[:failures].empty?
      reasons << "The xcresult bundle lists no failures, but #{log_path} does; using the log's list."
      failures = log_view[:failures]
    end
    if stats[:failed].to_i.zero?
      reasons << "The xcresult bundle reports failed=0 while #{log_path} records a failed run; " \
                 "the bundle is stale or was written by a run that died before finalizing."
    end
    if log_stats[:failed].to_i > stats[:failed].to_i
      stats[:failed] = log_stats[:failed]
      stats[:passed] = [stats[:total] - stats[:failed] - stats[:skipped], 0].max
    end
  end

  log_total = log_stats[:total].to_i
  if log_total.positive? && log_total != stats[:total].to_i
    total_mismatch = true
    delta = log_total - stats[:total].to_i
    detail = if delta.positive?
               "The bundle is missing #{delta} of the tests the log ran, so any failure among them would be invisible here."
             else
               "The bundle reports #{delta.abs} extra test entries; totals cannot be reconciled (for example, an issue outside a test may create a synthetic entry)."
             end
    reasons << "Test total disagrees with the xcodebuild log: report=#{stats[:total]} log=#{log_total} " \
               "(delta #{format("%+d", delta)}). #{detail}"
  end
end

stats ||= empty_stats

if test_exit && !test_exit.zero?
  reasons << "xcodebuild exited #{test_exit}; a non-zero exit can never be reported as a pass."
end

status =
  if verdict == STATUS_FAILED || stats[:failed].to_i.positive? || !failures.empty?
    STATUS_FAILED
  elsif source == SOURCE_NONE
    STATUS_UNKNOWN
  elsif test_exit && !test_exit.zero?
    STATUS_UNKNOWN
  elsif total_mismatch
    STATUS_UNKNOWN
  elsif stats[:total].to_i.zero? && !allow_empty
    reasons << "Parsed zero tests; refusing to report an unverified pass (use --allow-empty if that is expected)."
    STATUS_UNKNOWN
  else
    STATUS_PASSED
  end

# --- JSON output ------------------------------------------------------------

File.write(json_path, "#{JSON.pretty_generate({
  ok: status == STATUS_PASSED,
  status: status,
  source: source,
  xcresult: xcresult_path,
  log: File.file?(log_path) ? log_path : nil,
  test_exit: test_exit,
  reasons: reasons,
  stats: stats,
  log_stats: source == SOURCE_XCRESULT ? log_stats : nil,
  total_mismatch: total_mismatch,
  failures: failures
})}\n")

# --- Markdown output --------------------------------------------------------

md = +"# Xedit Test Report\n\n"

case status
when STATUS_PASSED
  md << "**Status:** ✅ "
when STATUS_FAILED
  md << "**Status:** ❌ "
else
  md << "**Status:** ⚠️ UNKNOWN — result could not be verified; "
end
md << "passed=#{stats[:passed]} failed=#{stats[:failed]} skipped=#{stats[:skipped]} total=#{stats[:total]}"
md << " (#{stats[:duration]}s)" if stats[:duration]
md << "\n\n"
md << "**Source:** #{source}\n\n"

unless reasons.empty?
  md << (status == STATUS_UNKNOWN ? "## Why this is not a pass\n\n" : "## Notes\n\n")
  reasons.each { |reason| md << "- #{reason}\n" }
  md << "\n"
end

if failures.empty?
  md << (status == STATUS_UNKNOWN ? "_No failure list available._\n" : "_No failures._\n")
else
  md << "## Failures\n\n"
  failures.first(50).each do |failure|
    md << "- **#{failure[:name]}**\n"
    Array(failure[:details]).first(5).each { |detail| md << "  - `#{detail}`\n" }
  end
  md << "\n_…and #{failures.length - 50} more_\n" if failures.length > 50
end

File.write(md_path, md)

warn "xcresult_report: #{status} (source=#{source})" unless status == STATUS_PASSED
reasons.each { |reason| warn "xcresult_report: #{reason}" } unless status == STATUS_PASSED

case status
when STATUS_PASSED then exit EXIT_PASSED
when STATUS_FAILED then exit EXIT_FAILED
else exit EXIT_UNKNOWN
end
