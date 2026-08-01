#!/usr/bin/env ruby
# frozen_string_literal: true

# Fast, worktree-safe Xedit unit-test entry point.
#
# Examples:
#   ruby scripts/run_tests_fast.rb
#   ruby scripts/run_tests_fast.rb -only-testing:XeditTests/AgentFileSearchTests
#   ruby scripts/run_tests_fast.rb --without-building -only-testing:XeditTests/AgentFileSearchTests
#
# The default path still asks Xcode to build incrementally, so source changes can
# never be skipped accidentally. --without-building is accepted only when the
# saved source fingerprint exactly matches the current worktree.

require "digest"
require "English"
require "fileutils"
require "json"
require "open3"
require "time"

# This repository's CHANGELOG and docs are Chinese, so `git diff`/`git status`
# output routinely carries non-ASCII bytes. Ruby tags subprocess output with the
# caller's locale encoding, which is US-ASCII whenever LANG/LC_ALL are unset — and
# JSON.generate then aborts the whole run on the first Chinese byte. Pin UTF-8
# here so the script never depends on how the caller's shell happens to be set up,
# matching scripts/project_build_guard.rb.
Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

ROOT = File.expand_path("..", __dir__)
OUT_DIR = File.join(ROOT, "build", "fast-tests")
LOCAL_XCODE_CACHE_ROOT = File.expand_path(
  ENV.fetch(
    "WILLDEEP_XCODE_CACHE_ROOT",
    File.join(Dir.home, "Library", "Caches", "WillDeep", "Xcode", "Xedit")
  )
)
DERIVED_DATA = ENV.fetch(
  "WILLDEEP_XCODE_DERIVED_DATA_PATH",
  File.join(LOCAL_XCODE_CACHE_ROOT, "DerivedData")
)
XCRESULT = File.join(OUT_DIR, "XeditFastTests.xcresult")
LOG = File.join(OUT_DIR, "xcodebuild.log")
REPORT_MD = File.join(OUT_DIR, "report.md")
REPORT_JSON = File.join(OUT_DIR, "report.json")
GUARD_REPORT_MD = File.join(OUT_DIR, "project_build_guard_report.md")
GUARD_REPORT_JSON = File.join(OUT_DIR, "project_build_guard_report.json")
BUILD_STAMP = File.join(OUT_DIR, "build_fingerprint.json")
SCHEME = "XeditUnitTests"
BUILD_INPUT_PATHS = [
  "Xedit",
  "XeditTests",
  "Xedit.xcodeproj",
  "Vendor",
  "ComputerUseHelper",
  "willdeep-agent",
  "scripts/generate_build_credentials.rb"
].freeze

def command_output(*command)
  output, status = Open3.capture2e(*command, chdir: ROOT)
  output = utf8(output)
  abort "Command failed: #{command.join(" ")}\n#{output}" unless status.success?

  output
end

# Re-tag subprocess bytes as UTF-8 and drop anything that still is not valid —
# a tracked file saved in a legacy encoding would otherwise reach JSON.generate
# as malformed UTF-8. Substitution is deterministic, so fingerprints stay stable.
def utf8(text)
  text = text.dup.force_encoding(Encoding::UTF_8)
  text.valid_encoding? ? text : text.scrub
end

def sha256_file(path)
  File.file?(path) ? Digest::SHA256.file(path).hexdigest : nil
end

def build_input_git_output(*arguments)
  command_output("git", *arguments, "--", *BUILD_INPUT_PATHS)
end

def source_fingerprint
  untracked = build_input_git_output("ls-files", "--others", "--exclude-standard", "-z")
    .split("\0")
    .reject(&:empty?)
    .sort
    .map do |relative_path|
      absolute_path = File.join(ROOT, relative_path)
      [relative_path, sha256_file(absolute_path)]
    end

  input = {
    "git_head" => command_output("git", "rev-parse", "HEAD").strip,
    "build_input_paths" => BUILD_INPUT_PATHS,
    "git_status_sha256" => Digest::SHA256.hexdigest(
      build_input_git_output("status", "--porcelain=v1")
    ),
    "git_diff_sha256" => Digest::SHA256.hexdigest(
      build_input_git_output("diff", "--binary")
    ),
    "git_cached_diff_sha256" => Digest::SHA256.hexdigest(
      build_input_git_output("diff", "--cached", "--binary")
    ),
    "untracked_files" => untracked,
    "local_build_credentials_sha256" => sha256_file(File.join(ROOT, ".env.local")),
    "xcodebuild_version" => command_output("xcodebuild", "-version").strip,
    "project" => sha256_file(File.join(ROOT, "Xedit.xcodeproj", "project.pbxproj")),
    "package_resolved" => sha256_file(
      File.join(
        ROOT,
        "Xedit.xcodeproj",
        "project.xcworkspace",
        "xcshareddata",
        "swiftpm",
        "Package.resolved"
      )
    ),
    "scheme" => sha256_file(
      File.join(ROOT, "Xedit.xcodeproj", "xcshareddata", "xcschemes", "#{SCHEME}.xcscheme")
    )
  }
  [Digest::SHA256.hexdigest(JSON.generate(input)), input]
end

def write_json_atomically(path, value)
  FileUtils.mkdir_p(File.dirname(path))
  temporary_path = "#{path}.tmp-#{Process.pid}"
  File.write(temporary_path, JSON.pretty_generate(value))
  File.rename(temporary_path, path)
end

without_building = false
force = false
xcode_arguments = []

ARGV.each do |argument|
  case argument
  when "--without-building"
    without_building = true
  when "--force"
    force = true
  when "--help", "-h"
    puts <<~USAGE
      Usage: ruby scripts/run_tests_fast.rb [options] [xcodebuild test selection arguments]

        --without-building  Re-run tests only when the current source fingerprint matches.
        --force             Ignore the successful-result cache; keep incremental build data.
        -only-testing:...   Select a test bundle, suite, or test.
    USAGE
    exit 0
  else
    xcode_arguments << argument
  end
end

unless xcode_arguments.any? { |argument| argument.start_with?("-only-testing:", "-skip-testing:") }
  xcode_arguments << "-only-testing:XeditTests"
end

FileUtils.mkdir_p(OUT_DIR)
fingerprint, fingerprint_input = source_fingerprint
test_bundle = File.join(
  DERIVED_DATA,
  "Build",
  "Products",
  "Debug",
  "WillDeep.app",
  "Contents",
  "PlugIns",
  "XeditTests.xctest"
)

if without_building
  saved_stamp = File.file?(BUILD_STAMP) ? JSON.parse(File.read(BUILD_STAMP, encoding: "UTF-8")) : {}
  abort "No verified test build exists. Run this script once without --without-building." unless File.directory?(test_bundle)
  unless saved_stamp["fingerprint"] == fingerprint
    abort "Source or build inputs changed. Refusing a stale test binary; run without --without-building."
  end
end

source_packages_dir = ENV.fetch(
  "WILLDEEP_XCODE_SOURCE_PACKAGES_DIR",
  File.join(LOCAL_XCODE_CACHE_ROOT, "SourcePackages")
)
package_cache_dir = ENV.fetch(
  "WILLDEEP_XCODE_PACKAGE_CACHE_DIR",
  File.join(LOCAL_XCODE_CACHE_ROOT, "PackageCache")
)
xcode_action = without_building ? "test-without-building" : "test"
xcode_command = [
  "xcodebuild", xcode_action,
  "-project", File.join(ROOT, "Xedit.xcodeproj"),
  "-scheme", SCHEME,
  "-destination", "platform=macOS",
  "-resultBundlePath", XCRESULT,
  "-derivedDataPath", DERIVED_DATA,
  "-clonedSourcePackagesDirPath", source_packages_dir,
  "-packageCachePath", package_cache_dir,
  "-skipPackageUpdates",
  "-onlyUsePackageVersionsFromResolvedFile",
  "-enableCodeCoverage", "NO",
  "-showBuildTimingSummary",
  "COMPILATION_CACHE_ENABLE_CACHING=#{ENV.fetch("WILLDEEP_XCODE_COMPILATION_CACHE", "YES")}",
  "COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS=#{ENV.fetch("WILLDEEP_XCODE_CACHE_REMARKS", "NO")}",
  "COMPILER_INDEX_STORE_ENABLE=#{ENV.fetch("WILLDEEP_XCODE_INDEX_STORE", "NO")}",
  "CODE_SIGNING_ALLOWED=NO",
  "CODE_SIGNING_REQUIRED=NO",
  "CODE_SIGN_IDENTITY=",
  *xcode_arguments
]

guard_command = [
  "ruby", File.join(ROOT, "scripts", "project_build_guard.rb"),
  "--workspace", ROOT,
  "--name", "xedit-fast-tests-#{xcode_action}",
  "--kind", "xcode-test",
  "--artifact", XCRESULT,
  "--fingerprint-file", "Xedit.xcodeproj/project.pbxproj",
  "--fingerprint-file", "Xedit.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
  "--fingerprint-file", "Xedit.xcodeproj/xcshareddata/xcschemes/#{SCHEME}.xcscheme",
  "--fingerprint-string", fingerprint,
  "--json-report", GUARD_REPORT_JSON,
  "--markdown-report", GUARD_REPORT_MD,
  "--replace-artifacts"
]
guard_command << "--no-cache" if force
guard_command.concat(
  [
    "--",
    "ruby", File.join(ROOT, "scripts", "xcodebuild_ci.rb"),
    "--log", LOG,
    "--pass-grace", "180",
    "--",
    *xcode_command
  ]
)

puts "▶ #{xcode_action} #{xcode_arguments.join(" ")}"
success = system(*guard_command, chdir: ROOT)
exit_status = $CHILD_STATUS&.exitstatus || 1
exit(exit_status) unless success

unless without_building
  write_json_atomically(
    BUILD_STAMP,
    {
      "fingerprint" => fingerprint,
      "fingerprint_input" => fingerprint_input,
      "built_at" => Time.now.utc.iso8601
    }
  )
end

report_success = system(
  "ruby",
  File.join(ROOT, "scripts", "xcresult_report.rb"),
  XCRESULT,
  REPORT_MD,
  REPORT_JSON,
  chdir: ROOT
)
abort "Tests passed, but report generation failed." unless report_success

puts "✅ Fast test report: #{REPORT_MD}"
