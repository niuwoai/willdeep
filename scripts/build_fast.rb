#!/usr/bin/env ruby
# frozen_string_literal: true

# Incremental local Xcode build that shares persistent caches with the local
# test runners. This is a CLI-only optimization: it does not change Xcode IDE
# indexing or the project's checked-in index settings.
#
# Examples:
#   ruby scripts/build_fast.rb
#   ruby scripts/build_fast.rb --release
#   ruby scripts/build_fast.rb --sign
#   ruby scripts/build_fast.rb -- --showBuildTimingSummary

require "english"
require "fileutils"
require "json"
require "optparse"
require "shellwords"
require "time"

ROOT = File.expand_path("..", __dir__)
OUT_DIR = File.join(ROOT, "build", "local")
DEFAULT_CACHE_ROOT = File.join(Dir.home, "Library", "Caches", "WillDeep", "Xcode", "Xedit")

options = {
  scheme: "Xedit",
  configuration: "Debug",
  destination: ENV.fetch("WILLDEEP_XCODE_DESTINATION", "platform=macOS"),
  signing: false,
  index_store: ENV.fetch("WILLDEEP_XCODE_INDEX_STORE", "NO"),
  cache_remarks: ENV.fetch("WILLDEEP_XCODE_CACHE_REMARKS", "NO")
}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: ruby scripts/build_fast.rb [options] [-- xcodebuild arguments]"
  opts.on("--scheme NAME", "Xcode scheme. Defaults to Xedit.") { |value| options[:scheme] = value }
  opts.on("--configuration NAME", "Build configuration. Defaults to Debug.") do |value|
    options[:configuration] = value
  end
  opts.on("--destination DESTINATION", "Xcode destination. Defaults to platform=macOS.") do |value|
    options[:destination] = value
  end
  opts.on("--release", "Shortcut for --configuration Release.") { options[:configuration] = "Release" }
  opts.on("--sign", "Allow the normal project code-signing path.") { options[:signing] = true }
  opts.on("--index", "Generate an index store for this CLI build.") { options[:index_store] = "YES" }
  opts.on("--cache-remarks", "Print compiler cache hit/miss remarks.") { options[:cache_remarks] = "YES" }
  opts.on("-h", "--help", "Show this help.") do
    puts opts
    exit 0
  end
end

separator = ARGV.index("--")
option_arguments = separator ? ARGV[0...separator] : ARGV
xcode_arguments = separator ? ARGV[(separator + 1)..] : []
parser.parse!(option_arguments)
abort parser.to_s unless option_arguments.empty?

cache_root = File.expand_path(ENV.fetch("WILLDEEP_XCODE_CACHE_ROOT", DEFAULT_CACHE_ROOT))
derived_data = File.expand_path(
  ENV.fetch("WILLDEEP_XCODE_DERIVED_DATA_PATH", File.join(cache_root, "DerivedData"))
)
source_packages = File.expand_path(
  ENV.fetch("WILLDEEP_XCODE_SOURCE_PACKAGES_DIR", File.join(cache_root, "SourcePackages"))
)
package_cache = File.expand_path(
  ENV.fetch("WILLDEEP_XCODE_PACKAGE_CACHE_DIR", File.join(cache_root, "PackageCache"))
)
log_path = File.join(OUT_DIR, "xcodebuild.log")
report_json = File.join(OUT_DIR, "build_report.json")
report_markdown = File.join(OUT_DIR, "build_report.md")
guard_json = File.join(OUT_DIR, "project_build_guard_report.json")
guard_markdown = File.join(OUT_DIR, "project_build_guard_report.md")
configuration_dir = options.fetch(:configuration)
app_path = File.join(derived_data, "Build", "Products", configuration_dir, "WillDeep.app")

FileUtils.mkdir_p([OUT_DIR, derived_data, source_packages, package_cache])

xcode_command = [
  "xcodebuild", "build",
  "-project", File.join(ROOT, "Xedit.xcodeproj"),
  "-scheme", options.fetch(:scheme),
  "-configuration", options.fetch(:configuration),
  "-destination", options.fetch(:destination),
  "-derivedDataPath", derived_data,
  "-clonedSourcePackagesDirPath", source_packages,
  "-packageCachePath", package_cache,
  "-skipPackageUpdates",
  "-onlyUsePackageVersionsFromResolvedFile",
  "-parallelizeTargets",
  "-showBuildTimingSummary",
  "COMPILATION_CACHE_ENABLE_CACHING=#{ENV.fetch("WILLDEEP_XCODE_COMPILATION_CACHE", "YES")}",
  "COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS=#{options.fetch(:cache_remarks)}",
  "COMPILER_INDEX_STORE_ENABLE=#{options.fetch(:index_store)}"
]
unless options.fetch(:signing)
  xcode_command.concat(
    [
      "CODE_SIGNING_ALLOWED=NO",
      "CODE_SIGNING_REQUIRED=NO",
      "CODE_SIGN_IDENTITY="
    ]
  )
end
xcode_command.concat(xcode_arguments)

guard_command = [
  "ruby", File.join(ROOT, "scripts", "project_build_guard.rb"),
  "--workspace", ROOT,
  "--name", "xedit-local-build-#{options.fetch(:configuration).downcase}",
  "--kind", "xcode-build",
  "--artifact", app_path,
  "--fingerprint-file", "Xedit.xcodeproj/project.pbxproj",
  "--fingerprint-file", "Xedit.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
  "--fingerprint-file", "scripts/build_fast.rb",
  "--json-report", guard_json,
  "--markdown-report", guard_markdown,
  "--no-cache",
  "--",
  "ruby", File.join(ROOT, "scripts", "xcodebuild_ci.rb"),
  "--log", log_path,
  "--pass-grace", "180",
  "--",
  *xcode_command
]

started_at = Time.now.utc
started_clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)
puts "▶ #{xcode_command.shelljoin}"
success = system(*guard_command, chdir: ROOT)
exit_status = $CHILD_STATUS&.exitstatus || 1
finished_at = Time.now.utc
elapsed_seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_clock

report = {
  "ok" => !!success,
  "exit_status" => exit_status,
  "scheme" => options.fetch(:scheme),
  "configuration" => options.fetch(:configuration),
  "destination" => options.fetch(:destination),
  "started_at" => started_at.iso8601,
  "finished_at" => finished_at.iso8601,
  "elapsed_seconds" => elapsed_seconds.round(3),
  "cache_root" => cache_root,
  "derived_data" => derived_data,
  "source_packages" => source_packages,
  "package_cache" => package_cache,
  "compilation_cache_enabled" => ENV.fetch("WILLDEEP_XCODE_COMPILATION_CACHE", "YES"),
  "index_store_enabled" => options.fetch(:index_store),
  "code_signing_enabled" => options.fetch(:signing),
  "app_path" => app_path,
  "app_exists" => File.directory?(app_path),
  "log_path" => log_path
}
File.write(report_json, JSON.pretty_generate(report))

markdown = <<~MARKDOWN
  # Local Fast Build Report

  - Status: #{success ? "pass" : "fail"}
  - Scheme: `#{options.fetch(:scheme)}`
  - Configuration: `#{options.fetch(:configuration)}`
  - Destination: `#{options.fetch(:destination)}`
  - Elapsed: #{format("%.3f", elapsed_seconds)}s
  - Compilation cache: #{report.fetch("compilation_cache_enabled")}
  - Index store: #{report.fetch("index_store_enabled")}
  - Code signing: #{report.fetch("code_signing_enabled")}
  - Cache root: `#{cache_root}`
  - DerivedData: `#{derived_data}`
  - App: `#{app_path}`
  - App exists: #{report.fetch("app_exists")}
  - Log: `#{log_path}`
MARKDOWN
File.write(report_markdown, markdown)

puts(success ? "✅ Local build: #{app_path}" : "❌ Local build failed; see #{log_path}")
puts "📄 Reports: #{report_markdown}, #{report_json}"
exit exit_status
