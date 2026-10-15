# frozen_string_literal: true
require "json"
require "digest"
require "fileutils"
require "open3"
require "securerandom"

module AgentRSIFrozenRunner
  module_function
  def tree_files(app)
    Dir[File.join(app, "**", "*"), File.join(app, "**", ".*")].uniq.sort.filter_map do |path|
      next unless File.file?(path)
      [path.delete_prefix(app + "/"), Digest::SHA256.file(path).hexdigest]
    end.to_h
  end
  def scripts(root)
    %w[agent_rsi_approved_trial.rb agent_rsi_frozen_runner.rb].to_h do |name|
      [name, Digest::SHA256.file(File.join(root, "scripts", name)).hexdigest]
    end
  end
  def freeze(root, path)
    derived = ENV.fetch("WILLDEEP_XCODE_DERIVED_DATA_PATH", File.join(Dir.home, "Library/Caches/WillDeep/Xcode/Xedit/DerivedData"))
    app = File.join(derived, "Build/Products/Debug/WillDeep.app")
    abort "verified native test build missing" unless File.file?(File.join(app, "Contents/PlugIns/XeditTests.xctest/Contents/MacOS/XeditTests"))
    manifest = {schema: "willdeep.agent-rsi.frozen-native-runner.v1", derived_data: derived,
                app: app, app_files: tree_files(app), adapter_scripts: scripts(root)}
    FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
    File.write(path, JSON.pretty_generate(manifest) + "\n", mode: "w", perm: 0o600)
    puts JSON.generate({frozen_runner: path, app_files: manifest[:app_files].size,
                         manifest_sha256: Digest::SHA256.file(path).hexdigest})
  end
  def verify(root, manifest)
    abort "unsupported frozen runner" unless manifest["schema"] == "willdeep.agent-rsi.frozen-native-runner.v1"
    abort "frozen adapter script changed" unless scripts(root) == manifest.fetch("adapter_scripts")
    abort "frozen App/test bundle changed" unless tree_files(manifest.fetch("app")) == manifest.fetch("app_files")
  end
  def run(root, path)
    manifest = JSON.parse(File.read(path))
    verify(root, manifest)
    directory = File.join(root, "build/rsi-approved-frozen-runs", SecureRandom.uuid)
    FileUtils.mkdir_p(directory, mode: 0o700)
    command = ["xcodebuild", "test-without-building", "-project", File.join(root, "Xedit.xcodeproj"),
      "-scheme", "XeditUnitTests", "-destination", "platform=macOS", "-derivedDataPath", manifest.fetch("derived_data"),
      "-skipPackageUpdates", "-onlyUsePackageVersionsFromResolvedFile", "-parallel-testing-enabled", "NO",
      "-only-testing:XeditTests/AgentRSIApprovedTrialTests/hostControlledNativeEntry()",
      "-resultBundlePath", File.join(directory, "result.xcresult"), "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO"]
    log, status = Open3.capture2e(*command, chdir: root)
    File.write(File.join(directory, "xcodebuild.log"), log, mode: "w", perm: 0o600)
    verify(root, manifest)
    abort "unexpected compile in frozen execution" if log.match?(/^\s*(?:SwiftCompile|CompileC)\b/)
    summary = {passed: status.success? && log.include?("** TEST EXECUTE SUCCEEDED **") && log.match?(/Test run with 1 test in 1 suite passed/),
               frozen_runner_sha256: Digest::SHA256.file(path).hexdigest, build_attempted: false,
               log: File.join(directory, "xcodebuild.log"), exit: status.exitstatus}
    File.write(File.join(directory, "report.json"), JSON.pretty_generate(summary) + "\n")
    File.write(File.join(directory, "report.md"), "# 原生冻结产物执行\n\n完成：#{summary[:passed]}\n\n仅 test-without-building；执行前后 App、测试包与适配脚本哈希一致。\n")
    puts JSON.generate(summary)
    summary[:passed]
  end
end
