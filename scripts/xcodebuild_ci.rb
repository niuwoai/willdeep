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
  pass_grace_seconds: 180
}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: ruby scripts/xcodebuild_ci.rb [options] -- xcodebuild test ..."
  opts.on("--log PATH", "Write combined xcodebuild output to PATH") { |value| options[:log_path] = value }
  opts.on("--pass-grace SECONDS", Integer, "Seconds to wait after the full test run passed") do |value|
    options[:pass_grace_seconds] = value
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
  /\*\* TEST FAILED \*\*/
]

buffer = +""
test_run_passed_at = nil
test_run_failed = false
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

    if test_run_passed_at && !test_run_failed &&
       Time.now - test_run_passed_at >= options[:pass_grace_seconds]
      message = "\n[xcodebuild_ci] xcodebuild did not exit #{options[:pass_grace_seconds]}s after the full test run passed; terminating stale process group #{pid}.\n"
      STDOUT.write(message)
      STDOUT.flush
      log.write(message)
      log.flush
      signal_process(pid, "TERM")
      sleep 2
      unless Process.waitpid2(pid, Process::WNOHANG)
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

      buffer << chunk
      lines = buffer.split("\n", -1)
      buffer = lines.pop || +""
      lines.each do |line|
        test_run_failed ||= failed_patterns.any? { |pattern| line.match?(pattern) }
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

exit(test_run_passed_at && !test_run_failed ? 0 : 1)
