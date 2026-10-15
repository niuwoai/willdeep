#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "open3"
require "tmpdir"
require "rbconfig"

class AgentRSIFreeReviewEntryContractTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("willdeep-free-entry-", "/private/tmp")
    @cache = File.join(@root, "cache")
    @script = File.join(@root, "scripts", "agent_rsi_free_review.rb")
    FileUtils.mkdir_p(File.dirname(@script))
    File.binwrite(@script, File.binread(File.join(__dir__, "agent_rsi_free_review.rb")))
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def invoke(*args, cache: @cache)
    Open3.capture3({"WILLDEEP_XCODE_CACHE_ROOT" => cache}, RbConfig.ruby, @script, *args)
  end

  def test_live_or_legacy_arguments_are_rejected_before_building
    ["--execute", "--model", "--control"].each do |argument|
      _, error, status = invoke(argument)
      refute status.success?
      assert_includes error, "Only offline_mock_only"
      refute File.exist?(@cache)
    end
  end

  def test_user_or_frozen_cache_location_is_rejected_before_creation
    _, error, status = invoke("--offline-mock-only", cache: "/Users/not-a-real-user/frozen")
    refute status.success?
    assert_includes error, "independent temporary build cache"
  end

  def test_existing_observations_are_preserved
    directory = File.join(@root, "build", "rsi-free-review-v2")
    FileUtils.mkdir_p(directory)
    proof = File.join(directory, "immutable-proof")
    File.binwrite(proof, "prior evidence")
    _, error, status = invoke("--offline-mock-only")
    refute status.success?
    assert_includes error, "Existing observation directory"
    assert_equal "prior evidence", File.binread(proof)
  end

  def test_cache_symlink_cannot_escape_to_user_storage
    File.symlink("/Users", @cache)
    _, error, status = invoke("--offline-mock-only")
    refute status.success?
    assert_includes error, "Cache symlink escapes"
  end

  def test_another_entry_cannot_write_the_same_cache
    FileUtils.mkdir_p(@cache)
    File.open(File.join(@cache, ".free-review-build.lock"), File::RDWR | File::CREAT, 0o600) do |lock|
      lock.flock(File::LOCK_EX)
      _, error, status = invoke("--offline-mock-only")
      refute status.success?
      assert_includes error, "already building"
    end
  end
end
