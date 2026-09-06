# frozen_string_literal: true
require 'minitest/autorun'
require_relative 'goal_soak'

class GoalSoakEvidenceTest < Minitest::Test
  def record
    { 'final' => true, 'runtime_id' => 'fixture', 'requested_seconds' => 14_400,
      'elapsed_seconds' => 14_401, 'reached_duration' => true, 'verified_reads' => 3000,
      'compressions' => 40, 'empty_responses' => 60, 'failures' => [], 'pending_user_decisions' => 0,
      'unfinished_requests' => 0, 'requests' => 3100, 'ledger_attempts' => 3100 }
  end

  def verify(records, report = { 'ok' => true, 'test_exit' => 0, 'stats' => { 'total' => 1, 'passed' => 1 } })
    GoalSoakEvidence.verify(records, seconds: 14_400, test_report: report)
  end

  def test_complete_evidence
    assert verify([record])['ok']
  end

  def test_short_smoke_cannot_pass_as_four_hours
    refute verify([record.merge('requested_seconds' => 3, 'elapsed_seconds' => 10)])['ok']
  end

  def test_missing_or_repeated_terminal_is_rejected
    refute verify([])['ok']
    refute verify([record, record])['ok']
  end

  def test_failed_gate_or_invariants_are_rejected
    refute verify([record], {})['ok']
    refute verify([record.merge('failures' => ['lost_constraint'])])['ok']
    refute verify([record.merge('compressions' => 0)])['ok']
  end

  def test_restarting_fixture_does_not_count_as_one_long_goal
    refute verify([record.merge('final' => false, 'runtime_id' => 'other'), record])['ok']
  end

  def test_unsettled_or_missing_requests_fail
    refute verify([record.merge('unfinished_requests' => 1)])['ok']
    refute verify([record.merge('ledger_attempts' => 3099)])['ok']
  end
end
