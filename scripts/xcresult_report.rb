#!/usr/bin/env ruby
# frozen_string_literal: true

# xcresult_report.rb — parse xcodebuild's xcresult bundle into markdown + json.
#
# Usage:
#   scripts/xcresult_report.rb <xcresult-path> <out.md> <out.json>
#
# Implementation note: macOS 15 + Xcode 16's xcresulttool requires
# `--legacy` to keep the old `get --format json` interface. We try the
# legacy invocation first and fall back to the new `get test-results`
# subcommand. Either way, we emit a compact, model-friendly summary.

require "json"
require "open3"

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

xcresult_path = ARGV[0] or abort("usage: xcresult_report.rb <xcresult> <out.md> <out.json>")
md_path       = ARGV[1] or abort("usage: xcresult_report.rb <xcresult> <out.md> <out.json>")
json_path     = ARGV[2] or abort("usage: xcresult_report.rb <xcresult> <out.md> <out.json>")

unless File.directory?(xcresult_path)
  warn "xcresult not found: #{xcresult_path}"
  File.write(md_path, "# Xedit Test Report\n\n_no xcresult at #{xcresult_path}_\n")
  File.write(json_path, JSON.pretty_generate({ ok: false, reason: "missing-xcresult" }))
  exit 0
end

def run_json(cmd)
  out, _err, status = Open3.capture3(*cmd)
  return nil unless status.success?
  out = out.force_encoding(Encoding::UTF_8)
  out = out.scrub("?") unless out.valid_encoding?
  JSON.parse(out)
rescue JSON::ParserError, Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError
  nil
end

# Try the modern command first (Xcode 16+):
#   xcrun xcresulttool get test-results summary --path X --format json
summary = run_json(["xcrun", "xcresulttool", "get", "test-results", "summary",
                    "--path", xcresult_path, "--format", "json"])

tests_json = run_json(["xcrun", "xcresulttool", "get", "test-results", "tests",
                       "--path", xcresult_path, "--format", "json"])

# Fallback: legacy invocation
legacy = nil
if summary.nil? && tests_json.nil?
  legacy = run_json(["xcrun", "xcresulttool", "get", "--legacy",
                     "--path", xcresult_path, "--format", "json"])
end

stats = {
  total:    0,
  passed:   0,
  failed:   0,
  skipped:  0,
  duration: nil
}
failures = []

if summary
  stats[:total]    = summary["totalTestCount"]    || summary["totalTests"]    || 0
  stats[:passed]   = summary["passedTests"]       || 0
  stats[:failed]   = summary["failedTests"]       || 0
  stats[:skipped]  = summary["skippedTests"]      || 0
  stats[:duration] = summary["finishTime"] && summary["startTime"] ?
                       (summary["finishTime"].to_f - summary["startTime"].to_f).round(2) : nil
end

# Walk the tests tree to collect failure details (modern format).
walk = lambda do |node|
  return unless node.is_a?(Hash)
  if node["nodeType"] == "Test Case" || node["nodeType"] == "Test"
    name   = node["name"] || node["nodeIdentifier"]
    result = node["result"] || node["testResult"]
    if result == "Failed" || result == "failed"
      details = []
      Array(node["children"]).each do |child|
        next unless child.is_a?(Hash)
        next unless (child["nodeType"] || "").downcase.include?("failure")
        details << (child["name"] || child["nodeIdentifier"] || "failure")
      end
      failures << { name: name, details: details }
    end
  end
  Array(node["children"]).each { |c| walk.call(c) }
end

if tests_json
  Array(tests_json["testNodes"]).each { |n| walk.call(n) }
  Array(tests_json["devicesAndConfigurations"]).each do |dc|
    Array(dc.dig("testPlanRunSummaries", "testPlanRunSummaries")).each { |s| walk.call(s) }
  end
end

# Legacy-format extraction if modern paths empty
if legacy && stats[:total] == 0
  metrics = legacy.dig("metrics", "_value") || legacy["metrics"] || {}
  stats[:total]   = (metrics.dig("testsCount", "_value") || metrics["testsCount"] || 0).to_i
  stats[:failed]  = (metrics.dig("testsFailedCount", "_value") || metrics["testsFailedCount"] || 0).to_i
  stats[:passed]  = stats[:total] - stats[:failed] - stats[:skipped]
end

stats[:passed] = [stats[:total] - stats[:failed] - stats[:skipped], 0].max if stats[:passed] == 0

# JSON output
File.write(json_path, JSON.pretty_generate({
  ok: stats[:failed] == 0,
  xcresult: xcresult_path,
  stats: stats,
  failures: failures
}))

# Markdown output
md = +""
md << "# Xedit Test Report\n\n"
status_emoji = stats[:failed] == 0 ? "✅" : "❌"
md << "**Status:** #{status_emoji} "
md << "passed=#{stats[:passed]} failed=#{stats[:failed]} skipped=#{stats[:skipped]} total=#{stats[:total]}"
md << " (#{stats[:duration]}s)" if stats[:duration]
md << "\n\n"

if failures.empty?
  md << "_No failures._\n"
else
  md << "## Failures\n\n"
  failures.first(50).each do |f|
    md << "- **#{f[:name]}**\n"
    f[:details].first(5).each { |d| md << "  - `#{d}`\n" }
  end
  md << "\n_…and #{failures.length - 50} more_\n" if failures.length > 50
end

File.write(md_path, md)
