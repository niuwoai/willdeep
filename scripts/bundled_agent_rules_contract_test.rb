#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"

ROOT = File.expand_path("..", __dir__)
RULES_ROOT = File.join(ROOT, "BundledAgentRules")
MANIFEST_PATH = File.join(RULES_ROOT, "manifest.json")
INDEX_PATH = File.join(RULES_ROOT, "AGENTS.md")
PBXPROJ_PATH = File.join(ROOT, "Xedit.xcodeproj", "project.pbxproj")
STORE_PATH = File.join(ROOT, "Xedit", "AgentGlobalRulesStore.swift")
LIBRARY_PATH = File.join(ROOT, "Xedit", "AgentBundledRules.swift")

markdown_path = File.expand_path(ARGV[0] || "build/bundled_agent_rules/report.md", ROOT)
json_path = File.expand_path(ARGV[1] || "build/bundled_agent_rules/report.json", ROOT)

def content_fingerprint(directory)
  digest = Digest::SHA256.new
  Dir.glob(File.join(directory, "**", "*"))
    .select { |path| File.file?(path) && File.basename(path) != "manifest.json" }
    .sort
    .each do |path|
      relative = path.delete_prefix("#{directory}/")
      digest << relative << "\0" << File.binread(path) << "\0"
    end
  digest.hexdigest
end

manifest = File.file?(MANIFEST_PATH) ? JSON.parse(File.read(MANIFEST_PATH, encoding: "UTF-8")) : {}
index = File.file?(INDEX_PATH) ? File.read(INDEX_PATH, encoding: "UTF-8") : ""
pbxproj = File.read(PBXPROJ_PATH, encoding: "UTF-8")
store = File.read(STORE_PATH, encoding: "UTF-8")
library = File.read(LIBRARY_PATH, encoding: "UTF-8")
listed_files = Array(manifest["files"])
actual_files = Dir.glob(File.join(RULES_ROOT, "**", "*"))
  .select { |path| File.file?(path) && File.basename(path) != "manifest.json" }
  .map { |path| path.delete_prefix("#{RULES_ROOT}/") }
  .sort

checks = {
  "manifest_schema" => manifest["schema_version"] == 1,
  "manifest_version" => manifest["rules_version"].to_s.match?(/\A\d+\.\d+\.\d+(?:-rc\d+)?\z/),
  "manifest_files_match_snapshot" => listed_files.sort == actual_files,
  "manifest_fingerprint_matches_snapshot" => manifest["content_sha256"] == content_fingerprint(RULES_ROOT),
  "index_is_compact" => index.bytesize.between?(1, 4_000) && index.lines.count <= 60,
  "index_uses_relative_links" => index.include?("](./programming.md)") && !index.include?("/blob/main/"),
  "index_does_not_embed_rule_bodies" => !index.include?("## 硬约束") && !index.include?("BEGIN ALMA AGENTRULES SYNC"),
  "xcode_copies_rules_directory" => pbxproj.include?("BundledAgentRules in Resources"),
  "store_uses_compact_template" => store.include?("AgentBundledRules.defaultGlobalRulesTemplate"),
  "prompt_resolves_bundle_placeholder" => store.include?("AgentBundledRules.resolvingRootPlaceholder"),
  "library_routes_rules_on_demand" => library.include?("不要一次性读取整个目录") &&
    library.include?("{{WILLDEEP_BUNDLED_RULES_DIR}}")
}

failures = checks.reject { |_name, passed| passed }.keys
report = {
  status: failures.empty? ? "passed" : "failed",
  rules_version: manifest["rules_version"],
  index_bytes: index.bytesize,
  index_lines: index.lines.count,
  bundled_files: actual_files.count,
  checks: checks.map { |name, passed| { name: name, status: passed ? "passed" : "failed" } },
  failures: failures
}

FileUtils.mkdir_p(File.dirname(markdown_path))
FileUtils.mkdir_p(File.dirname(json_path))
File.write(json_path, "#{JSON.pretty_generate(report)}\n")

markdown = [
  "# Bundled Agent Rules Contract",
  "",
  "- Status: `#{report[:status]}`",
  "- Rules version: `#{report[:rules_version]}`",
  "- Index: #{report[:index_bytes]} bytes / #{report[:index_lines]} lines",
  "- Bundled files: #{report[:bundled_files]}",
  "",
  "## Results",
  ""
]
checks.each { |name, passed| markdown << "- #{passed ? '[x]' : '[ ]'} `#{name}`" }
File.write(markdown_path, "#{markdown.join("\n")}\n")

puts "bundled_agent_rules: #{report[:status]} checks=#{checks.count} failures=#{failures.count}"
exit(failures.empty? ? 0 : 1)
