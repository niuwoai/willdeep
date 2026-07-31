#!/usr/bin/env ruby
# frozen_string_literal: true

summary_path = ENV.fetch("GITHUB_STEP_SUMMARY") do
  abort "GITHUB_STEP_SUMMARY is not set"
end

paths = ARGV.map { |path| File.expand_path(path) }
missing = paths.reject { |path| File.file?(path) }
abort "Missing Markdown report(s): #{missing.join(", ")}" unless missing.empty?

File.open(summary_path, "a") do |summary|
  paths.each do |path|
    summary.write("\n")
    summary.write(File.read(path, encoding: "UTF-8"))
    summary.write("\n")
  end
end
