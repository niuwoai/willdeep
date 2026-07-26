#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "rexml/document"
require "time"

ROOT = File.expand_path("..", __dir__)
SCHEME_PATH = File.join(ROOT, "Xedit.xcodeproj", "xcshareddata", "xcschemes", "XeditUnitTests.xcscheme")
FAST_RUNNER_PATH = File.join(ROOT, "scripts", "run_tests_fast.rb")
FULL_RUNNER_PATH = File.join(ROOT, "scripts", "run_tests.sh")

def check(condition, message, results)
  results << { "ok" => condition, "message" => message }
end

scheme_source = File.read(SCHEME_PATH, encoding: "UTF-8")
scheme = REXML::Document.new(scheme_source)
fast_runner = File.read(FAST_RUNNER_PATH, encoding: "UTF-8")
full_runner = File.read(FULL_RUNNER_PATH, encoding: "UTF-8")
results = []

buildable_names = REXML::XPath.match(scheme, "//BuildableReference").map do |node|
  node.attributes["BlueprintName"]
end
testable_names = REXML::XPath.match(scheme, "//TestAction/Testables/TestableReference/BuildableReference").map do |node|
  node.attributes["BlueprintName"]
end
test_action = REXML::XPath.first(scheme, "//TestAction")

check(buildable_names.include?("Xedit"), "Unit scheme builds the hosted app target.", results)
check(buildable_names.include?("XeditTests"), "Unit scheme builds XeditTests.", results)
check(!buildable_names.include?("XeditUITests"), "Unit scheme excludes XeditUITests.", results)
check(testable_names == ["XeditTests"], "Unit scheme executes only XeditTests.", results)
check(test_action&.attributes&.[]("codeCoverageEnabled") == "NO", "Local unit coverage is disabled.", results)

[
  ["-clonedSourcePackagesDirPath", "Fast runner reuses SwiftPM checkouts."],
  ["-packageCachePath", "Fast runner reuses the SwiftPM package cache."],
  ["--git-common-dir", "Fast runner derives shared package cache from the repository root."],
  ["-skipPackageUpdates", "Fast runner skips package update checks."],
  ["-onlyUsePackageVersionsFromResolvedFile", "Fast runner pins Package.resolved versions."],
  ["-enableCodeCoverage\", \"NO", "Fast runner disables coverage."],
  ["-showBuildTimingSummary", "Fast runner records build timing."],
  ["Source or build inputs changed", "Stale test-without-building is rejected."],
  ["project_build_guard.rb", "Fast runner uses the repository build coordinator."]
].each do |needle, message|
  check(fast_runner.include?(needle), message, results)
end

check(full_runner.include?("-scheme XeditUnitTests"), "Full local test runner uses the unit-only scheme.", results)
check(
  full_runner.include?("-onlyUsePackageVersionsFromResolvedFile"),
  "Full local test runner pins Package.resolved versions.",
  results
)

failed = results.reject { |result| result["ok"] }
report = {
  "ok" => failed.empty?,
  "checked_at" => Time.now.utc.iso8601,
  "checks" => results
}

json_path = ARGV[0]
markdown_path = ARGV[1]
File.write(json_path, JSON.pretty_generate(report)) if json_path
if markdown_path
  lines = ["# Fast Test Entry Contract", "", "- Status: #{report["ok"] ? "pass" : "fail"}", "", "## Checks", ""]
  results.each { |result| lines << "- #{result["ok"] ? "PASS" : "FAIL"}: #{result["message"]}" }
  File.write(markdown_path, "#{lines.join("\n")}\n")
end

abort failed.map { |result| result["message"] }.join("\n") unless failed.empty?

puts JSON.pretty_generate(report)
