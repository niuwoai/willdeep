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
  options = WillDeepRelease::CLI.parse(%w[--dry-run --skip-tests --skip-notarize --skip-upload])
  assert.call(options.values_at(:dry_run, :skip_tests, :skip_notarize, :skip_upload).all?, "CLI flags were not parsed")
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
