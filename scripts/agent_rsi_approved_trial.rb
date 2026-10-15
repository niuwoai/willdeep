#!/usr/bin/env ruby
# frozen_string_literal: true

# No provider key is read here. Only the host broker's per-trial capability in
# the external 0600 control file can authorize a model request.
require "json"
require "optparse"
require "fileutils"
require_relative "agent_rsi_frozen_runner"
root = File.expand_path("..", __dir__)
options = { mode: "preview" }
OptionParser.new do |parser|
  parser.on("--control PATH") { |value| options[:control] = File.expand_path(value) }
  parser.on("--execute") { options[:mode] = "execute" }
  parser.on("--freeze-runner PATH") { |value| options[:freeze] = File.expand_path(value) }
  parser.on("--frozen-runner PATH") { |value| options[:frozen] = File.expand_path(value) }
end.parse!
if options[:freeze]
  AgentRSIFrozenRunner.freeze(root, options[:freeze])
  exit 0
end
abort "--control is required" unless options[:control]
metadata = File.lstat(options[:control])
abort "control must be a regular 0600 file" unless metadata.file? && !metadata.symlink? && (metadata.mode & 0o777) == 0o600
control = JSON.parse(File.read(options[:control]))
output = control.fetch("output_directory")
abort "trial output directory must be new" if File.exist?(output) || File.symlink?(output)
configuration = File.join(root, "build", "rsi-approved-trial-input.json")
FileUtils.mkdir_p(File.dirname(configuration), mode: 0o700)
File.write(configuration, JSON.generate({control_path: options[:control], mode: options[:mode]}), mode: "w", perm: 0o600)
begin
  success = if options[:frozen]
    AgentRSIFrozenRunner.run(root, options[:frozen])
  else
    system("ruby", File.join(root, "scripts/run_tests_fast.rb"),
      "-only-testing:XeditTests/AgentRSIApprovedTrialTests/hostControlledNativeEntry()", "-parallel-testing-enabled", "NO", "-jobs", "2", chdir: root)
  end
  observation_path = File.join(output, "observation.json")
  success &&= File.file?(observation_path)
  if success && options[:mode] == "preview"
    observation = JSON.parse(File.read(observation_path))
    success &&= observation["status"] == "preview" && File.file?(File.join(output, "first_request.json"))
    success &&= observation.fetch("events").none? { |event| event["kind"] == "request_started" }
  end
  puts JSON.generate({passed: success, mode: options[:mode], report: File.join(root, "build/fast-tests/report.json")})
  exit(success ? 0 : 1)
ensure
  File.delete(configuration) if File.exist?(configuration)
end
