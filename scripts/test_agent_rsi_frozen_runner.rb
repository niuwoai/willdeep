#!/usr/bin/env ruby
# frozen_string_literal: true
require "minitest/autorun"
require "tmpdir"
require_relative "agent_rsi_frozen_runner"

class AgentRSIFrozenRunnerTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("willdeep-frozen-runner-test-")
    @old_derived = ENV["WILLDEEP_XCODE_DERIVED_DATA_PATH"]
    ENV["WILLDEEP_XCODE_DERIVED_DATA_PATH"] = File.join(@root, "derived")
    @app = File.join(ENV.fetch("WILLDEEP_XCODE_DERIVED_DATA_PATH"), "Build/Products/Debug/WillDeep.app")
    @files = ["Contents/MacOS/WillDeep", "Contents/MacOS/WillDeep.debug.dylib", "Contents/PlugIns/XeditTests.xctest/Contents/MacOS/XeditTests"]
    @files.each do |relative|
      file = File.join(@app, relative); FileUtils.mkdir_p(File.dirname(file)); File.write(file, relative)
    end
    FileUtils.mkdir_p(File.join(@root, "scripts"))
    %w[agent_rsi_approved_trial.rb agent_rsi_frozen_runner.rb].each { |name| File.write(File.join(@root, "scripts", name), name) }
    @manifest = File.join(@root, "runner.json")
    capture_io { AgentRSIFrozenRunner.freeze(@root, @manifest) }
    @document = JSON.parse(File.read(@manifest))
  end
  def teardown
    @old_derived ? ENV["WILLDEEP_XCODE_DERIVED_DATA_PATH"] = @old_derived : ENV.delete("WILLDEEP_XCODE_DERIVED_DATA_PATH")
    FileUtils.remove_entry(@root)
  end
  def test_actual_code_dylib_and_test_bundle_are_included
    assert_equal @files.sort, @document.fetch("app_files").keys.sort
    assert_equal 0o600, File.stat(@manifest).mode & 0o777
    AgentRSIFrozenRunner.verify(@root, @document)
  end
  def test_changed_code_dylib_is_rejected
    File.write(File.join(@app, "Contents/MacOS/WillDeep.debug.dylib"), "different")
    capture_io { assert_raises(SystemExit) { AgentRSIFrozenRunner.verify(@root, @document) } }
  end
  def test_changed_test_bundle_is_rejected
    File.write(File.join(@app, @files.last), "different")
    capture_io { assert_raises(SystemExit) { AgentRSIFrozenRunner.verify(@root, @document) } }
  end
  def test_added_bundle_resource_is_rejected
    File.write(File.join(@app, "unexpected-resource"), "different")
    capture_io { assert_raises(SystemExit) { AgentRSIFrozenRunner.verify(@root, @document) } }
  end
  def test_changed_adapter_script_is_rejected
    File.write(File.join(@root, "scripts/agent_rsi_approved_trial.rb"), "different")
    capture_io { assert_raises(SystemExit) { AgentRSIFrozenRunner.verify(@root, @document) } }
  end
end
