#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "pathname"
require "tmpdir"

ROOT = Pathname.new(__dir__).parent
SOURCE = ROOT.join("chrome-extension", "willdeep-browser")
DIST = ROOT.join("dist", "chrome-extension")

manifest = JSON.parse(SOURCE.join("manifest.json").read)
version = manifest.fetch("version_name")
archive = DIST.join("WillDeep-Browser-#{version}.zip")
metadata = DIST.join("WillDeep-Browser-#{version}.release.json")

FileUtils.mkdir_p(DIST)
FileUtils.rm_f(archive)

Dir.mktmpdir("willdeep-browser-package") do |temporary_root|
  package_root = Pathname.new(temporary_root).join("WillDeep-Browser")
  FileUtils.cp_r(SOURCE, package_root)
  package_root.glob("**/.DS_Store").each { |path| FileUtils.rm_f(path) }
  success = system(
    "/usr/bin/zip",
    "-r",
    "-X",
    archive.to_s,
    package_root.basename.to_s,
    chdir: temporary_root
  )
  abort("failed to package Chrome extension") unless success
end

release = {
  app_id: "willdeep-browser-extension",
  app_name: "WillDeep Browser",
  platform: "chrome",
  channel: "stable",
  latest_version: version,
  download_filename: archive.basename.to_s,
  sha256: Digest::SHA256.file(archive).hexdigest,
  file_size_bytes: archive.size,
  release_notes_url: "https://some.im/products/willdeep/browser-extension"
}
metadata.write(JSON.pretty_generate(release) + "\n")

puts JSON.generate(release.merge(archive: archive.to_s, metadata: metadata.to_s))
