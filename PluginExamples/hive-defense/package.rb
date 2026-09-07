# frozen_string_literal: true
require 'fileutils'
require 'json'
require 'tmpdir'
require 'digest'

root = __dir__
version = JSON.parse(File.read(File.join(root, '.codex-plugin/plugin.json'))).fetch('version')
output = File.expand_path('../../build/artifacts', root)
FileUtils.mkdir_p(output)
archive = File.join(output, "hive-defense-#{version}.zip")
Dir.mktmpdir('hive-package') do |temporary|
  package = File.join(temporary, 'hive-defense')
  FileUtils.mkdir_p(package)
  %w[.codex-plugin .willdeep-plugin ui README.md ART_PROMPTS.md].each do |relative|
    FileUtils.cp_r(File.join(root, relative), File.join(package, relative))
  end
  abort 'Packaging failed' unless system('/usr/bin/ditto', '-c', '-k', '--norsrc', '--noextattr', '--keepParent', package, archive)
end
File.write("#{archive}.sha256", "#{Digest::SHA256.file(archive).hexdigest}  #{File.basename(archive)}\n")
puts archive
