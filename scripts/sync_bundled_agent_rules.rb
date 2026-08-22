#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "optparse"
require "rbconfig"
require "tmpdir"

ROOT = File.expand_path("..", __dir__)
DEFAULT_SOURCE = File.expand_path("../agentrules", ROOT)
DEFAULT_OUTPUT = File.join(ROOT, "BundledAgentRules")
RULE_FILES = %w[
  README.md
  PRODUCT_OVERVIEW.md
  ARCHITECTURE.md
  CHANGELOG.md
  ai-guardrails.md
  programming.md
  design.md
  frontend.md
  go.md
  python.md
  database-migrations.md
  database-queries.md
  database-sync.md
  deployment.md
  linux-server.md
  version-control.md
].freeze

def parse_options(argv)
  options = { source: DEFAULT_SOURCE, output: DEFAULT_OUTPUT, verify: false }
  OptionParser.new do |parser|
    parser.banner = "Usage: ruby scripts/sync_bundled_agent_rules.rb [options]"
    parser.on("--source PATH", "agentrules repository root") { |value| options[:source] = File.expand_path(value) }
    parser.on("--output PATH", "bundled output directory") { |value| options[:output] = File.expand_path(value) }
    parser.on("--verify", "verify the committed snapshot without changing it") { options[:verify] = true }
  end.parse!(argv)
  options
end

def source_version(source)
  overview = File.read(File.join(source, "PRODUCT_OVERVIEW.md"), encoding: "UTF-8")
  overview[/当前版本：v([^\s]+)/, 1] || abort("Cannot read agentrules version from PRODUCT_OVERVIEW.md")
end

def source_revision(source)
  output, status = Open3.capture2("git", "-C", source, "rev-parse", "HEAD")
  status.success? ? output.strip : "unknown"
end

def generate_index(source, destination)
  generator = File.join(source, "scripts", "generate_claude_md.rb")
  output, status = Open3.capture2e(
    RbConfig.ruby,
    generator,
    "--all",
    "--index",
    "--index-base",
    ".",
    "--output",
    File.join(destination, "AGENTS.md"),
    "--force"
  )
  abort("Failed to generate bundled AGENTS.md:\n#{output}") unless status.success?
end

def content_fingerprint(directory)
  digest = Digest::SHA256.new
  Dir.glob(File.join(directory, "**", "*"))
    .select { |path| File.file?(path) }
    .sort
    .each do |path|
      relative = path.delete_prefix("#{directory}/")
      digest << relative << "\0" << File.binread(path) << "\0"
    end
  digest.hexdigest
end

def build_snapshot(source, destination)
  missing = RULE_FILES.reject { |name| File.file?(File.join(source, name)) }
  abort("Missing agentrules source files: #{missing.join(', ')}") unless missing.empty?

  FileUtils.mkdir_p(destination)
  RULE_FILES.each { |name| FileUtils.cp(File.join(source, name), File.join(destination, name)) }
  generate_index(source, destination)

  manifest = {
    schema_version: 1,
    rules_version: source_version(source),
    source_repository: "https://github.com/xurenlu/agentrules",
    source_revision: source_revision(source),
    content_sha256: content_fingerprint(destination),
    files: (["AGENTS.md"] + RULE_FILES).sort
  }
  File.write(File.join(destination, "manifest.json"), "#{JSON.pretty_generate(manifest)}\n")
end

def directory_snapshot(directory)
  Dir.glob(File.join(directory, "**", "*"))
    .select { |path| File.file?(path) }
    .sort
    .to_h { |path| [path.delete_prefix("#{directory}/"), File.binread(path)] }
end

def verify_snapshot(source, output)
  Dir.mktmpdir("willdeep-agent-rules") do |temporary_root|
    expected = File.join(temporary_root, "BundledAgentRules")
    build_snapshot(source, expected)
    abort("BundledAgentRules is out of sync; run this script without --verify") unless
      File.directory?(output) && directory_snapshot(output) == directory_snapshot(expected)
  end
  puts "BundledAgentRules verified: #{output}"
end

def write_snapshot(source, output)
  parent = File.dirname(output)
  FileUtils.mkdir_p(parent)
  Dir.mktmpdir("willdeep-agent-rules", parent) do |temporary_root|
    staged = File.join(temporary_root, "BundledAgentRules")
    build_snapshot(source, staged)
    FileUtils.rm_rf(output)
    FileUtils.mv(staged, output)
  end
  puts "BundledAgentRules updated: #{output}"
end

options = parse_options(ARGV)
if options.fetch(:verify)
  verify_snapshot(options.fetch(:source), options.fetch(:output))
else
  write_snapshot(options.fetch(:source), options.fetch(:output))
end
