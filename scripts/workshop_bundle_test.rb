# frozen_string_literal: true
require 'json'
require 'open3'
require 'tmpdir'
require 'fileutils'
require 'digest'

root = File.expand_path('..', __dir__)
report_dir = File.join(root, 'build', 'workshop-bundle')
FileUtils.mkdir_p(report_dir)
checks = []
begin
  json, error, status = Open3.capture3('/usr/bin/plutil', '-convert', 'json', '-o', '-', File.join(root, 'Xedit.xcodeproj/project.pbxproj'))
  raise "Cannot parse Xcode project: #{error}" unless status.success?
  project = JSON.parse(json)
  phase = project.fetch('objects').values.find { |object| object['name'] == 'Bundle built-in plugins' }
  raise 'Bundled plugin phase missing' unless phase
  Dir.mktmpdir('workshop-app-bundle-') do |build_root|
    env = { 'SRCROOT' => root, 'TARGET_BUILD_DIR' => build_root, 'UNLOCALIZED_RESOURCES_FOLDER_PATH' => 'WillDeep.app/Contents/Resources' }
    _, error, status = Open3.capture3(env, '/bin/zsh', '-c', phase.fetch('shellScript'))
    raise "Xcode bundling phase failed: #{error}" unless status.success?
    checks << 'Executed the actual Xcode bundle phase successfully'
    source = File.join(root, 'PluginExamples', 'workshop-run')
    bundled = File.join(build_root, env.fetch('UNLOCALIZED_RESOURCES_FOLDER_PATH'), 'BundledPlugins', 'workshop-run')
    manifest = JSON.parse(File.read(File.join(bundled, '.willdeep-plugin/plugin.json')))
    raise 'Unexpected permissions' unless manifest.fetch('permissions').empty?
    page = manifest.fetch('contributes').fetch('pages').fetch(0)
    raise 'Missing page' unless File.file?(File.join(bundled, page.fetch('entryPath')))
    expected = Dir.chdir(source) { Dir['.codex-plugin/**/*', '.willdeep-plugin/**/*', 'ui/dist/client/**/*'].select { |file| File.file?(file) }.sort }
    actual = Dir.chdir(bundled) { Dir.glob('**/*', File::FNM_DOTMATCH).select { |file| File.file?(file) }.sort }
    raise 'Bundle contains missing or unexpected files' unless actual == expected
    expected.each do |file|
      raise "Content mismatch: #{file}" unless Digest::SHA256.file(File.join(source, file)).hexdigest == Digest::SHA256.file(File.join(bundled, file)).hexdigest
      raise "Oversized web asset: #{file}" if File.size(File.join(bundled, file)) > 8 * 1024 * 1024
    end
    checks << "All #{expected.length} runtime files match the committed build bytes"
    checks << 'No source, node_modules, tests, reports or Sites server in the bundled game'
    checks << 'Zero permissions and a valid compiled entry'
    %w[.codex-plugin .willdeep-plugin ui/dist/client].each do |relative|
      input = "$(SRCROOT)/PluginExamples/workshop-run/#{relative}"
      raise "Missing Xcode input declaration: #{relative}" unless phase.fetch('inputPaths').include?(input)
    end
    checks << 'Xcode inputs declare both manifests and the complete client output'
  end
  report = { status: 'passed', checks: checks }
rescue StandardError => e
  report = { status: 'failed', checks: checks, error: e.message }
end
File.write(File.join(report_dir, 'report.json'), JSON.pretty_generate(report) + "\n")
File.write(File.join(report_dir, 'report.md'), "# Workshop bundle verification\n\nStatus: #{report[:status]}\n\n#{checks.map { |check| "- PASS: #{check}" }.join("\n")}\n\n#{report[:error]}\n")
puts JSON.pretty_generate(report)
exit(report[:status] == 'passed' ? 0 : 1)
