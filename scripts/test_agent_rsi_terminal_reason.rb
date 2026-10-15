#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "tmpdir"

root = File.expand_path("..", __dir__)
output = File.join(root, "build", "rsi-terminal-reason")
FileUtils.mkdir_p(output)
Dir.mktmpdir("willdeep-terminal-swift-") do |directory|
  binary = File.join(directory, "terminal-tests")
  command = ["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6",
             "-module-cache-path", File.join(directory, "module-cache"),
             File.join(root, "Xedit", "AgentSubagentTerminationReason.swift"),
             File.join(root, "scripts", "agent_rsi_terminal_reason_tests.swift"), "-o", binary]
  abort "Isolated production terminal compilation failed" unless system(*command)
  abort "Production terminal tests failed" unless system(binary, output)
end
