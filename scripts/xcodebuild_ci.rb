#!/usr/bin/env ruby
# frozen_string_literal: true

# xcodebuild_ci.rb streams xcodebuild output to both stdout and a log file.
# On macOS GitHub runners, xcodebuild can hang after Swift Testing reports that
# the whole test run passed. When that happens, let reports/artifacts continue
# instead of burning the entire job timeout.

require "fileutils"
require "optparse"

options = {
  log_path: "build/ci/xcodebuild.log",
  pass_grace_seconds: 180,
  idle_timeout_seconds: 180,
  term_grace_seconds: 15
}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: ruby scripts/xcodebuild_ci.rb [options] -- xcodebuild test ..."
  opts.on("--log PATH", "Write combined xcodebuild output to PATH") { |value| options[:log_path] = value }
  opts.on("--pass-grace SECONDS", Integer, "Seconds to wait after the full test run passed") do |value|
    options[:pass_grace_seconds] = value
  end
  opts.on("--idle-timeout SECONDS", Integer,
          "Once tests are running, terminate xcodebuild if it emits no output for this many seconds") do |value|
    options[:idle_timeout_seconds] = value
  end
  opts.on("--term-grace SECONDS", Integer,
          "Seconds to wait after SIGTERM before SIGKILL, giving xcodebuild a chance to finalize the xcresult") do |value|
    options[:term_grace_seconds] = value
  end
end

argv = ARGV.dup
separator = argv.index("--")
abort(parser.to_s) unless separator

parser.parse!(argv[0...separator])
command = argv[(separator + 1)..]
abort(parser.to_s) if command.empty?

FileUtils.mkdir_p(File.dirname(options[:log_path]))
log = File.open(options[:log_path], "w:UTF-8")

reader, writer = IO.pipe
pid = Process.spawn(*command, out: writer, err: writer, pgroup: true)
writer.close

pass_patterns = [
  /Test run with \d+ tests(?: in \d+ suites)? passed/
]
failed_patterns = [
  /Test run with .* failed/,
  /Test Suite .* failed/,
  /\*\* TEST FAILED \*\*/,
  /✘ Test .* failed/,
  /✘ Suite .* failed/
]
# Signals that the test phase is actually running. We only arm the idle
# watchdog after one of these appears so the (sometimes quiet) build/link
# phase can't trip it.
activity_patterns = [
  /Test Suite .* (?:started|passed)/,
  /[◇✔✘] (?:Test|Suite) /,
  /Test run with \d+ tests/
]

buffer = +""
test_run_passed_at = nil
test_run_failed = false
tests_active = false
last_output_at = Time.now
status = nil

def signal_process(pid, signal)
  Process.kill(signal, -pid)
rescue Errno::EPERM
  Process.kill(signal, pid)
rescue Errno::ESRCH
end

def wait_for_process(pid)
  Process.waitpid(pid)
rescue Errno::ECHILD
end

begin
  loop do
    if (waited = Process.waitpid2(pid, Process::WNOHANG))
      status = waited[1]
      break
    end

    grace_elapsed = test_run_passed_at && !test_run_failed &&
                    Time.now - test_run_passed_at >= options[:pass_grace_seconds]
    # Primary watchdog: xcodebuild on macOS runners often hangs *before*
    # printing the final "Test run ... passed" line, so the pass-grace timer
    # above never arms. Once any test activity has been seen, treat a long
    # output silence as a stale hang and reclaim the job. (Deliberately does
    # not exclude failures: a hang after a failed test must be reclaimed too,
    # and the exit-code logic below still reports it as a failure.)
    idle_elapsed = tests_active &&
                   Time.now - last_output_at >= options[:idle_timeout_seconds]

    if grace_elapsed || idle_elapsed
      reason = grace_elapsed ?
        "did not exit #{options[:pass_grace_seconds]}s after the full test run passed" :
        "emitted no output for #{options[:idle_timeout_seconds]}s after tests started running"
      message = "\n[xcodebuild_ci] xcodebuild #{reason}; terminating stale process group #{pid}.\n"
      STDOUT.write(message)
      STDOUT.flush
      log.write(message)
      log.flush
      # SIGTERM first, then wait out --term-grace before escalating. xcodebuild
      # writes the .xcresult bundle's Info.plist last; a SIGKILL two seconds in
      # leaves only Data/ and Staging/ behind, which every xcresulttool
      # invocation then rejects as corrupt. The grace period is best effort —
      # a truly wedged xcodebuild will not finalize no matter how long we wait,
      # which is why scripts/xcresult_report.rb can also recover counts from the
      # log below instead of trusting the bundle.
      signal_process(pid, "TERM")
      deadline = Time.now + options[:term_grace_seconds]
      reaped = nil
      loop do
        reaped = begin
          Process.waitpid2(pid, Process::WNOHANG)
        rescue Errno::ECHILD
          # Already reaped elsewhere; treat as exited so we don't SIGKILL a
          # recycled pid.
          [pid, nil]
        end
        break if reaped || Time.now >= deadline

        # Keep draining the pipe: a process blocked on a full stdout pipe can
        # never reach its own signal handling and finalize the bundle.
        next unless IO.select([reader], nil, nil, 0.5)

        drained = reader.read_nonblock(16_384, exception: false)
        unless drained.is_a?(String)
          # At EOF read_nonblock returns nil while select keeps reporting the
          # pipe readable; pace the loop so we don't spin hot waiting on waitpid.
          sleep 0.1
          next
        end

        drained = drained.force_encoding(Encoding::UTF_8)
        drained = drained.scrub("?") unless drained.valid_encoding?
        STDOUT.write(drained)
        STDOUT.flush
        log.write(drained)
        log.flush
      end

      unless reaped
        escalation = "[xcodebuild_ci] xcodebuild ignored SIGTERM for #{options[:term_grace_seconds]}s; " \
                     "sending SIGKILL. The .xcresult bundle may be incomplete — " \
                     "scripts/xcresult_report.rb will fall back to #{options[:log_path]}.\n"
        STDOUT.write(escalation)
        STDOUT.flush
        log.write(escalation)
        log.flush
        signal_process(pid, "KILL")
        wait_for_process(pid)
      end
      status = nil
      break
    end

    ready = IO.select([reader], nil, nil, 1)
    next unless ready

    chunk = reader.read_nonblock(16_384, exception: false)
    case chunk
    when :wait_readable
      next
    when nil
      next
    else
      chunk = chunk.force_encoding(Encoding::UTF_8)
      chunk = chunk.scrub("?") unless chunk.valid_encoding?
      STDOUT.write(chunk)
      STDOUT.flush
      log.write(chunk)
      log.flush
      last_output_at = Time.now

      buffer << chunk
      lines = buffer.split("\n", -1)
      buffer = lines.pop || +""
      lines.each do |line|
        test_run_failed ||= failed_patterns.any? { |pattern| line.match?(pattern) }
        tests_active ||= activity_patterns.any? { |pattern| line.match?(pattern) }
        if test_run_passed_at.nil? && pass_patterns.any? { |pattern| line.match?(pattern) }
          test_run_passed_at = Time.now
        end
      end
    end
  end
ensure
  reader.close unless reader.closed?
  log.close
end

if status
  exit(status.exitstatus || (status.success? ? 0 : 1))
end

# We get here only after the watchdog reclaimed a hung xcodebuild (status nil).
# Treat it as success when the run reached the test phase and never reported a
# failure — the hang is in xcodebuild's own shutdown, not in the tests.
passed_cleanly = (test_run_passed_at || tests_active) && !test_run_failed
exit(passed_cleanly ? 0 : 1)
