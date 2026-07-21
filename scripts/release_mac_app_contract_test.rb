#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"
require "time"
require_relative "release_mac_app"

repo_root = File.expand_path("..", __dir__)
markdown_path = File.expand_path(ARGV[0] || "build/ci/release_mac_app_contract_test.md", repo_root)
json_path = File.expand_path(ARGV[1] || "build/ci/release_mac_app_contract_test.json", repo_root)
results = []

check = lambda do |name, &block|
  block.call
  results << { name: name, ok: true }
rescue StandardError => e
  results << { name: name, ok: false, error: e.message }
end

assert = lambda do |condition, message|
  raise message unless condition
end

check.call("dotenv 仅加载白名单且不覆盖现有环境") do
  Dir.mktmpdir("willdeep-release-test") do |directory|
    path = File.join(directory, ".env.local")
    File.write(
      path,
      <<~ENV_FILE
        # comment
        export ALLOWED_ONE="from-file"
        ALLOWED_TWO='second-value'
        BLOCKED_KEY=must-not-load
      ENV_FILE
    )
    environment = { "ALLOWED_TWO" => "already-set" }
    loaded = WillDeepRelease::Dotenv.load(
      path,
      allowed_keys: %w[ALLOWED_ONE ALLOWED_TWO],
      environment: environment
    )

    assert.call(loaded == ["ALLOWED_ONE"], "dotenv loaded unexpected keys: #{loaded.inspect}")
    assert.call(environment["ALLOWED_ONE"] == "from-file", "quoted value was not unwrapped")
    assert.call(environment["ALLOWED_TWO"] == "already-set", "existing environment was overwritten")
    assert.call(!environment.key?("BLOCKED_KEY"), "non-whitelisted key was loaded")
  end
end

check.call("日志脱敏覆盖发布凭据") do
  previous = ENV["WILLDEEP_CLIENT_LOGIN_SECRET"]
  ENV["WILLDEEP_CLIENT_LOGIN_SECRET"] = "contract-test-secret"
  runner = WillDeepRelease::CommandRunner.new(log_path: File::NULL, dry_run: true)
  redacted = runner.redact("value=contract-test-secret")
  assert.call(!redacted.include?("contract-test-secret"), "secret remained in log output")
  assert.call(redacted.include?("[REDACTED:WILLDEEP_CLIENT_LOGIN_SECRET]"), "redaction marker missing")
ensure
  ENV["WILLDEEP_CLIENT_LOGIN_SECRET"] = previous
end

check.call("CLI 支持安全的本地演练参数") do
  options = WillDeepRelease::CLI.parse(%w[--dry-run --skip-tests --skip-notarize --skip-upload --skip-update-metadata])
  assert.call(
    options.values_at(:dry_run, :skip_tests, :skip_notarize, :skip_upload, :skip_update_metadata).all?,
    "CLI flags were not parsed"
  )
end

check.call("CLI 支持从既有 DMG 恢复发布 appcast 元数据") do
  options = WillDeepRelease::CLI.parse(
    %w[--publish-metadata-only /tmp/WillDeep-1.2.3-rc1.dmg --release-version 1.2.3-rc1 --bundle-version 42]
  )
  assert.call(options[:publish_metadata_only] == "/tmp/WillDeep-1.2.3-rc1.dmg", "metadata-only DMG path missing")
  assert.call(options[:release_version] == "1.2.3-rc1", "release version override missing")
  assert.call(options[:bundle_version] == 42, "bundle version override missing")
end

check.call("appcast 发布时间使用 MySQL TIMESTAMP 兼容格式") do
  release = WillDeepRelease::Release.new(
    dry_run: true,
    clean: false,
    skip_tests: true,
    skip_notarize: true,
    skip_upload: true,
    skip_update_metadata: true,
    build_root: File.join(Dir.tmpdir, "willdeep-release-contract")
  )
  timestamp = release.send(:database_timestamp, Time.utc(2026, 7, 18, 3, 4, 5))
  assert.call(timestamp == "2026-07-18 03:04:05", "unexpected database timestamp: #{timestamp}")
end

check.call("appcast 发布说明固定使用 WillDeep changelog 页面") do
  assert.call(
    WillDeepRelease::RELEASE_NOTES_URL == "https://some.im/zh/products/willdeep/changelog",
    "unexpected release notes URL: #{WillDeepRelease::RELEASE_NOTES_URL}"
  )
end

check.call("OSS 同时生成版本对象和 latest 对象") do
  release = WillDeepRelease::Release.new(
    dry_run: true,
    clean: false,
    skip_tests: true,
    skip_notarize: true,
    skip_upload: true,
    oss_bucket: "test-bucket",
    oss_prefix: "mac-apps",
    oss_public_base_url: "https://downloads.example.test",
    build_root: File.join(Dir.tmpdir, "willdeep-release-contract")
  )
  version_key, latest_key = release.send(:oss_keys)
  assert.call(version_key.match?(%r{\Amac-apps/WillDeep-\d+\.\d+\.\d+(?:-rc\d+)?\.dmg\z}), "invalid version key: #{version_key}")
  assert.call(latest_key == "mac-apps/latest/WillDeep.dmg", "invalid latest key: #{latest_key}")
end

check.call("clean 构建目录限制在仓库 build 或系统临时目录") do
  release = WillDeepRelease::Release.new(
    dry_run: true,
    clean: true,
    skip_tests: true,
    skip_notarize: true,
    skip_upload: true,
    build_root: File.expand_path("~/unsafe-release-root")
  )
  begin
    release.send(:validate_build_root!)
  rescue WillDeepRelease::ReleaseError
    next
  end
  raise "unsafe build root was accepted"
end

check.call("发布导出会为嵌套可执行文件启用 hardened runtime") do
  Dir.mktmpdir("willdeep-release-signing") do |directory|
    app_path = File.join(directory, "WillDeep.app")
    nested_paths = WillDeepRelease::NOTARIZATION_NESTED_CODE_PATHS.map do |relative_path|
      File.join(app_path, relative_path)
    end
    nested_paths.each do |path|
      if File.extname(path) == ".app"
        FileUtils.mkdir_p(path)
      else
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "test executable")
      end
    end

    runner = Object.new
    commands = []
    runner.define_singleton_method(:run!) do |arguments|
      commands << arguments
      ""
    end

    release = WillDeepRelease::Release.new(
      dry_run: true,
      clean: false,
      skip_tests: true,
      skip_notarize: true,
      skip_upload: true,
      build_root: File.join(Dir.tmpdir, "willdeep-release-contract")
    )
    release.instance_variable_set(:@paths, { app: app_path })
    release.instance_variable_set(:@identity, "TEST_DEVELOPER_ID")
    release.instance_variable_set(:@runner, runner)
    release.send(:resign_exported_app_for_notarization)

    assert.call(commands.length == nested_paths.length + 1, "unexpected codesign command count: #{commands.length}")
    commands.each do |command|
      assert.call(command.include?("--timestamp"), "codesign command omitted timestamp: #{command.inspect}")
      runtime_index = command.index("--options")
      assert.call(runtime_index && command[runtime_index + 1] == "runtime", "codesign command omitted hardened runtime: #{command.inspect}")
    end
    assert.call(
      commands.last.include?("--preserve-metadata=#{WillDeepRelease::PRESERVED_APP_SIGNATURE_METADATA}"),
      "outer app signature did not preserve metadata"
    )
  end
end

check.call("create-dmg 路径不会重复创建 Applications 链接") do
  Dir.mktmpdir("willdeep-release-dmg") do |directory|
    app_path = File.join(directory, "export", "WillDeep.app")
    dmg_source = File.join(directory, "dmg-src")
    FileUtils.mkdir_p(app_path)

    runner = Object.new
    runner.define_singleton_method(:run!) { |_arguments| "" }
    release = WillDeepRelease::Release.new(
      dry_run: true,
      clean: false,
      skip_tests: true,
      skip_notarize: true,
      skip_upload: true,
      build_root: File.join(Dir.tmpdir, "willdeep-release-contract")
    )
    release.instance_variable_set(
      :@paths,
      {
        app: app_path,
        dmg_source: dmg_source,
        staged_app: File.join(dmg_source, "WillDeep.app")
      }
    )
    release.instance_variable_set(:@runner, runner)
    release.define_singleton_method(:command_available?) { |command| command == "create-dmg" }
    release.send(:stage_app_for_dmg)

    assert.call(!File.exist?(File.join(dmg_source, "Applications")), "Applications link was pre-created for create-dmg")
  end
end

check.call("Sparkle 更新签名会校验签名片段与真实文件大小") do
  Dir.mktmpdir("willdeep-release-sparkle") do |directory|
    dmg_path = File.join(directory, "WillDeep.dmg")
    sign_update_path = File.join(directory, "sign_update")
    File.write(dmg_path, "signed release payload")
    File.write(sign_update_path, "test executable")
    FileUtils.chmod(0o755, sign_update_path)
    signature = "A" * 86 + "=="

    runner = Object.new
    runner.define_singleton_method(:capture!) do |arguments|
      raise "unexpected sign_update path" unless arguments == [sign_update_path, dmg_path]

      %(sparkle:edSignature="#{signature}" length="#{File.size(dmg_path)}")
    end
    release = WillDeepRelease::Release.new(
      dry_run: true,
      clean: false,
      skip_tests: true,
      skip_notarize: true,
      skip_upload: true,
      skip_update_metadata: true,
      build_root: File.join(Dir.tmpdir, "willdeep-release-contract")
    )
    release.instance_variable_set(:@paths, { dmg: dmg_path, source_packages: directory })
    release.instance_variable_set(:@runner, runner)
    previous = ENV["SPARKLE_SIGN_UPDATE_BIN"]
    ENV["SPARKLE_SIGN_UPDATE_BIN"] = sign_update_path
    release.send(:sign_update_archive)

    assert.call(release.instance_variable_get(:@sparkle_ed_signature) == signature, "signature was not retained")
    assert.call(release.instance_variable_get(:@sparkle_file_size) == File.size(dmg_path), "file size was not retained")
  ensure
    ENV["SPARKLE_SIGN_UPDATE_BIN"] = previous
  end
end

check.call("新版本必须递增 Sparkle bundle version") do
  release = WillDeepRelease::Release.new(
    dry_run: true,
    clean: false,
    skip_tests: true,
    skip_notarize: true,
    skip_upload: true,
    skip_update_metadata: true,
    build_root: File.join(Dir.tmpdir, "willdeep-release-contract")
  )
  current_version = release.instance_variable_get(:@version)
  current_bundle_version = release.instance_variable_get(:@bundle_version)
  release.send(
    :validate_existing_bundle_version!,
    { "latest_version" => current_version, "bundle_version" => current_bundle_version }
  )

  begin
    release.send(
      :validate_existing_bundle_version!,
      { "latest_version" => "0.0.1", "bundle_version" => current_bundle_version }
    )
  rescue WillDeepRelease::ReleaseError
    next
  end
  raise "new user version reused the existing bundle version"
end

ok = results.all? { |result| result[:ok] }
report = {
  ok: ok,
  generated_at: Time.now.utc.iso8601,
  checks: results
}

[markdown_path, json_path].each { |path| FileUtils.mkdir_p(File.dirname(path)) }
File.write(json_path, JSON.pretty_generate(report) + "\n")

markdown = +"# Release macOS App Contract Test\n\n"
markdown << "- Status: #{ok ? 'PASS' : 'FAIL'}\n"
markdown << "- Generated at: #{report[:generated_at]}\n"
markdown << "- Checks: #{results.length}\n\n"
markdown << "| Check | Status | Details |\n"
markdown << "| --- | --- | --- |\n"
results.each do |result|
  details = result[:error].to_s.gsub("|", "\\|")
  markdown << "| #{result[:name]} | #{result[:ok] ? 'PASS' : 'FAIL'} | #{details} |\n"
end
File.write(markdown_path, markdown)

puts "release_mac_app_contract_test: #{ok ? 'pass' : 'fail'} checks=#{results.length}"
results.reject { |result| result[:ok] }.each { |result| warn "- #{result[:name]}: #{result[:error]}" }
exit(ok ? 0 : 1)
