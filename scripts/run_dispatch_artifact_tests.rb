# frozen_string_literal: true

# Compile the real Git integration kernel and its existing Swift Testing suites
# without building the entire UI. This is not a replacement for XeditTests.
require "digest"
require "fileutils"
require "json"
require "open3"
require_relative "lib/swift_testing_summary"

ROOT = File.expand_path("..", __dir__)
OUTPUT = File.join(ROOT, "build", "dispatch-artifact-tests")

def inputs
  result = {}
  ["AgentSubprocess.swift", "AgentDispatchArtifactIntegrator.swift", "AgentDispatchDeliveryJournal.swift",
   "AgentDispatchVerificationReceipt.swift", "AgentGoalContinuationBudget.swift", "AgentToolExecutionBudget.swift",
   "AgentDispatchReadyScheduler.swift", "AgentModelRequestLedger.swift"].each do |name|
    result["Sources/WillDeep/#{name}"] = File.read(File.join(ROOT, "Xedit", name))
  end
  tools = File.read(File.join(ROOT, "Xedit", "AgentTools.swift"))
  support = tools[/enum AgentProcessSupport \{.*?(?=\n\/\/ MARK: - Tool runner)/m]
  abort "AgentProcessSupport source boundary changed; refusing to substitute a test implementation" unless support&.include?("class Waiter")
  result["Sources/WillDeep/AgentProcessSupport.swift"] = "import Foundation\nimport Darwin\n" + support
  ["AgentDispatchArtifactIntegratorTests.swift", "AgentDispatchDeliveryJournalTests.swift", "AgentSubprocessTests.swift",
   "AgentToolExecutionBudgetTests.swift", "AgentDispatchReadySchedulerTests.swift", "AgentSubprocessOutputTests.swift"].each do |name|
    result["Tests/WillDeepTests/#{name}"] = File.read(File.join(ROOT, "XeditTests", name))
  end
  result["Package.swift"] = [
    "// swift-tools-version: 6.2", "import PackageDescription",
    'let package = Package(name: "WillDeepKernelTests", platforms: [.macOS(.v14)],',
    '  products: [.library(name: "WillDeep", targets: ["WillDeep"])],',
    '  targets: [.target(name: "WillDeep"), .testTarget(name: "WillDeepTests", dependencies: ["WillDeep"])])', ""
  ].join("\n")
  result
end

def fingerprint(contents)
  Digest::SHA256.hexdigest(contents.sort.map { |path, body| "#{path}\0#{body}" }.join("\0"))
end

if ARGV == ["--help"]
  puts "Usage: ruby scripts/run_dispatch_artifact_tests.rb [--check]"
  puts "--check validates source extraction only; it does not run or claim passing tests."
  exit 0
end
abort "Unknown arguments: #{ARGV.inspect}" unless ARGV.empty? || ARGV == ["--check"]
snapshot = inputs
if ARGV == ["--check"]
  puts "source extraction: #{snapshot.length} generated inputs, fingerprint #{fingerprint(snapshot)}"
  exit 0
end

FileUtils.mkdir_p(OUTPUT)
File.open(File.join(OUTPUT, "runner.lock"), File::RDWR | File::CREAT, 0o600) do |lock|
  lock.flock(File::LOCK_EX)
  snapshot = inputs
  snapshot.each do |path, body|
    target = File.join(OUTPUT, path)
    FileUtils.mkdir_p(File.dirname(target))
    File.write(target, body) unless File.file?(target) && File.read(target) == body
  end
  command = ["swift", "test", "--package-path", OUTPUT, "--jobs", "2"]
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  output, status = Open3.capture2e(*command)
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  File.write(File.join(OUTPUT, "swift-test.log"), output)
  passed_count = SwiftTestingSummary.passed_count(output)
  unchanged = fingerprint(snapshot) == fingerprint(inputs)
  passed = status.success? && passed_count.positive? && unchanged
  report = {
    status: passed ? "passed" : "failed_or_unverified", exit_code: status.exitstatus,
    tests_passed: passed_count, seconds: elapsed.round(3), source_unchanged: unchanged,
    source_fingerprint: fingerprint(snapshot), command: command, cache: File.join(OUTPUT, ".build"),
    scope: "Real artifact integration and subprocess component tests; not full App acceptance"
  }
  File.write(File.join(OUTPUT, "report.json"), JSON.pretty_generate(report) + "\n")
  File.write(File.join(OUTPUT, "report.md"), [
    "# Dispatch artifact component tests", "", "Status: #{report[:status]}",
    "Tests passed: #{passed_count}; exit: #{status.exitstatus}; duration: #{report[:seconds]}s",
    "Source unchanged: #{unchanged}; fingerprint: #{report[:source_fingerprint]}",
    "", report[:scope], "", "Full output: swift-test.log", ""
  ].join("\n"))
  puts output.lines.select { |line| line.match?(/error:|warning:|Test run|failed|passed/) }.join
  puts JSON.generate(report)
  exit(passed ? 0 : 1)
end
