#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "rexml/document"
require "time"

ROOT = File.expand_path("..", __dir__)
SCHEME_PATH = File.join(ROOT, "Xedit.xcodeproj", "xcshareddata", "xcschemes", "XeditUnitTests.xcscheme")
FAST_RUNNER_PATH = File.join(ROOT, "scripts", "run_tests_fast.rb")
FULL_RUNNER_PATH = File.join(ROOT, "scripts", "run_tests.sh")
FAST_BUILD_PATH = File.join(ROOT, "scripts", "build_fast.rb")
CI_GUARD_RUNNER_PATH = File.join(ROOT, "scripts", "run_ci_guard_group.rb")
WORKFLOW_PATH = File.join(ROOT, ".github", "workflows", "test.yml")

def check(condition, message, results)
  results << { "ok" => condition, "message" => message }
end

scheme_source = File.read(SCHEME_PATH, encoding: "UTF-8")
scheme = REXML::Document.new(scheme_source)
fast_runner = File.read(FAST_RUNNER_PATH, encoding: "UTF-8")
full_runner = File.read(FULL_RUNNER_PATH, encoding: "UTF-8")
fast_build = File.read(FAST_BUILD_PATH, encoding: "UTF-8")
ci_guard_runner = File.read(CI_GUARD_RUNNER_PATH, encoding: "UTF-8")
workflow = File.read(WORKFLOW_PATH, encoding: "UTF-8")
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
  ["LOCAL_XCODE_CACHE_ROOT", "Fast runner derives package cache from the shared local Xcode cache."],
  ["-skipPackageUpdates", "Fast runner skips package update checks."],
  ["-onlyUsePackageVersionsFromResolvedFile", "Fast runner pins Package.resolved versions."],
  ["-enableCodeCoverage\", \"NO", "Fast runner disables coverage."],
  ["-showBuildTimingSummary", "Fast runner records build timing."],
  ["WILLDEEP_XCODE_DERIVED_DATA_PATH", "Fast runner accepts repository-external DerivedData."],
  ["COMPILATION_CACHE_ENABLE_CACHING", "Fast runner enables Xcode compilation caching."],
  ["COMPILER_INDEX_STORE_ENABLE", "Fast runner disables CI index emission by default."],
  ["BUILD_INPUT_PATHS", "Fast runner fingerprints build inputs instead of unrelated documents."],
  ["git_diff_sha256", "Fast runner stores a bounded build-input diff digest."],
  ["local_build_credentials_sha256", "Fast runner invalidates for local generated credential inputs."],
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
check(
  full_runner.include?("WILLDEEP_XCODE_DERIVED_DATA_PATH"),
  "Full local test runner accepts repository-external DerivedData.",
  results
)
check(
  full_runner.include?("COMPILATION_CACHE_ENABLE_CACHING"),
  "Full local test runner enables Xcode compilation caching.",
  results
)
check(
  full_runner.include?("COMPILER_INDEX_STORE_ENABLE"),
  "Full local test runner disables CI index emission by default.",
  results
)
check(
  fast_runner.include?("Library\", \"Caches\", \"WillDeep\", \"Xcode\", \"Xedit"),
  "Fast runner defaults to the shared local Xcode cache.",
  results
)
check(
  full_runner.include?("Library/Caches/WillDeep/Xcode/Xedit"),
  "Full local runner defaults to the shared local Xcode cache.",
  results
)
check(
  fast_runner.include?("File.join(LOCAL_XCODE_CACHE_ROOT, \"PackageCache\")"),
  "Fast runner keeps package downloads separate from SwiftPM checkouts.",
  results
)
check(
  full_runner.include?("LOCAL_XCODE_CACHE_ROOT}/PackageCache"),
  "Full local runner keeps package downloads separate from SwiftPM checkouts.",
  results
)

[
  ["xcodebuild\", \"build", "Fast local build invokes the Xcode build action."],
  ["WILLDEEP_XCODE_CACHE_ROOT", "Fast local build supports a shared cache root override."],
  ["WILLDEEP_XCODE_DESTINATION", "Fast local build supports a destination override for release prewarming."],
  ["--destination DESTINATION", "Fast local build exposes an explicit destination option."],
  ["File.join(cache_root, \"PackageCache\")", "Fast local build separates package downloads from checkouts."],
  ["-clonedSourcePackagesDirPath", "Fast local build reuses SwiftPM checkouts."],
  ["-packageCachePath", "Fast local build reuses the SwiftPM package cache."],
  ["COMPILATION_CACHE_ENABLE_CACHING", "Fast local build enables Xcode compilation caching."],
  ["COMPILER_INDEX_STORE_ENABLE", "Fast local build disables CLI index emission by default."],
  ["project_build_guard.rb", "Fast local build uses the repository build coordinator."],
  ["build_report.json", "Fast local build emits a JSON report."],
  ["build_report.md", "Fast local build emits a Markdown report."]
].each do |needle, message|
  check(fast_build.include?(needle), message, results)
end

[
  ["ruby-guards:", "CI separates Ruby guards from native tests."],
  ["go-agent-tests:", "CI separates Go agent tests from native tests."],
  ["mac-unit-tests:", "CI keeps Xcode tests in a dedicated macOS job."],
  ["runs-on: [self-hosted, macOS, ARM64]", "Native tests require an Apple Silicon macOS runner."],
  ["xcodebuild build-for-testing", "CI builds test products once."],
  ["xcodebuild test-without-building", "CI executes tests without rebuilding."],
  ["Library/Caches/WillDeepCI/Xcode", "CI stores Xcode cache outside the checkout."],
  ["RUNNER_NAME:-default", "CI isolates persistent Xcode caches per runner process."],
  ["COMPILATION_CACHE_ENABLE_CACHING=YES", "CI enables Xcode compilation caching."],
  ["COMPILER_INDEX_STORE_ENABLE=NO", "CI disables index emission."]
].each do |needle, message|
  check(workflow.include?(needle), message, results)
end

%w[quality interaction short-drama].each do |group|
  check(
    ci_guard_runner.include?(%Q{"#{group}" =>}),
    "CI guard runner defines the #{group} group.",
    results
  )
end

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
