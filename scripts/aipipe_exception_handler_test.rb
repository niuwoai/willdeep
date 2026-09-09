# frozen_string_literal: true
require 'json'
require 'open3'
require 'tmpdir'
require 'fileutils'
require 'timeout'

root = File.expand_path('..', __dir__)
report_dir = File.join(root, 'build/aipipe-exception-handler')
FileUtils.mkdir_p(report_dir)
begin
  Dir.mktmpdir('aipipe-handler-') do |dir|
    sdk = File.join(root, 'Vendor/iossdk/AIPipe')
    binary = File.join(dir, 'handler-test')
    command = ['xcrun', 'clang', '-fobjc-arc', '-framework', 'Foundation', '-I', sdk,
               File.join(__dir__, 'fixtures/aipipe_exception_handler.m'),
               *%w[AIPipe AIPipeConfig AIPipeLogItem].map { |name| File.join(sdk, "#{name}.m") }, '-o', binary]
    output, status = Open3.capture2e(*command)
    raise "Fixture build failed: #{output}" unless status.success?
    Open3.popen2e(binary) do |input, output_pipe, waiter|
      input.close
      reader = Thread.new { output_pipe.read }
      begin
        status = Timeout.timeout(15) { waiter.value }
        raise "Handler regression failed: #{reader.value}" unless status.success?
      rescue Timeout::Error
        Process.kill('KILL', waiter.pid)
        waiter.value
        reader.value
        raise 'Handler did not return; possible recursive handler chain'
      end
    end
  end
  report = { status: 'passed', checks: ['Repeated initialization preserves the previous handler exactly once', 'A missing previous handler returns without recursion'] }
rescue StandardError => e
  report = { status: 'failed', error: e.message }
end
File.write(File.join(report_dir, 'report.json'), JSON.pretty_generate(report) + "\n")
File.write(File.join(report_dir, 'report.md'), "# AIPipe exception handler regression\n\n#{JSON.pretty_generate(report)}\n")
puts JSON.pretty_generate(report)
exit(report[:status] == 'passed' ? 0 : 1)
