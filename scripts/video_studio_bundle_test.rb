# frozen_string_literal: true

require 'json'
require 'open3'
require 'tmpdir'
require 'fileutils'

root = File.expand_path(ARGV[0] || '..', __dir__)
report_dir = File.expand_path(ARGV[1] || File.join(root, 'build/video-studio-bundle'))
checks = []
begin
  json, error, status = Open3.capture3('/usr/bin/plutil', '-convert', 'json', '-o', '-', File.join(root, 'Xedit.xcodeproj/project.pbxproj'))
  raise "Cannot parse Xcode project: #{error}" unless status.success?
  phase = JSON.parse(json).fetch('objects').values.find { |object| object['name'] == 'Bundle built-in plugins' }
  raise 'Bundled plugin phase missing' unless phase
  Dir.mktmpdir('video-studio-app-bundle-') do |build_root|
    env = { 'SRCROOT' => root, 'TARGET_BUILD_DIR' => build_root, 'UNLOCALIZED_RESOURCES_FOLDER_PATH' => 'WillDeep.app/Contents/Resources' }
    _, error, status = Open3.capture3(env, '/bin/zsh', '-c', phase.fetch('shellScript'))
    raise "Xcode bundling phase failed: #{error}" unless status.success?
    checks << 'Executed the actual Xcode bundle phase'
    bundled = File.join(build_root, env.fetch('UNLOCALIZED_RESOURCES_FOLDER_PATH'), 'BundledPlugins/video-studio')
    code = "exit(CreativeSchema::CATALOG.fetch('$defs').key?('frames') ? 0 : 1)"
    _, error, status = Open3.capture3('/usr/bin/ruby', '-r', File.join(bundled, 'server/lib/creative_schema.rb'), '-e', code)
    raise "Bundled service cannot load its creative schema: #{error}" unless status.success?
    checks << 'Bundled Ruby service loads its schema without reading the source checkout'
    schema = 'schemas/creative-v1.json'
    raise 'Schema contents differ' unless File.binread(File.join(bundled, schema)) == File.binread(File.join(root, 'PluginExamples/video-studio', schema))
    raise 'Schema directory missing from Xcode input paths' unless phase.fetch('inputPaths').include?('$(SRCROOT)/PluginExamples/video-studio/schemas')
    checks << 'Schema bytes match the source and are declared as a build input'
  end
  report = { status: 'passed', checks: checks }
rescue StandardError => e
  report = { status: 'failed', checks: checks, error: e.message }
end
FileUtils.mkdir_p(report_dir)
File.write(File.join(report_dir, 'report.json'), JSON.pretty_generate(report) + "\n")
File.write(File.join(report_dir, 'report.md'), "# Video Studio bundle verification\n\nStatus: #{report[:status]}\n\n#{checks.map { |check| "- PASS: #{check}" }.join("\n")}\n\n#{report[:error]}\n")
puts JSON.pretty_generate(report)
exit(report[:status] == 'passed' ? 0 : 1)
