#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'open3'
require 'optparse'
require 'tmpdir'
require 'fileutils'

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

module GoalSoakEvidence
  def self.verify(records, seconds:, test_report:)
    finals = records.select { |record| record['final'] == true }
    reasons = []
    reasons << 'test_gate_failed' unless test_report['ok'] == true && test_report['test_exit'] == 0 &&
      test_report.dig('stats', 'total') == 1 && test_report.dig('stats', 'passed') == 1
    reasons << 'missing_or_duplicate_final' unless finals.length == 1
    reasons << 'multiple_or_missing_runtime' unless records.map { |record| record['runtime_id'] }.uniq.length == 1 &&
      records.first&.fetch('runtime_id', nil).is_a?(String)
    final = finals.first || {}
    reasons << 'duration_not_proven' unless final['requested_seconds'] == seconds &&
      final.fetch('elapsed_seconds', 0) >= seconds && final['reached_duration'] == true
    reasons << 'trajectory_incomplete' unless final.fetch('verified_reads', 0) >= 257 &&
      final.fetch('compressions', 0) >= 4 && final.fetch('empty_responses', 0) >= 5
    reasons << 'invariant_failed' unless final['failures'] == [] && final['pending_user_decisions'] == 0 &&
      records.all? { |record| record['failures'] == [] && record['requested_seconds'] == seconds }
    reasons << 'request_accounting_incomplete' unless final['unfinished_requests'] == 0 &&
      final.fetch('requests', 0) > 0 && final['ledger_attempts'] == final['requests']
    { 'ok' => reasons.empty?, 'reasons' => reasons, 'final' => final }
  end

  def self.run(arguments)
    options = { seconds: 14_400, reuse: false }
    OptionParser.new do |parser|
      parser.banner = 'Usage: ruby scripts/goal_soak.rb [--seconds 14400] [--without-building]'
      parser.on('--seconds N', Integer) { |value| options[:seconds] = value }
      parser.on('--without-building') { options[:reuse] = true }
    end.parse!(arguments)
    abort 'seconds must be in 1..14400' unless (1..14_400).cover?(options[:seconds])
    root = File.expand_path('..', __dir__)
    output = Dir.mktmpdir('goal-soak-', File.join(root, 'build'))
    values = { 'WILLDEEP_GOAL_SOAK_SECONDS' => options[:seconds].to_s }
    environment = values.merge(values.transform_keys { |key| "TEST_RUNNER_#{key}" })
    command = ['ruby', File.join(__dir__, 'run_tests_fast.rb')]
    command << '--without-building' if options[:reuse]
    command << '-only-testing:XeditTests/AgentGoalSoakTests'
    command.concat(['-test-timeouts-enabled', 'YES', '-maximum-test-execution-time-allowance', (options[:seconds] + 180).to_s])
    puts "Goal soak evidence directory: #{output}"
    status = nil
    File.open(File.join(output, 'runner.log'), 'w') do |log|
      Open3.popen2e(environment, *command, chdir: root) do |input, stream, waiter|
        input.close
        stream.each_line do |line|
          log.write(line)
          next unless line.match?(/goal_soak_evidence|TEST.*(?:SUCCEEDED|FAILED)|recorded an issue|error:|Test run with|build slot/)
          puts line
          $stdout.flush
        end
        status = waiter.value
      end
    end
    evidence = File.join(root, 'build', 'fast-tests')
    FileUtils.cp_r(evidence, File.join(output, 'tests'))
    records = File.readlines(File.join(evidence, 'xcodebuild.log')).filter_map do |line|
      marker = line.index('goal_soak_evidence ')
      JSON.parse(line[(marker + 'goal_soak_evidence '.length)..]) if marker
    end
    test_report = JSON.parse(File.read(File.join(evidence, 'report.json')))
    result = verify(records, seconds: options[:seconds], test_report: test_report)
    result['ok'] &&= status.success?
    result['reasons'] << 'process_failed' unless status.success?
    result['process_exit'] = status.exitstatus
    result['requested_seconds'] = options[:seconds]
    result['checkpoints'] = records
    result['scope'] = 'One local Goal with isolated model transport; no real provider, crash/restart, remote executor or semantic completion claim.'
    File.write(File.join(output, 'report.json'), JSON.pretty_generate(result))
    File.write(File.join(output, 'report.md'), "# Goal continuous-run evidence\n\n- Passed: #{result['ok']}\n- Requested seconds: #{options[:seconds]}\n- Process exit: #{status.exitstatus}\n- Reasons: #{result['reasons'].join(', ')}\n\n#{result['scope']}\n")
    puts "Goal soak report: #{File.join(output, 'report.md')}"
    result['ok'] ? 0 : 1
  end
end

exit GoalSoakEvidence.run(ARGV) if $PROGRAM_NAME == __FILE__
