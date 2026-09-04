#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "tmpdir"

root = File.expand_path("..", __dir__)
source = File.join(root, "PluginExamples", "video-studio")
manifest = JSON.parse(File.read(File.join(source, ".codex-plugin", "plugin.json")))
name = manifest.fetch("name")
version = manifest.fetch("version")
abort "Invalid plugin identity" unless name.match?(/\A[a-z0-9-]+\z/) && version.match?(/\A\d+\.\d+\.\d+(?:-[a-z0-9.]+)?\z/)
output = File.join(root, "build", "plugins", "#{name}-#{version}.zip")
runtime_paths = %w[.codex-plugin .willdeep-plugin mcp.json server skills ui/dist README.md CHANGELOG.md]

Dir.mktmpdir("video-studio-package-") do |temporary|
  package = File.join(temporary, name)
  FileUtils.mkdir_p(package)
  runtime_paths.each do |relative|
    destination = File.join(package, relative)
    FileUtils.mkdir_p(File.dirname(destination))
    FileUtils.cp_r(File.join(source, relative), destination)
  end
  archive = File.join(temporary, "plugin.zip")
  _stdout, stderr, status = Open3.capture3("/usr/bin/zip", "-q", "-r", archive, name, chdir: temporary)
  abort "Packaging failed: #{stderr}" unless status.success?
  FileUtils.mkdir_p(File.dirname(output))
  FileUtils.mv(archive, output)
end

puts JSON.pretty_generate(path: output, version: version, bytes: File.size(output), sha256: Digest::SHA256.file(output).hexdigest)
