#!/usr/bin/env ruby
# frozen_string_literal: true

# Explicit QA build. It selects a separate @main with no production AppDelegate
# or AppState. Use only a task-owned CoW cache, never the installed/frozen App.
require "fileutils"
require "json"
require "open3"
require "optparse"

def owned_builds(root, cache)
  text, status = Open3.capture2("ps", "-axo", "pid=,pgid=,command=")
  raise "cannot verify build processes" unless status.success?
  text.lines.filter_map do |line|
    match = line.match(/^\s*(\d+)\s+(\d+)\s+(.+)$/)
    next unless match && File.basename(match[3].split.first) == "xcodebuild"
    next unless match[3].include?(File.join(root, "Xedit.xcodeproj")) && match[3].include?(File.join(cache, "DerivedData"))
    {pid: match[1].to_i, group: match[2].to_i}
  end
end

options = {}
OptionParser.new do |parser|
  parser.banner = "ruby scripts/build_agent_workspace_preview.rb --cache-root ABSOLUTE_TASK_CACHE"
  parser.on("--cache-root PATH") { |value| options[:cache] = value }
  parser.on("--help") { puts parser; exit }
end.parse!
root = File.realpath(File.expand_path("..", __dir__))
cache = options.fetch(:cache) { abort "--cache-root is required" }
abort "a separate preview cache is required; never use the tested App cache" unless cache.start_with?("/private/tmp/xedit-agent-workspace-preview-cache-") && File.directory?(cache)
abort "cache aliases are not permitted" unless File.realpath(cache) == cache
out = File.join(root, "build/agent-workspace-preview")
FileUtils.mkdir_p(out)
free = -> { text, status = Open3.capture2("df", "-Pk", cache); raise "df failed" unless status.success?; text.lines.last.split[3].to_i * 1024 }
floor = 6 * 1024**3
abort "less than 6 GiB available" if free.call <= floor
env = {"TMPDIR" => File.join(cache, "tmp"), "GOCACHE" => File.join(cache, "GoBuildCache"),
       "GOMODCACHE" => File.join(cache, "GoModuleCache"), "GOPROXY" => "off",
       "SWIFTPM_MODULECACHE_OVERRIDE" => File.join(cache, "SwiftPMModuleCache"), "XDG_CACHE_HOME" => File.join(cache, "UserCache")}
FileUtils.mkdir_p(env.fetch("TMPDIR"))
app = File.join(cache, "DerivedData/Build/Products/Debug/WillDeep.app")
command = ["ruby", File.join(root, "scripts/project_build_guard.rb"), "--workspace", root,
           "--name", "agent-workspace-preview", "--kind", "xcode-build", "--no-cache", "--artifact", app,
           "--json-report", File.join(out, "guard.json"), "--markdown-report", File.join(out, "guard.md"), "--",
           "xcodebuild", "build", "-project", File.join(root, "Xedit.xcodeproj"), "-scheme", "Xedit",
           "-configuration", "Debug", "-destination", "platform=macOS,arch=arm64,name=My Mac",
           "-derivedDataPath", File.join(cache, "DerivedData"), "-clonedSourcePackagesDirPath", File.join(cache, "SourcePackages"),
           "-packageCachePath", File.join(cache, "PackageCache"), "-skipPackageUpdates", "-onlyUsePackageVersionsFromResolvedFile",
           "SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG AGENT_WORKSPACE_PREVIEW", "PRODUCT_BUNDLE_IDENTIFIER=com.willdeep.workspace-preview",
           "INFOPLIST_KEY_CFBundleDisplayName=WillDeep Workspace Preview", "COMPILATION_CACHE_ENABLE_CACHING=NO", "COMPILER_INDEX_STORE_ENABLE=NO",
           "GCC_GENERATE_DEBUGGING_SYMBOLS=NO", "SWIFT_SERIALIZE_DEBUGGING_OPTIONS=NO",
           "CLANG_MODULE_CACHE_PATH=#{cache}/DerivedData/ModuleCache.noindex", "SWIFT_MODULE_CACHE_PATH=#{cache}/DerivedData/ModuleCache.noindex",
           "SHARED_PRECOMPS_DIR=#{cache}/DerivedData/PrecompiledHeaders", "CACHE_ROOT=#{cache}/XcodeCache", "DSTROOT=#{cache}/Installation",
           "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO", "CODE_SIGN_IDENTITY=", "-jobs", "2"]
minimum = free.call; stopped = false; done = false; started = Time.now
pid = Process.spawn(env, *command, chdir: root, out: [File.join(out, "build.log"), "w", 0o600], err: [:child, :out], pgroup: true)
monitor = Thread.new do
  until done
    minimum = [minimum, free.call].min
    if minimum <= floor
      stopped = true
      groups = owned_builds(root, cache).map { |item| item[:group] }.uniq
      groups.each { |group| Process.kill("INT", -group) rescue Errno::ESRCH }
      Process.kill("INT", -pid) if groups.empty?
      break
    end
    sleep 2
  end
end
_, status = Process.wait2(pid); done = true; monitor.join
deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30
remaining = owned_builds(root, cache)
while !remaining.empty? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
  sleep 0.25
  remaining = owned_builds(root, cache)
end
bundle_id, plist_status = Open3.capture2("/usr/libexec/PlistBuddy", "-c", "Print :CFBundleIdentifier", File.join(app, "Contents/Info.plist"))
binaries = [File.join(app, "Contents/MacOS/WillDeep"), *Dir[File.join(app, "Contents/MacOS/*.dylib")]].select { |path| File.file?(path) }
preview_entry = status.success? && binaries.any? do |path|
  symbols, result = Open3.capture2("xcrun", "nm", "-g", path)
  result.success? && symbols.include?("AgentWorkspacePreviewApp")
end
verified = status.success? && !stopped && remaining.empty? && plist_status.success? && bundle_id.strip == "com.willdeep.workspace-preview" && preview_entry
report = {exit_code: status.exitstatus, signal: status.termsig, disk_floor_interrupted: stopped,
          elapsed_seconds: (Time.now - started).round(2), minimum_free_bytes: minimum,
          app: app, bundle_identifier: bundle_id.strip, preview_entry_verified: preview_entry, verified: verified, installed: false, model_requests: 0,
          configuration: "Debug; DEBUG+AGENT_WORKSPACE_PREVIEW; no DWARF; optimization unchanged",
          remaining_owned_xcodebuilds: remaining, actual_build_processes_exited: remaining.empty?,
          launch: ["env", "WILLDEEP_AGENT_WORKSPACE_PREVIEW_ROOT=/private/tmp/willdeep-agent-workspace-preview-fixture", File.join(app, "Contents/MacOS/WillDeep")]}
File.write(File.join(out, "build.json"), JSON.pretty_generate(report) + "\n")
puts JSON.generate(report)
exit(verified ? 0 : 1)
