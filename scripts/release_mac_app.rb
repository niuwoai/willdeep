#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "optparse"
require "shellwords"
require "tmpdir"
require "time"

module WillDeepRelease
  SCRIPT_VERSION = "1.0.0"
  REPO_ROOT = File.expand_path("..", __dir__)
  LOCAL_ENV_PATH = File.join(REPO_ROOT, ".env.local")

  DEFAULT_TEAM_ID = "ZH2S7D6PL6"
  DEFAULT_NOTARY_PROFILE = "veilwriter-notary"
  DEFAULT_BUILD_ROOT = File.join(REPO_ROOT, "build", "mac-releases", "veilwriter")
  DEFAULT_OSS_BUCKET = "sz-trans"
  DEFAULT_OSS_PREFIX = "mac-apps"
  DEFAULT_OSS_PUBLIC_BASE_URL = "https://img.niuwoai.com"

  PRODUCT_NAME = "WillDeep"
  PROJECT_NAME = "Xedit.xcodeproj"
  SCHEME = "Xedit"
  TEST_BUNDLE = "XeditTests"

  DOTENV_KEYS = %w[
    WILLDEEP_CLIENT_LOGIN_SECRET
    AIPIPE_API_KEY
    AIPIPE_ENDPOINT
    AIPIPE_TOPIC
    APPLE_TEAM_ID
    DEVELOPER_ID_APPLICATION
    NOTARY_PROFILE
    MAC_RELEASE_BUILD_ROOT
    OSSUTIL_BIN
    OSSUTIL_CONFIG
    OSS_ACCESS_KEY_ID
    OSS_ACCESS_KEY_SECRET
    OSS_SECURITY_TOKEN
    OSS_STS_TOKEN
    OSS_ENDPOINT
    OSS_REGION
    OSS_BUCKET
    OSS_PREFIX
    OSS_PUBLIC_BASE_URL
  ].freeze

  SENSITIVE_ENV_KEYS = %w[
    WILLDEEP_CLIENT_LOGIN_SECRET
    AIPIPE_API_KEY
    OSS_ACCESS_KEY_ID
    OSS_ACCESS_KEY_SECRET
    OSS_SECURITY_TOKEN
    OSS_STS_TOKEN
  ].freeze

  BUILD_SECRET_KEYS = %w[
    WILLDEEP_CLIENT_LOGIN_SECRET
    AIPIPE_API_KEY
  ].freeze

  OSS_SECRET_KEYS = %w[
    OSS_ACCESS_KEY_ID
    OSS_ACCESS_KEY_SECRET
    OSS_SECURITY_TOKEN
    OSS_STS_TOKEN
  ].freeze

  SEMVER_PATTERN = /\A\d+\.\d+\.\d+(?:-rc\d+)?\z/

  class ReleaseError < StandardError; end

  module Dotenv
    module_function

    def load(path, allowed_keys:, environment: ENV)
      return [] unless File.file?(path)

      allowed = allowed_keys.to_h { |key| [key, true] }
      loaded = []

      File.readlines(path, chomp: true).each do |line|
        stripped = line.strip
        next if stripped.empty? || stripped.start_with?("#")

        assignment = stripped.sub(/\Aexport\s+/, "")
        key, raw_value = assignment.split("=", 2)
        key = key.to_s.strip
        next unless allowed[key] && raw_value
        next unless environment.fetch(key, "").to_s.empty?

        environment[key] = unquote(raw_value)
        loaded << key
      end

      loaded
    end

    def unquote(value)
      raw = value.to_s.strip
      return raw if raw.length < 2
      return raw unless %w[" '].include?(raw[0]) && raw[-1] == raw[0]

      raw[1...-1]
    end
  end

  class CommandRunner
    def initialize(log_path:, dry_run: false)
      @log_path = log_path
      @dry_run = dry_run
    end

    def run!(argv, allow_failure: false, allowed_secret_keys: [])
      display = "$ #{argv.shelljoin}"
      puts display
      return "" if @dry_run

      FileUtils.mkdir_p(File.dirname(@log_path))
      output_text = +""
      status = nil

      File.open(@log_path, "a") do |log|
        log.puts
        log.puts(display)
        Open3.popen2e(child_environment(allowed_secret_keys), *argv) do |_stdin, output, wait_thread|
          output.each_line do |line|
            safe_line = redact(line)
            output_text << safe_line
            print safe_line
            log.print safe_line
          end
          status = wait_thread.value
        end
      end

      return output_text if status&.success? || allow_failure

      raise ReleaseError, "命令执行失败：#{argv.first}；详见 #{@log_path}"
    rescue Errno::ENOENT
      raise ReleaseError, "找不到命令：#{argv.first}"
    end

    def capture!(argv, allowed_secret_keys: [])
      return "" if @dry_run

      stdout, stderr, status = Open3.capture3(child_environment(allowed_secret_keys), *argv)
      return stdout if status.success?

      raise ReleaseError, "命令执行失败：#{argv.shelljoin}\n#{redact(stderr)}"
    rescue Errno::ENOENT
      raise ReleaseError, "找不到命令：#{argv.first}"
    end

    def redact(text)
      safe = text.to_s.dup
      SENSITIVE_ENV_KEYS.each do |key|
        value = ENV.fetch(key, "").to_s
        safe.gsub!(value, "[REDACTED:#{key}]") unless value.empty?
      end
      safe
    end

    private

    def child_environment(allowed_secret_keys)
      allowed = allowed_secret_keys.to_h { |key| [key, true] }
      ENV.to_h.tap do |environment|
        SENSITIVE_ENV_KEYS.each do |key|
          environment.delete(key) unless allowed[key]
        end
      end
    end
  end

  class Release
    def initialize(options)
      @options = options
      @loaded_env_keys = Dotenv.load(LOCAL_ENV_PATH, allowed_keys: DOTENV_KEYS)
      apply_environment_defaults!
      @paths = release_paths
      @runner = CommandRunner.new(log_path: @paths[:log], dry_run: @options[:dry_run])
      @timings = {}
      @submission_ids = {}
      @started_at = Time.now
    end

    def call
      validate_configuration!
      print_summary
      return print_dry_run_plan if @options[:dry_run]

      prepare_build_directory
      @identity = resolve_signing_identity!
      run_tests unless @options[:skip_tests]
      archive_and_export
      verify_exported_app
      notarize_and_staple_app unless @options[:skip_notarize]
      stage_app_for_dmg
      create_and_sign_dmg
      notarize_and_staple_dmg unless @options[:skip_notarize]
      upload_to_oss unless @options[:skip_upload]
      write_reports
      print_completion
    rescue ReleaseError => e
      warn "\n❌ Release 失败：#{e.message}"
      warn "日志：#{@paths[:log]}" unless @options[:dry_run]
      exit 1
    end

    private

    def apply_environment_defaults!
      @options[:team_id] ||= ENV.fetch("APPLE_TEAM_ID", DEFAULT_TEAM_ID)
      @options[:notary_profile] ||= ENV.fetch("NOTARY_PROFILE", DEFAULT_NOTARY_PROFILE)
      @options[:build_root] ||= File.expand_path(ENV.fetch("MAC_RELEASE_BUILD_ROOT", DEFAULT_BUILD_ROOT))
      @options[:oss_bucket] ||= ENV.fetch("OSS_BUCKET", DEFAULT_OSS_BUCKET)
      @options[:oss_prefix] ||= ENV.fetch("OSS_PREFIX", DEFAULT_OSS_PREFIX)
      @options[:oss_public_base_url] ||= ENV.fetch("OSS_PUBLIC_BASE_URL", DEFAULT_OSS_PUBLIC_BASE_URL)
      @options[:ossutil] ||= ENV.fetch("OSSUTIL_BIN", "ossutil")
      @version = read_marketing_version
    end

    def release_paths
      build_root = @options.fetch(:build_root)
      artifact = "#{PRODUCT_NAME}-#{@version}.dmg"
      {
        build_root: build_root,
        archive: File.join(build_root, "#{PRODUCT_NAME}.xcarchive"),
        export_dir: File.join(build_root, "export"),
        export_options: File.join(build_root, "ExportOptions.plist"),
        app: File.join(build_root, "export", "#{PRODUCT_NAME}.app"),
        notarize_zip: File.join(build_root, "#{PRODUCT_NAME}.app.notarize.zip"),
        dmg_source: File.join(build_root, "dmg-src"),
        staged_app: File.join(build_root, "dmg-src", "#{PRODUCT_NAME}.app"),
        dmg: File.join(build_root, artifact),
        derived_data: File.join(build_root, "DerivedData"),
        source_packages: File.join(build_root, "SourcePackages"),
        test_result: File.join(build_root, "test-results.xcresult"),
        log: File.join(build_root, "release.log"),
        report_json: File.join(build_root, "release-report.json"),
        report_markdown: File.join(build_root, "release-report.md")
      }
    end

    def read_marketing_version
      pbxproj = File.join(REPO_ROOT, PROJECT_NAME, "project.pbxproj")
      content = File.read(pbxproj, encoding: "UTF-8")
      version = content[/MARKETING_VERSION = "?([^";\n]+)"?;/, 1].to_s.strip
      raise ReleaseError, "无法从 #{pbxproj} 读取 MARKETING_VERSION" unless version.match?(SEMVER_PATTERN)

      version
    end

    def validate_configuration!
      raise ReleaseError, "必须在 macOS 上执行" unless RUBY_PLATFORM.include?("darwin")
      raise ReleaseError, "缺少 .env.local 中的 WILLDEEP_CLIENT_LOGIN_SECRET" if ENV.fetch("WILLDEEP_CLIENT_LOGIN_SECRET", "").strip.empty?
      validate_build_root!
      if @options[:skip_notarize] && !@options[:skip_upload]
        raise ReleaseError, "跳过公证时禁止上传；请同时传入 --skip-upload"
      end

      required_commands = %w[xcodebuild codesign security xcrun ditto hdiutil plutil]
      required_commands << @options[:ossutil] unless @options[:skip_upload]
      missing = required_commands.reject { |command| command_available?(command) }
      raise ReleaseError, "缺少命令：#{missing.join(', ')}" unless missing.empty?
    end

    def validate_build_root!
      build_root = File.expand_path(@paths[:build_root])
      safe_prefixes = [
        "#{File.join(REPO_ROOT, 'build')}#{File::SEPARATOR}",
        "#{File.expand_path(Dir.tmpdir)}#{File::SEPARATOR}"
      ]
      return if safe_prefixes.any? { |prefix| build_root.start_with?(prefix) }

      raise ReleaseError, "构建目录必须位于 #{File.join(REPO_ROOT, 'build')} 或 #{Dir.tmpdir} 下：#{build_root}"
    end

    def command_available?(command)
      return File.executable?(command) if command.include?(File::SEPARATOR)

      system("which", command, out: File::NULL, err: File::NULL)
    end

    def print_summary
      loaded_names = @loaded_env_keys.empty? ? "无（使用当前进程环境）" : @loaded_env_keys.join(", ")
      puts <<~SUMMARY

        == WillDeep v#{@version} Release ==
        脚本版本：#{SCRIPT_VERSION}
        环境文件：#{LOCAL_ENV_PATH}
        已加载键：#{loaded_names}
        构建目录：#{@paths[:build_root]}
        公证配置：#{@options[:notary_profile]}
        OSS 目标：oss://#{@options[:oss_bucket]}/#{@options[:oss_prefix]}
        测试：#{@options[:skip_tests] ? '跳过' : '执行'}
        公证：#{@options[:skip_notarize] ? '跳过' : 'App + DMG'}
        上传：#{@options[:skip_upload] ? '跳过' : '版本文件 + latest'}
      SUMMARY
    end

    def print_dry_run_plan
      version_key, latest_key = oss_keys
      puts "演练完成：未执行构建、签名、公证或上传。"
      puts "计划产物：#{@paths[:dmg]}"
      puts "版本对象：oss://#{@options[:oss_bucket]}/#{version_key}"
      puts "latest 对象：oss://#{@options[:oss_bucket]}/#{latest_key}"
    end

    def prepare_build_directory
      if @options[:clean]
        FileUtils.rm_rf(@paths[:build_root])
      else
        %i[archive export_dir notarize_zip dmg_source dmg test_result log report_json report_markdown].each do |key|
          path = @paths.fetch(key)
          File.directory?(path) ? FileUtils.rm_rf(path) : FileUtils.rm_f(path)
        end
      end
      FileUtils.mkdir_p(@paths[:build_root])
    end

    def resolve_signing_identity!
      configured = ENV.fetch("DEVELOPER_ID_APPLICATION", "").strip
      output = @runner.capture!(["security", "find-identity", "-v", "-p", "codesigning"])
      candidates = output.lines.filter_map do |line|
        match = line.match(/\A\s*\d+\)\s+([A-Fa-f0-9]+)\s+"(Developer ID Application:[^"]+)"/)
        next unless match
        next unless match[2].include?("(#{@options[:team_id]})")
        next unless configured.empty? || match[2] == configured || match[1].casecmp?(configured)

        { hash: match[1], name: match[2] }
      end
      raise ReleaseError, "钥匙串中找不到 Team #{@options[:team_id]} 的 Developer ID Application 证书" if candidates.empty?
      raise ReleaseError, "找到多个匹配的 Developer ID 证书，请通过 DEVELOPER_ID_APPLICATION 精确指定" if candidates.length > 1

      puts "签名身份：#{candidates.first[:name]}"
      candidates.first[:hash]
    end

    def run_tests
      measure(:tests) do
        @runner.run!(
          [
            "ruby", File.join(REPO_ROOT, "scripts", "project_build_guard.rb"),
            "--workspace", REPO_ROOT,
            "--name", "willdeep-release-tests",
            "--kind", "xcode-test",
            "--artifact", @paths[:test_result],
            "--replace-artifacts",
            "--",
            "xcodebuild", "test",
            "-project", File.join(REPO_ROOT, PROJECT_NAME),
            "-scheme", SCHEME,
            "-destination", "platform=macOS",
            "-only-testing:#{TEST_BUNDLE}",
            "-resultBundlePath", @paths[:test_result]
          ],
          allowed_secret_keys: BUILD_SECRET_KEYS
        )
      end
    end

    def archive_and_export
      write_export_options
      measure(:build) do
        @runner.run!(
          [
            "ruby", File.join(REPO_ROOT, "scripts", "project_build_guard.rb"),
            "--workspace", REPO_ROOT,
            "--name", "willdeep-release-archive",
            "--kind", "xcode-archive",
            "--artifact", @paths[:archive],
            "--replace-artifacts",
            "--",
            "xcodebuild",
            "-project", File.join(REPO_ROOT, PROJECT_NAME),
            "-scheme", SCHEME,
            "-configuration", "Release",
            "-destination", "generic/platform=macOS",
            "-archivePath", @paths[:archive],
            "-derivedDataPath", @paths[:derived_data],
            "-clonedSourcePackagesDirPath", @paths[:source_packages],
            "-allowProvisioningUpdates",
            "CODE_SIGN_STYLE=Automatic",
            "DEVELOPMENT_TEAM=#{@options[:team_id]}",
            "archive"
          ],
          allowed_secret_keys: BUILD_SECRET_KEYS
        )

        @runner.run!(
          [
            "xcodebuild", "-exportArchive",
            "-archivePath", @paths[:archive],
            "-exportPath", @paths[:export_dir],
            "-exportOptionsPlist", @paths[:export_options],
            "-allowProvisioningUpdates"
          ],
          allowed_secret_keys: BUILD_SECRET_KEYS
        )
      end

      raise ReleaseError, "导出的 App 不存在：#{@paths[:app]}" unless File.directory?(@paths[:app])
    end

    def write_export_options
      content = <<~PLIST
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>method</key><string>developer-id</string>
          <key>teamID</key><string>#{@options[:team_id]}</string>
          <key>signingStyle</key><string>automatic</string>
        </dict>
        </plist>
      PLIST
      File.write(@paths[:export_options], content)
    end

    def verify_exported_app
      @runner.run!(["codesign", "--verify", "--deep", "--strict", "--verbose=4", @paths[:app]])
      _stdout, _stderr, status = Open3.capture3(
        "/usr/libexec/PlistBuddy",
        "-c", "Print :WillDeepSomeIMClientLoginSecret",
        File.join(@paths[:app], "Contents", "Info.plist")
      )
      if status.success?
        raise ReleaseError, "拒绝发布：WillDeepSomeIMClientLoginSecret 不应出现在 Info.plist"
      end
    end

    def notarize_and_staple_app
      measure(:app_notarization) do
        @runner.run!(["ditto", "-c", "-k", "--keepParent", @paths[:app], @paths[:notarize_zip]])
        submit_for_notarization(@paths[:notarize_zip], "App")
        @runner.run!(["xcrun", "stapler", "staple", @paths[:app]])
        @runner.run!(["xcrun", "stapler", "validate", @paths[:app]])
        @runner.run!(["spctl", "--assess", "--type", "execute", "--verbose=4", @paths[:app]], allow_failure: true)
        FileUtils.rm_f(@paths[:notarize_zip])
      end
    end

    def stage_app_for_dmg
      FileUtils.rm_rf(@paths[:dmg_source])
      FileUtils.mkdir_p(@paths[:dmg_source])
      @runner.run!(["ditto", @paths[:app], @paths[:staged_app]])
      FileUtils.ln_s("/Applications", File.join(@paths[:dmg_source], "Applications"))
    end

    def create_and_sign_dmg
      measure(:dmg_build) do
        if command_available?("create-dmg")
          @runner.run!(
            [
              "create-dmg",
              "--volname", PRODUCT_NAME,
              "--window-pos", "200", "120",
              "--window-size", "600", "400",
              "--icon-size", "100",
              "--icon", "#{PRODUCT_NAME}.app", "150", "180",
              "--app-drop-link", "450", "180",
              "--no-internet-enable",
              @paths[:dmg], @paths[:dmg_source]
            ]
          )
        else
          @runner.run!(
            [
              "hdiutil", "create",
              "-volname", PRODUCT_NAME,
              "-srcfolder", @paths[:dmg_source],
              "-ov", "-format", "UDZO",
              @paths[:dmg]
            ]
          )
        end

        @runner.run!(["codesign", "--force", "--sign", @identity, "--timestamp", @paths[:dmg]])
        @runner.run!(["codesign", "--verify", "--verbose=2", @paths[:dmg]])
        @runner.run!(["hdiutil", "verify", @paths[:dmg]])
      end
    end

    def notarize_and_staple_dmg
      measure(:dmg_notarization) do
        submit_for_notarization(@paths[:dmg], "DMG")
        @runner.run!(["xcrun", "stapler", "staple", @paths[:dmg]])
        @runner.run!(["xcrun", "stapler", "validate", @paths[:dmg]])
        @runner.run!(["hdiutil", "verify", @paths[:dmg]])
        @runner.run!(
          ["spctl", "--assess", "--type", "open", "--context", "context:primary-signature", "--verbose=4", @paths[:dmg]],
          allow_failure: true
        )
      end
    end

    def submit_for_notarization(path, label)
      output = @runner.run!(
        [
          "xcrun", "notarytool", "submit", path,
          "--keychain-profile", @options[:notary_profile],
          "--wait", "--output-format", "json"
        ]
      )
      result = JSON.parse(output)
      status = result.fetch("status", "Unknown")
      submission_id = result.fetch("id", result.fetch("submissionId", "unknown"))
      @submission_ids[label.downcase] = submission_id
      puts "#{label} 公证：#{status}（#{submission_id}）"
      return if status == "Accepted"

      @runner.run!(
        ["xcrun", "notarytool", "log", submission_id, "--keychain-profile", @options[:notary_profile]],
        allow_failure: true
      )
      raise ReleaseError, "#{label} 公证未通过：#{status}；Submission ID=#{submission_id}"
    rescue JSON::ParserError
      raise ReleaseError, "无法解析 #{label} 公证结果；详见 #{@paths[:log]}"
    end

    def upload_to_oss
      raise ReleaseError, "DMG 不存在：#{@paths[:dmg]}" unless File.file?(@paths[:dmg])

      measure(:upload) do
        oss_keys.each do |key|
          destination = "oss://#{@options[:oss_bucket]}/#{key}"
          @runner.run!(
            [
              @options[:ossutil], "cp", @paths[:dmg], destination,
              "-f",
              "--content-type", "application/x-apple-diskimage",
              "--no-progress"
            ],
            allowed_secret_keys: OSS_SECRET_KEYS
          )
          @runner.run!([@options[:ossutil], "stat", destination], allowed_secret_keys: OSS_SECRET_KEYS)
        end
      end
    end

    def oss_keys
      prefix = @options[:oss_prefix].to_s.gsub(%r{\A/+|/+$}, "")
      version_key = File.join(prefix, File.basename(@paths[:dmg]))
      latest_key = File.join(prefix, "latest", "#{PRODUCT_NAME}.dmg")
      [version_key, latest_key]
    end

    def public_url(key)
      base = @options[:oss_public_base_url].to_s.sub(%r{/+\z}, "")
      return "oss://#{@options[:oss_bucket]}/#{key}" if base.empty?

      "#{base}/#{key}"
    end

    def measure(key)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      yield
      @timings[key] = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    end

    def write_reports
      version_key, latest_key = oss_keys
      report = {
        ok: true,
        script_version: SCRIPT_VERSION,
        app: PRODUCT_NAME,
        version: @version,
        generated_at: Time.now.iso8601,
        dmg_path: @paths[:dmg],
        dmg_sha256: Digest::SHA256.file(@paths[:dmg]).hexdigest,
        notarized: !@options[:skip_notarize],
        submission_ids: @submission_ids,
        uploaded: !@options[:skip_upload],
        download_url: @options[:skip_upload] ? nil : public_url(version_key),
        latest_url: @options[:skip_upload] ? nil : public_url(latest_key),
        timings_seconds: @timings.transform_values { |seconds| seconds.round(2) }
      }
      File.write(@paths[:report_json], JSON.pretty_generate(report) + "\n")
      File.write(@paths[:report_markdown], markdown_report(report))
    end

    def markdown_report(report)
      <<~MARKDOWN
        # WillDeep macOS Release Report

        - Status: PASS
        - Generated at: #{report[:generated_at]}
        - Version: #{report[:version]}
        - DMG: `#{report[:dmg_path]}`
        - SHA-256: `#{report[:dmg_sha256]}`
        - App and DMG notarized: #{report[:notarized]}
        - Uploaded to OSS: #{report[:uploaded]}
        - Version URL: #{report[:download_url] || "skipped"}
        - Latest URL: #{report[:latest_url] || "skipped"}

        ## Timings

        | Phase | Seconds |
        | --- | ---: |
        #{report[:timings_seconds].map { |phase, seconds| "| #{phase} | #{seconds} |" }.join("\n")}
      MARKDOWN
    end

    def print_completion
      version_key, latest_key = oss_keys
      elapsed = Time.now - @started_at
      puts <<~SUMMARY

        ✅ WillDeep v#{@version} 发布完成
        DMG：#{@paths[:dmg]}
        SHA-256：#{Digest::SHA256.file(@paths[:dmg]).hexdigest}
        版本下载：#{@options[:skip_upload] ? '未上传' : public_url(version_key)}
        latest：#{@options[:skip_upload] ? '未上传' : public_url(latest_key)}
        总耗时：#{elapsed.round(1)} 秒
        报告：#{@paths[:report_markdown]}
      SUMMARY
    end
  end

  module CLI
    module_function

    def parse(argv)
      options = {
        dry_run: false,
        clean: false,
        skip_tests: false,
        skip_notarize: false,
        skip_upload: false
      }

      parser = OptionParser.new do |opts|
        opts.banner = "Usage: ruby scripts/release_mac_app.rb [options]"
        opts.on("--dry-run", "只校验配置并展示计划") { options[:dry_run] = true }
        opts.on("--clean", "删除缓存并完整重建") { options[:clean] = true }
        opts.on("--skip-tests", "跳过 XeditTests") { options[:skip_tests] = true }
        opts.on("--skip-notarize", "跳过 App/DMG 公证，仅供本地验证") { options[:skip_notarize] = true }
        opts.on("--skip-upload", "不上传 OSS") { options[:skip_upload] = true }
        opts.on("--build-root PATH", "指定构建目录") { |value| options[:build_root] = File.expand_path(value) }
        opts.on("--notary-profile NAME", "指定 notarytool Keychain profile") { |value| options[:notary_profile] = value }
        opts.on("--team-id ID", "指定 Apple Developer Team ID") { |value| options[:team_id] = value }
        opts.on("--oss-bucket NAME", "指定 OSS bucket") { |value| options[:oss_bucket] = value }
        opts.on("--oss-prefix PREFIX", "指定 OSS 对象前缀") { |value| options[:oss_prefix] = value }
        opts.on("--oss-public-base-url URL", "指定公开下载域名") { |value| options[:oss_public_base_url] = value }
        opts.on("--ossutil PATH", "指定 ossutil 可执行文件") { |value| options[:ossutil] = value }
      end
      parser.parse!(argv)
      options
    end
  end
end

if $PROGRAM_NAME == __FILE__
  options = WillDeepRelease::CLI.parse(ARGV)
  WillDeepRelease::Release.new(options).call
end
