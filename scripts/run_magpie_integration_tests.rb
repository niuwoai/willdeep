#!/usr/bin/env ruby
# frozen_string_literal: true

# Compile the real Foundation-only reader/transport and the same Swift Testing
# suite Xcode discovers. No App launch, user settings, Keychain, or external API.
require "fileutils"
require "pathname"
require "digest"
require "json"
require "open3"
require "time"

Encoding.default_external = Encoding::UTF_8

root = File.expand_path("..", __dir__)
fixture = File.expand_path(ARGV.fetch(0) { abort "Usage: ruby scripts/run_magpie_integration_tests.rb /absolute/path/to/canonical/cases.json" })
abort "Canonical fixture missing: #{fixture}" unless File.file?(fixture)
package = File.join(root, "build", "magpie-integration-tests")
FileUtils.mkdir_p(package)
File.open(File.join(package, ".run.lock"), File::RDWR | File::CREAT, 0o600) do |lock|
  lock.flock(File::LOCK_EX)
  sources = File.join(package, "Sources", "MagpieIntegrationCore")
  tests = File.join(package, "Tests", "MagpieIntegrationCoreTests")
  FileUtils.mkdir_p([sources, tests])
  inputs = %w[AgentMagpieIntegration.swift AgentMagpieTransport.swift].map { |name| File.join(root, "Xedit", name) } +
    %w[AgentMagpieIntegrationTests.swift MagpieFakeUpstream.swift].map { |name| File.join(root, "XeditTests", name) } + [fixture]
  fingerprint = -> { inputs.to_h { |path| [path, Digest::SHA256.file(path).hexdigest] } }
  before = fingerprint.call
  %w[AgentMagpieIntegration.swift AgentMagpieTransport.swift].each do |name|
    FileUtils.cp(File.join(root, "Xedit", name), File.join(sources, name))
  end
  %w[AgentMagpieIntegrationTests.swift MagpieFakeUpstream.swift].each do |name|
    FileUtils.cp(File.join(root, "XeditTests", name), tests)
  end
  manifest = <<~SWIFT
    // swift-tools-version: 6.2
    import PackageDescription
    let package = Package(name: "MagpieIntegrationCore", platforms: [.macOS(.v14)],
      products: [.library(name: "MagpieIntegrationCore", targets: ["MagpieIntegrationCore"])],
      targets: [.target(name: "MagpieIntegrationCore"),
        .testTarget(name: "MagpieIntegrationCoreTests", dependencies: ["MagpieIntegrationCore"])])
  SWIFT
  File.write(File.join(package, "Package.swift"), manifest)
  started = Time.now.utc
  output = +""
  status = nil
  command = ["swift", "test", "--package-path", package, "--parallel"]
  File.open(File.join(package, "swift-test.log"), "w") do |log|
    Open3.popen2e({ "WILLDEEP_MAGPIE_FIXTURES" => fixture }, *command, chdir: root) do |stdin, stream, process|
      stdin.close
      stream.each_line { |line| output << line; log.write(line); $stdout.write(line) }
      status = process.value
    end
  end
  summary = output.match(/Test run with (\d+) tests? in (\d+) suites? passed/)
  unchanged = before == fingerprint.call
  success = status.success? && summary && summary[1].to_i.positive? && unchanged
  report = { ok: !!success, exit_status: status.exitstatus, started_at: started.iso8601,
    finished_at: Time.now.utc.iso8601, tests: summary && summary[1].to_i,
    suites: summary && summary[2].to_i, inputs_unchanged: unchanged,
    fixture_cases: JSON.parse(File.read(fixture)).fetch("cases").length,
    fixture_sha256: before.fetch(fixture), command: command, input_sha256: before,
    log: File.join(package, "swift-test.log") }
  File.write(File.join(package, "report.json"), JSON.pretty_generate(report))
  File.write(File.join(package, "report.md"), "# Magpie Native Contract Tests\n\nStatus: #{success ? 'PASS' : 'FAIL'}\n\nTests: #{report[:tests] || 'unconfirmed'}; suites: #{report[:suites] || 'unconfirmed'}; raw fixtures: #{report[:fixture_cases]}.\n\nInputs unchanged: #{unchanged}. Exit: #{status.exitstatus}.\n\nLog: `#{report[:log]}`\n")
  exit(success ? 0 : 1)
end
