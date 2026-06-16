#!/usr/bin/env ruby
# frozen_string_literal: true

# version_consistency.rb — verify every product-facing version source agrees.
#
# Usage:
#   ruby scripts/version_consistency.rb
#   ruby scripts/version_consistency.rb build/ci/version_report.md build/ci/version_report.json

require "json"
require "fileutils"
require "time"

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

repo_root = File.expand_path("..", __dir__)
markdown_path = ARGV[0] || "build/ci/version_report.md"
json_path = ARGV[1] || "build/ci/version_report.json"
version_pattern = /\d+\.\d+\.\d+(?:-rc\d+)?/
semver_pattern = /\A#{version_pattern.source}\z/

def read_file(repo_root, relative)
  File.read(File.join(repo_root, relative), encoding: "UTF-8")
end

def badge_to_version(value)
  value.tr("_", "-").gsub("--", "-")
end

checks = []

add_check = lambda do |name, path, versions, expected_count: nil|
  versions = Array(versions).compact
  versions = versions.map(&:strip).reject(&:empty?)
  checks << {
    name: name,
    path: path,
    versions: versions,
    expected_count: expected_count
  }
end

pbxproj = read_file(repo_root, "Xedit.xcodeproj/project.pbxproj")
add_check.call(
  "Xcode MARKETING_VERSION",
  "Xedit.xcodeproj/project.pbxproj",
  pbxproj.scan(/MARKETING_VERSION = "?([^";]+)"?;/).flatten,
  expected_count: 6
)

go_version = read_file(repo_root, "willdeep-agent/internal/agent/version.go")
add_check.call(
  "Go agent Version",
  "willdeep-agent/internal/agent/version.go",
  go_version[/const Version = "([^"]+)"/, 1],
  expected_count: 1
)

help_plist = read_file(repo_root, "Help/WillDeep.help/Contents/Info.plist")
add_check.call(
  "Help bundle CFBundleShortVersionString",
  "Help/WillDeep.help/Contents/Info.plist",
  help_plist[/<key>CFBundleShortVersionString<\/key>\s*<string>([^<]+)<\/string>/m, 1],
  expected_count: 1
)

readme = read_file(repo_root, "README.md")
add_check.call(
  "README version badges",
  "README.md",
  readme.scan(%r{badge/version-([0-9][0-9A-Za-z_.-]*?)-blue}).flatten.map { |value| badge_to_version(value) }
)

product_overview = read_file(repo_root, "product-overview.md")
add_check.call(
  "Product overview current version",
  "product-overview.md",
  product_overview[/Current version:\s*v?(#{version_pattern})/, 1],
  expected_count: 1
)

mobile_requirements = read_file(repo_root, "docs/MOBILE_GATEWAY_REQUIREMENTS.md")
add_check.call(
  "Mobile Gateway target/header versions",
  "docs/MOBILE_GATEWAY_REQUIREMENTS.md",
  mobile_requirements.scan(/(?:Target version:\s*v?|X-(?:App|Server)-Version:\s*`?|\"version\":\s*\")(#{version_pattern})/).flatten,
  expected_count: 4
)

harness_priorities = read_file(repo_root, "docs/AGENT_HARNESS_IMPROVEMENT_PRIORITIES.md")
add_check.call(
  "Agent harness priorities current version",
  "docs/AGENT_HARNESS_IMPROVEMENT_PRIORITIES.md",
  harness_priorities[/Current version:\s*v?(#{version_pattern})/, 1],
  expected_count: 1
)

changelog = read_file(repo_root, "CHANGELOG.md")
add_check.call(
  "CHANGELOG top entry",
  "CHANGELOG.md",
  changelog[/^##\s+([0-9]+\.[0-9]+\.[0-9]+(?:-rc\d+)?)\s+-/m, 1],
  expected_count: 1
)

all_versions = checks.flat_map { |check| check[:versions] }
canonical_version = all_versions.group_by(&:itself).max_by { |_version, values| values.length }&.first
failures = []

checks.each do |check|
  unique_versions = check[:versions].uniq
  if check[:versions].empty?
    failures << "#{check[:name]} did not expose a version"
    next
  end
  if check[:expected_count] && check[:versions].length != check[:expected_count]
    failures << "#{check[:name]} expected #{check[:expected_count]} occurrence(s), found #{check[:versions].length}"
  end
  invalid_versions = unique_versions.reject { |version| version.match?(semver_pattern) }
  unless invalid_versions.empty?
    failures << "#{check[:name]} has invalid semver value(s): #{invalid_versions.join(", ")}"
  end
  if unique_versions.length != 1
    failures << "#{check[:name]} has multiple versions: #{unique_versions.join(", ")}"
  elsif canonical_version && unique_versions.first != canonical_version
    failures << "#{check[:name]} is #{unique_versions.first}, expected #{canonical_version}"
  end
end

if all_versions.uniq.length > 1
  failures << "Version sources disagree: #{all_versions.uniq.sort.join(", ")}"
end

ok = failures.empty?
report = {
  ok: ok,
  generated_at: Time.now.utc.iso8601,
  canonical_version: canonical_version,
  checks: checks,
  failures: failures
}

[markdown_path, json_path].each do |path|
  directory = File.dirname(File.expand_path(path, repo_root))
  FileUtils.mkdir_p(directory) unless Dir.exist?(directory)
end

File.write(File.expand_path(json_path, repo_root), JSON.pretty_generate(report))

status = ok ? "PASS" : "FAIL"
md = +"# Version Consistency Report\n\n"
md << "**Status:** #{status}\n\n"
md << "- Canonical version: #{canonical_version || "unknown"}\n"
md << "- Checked sources: #{checks.length}\n"
md << "- Failures: #{failures.length}\n\n"

if failures.empty?
  md << "All version sources agree.\n\n"
else
  md << "## Failures\n\n"
  failures.each { |failure| md << "- #{failure}\n" }
  md << "\n"
end

md << "## Sources\n\n"
md << "| Source | Path | Versions |\n"
md << "| --- | --- | --- |\n"
checks.each do |check|
  versions = check[:versions].empty? ? "_missing_" : check[:versions].uniq.join(", ")
  md << "| #{check[:name]} | `#{check[:path]}` | `#{versions}` |\n"
end

File.write(File.expand_path(markdown_path, repo_root), md)

puts "version_consistency: #{status.downcase} version=#{canonical_version || "unknown"} failures=#{failures.length}"
exit(ok ? 0 : 1)
