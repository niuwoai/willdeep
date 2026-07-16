#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "optparse"
require "pathname"
require "time"
require "uri"
require "yaml"

options = {
  report_dir: File.expand_path("build/mac-app-docs-site-audit", Dir.pwd)
}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: audit_docs.rb DOCS_DIR [--report-dir DIR]"
  opts.on("--report-dir DIR", "Write Markdown and JSON reports to DIR") do |value|
    options[:report_dir] = File.expand_path(value)
  end
end

parser.parse!
docs_arg = ARGV.shift
abort parser.to_s unless docs_arg

docs_dir = Pathname.new(File.expand_path(docs_arg))
errors = []
warnings = []
checks = []
referenced_images = []

record = lambda do |name, passed, detail, severity = :error|
  checks << { name: name, passed: passed, detail: detail, severity: severity.to_s }
  next if passed

  message = "#{name}: #{detail}"
  severity == :warning ? warnings << message : errors << message
end

unless docs_dir.directory?
  abort "Documentation directory does not exist: #{docs_dir}"
end

markdown_files = docs_dir.glob("*.md").sort
record.call("Markdown pages exist", !markdown_files.empty?, docs_dir.to_s)
record.call("README.md exists", docs_dir.join("README.md").file?, "Expected tutorial overview at README.md")

orders = Hash.new { |hash, key| hash[key] = [] }
image_extensions = %w[.png .jpg .jpeg .webp .gif].freeze

markdown_files.each do |file|
  relative_file = file.relative_path_from(docs_dir).to_s
  content = file.read(encoding: "UTF-8")
  front_matter = nil

  if content.start_with?("---\n") && (closing = content.index("\n---\n", 4))
    raw_front_matter = content[4...closing]
    begin
      parsed = YAML.safe_load(raw_front_matter, permitted_classes: [], aliases: false)
      front_matter = parsed.is_a?(Hash) ? parsed : nil
    rescue Psych::SyntaxError => e
      record.call("#{relative_file} front matter parses", false, e.message.lines.first.to_s.strip)
    end
  end

  record.call("#{relative_file} has front matter", !front_matter.nil?, "Expected YAML block at top of file")
  next unless front_matter

  %w[title order description].each do |key|
    value = front_matter[key]
    present = !value.nil? && !value.to_s.strip.empty?
    record.call("#{relative_file} has #{key}", present, "Missing or empty #{key}")
  end

  order = front_matter["order"]
  numeric_order = order.is_a?(Integer) || order.to_s.match?(/\A\d+\z/)
  record.call("#{relative_file} order is numeric", numeric_order, "Found #{order.inspect}")
  orders[order.to_i] << relative_file if numeric_order

  local_path_leaks = content.scan(%r{(?:file://|/Users/|/private/var/folders/)[^\s)>]*})
  record.call(
    "#{relative_file} contains no local absolute paths",
    local_path_leaks.empty?,
    local_path_leaks.empty? ? "OK" : local_path_leaks.uniq.join(", ")
  )

  content.scan(/(!?)\[[^\]]*\]\(([^)]+)\)/).each do |image_marker, raw_target|
    target = raw_target.strip.sub(/\s+["'][^"']*["']\z/, "")
    next if target.empty? || target.start_with?("#")
    next if target.match?(%r{\A(?:https?:|mailto:|tel:|data:)})

    target = URI.decode_www_form_component(target.split("#", 2).first.split("?", 2).first)
    resolved = file.dirname.join(target).cleanpath
    within_docs = resolved.to_s == docs_dir.to_s || resolved.to_s.start_with?("#{docs_dir}/")
    record.call("#{relative_file} link stays in docs directory", within_docs, target)
    next unless within_docs

    exists = resolved.file?
    kind = image_marker == "!" ? "image" : "link"
    record.call("#{relative_file} #{kind} resolves", exists, target)
    referenced_images << resolved.expand_path.to_s if image_marker == "!" && image_extensions.include?(resolved.extname.downcase)
  rescue ArgumentError
    record.call("#{relative_file} link decodes", false, raw_target)
  end
end

orders.each do |order, files|
  record.call("Order #{order} is unique", files.length == 1, files.join(", "))
end

all_images = docs_dir.glob("assets/**/*").select do |path|
  path.file? && image_extensions.include?(path.extname.downcase)
end.map { |path| path.expand_path.to_s }

orphaned_images = all_images - referenced_images.uniq
orphaned_images.each do |image|
  relative = Pathname.new(image).relative_path_from(docs_dir).to_s
  record.call("Image is referenced", false, relative, :warning)
end

report = {
  generated_at: Time.now.iso8601,
  docs_dir: docs_dir.to_s,
  passed: errors.empty?,
  summary: {
    markdown_pages: markdown_files.length,
    images: all_images.length,
    checks: checks.length,
    errors: errors.length,
    warnings: warnings.length
  },
  errors: errors,
  warnings: warnings,
  checks: checks
}

FileUtils.mkdir_p(options[:report_dir])
json_path = File.join(options[:report_dir], "report.json")
markdown_path = File.join(options[:report_dir], "report.md")
File.write(json_path, JSON.pretty_generate(report) + "\n")

status = report[:passed] ? "PASS" : "FAIL"
markdown = +"# Mac App Docs Site Audit\n\n"
markdown << "- Status: **#{status}**\n"
markdown << "- Documentation: `#{docs_dir}`\n"
markdown << "- Pages: #{report[:summary][:markdown_pages]}\n"
markdown << "- Images: #{report[:summary][:images]}\n"
markdown << "- Errors: #{errors.length}\n"
markdown << "- Warnings: #{warnings.length}\n\n"
markdown << "| Check | Result | Severity | Detail |\n"
markdown << "|---|---|---|---|\n"
checks.each do |check|
  detail = check[:detail].to_s.gsub("|", "\\|").gsub("\n", " ")
  markdown << "| #{check[:name]} | #{check[:passed] ? 'PASS' : 'FAIL'} | #{check[:severity]} | #{detail} |\n"
end
File.write(markdown_path, markdown)

puts JSON.generate({ status: status, report_json: json_path, report_markdown: markdown_path, errors: errors.length, warnings: warnings.length })
exit(errors.empty? ? 0 : 1)
