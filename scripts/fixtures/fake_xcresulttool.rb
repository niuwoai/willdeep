#!/usr/bin/env ruby
# frozen_string_literal: true

# fake_xcresulttool.rb — replay recorded xcresulttool output.
#
# scripts/xcresult_report.rb shells out to `xcrun xcresulttool` and honours
# WILLDEEP_XCRESULTTOOL as an override. Point that at this script to feed the
# reporter a bundle whose contents the test controls — the interesting failure
# modes (a bundle that is stale, or truncated before its last suites landed)
# cannot be produced with a real xcresulttool.
#
# Usage:
#   WILLDEEP_XCRESULTTOOL="ruby scripts/fixtures/fake_xcresulttool.rb" \
#   FAKE_XCRESULT_DIR=/path/with/summary.json+tests.json \
#     scripts/xcresult_report.rb <bundle> <out.md> <out.json>
#
# The directory supplies `summary.json` and `tests.json`. A missing file makes
# that sub-command fail the way xcresulttool does on an unreadable bundle.

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

directory = ENV["FAKE_XCRESULT_DIR"].to_s
if directory.empty?
  warn "fake_xcresulttool: FAKE_XCRESULT_DIR is not set"
  exit 2
end

fixture =
  if ARGV.include?("summary")
    "summary.json"
  elsif ARGV.include?("tests")
    "tests.json"
  else
    "legacy.json"
  end

path = File.join(directory, fixture)
unless File.file?(path)
  warn "fake_xcresulttool: no #{fixture} in #{directory}"
  exit 1
end

print File.read(path, encoding: "UTF-8")
