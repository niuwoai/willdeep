#!/usr/bin/env ruby
# frozen_string_literal: true

# complexity_guard.rb — scan source-like files for line-count risk and emit
# markdown + json reports.
#
# Usage:
#   ruby scripts/complexity_guard.rb
#   ruby scripts/complexity_guard.rb build/ci/complexity_report.md build/ci/complexity_report.json
#   ruby scripts/complexity_guard.rb --fail-on-soft
#
# Defaults follow AGENTS.md:
#   - > 2000 lines: warn / consider splitting
#   - > 3000 lines: fail / must split

require "json"
require "fileutils"
require "optparse"
require "time"

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

options = {
  soft_limit: 2_000,
  hard_limit: 3_000,
  fail_on_soft: false,
  roots: ["Xedit", "XeditTests", "willdeep-agent", "scripts", ".github/workflows"],
  extensions: %w[.swift .go .rb .sh .yml .yaml],
  markdown_path: "build/ci/complexity_report.md",
  json_path: "build/ci/complexity_report.json"
}

OptionParser.new do |parser|
  parser.banner = "Usage: ruby scripts/complexity_guard.rb [options] [report.md] [report.json]"

  parser.on("--soft N", Integer, "Soft line-count threshold") do |value|
    options[:soft_limit] = value
  end

  parser.on("--hard N", Integer, "Hard line-count threshold") do |value|
    options[:hard_limit] = value
  end

  parser.on("--fail-on-soft", "Exit non-zero when any file exceeds the soft threshold") do
    options[:fail_on_soft] = true
  end

  parser.on("--root PATH", "Additional root to scan; can be repeated") do |path|
    options[:roots] << path
  end
end.parse!

options[:markdown_path] = ARGV.shift if ARGV[0]
options[:json_path] = ARGV.shift if ARGV[0]

skip_dirs = %w[
  .git
  .swiftpm
  DerivedData
  Vendor
  build
  node_modules
  Pods
  target
]

repo_root = File.expand_path("..", __dir__)

def source_file?(path, extensions)
  extensions.include?(File.extname(path))
end

def count_lines(path)
  count = 0
  File.foreach(path) { count += 1 }
  count
rescue ArgumentError, Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError
  File.binread(path).count("\n") + 1
end

files = []
options[:roots].uniq.each do |root|
  expanded = File.expand_path(root, repo_root)
  next unless File.exist?(expanded)

  if File.file?(expanded)
    files << expanded if source_file?(expanded, options[:extensions])
    next
  end

  Dir.glob(File.join(expanded, "**", "*"), File::FNM_DOTMATCH).each do |path|
    basename = File.basename(path)
    next if basename == "." || basename == ".."

    relative_parts = path.delete_prefix("#{repo_root}/").split(File::SEPARATOR)
    next if (relative_parts & skip_dirs).any?
    next unless File.file?(path)
    next unless source_file?(path, options[:extensions])

    files << path
  end
end

entries = files.uniq.map do |path|
  relative = path.delete_prefix("#{repo_root}/")
  lines = count_lines(path)
  severity =
    if lines > options[:hard_limit]
      "hard"
    elsif lines > options[:soft_limit]
      "soft"
    else
      "ok"
    end
  {
    path: relative,
    lines: lines,
    severity: severity
  }
end.sort_by { |entry| [-entry[:lines], entry[:path]] }

over_soft = entries.select { |entry| entry[:severity] == "soft" }
over_hard = entries.select { |entry| entry[:severity] == "hard" }
ok = over_hard.empty? && (!options[:fail_on_soft] || over_soft.empty?)

report = {
  ok: ok,
  generated_at: Time.now.utc.iso8601,
  soft_limit: options[:soft_limit],
  hard_limit: options[:hard_limit],
  fail_on_soft: options[:fail_on_soft],
  roots: options[:roots].uniq,
  scanned_files: entries.length,
  over_soft_count: over_soft.length,
  over_hard_count: over_hard.length,
  findings: entries.select { |entry| entry[:severity] != "ok" },
  top_files: entries.first(25)
}

[options[:markdown_path], options[:json_path]].each do |path|
  directory = File.dirname(File.expand_path(path, repo_root))
  FileUtils.mkdir_p(directory) unless Dir.exist?(directory)
end

File.write(File.expand_path(options[:json_path], repo_root), JSON.pretty_generate(report))

status = ok ? "PASS" : "FAIL"
md = +"# Complexity Guard Report\n\n"
md << "**Status:** #{status}\n\n"
md << "- Scanned files: #{entries.length}\n"
md << "- Soft limit: #{options[:soft_limit]} lines\n"
md << "- Hard limit: #{options[:hard_limit]} lines\n"
md << "- Files over soft limit: #{over_soft.length}\n"
md << "- Files over hard limit: #{over_hard.length}\n\n"

if report[:findings].empty?
  md << "No files exceed the configured thresholds.\n\n"
else
  md << "## Findings\n\n"
  md << "| Severity | Lines | File |\n"
  md << "| --- | ---: | --- |\n"
  report[:findings].each do |entry|
    md << "| #{entry[:severity]} | #{entry[:lines]} | `#{entry[:path]}` |\n"
  end
  md << "\n"
end

md << "## Largest Files\n\n"
md << "| Lines | File |\n"
md << "| ---: | --- |\n"
report[:top_files].each do |entry|
  md << "| #{entry[:lines]} | `#{entry[:path]}` |\n"
end

File.write(File.expand_path(options[:markdown_path], repo_root), md)

puts "complexity_guard: #{status.downcase} scanned=#{entries.length} soft=#{over_soft.length} hard=#{over_hard.length}"
exit(ok ? 0 : 1)
