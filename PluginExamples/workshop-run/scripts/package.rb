# frozen_string_literal: true
require 'json'
require 'digest'
require 'fileutils'
require 'tmpdir'

root = File.expand_path('..', __dir__)
identity = JSON.parse(File.read(File.join(root, '.codex-plugin/plugin.json')))
manifest = JSON.parse(File.read(File.join(root, '.willdeep-plugin/plugin.json')))
package = JSON.parse(File.read(File.join(root, 'ui/package.json')))
abort 'Version mismatch' unless identity.fetch('version') == package.fetch('version')
abort 'Unexpected permissions' unless manifest.fetch('permissions').empty?
contributions = manifest.fetch('contributes')
pages = contributions.fetch('pages')
abort 'Not a local page' unless pages.all? { |page| page.fetch('runtime') == 'localWeb' }
locales = %w[en zh-Hans].map { |locale| JSON.parse(File.read(File.join(root, ".willdeep-plugin/locales/#{locale}.json"))) }
contributions.fetch('destinations').each do |destination|
  abort 'Missing page reference' unless pages.any? { |page| page.fetch('id') == destination.fetch('mainPage') }
  abort 'Missing sidebar reference' unless contributions.fetch('sidebars').any? { |s| s.fetch('id') == destination.fetch('companionSidebar') }
  abort 'Missing translated title' unless locales.all? { |locale| locale[destination.fetch('titleKey')].is_a?(String) && !locale[destination.fetch('titleKey')].empty? }
end
pages.each { |page| abort 'Missing compiled entry' unless File.file?(File.join(root, page.fetch('entryPath'))) }
files = Dir.chdir(root) { Dir['.codex-plugin/**/*', '.willdeep-plugin/**/*', 'ui/dist/client/**/*', 'README.md', 'CHANGELOG.md', 'PRODUCT_OVERVIEW.md'].select { |f| File.file?(f) }.sort }
abort 'Empty build' if files.length < 10
files.each do |relative|
  path = File.join(root, relative)
  abort "Symlink not allowed: #{relative}" if File.symlink?(path)
  abort "Resource exceeds 8 MiB: #{relative}" if File.size(path) > 8 * 1024 * 1024
end
out = File.expand_path(ARGV[0] || File.join(root, 'artifacts'))
FileUtils.mkdir_p(out)
name = "#{identity.fetch('name')}-v#{identity.fetch('version')}"
zip = File.join(out, "#{name}.zip")
Dir.mktmpdir('workshop-package-') do |stage|
  files.each do |relative|
    dest = File.join(stage, relative)
    FileUtils.mkdir_p(File.dirname(dest))
    FileUtils.cp(File.join(root, relative), dest)
  end
  # zip receives explicit arguments, no shell interpolation or generated scripts.
  FileUtils.rm_f(zip)
  abort 'Packaging failed' unless system('zip', '-q', '-r', zip, '.', chdir: stage)
end
abort 'Archive verification failed' unless system('unzip', '-tq', zip, out: File::NULL)
digest = Digest::SHA256.file(zip).hexdigest
File.write("#{zip}.sha256", "#{digest}  #{File.basename(zip)}\n")
report = { version: identity.fetch('version'), files: files.length, bytes: File.size(zip), sha256: digest, checks: ['version consistency', 'local page and entry', 'destination references', 'complete locales', 'zero permissions', 'resource limits', 'archive CRC'], archive: zip }
File.write(File.join(out, 'package-report.json'), JSON.pretty_generate(report) + "\n")
File.write(File.join(out, 'package-report.md'), "# Package verification\n\nVersion: #{report[:version]}\n\n#{report[:checks].map { |check| "- PASS: #{check}" }.join("\n")}\n\nFiles: #{files.length}\n\nSHA-256: `#{digest}`\n")
puts JSON.pretty_generate(report)
