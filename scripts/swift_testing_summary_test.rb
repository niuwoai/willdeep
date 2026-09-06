# frozen_string_literal: true

require "minitest/autorun"
require_relative "lib/swift_testing_summary"

class SwiftTestingSummaryTest < Minitest::Test
  def test_summary_with_suite_count
    assert_equal 6, SwiftTestingSummary.passed_count("✔ Test run with 6 tests in 2 suites passed after 12.567 seconds.\n")
  end

  def test_legacy_summary_and_ansi_colors
    assert_equal 1, SwiftTestingSummary.passed_count("\e[32m✔ Test run with 1 test passed after 0.1 seconds.\e[0m\n")
  end

  def test_xctest_empty_suite_is_not_swift_testing_evidence
    assert_equal 0, SwiftTestingSummary.passed_count("Test Suite 'All tests' passed.\nExecuted 0 tests.\n")
  end

  def test_failed_or_missing_summary_cannot_pass
    assert_equal 0, SwiftTestingSummary.passed_count("✘ Test run with 6 tests in 2 suites failed after 1 second.")
    assert_equal 0, SwiftTestingSummary.passed_count("")
    assert_equal 0, SwiftTestingSummary.passed_count("✔ Test run with 0 tests passed after 1 second.")
  end
end
