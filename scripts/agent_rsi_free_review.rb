#!/usr/bin/env ruby
# frozen_string_literal: true

# This entry has no endpoint/model/key arguments. All model-like responses are
# the injected native URLProtocol fixture. It cannot authorize a live trial.
require "json"
require "fileutils"

abort "Only offline_mock_only is supported" unless ARGV.empty? || ARGV == ["--offline-mock-only"]
root = File.expand_path("..", __dir__)
cache = File.expand_path(ENV.fetch("WILLDEEP_XCODE_CACHE_ROOT", "/private/tmp/xedit-rsi-terminal-cache"))
abort "Use an independent temporary build cache" unless cache.start_with?("/private/tmp/", "/tmp/")
environment = {"WILLDEEP_XCODE_CACHE_ROOT" => cache,
               "WILLDEEP_XCODE_DERIVED_DATA_PATH" => File.join(cache, "DerivedData"),
               "WILLDEEP_XCODE_SOURCE_PACKAGES_DIR" => File.join(cache, "SourcePackages"),
               "WILLDEEP_XCODE_PACKAGE_CACHE_DIR" => File.join(cache, "PackageCache"),
               "SWIFTPM_MODULECACHE_OVERRIDE" => File.join(cache, "SwiftPMModuleCache"),
               "GOCACHE" => File.join(cache, "GoBuildCache"), "GOMODCACHE" => File.join(cache, "GoModuleCache"), "GOPROXY" => "off"}
output = File.join(root, "build", "rsi-free-review-v2")
abort "Existing observation directory; preserve prior evidence or use a new checkout" if File.exist?(output)
FileUtils.mkdir_p(cache)
abort "Cache symlink escapes the independent temporary root" unless File.realpath(cache).start_with?("/private/tmp/", "/tmp/")
lock = File.open(File.join(cache, ".free-review-build.lock"), File::RDWR | File::CREAT, 0o600)
abort "Independent cache is already building" unless lock.flock(File::LOCK_EX | File::LOCK_NB)
free_bytes = -> { IO.popen(["df", "-Pk", cache], &:read).lines.last.split[3].to_i * 1024 }
floor = 6 * 1024**3
abort "Keep at least 6 GiB free for the active experiment" if free_bytes.call <= floor
command = ["xcodebuild", "test", "-project", File.join(root, "Xedit.xcodeproj"), "-scheme", "XeditUnitTests",
           "-destination", "platform=macOS", "-derivedDataPath", environment.fetch("WILLDEEP_XCODE_DERIVED_DATA_PATH"),
           "-clonedSourcePackagesDirPath", environment.fetch("WILLDEEP_XCODE_SOURCE_PACKAGES_DIR"),
           "-packageCachePath", environment.fetch("WILLDEEP_XCODE_PACKAGE_CACHE_DIR"),
           "-skipPackageUpdates", "-onlyUsePackageVersionsFromResolvedFile", "COMPILATION_CACHE_ENABLE_CACHING=NO",
           "CLANG_MODULE_CACHE_PATH=#{cache}/DerivedData/ModuleCache.noindex", "SWIFT_MODULE_CACHE_PATH=#{cache}/DerivedData/ModuleCache.noindex",
           "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO", "-only-testing:XeditTests/AgentRSIFreeReviewTests",
           "-parallel-testing-enabled", "NO", "-jobs", "2"]
# Spawn Xcode directly so a disk-floor signal reaches its process group;
# nested runners may intentionally create a different group for Xcode.
pid = Process.spawn(environment, *command, chdir: root, pgroup: true)
done = false
interrupted = false
%w[INT TERM].each do |signal|
  Signal.trap(signal) { interrupted = true; Process.kill(signal, -pid) rescue Errno::ESRCH }
end
monitor = Thread.new do
  until done
    if free_bytes.call <= floor
      interrupted = true
      Process.kill("INT", -pid) rescue Errno::ESRCH
      break
    end
    sleep 2
  end
end
_, status = Process.wait2(pid)
done = true
monitor.join
lock.close
success = status.success? && !interrupted
report_path = File.join(output, "report.json")
success &&= File.file?(report_path)
if success
  report = JSON.parse(File.read(report_path))
  success &&= report["real_provider_requests"] == 0 && report.fetch("observations").length == 6
end
puts JSON.generate({passed: success, execution_mode: "offline_mock_only", real_provider_requests: 0, report: report_path})
exit(success ? 0 : 1)
