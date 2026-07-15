#!/usr/bin/env ruby
# frozen_string_literal: true

# project_build_guard.rb
#
# Workspace-level build coordinator. It serializes heavy project build/package
# commands across agent sessions, records build fingerprints, and skips a run
# when an identical successful artifact already exists.
#
# Usage:
#   ruby scripts/project_build_guard.rb --name xedit-tests \
#     --kind xcode-test \
#     --artifact build/ci/XeditTests.xcresult \
#     --fingerprint-file Xedit.xcodeproj/project.pbxproj \
#     -- xcodebuild test ...

require "digest"
require "fileutils"
require "json"
require "open3"
require "optparse"
require "securerandom"
require "time"

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

def iso_now
  Time.now.utc.iso8601
end

def sanitize_name(value)
  value.to_s.downcase.gsub(/[^a-z0-9._-]+/, "-").gsub(/\A-+|-+\z/, "")
end

def sha256(value)
  Digest::SHA256.hexdigest(value.to_s)
end

def read_json(path, fallback)
  return fallback unless File.file?(path)

  JSON.parse(File.read(path, encoding: "UTF-8"))
rescue JSON::ParserError
  fallback
end

def write_json(path, value)
  FileUtils.mkdir_p(File.dirname(path))
  temp = "#{path}.tmp-#{Process.pid}-#{SecureRandom.hex(4)}"
  File.write(temp, JSON.pretty_generate(value))
  File.rename(temp, path)
end

def command_output(*args, chdir:)
  stdout, status = Open3.capture2e(*args, chdir: chdir)
  return nil unless status.success?

  stdout.strip
rescue Errno::ENOENT
  nil
end

def git_root(start)
  command_output("git", "rev-parse", "--show-toplevel", chdir: start)
end

def git_value(root, *args)
  command_output("git", *args, chdir: root)
end

def file_digest(path)
  return nil unless File.file?(path)

  Digest::SHA256.file(path).hexdigest
end

def directory_digest(path)
  return nil unless File.directory?(path)

  entries = Dir.glob(File.join(path, "**", "*"), File::FNM_DOTMATCH)
    .reject { |entry| [".", ".."].include?(File.basename(entry)) }
    .select { |entry| File.file?(entry) }
    .sort
  digest = Digest::SHA256.new
  entries.each do |entry|
    relative = entry.delete_prefix("#{path}/")
    digest.update(relative)
    digest.update("\0")
    digest.update(Digest::SHA256.file(entry).hexdigest)
    digest.update("\0")
  end
  digest.hexdigest
end

def path_digest(path)
  return file_digest(path) if File.file?(path)
  return directory_digest(path) if File.directory?(path)

  nil
end

def artifact_present?(path)
  File.file?(path) || File.directory?(path)
end

def process_alive?(pid)
  Process.kill(0, Integer(pid))
  true
rescue Errno::ESRCH
  false
rescue Errno::EPERM
  true
rescue ArgumentError, TypeError
  false
end

def redact_token(token)
  key = token.split("=", 2).first.to_s.downcase
  return token unless key.match?(/(secret|token|password|passwd|api[_-]?key|credential)/)
  return "[REDACTED]" unless token.include?("=")

  "#{token.split("=", 2).first}=[REDACTED]"
end

def redacted_command(command)
  command.map { |token| redact_token(token) }
end

def write_report(markdown_path, json_path, report)
  write_json(json_path, report)

  md = +"# Project Build Guard Report\n\n"
  md << "- Status: #{report.fetch("status")}\n"
  md << "- Name: #{report.fetch("name")}\n"
  md << "- Kind: #{report.fetch("kind")}\n"
  md << "- Fingerprint: `#{report.fetch("fingerprint")}`\n"
  md << "- Fingerprint refreshed after wait: #{report.fetch("fingerprint_refreshed_after_wait", false)}\n"
  md << "- Workspace: `#{report.fetch("workspace")}`\n"
  md << "- Waited: #{report.fetch("waited_seconds")}s\n"
  md << "- Exit status: #{report.fetch("exit_status", "n/a")}\n"
  md << "- Started at: #{report.fetch("started_at", "")}\n"
  md << "- Finished at: #{report.fetch("finished_at", "")}\n\n"
  unless report.fetch("artifacts").empty?
    md << "## Artifacts\n\n"
    report.fetch("artifacts").each { |artifact| md << "- `#{artifact}`\n" }
    md << "\n"
  end
  md << "## Command\n\n"
  md << "```text\n#{report.fetch("command").join(" ")}\n```\n"
  FileUtils.mkdir_p(File.dirname(markdown_path))
  File.write(markdown_path, md)
end

options = {
  workspace: nil,
  state_dir: ".codex-build",
  name: nil,
  kind: "build",
  artifacts: [],
  fingerprint_files: [],
  fingerprint_strings: [],
  replace_artifacts: false,
  no_cache: false,
  json_report: nil,
  markdown_report: nil
}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: ruby scripts/project_build_guard.rb [options] -- command args..."
  opts.on("--workspace PATH", "Workspace root. Defaults to git root or cwd.") { |value| options[:workspace] = value }
  opts.on("--state-dir PATH", "Local guard state dir. Defaults to .codex-build.") { |value| options[:state_dir] = value }
  opts.on("--name NAME", "Human-readable build name.") { |value| options[:name] = value }
  opts.on("--kind KIND", "Build kind, e.g. xcode-test, archive, frontend-build.") { |value| options[:kind] = value }
  opts.on("--artifact PATH", "Artifact path that proves this build is reusable. Repeatable.") do |value|
    options[:artifacts] << value
  end
  opts.on("--fingerprint-file PATH", "File or directory included in the fingerprint. Repeatable.") do |value|
    options[:fingerprint_files] << value
  end
  opts.on("--fingerprint-string VALUE", "Extra stable value included in the fingerprint. Repeatable.") do |value|
    options[:fingerprint_strings] << value
  end
  opts.on("--replace-artifacts", "Remove artifact paths immediately before running the command.") do
    options[:replace_artifacts] = true
  end
  opts.on("--no-cache", "Queue and run even when matching artifacts exist.") { options[:no_cache] = true }
  opts.on("--json-report PATH", "Write machine-readable report.") { |value| options[:json_report] = value }
  opts.on("--markdown-report PATH", "Write markdown report.") { |value| options[:markdown_report] = value }
end

argv = ARGV.dup
separator = argv.index("--")
abort(parser.to_s) unless separator

parser.parse!(argv[0...separator])
command = argv[(separator + 1)..]
abort(parser.to_s) if command.empty?

workspace = File.expand_path(options[:workspace] || git_root(Dir.pwd) || Dir.pwd)
state_dir = File.expand_path(options[:state_dir], workspace)
queue_dir = File.join(state_dir, "queue")
reports_dir = File.join(state_dir, "reports")
manifest_path = File.join(state_dir, "manifest.json")
lock_path = File.join(state_dir, "workspace.lock")
name = sanitize_name(options[:name] || command.first || "build")
kind = options[:kind].to_s

FileUtils.mkdir_p(queue_dir)
FileUtils.mkdir_p(reports_dir)
FileUtils.mkdir_p(File.dirname(lock_path))

artifact_paths = options[:artifacts].map { |path| File.expand_path(path, workspace) }
fingerprint_paths = options[:fingerprint_files].map { |path| File.expand_path(path, workspace) }
redacted = redacted_command(command)

capture_fingerprint = lambda do
  input = {
    "workspace" => workspace,
    "name" => name,
    "kind" => kind,
    "command_sha256" => sha256(command.join("\0")),
    "git_head" => git_value(workspace, "rev-parse", "HEAD"),
    "git_status_sha256" => sha256(git_value(workspace, "status", "--porcelain=v1") || ""),
    "git_diff_sha256" => sha256([
      git_value(workspace, "diff", "--binary"),
      git_value(workspace, "diff", "--cached", "--binary")
    ].compact.join("\n")),
    "xcodebuild_version" => command.include?("xcodebuild") ? command_output("xcodebuild", "-version", chdir: workspace) : nil,
    "fingerprint_strings" => options[:fingerprint_strings],
    "fingerprint_files" => fingerprint_paths.map do |path|
      {
        "path" => path.delete_prefix("#{workspace}/"),
        "sha256" => path_digest(path),
        "exists" => File.exist?(path)
      }
    end
  }
  [input, sha256(JSON.generate(input))]
end

fingerprint_input, fingerprint = capture_fingerprint.call
initial_fingerprint = fingerprint
report_stamp = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
json_report = File.expand_path(options[:json_report] || File.join(reports_dir, "#{name}-#{report_stamp}.json"), workspace)
markdown_report = File.expand_path(options[:markdown_report] || File.join(reports_dir, "#{name}-#{report_stamp}.md"), workspace)

def reusable_entry?(entry, artifact_paths)
  return false unless entry
  return false unless entry["status"] == "success"
  return false if artifact_paths.empty?

  artifact_paths.all? { |path| artifact_present?(path) }
end

cache_status = lambda do
  manifest = read_json(manifest_path, {})
  entry = manifest[fingerprint]
  reusable_entry?(entry, artifact_paths) ? entry : nil
end

started_at = iso_now

job_id = "#{Time.now.to_f}-#{Process.pid}-#{SecureRandom.hex(4)}"
job_path = File.join(queue_dir, "#{job_id}.json")
job = {
  "id" => job_id,
  "pid" => Process.pid,
  "name" => name,
  "kind" => kind,
  "fingerprint" => fingerprint,
  "command" => redacted,
  "created_at" => Time.now.to_f,
  "created_at_iso" => iso_now
}
write_json(job_path, job)
at_exit { FileUtils.rm_f(job_path) }

wait_started = Time.now
loop do
  Dir.glob(File.join(queue_dir, "*.json")).each do |path|
    queued = read_json(path, nil)
    next unless queued
    next if process_alive?(queued["pid"])

    FileUtils.rm_f(path)
  end

  jobs = Dir.glob(File.join(queue_dir, "*.json")).map { |path| read_json(path, nil) }.compact
    .sort_by { |queued| [queued["created_at"].to_f, queued["id"].to_s] }
  position = jobs.index { |queued| queued["id"] == job_id }
  abort "[project_build_guard] queue entry disappeared: #{job_id}" unless position

  break if position.zero?

  puts "[project_build_guard] queued #{name}: position #{position + 1}/#{jobs.length}"
  sleep 3
end

exit_status = nil
status_label = "failed"
lock_file = File.open(lock_path, File::RDWR | File::CREAT, 0o644)
begin
  lock_file.flock(File::LOCK_EX)
  waited_seconds = (Time.now - wait_started).round(3)
  FileUtils.rm_f(job_path)
  fingerprint_input, fingerprint = capture_fingerprint.call
  fingerprint_refreshed = fingerprint != initial_fingerprint

  if !options[:no_cache] && (entry = cache_status.call)
    report = {
      "status" => "cache-hit-after-wait",
      "name" => name,
      "kind" => kind,
      "workspace" => workspace,
      "fingerprint" => fingerprint,
      "initial_fingerprint" => initial_fingerprint,
      "fingerprint_refreshed_after_wait" => fingerprint_refreshed,
      "fingerprint_input" => fingerprint_input,
      "artifacts" => artifact_paths,
      "command" => redacted,
      "waited_seconds" => waited_seconds,
      "exit_status" => 0,
      "started_at" => started_at,
      "finished_at" => iso_now,
      "reused_from" => entry["finished_at"]
    }
    write_report(markdown_report, json_report, report)
    puts "[project_build_guard] cache hit after wait: #{name} #{fingerprint}"
    puts "[project_build_guard] report: #{markdown_report}"
    exit 0
  end

  puts "[project_build_guard] acquired workspace build slot: #{name}"
  if options[:replace_artifacts]
    artifact_paths.each { |path| FileUtils.rm_rf(path) }
  end
  command_started_at = iso_now
  Open3.popen2e(*command, chdir: workspace) do |_stdin, stdout_err, wait_thread|
    stdout_err.each_line { |line| STDOUT.write(line) }
    exit_status = wait_thread.value.exitstatus
  end
  status_label = exit_status.to_i.zero? ? "success" : "failed"

  finished_at = iso_now
  manifest = read_json(manifest_path, {})
  manifest[fingerprint] = {
    "status" => status_label,
    "name" => name,
    "kind" => kind,
    "workspace" => workspace,
    "fingerprint" => fingerprint,
    "initial_fingerprint" => initial_fingerprint,
    "fingerprint_refreshed_after_wait" => fingerprint_refreshed,
    "fingerprint_input" => fingerprint_input,
    "artifacts" => artifact_paths,
    "command" => redacted,
    "exit_status" => exit_status,
    "started_at" => command_started_at,
    "finished_at" => finished_at,
    "report_json" => json_report,
    "report_markdown" => markdown_report
  }
  write_json(manifest_path, manifest)

  report = {
    "status" => status_label,
    "name" => name,
    "kind" => kind,
    "workspace" => workspace,
    "fingerprint" => fingerprint,
    "initial_fingerprint" => initial_fingerprint,
    "fingerprint_refreshed_after_wait" => fingerprint_refreshed,
    "fingerprint_input" => fingerprint_input,
    "artifacts" => artifact_paths,
    "command" => redacted,
    "waited_seconds" => waited_seconds,
    "exit_status" => exit_status,
    "started_at" => started_at,
    "finished_at" => finished_at
  }
  write_report(markdown_report, json_report, report)
  puts "[project_build_guard] #{status_label}: #{name} exit=#{exit_status}"
  puts "[project_build_guard] report: #{markdown_report}"
ensure
  lock_file.flock(File::LOCK_UN)
  lock_file.close
end

exit(exit_status || 1)
