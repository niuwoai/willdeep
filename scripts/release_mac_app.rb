#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "net/http"
require "open3"
require "optparse"
require "shellwords"
require "tmpdir"
require "time"
require "uri"

module WillDeepRelease
  SCRIPT_VERSION = "1.2.0"
  REPO_ROOT = File.expand_path("..", __dir__)
  LOCAL_ENV_PATH = File.join(REPO_ROOT, ".env.local")

  DEFAULT_TEAM_ID = "ZH2S7D6PL6"
  DEFAULT_NOTARY_PROFILE = "veilwriter-notary"
  DEFAULT_BUILD_ROOT = File.join(REPO_ROOT, "build", "mac-releases", "veilwriter")
  DEFAULT_OSS_BUCKET = "sz-trans"
  DEFAULT_OSS_PREFIX = "mac-apps"
  DEFAULT_OSS_PUBLIC_BASE_URL = "https://img.niuwoai.com"
  DEFAULT_CONTROL_PLANE_BASE_URL = "https://some.im/api/v1"
  RELEASE_NOTES_URL = "https://some.im/zh/products/willdeep/changelog"

  PRODUCT_NAME = "WillDeep"
  PROJECT_NAME = "Xedit.xcodeproj"
  SCHEME = "Xedit"
  TEST_BUNDLE = "XeditTests"

  NOTARIZATION_NESTED_CODE_PATHS = [
    "Contents/Resources/willdeep-agent",
    "Contents/Resources/WillDeepComputerUseHelper.app/Contents/MacOS/WillDeepComputerUseHelper",
    "Contents/Resources/WillDeepComputerUseHelper.app"
  ].freeze

  PRESERVED_APP_SIGNATURE_METADATA = "identifier,entitlements,requirements,flags,runtime"

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
    SOMEIM_CONTROL_PLANE_BASE_URL
    SOMEIM_ADMIN_TOKEN
    SPARKLE_SIGN_UPDATE_BIN
  ].freeze

  SENSITIVE_ENV_KEYS = %w[
    WILLDEEP_CLIENT_LOGIN_SECRET
    AIPIPE_API_KEY
    OSS_ACCESS_KEY_ID
    OSS_ACCESS_KEY_SECRET
    OSS_SECURITY_TOKEN
    OSS_STS_TOKEN
    SOMEIM_ADMIN_TOKEN
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

      return publish_existing_artifact_metadata if metadata_only?

      prepare_build_directory
      @identity = resolve_signing_identity!
      run_tests unless @options[:skip_tests]
      archive_and_export
      resign_exported_app_for_notarization
      verify_exported_app
      notarize_and_staple_app unless @options[:skip_notarize]
      stage_app_for_dmg
      create_and_sign_dmg
      notarize_and_staple_dmg unless @options[:skip_notarize]
      sign_update_archive
      upload_to_oss unless @options[:skip_upload]
      publish_update_metadata unless @options[:skip_upload] || @options[:skip_update_metadata]
      write_reports
      print_completion
    rescue ReleaseError => e
      warn "\n❌ Release 失败：#{e.message}"
      warn "日志：#{@paths[:log]}" unless @options[:dry_run]
      exit 1
    end

    private

    def metadata_only?
      !@options[:publish_metadata_only].to_s.empty?
    end

    def publish_existing_artifact_metadata
      validate_existing_release_artifact
      sign_update_archive
      verify_uploaded_version_artifact
      publish_update_metadata
      write_reports
      print_completion
    end

    def apply_environment_defaults!
      @options[:team_id] ||= ENV.fetch("APPLE_TEAM_ID", DEFAULT_TEAM_ID)
      @options[:notary_profile] ||= ENV.fetch("NOTARY_PROFILE", DEFAULT_NOTARY_PROFILE)
      @options[:build_root] ||= File.expand_path(ENV.fetch("MAC_RELEASE_BUILD_ROOT", DEFAULT_BUILD_ROOT))
      @options[:oss_bucket] ||= ENV.fetch("OSS_BUCKET", DEFAULT_OSS_BUCKET)
      @options[:oss_prefix] ||= ENV.fetch("OSS_PREFIX", DEFAULT_OSS_PREFIX)
      @options[:oss_public_base_url] ||= ENV.fetch("OSS_PUBLIC_BASE_URL", DEFAULT_OSS_PUBLIC_BASE_URL)
      @options[:ossutil] ||= ENV.fetch("OSSUTIL_BIN", "ossutil")
      @options[:control_plane_base_url] ||= ENV.fetch("SOMEIM_CONTROL_PLANE_BASE_URL", DEFAULT_CONTROL_PLANE_BASE_URL)
      @version = @options[:release_version] || read_marketing_version
      @bundle_version = @options[:bundle_version] || read_bundle_version
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
        dmg: @options[:publish_metadata_only] || File.join(build_root, artifact),
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

    def read_bundle_version
      pbxproj = File.join(REPO_ROOT, PROJECT_NAME, "project.pbxproj")
      versions = File.read(pbxproj, encoding: "UTF-8")
        .scan(/CURRENT_PROJECT_VERSION = "?([^";\n]+)"?;/)
        .flatten
        .map(&:strip)
        .uniq
      unless versions.length == 1 && versions.first.match?(/\A[1-9]\d*\z/)
        raise ReleaseError, "CURRENT_PROJECT_VERSION 必须在所有 target 中保持一致且为正整数：#{versions.inspect}"
      end

      versions.first.to_i
    end

    def validate_configuration!
      raise ReleaseError, "必须在 macOS 上执行" unless RUBY_PLATFORM.include?("darwin")
      raise ReleaseError, "无效的发布版本：#{@version}" unless @version.match?(SEMVER_PATTERN)
      raise ReleaseError, "Bundle version 必须为正整数" unless @bundle_version.to_i.positive?
      if (@options[:release_version] || @options[:bundle_version]) && !metadata_only?
        raise ReleaseError, "--release-version / --bundle-version 只允许与 --publish-metadata-only 一起使用"
      end
      validate_build_root!
      return validate_metadata_only_configuration! if metadata_only?

      raise ReleaseError, "缺少 .env.local 中的 WILLDEEP_CLIENT_LOGIN_SECRET" if ENV.fetch("WILLDEEP_CLIENT_LOGIN_SECRET", "").strip.empty?
      if @options[:skip_notarize] && !@options[:skip_upload]
        raise ReleaseError, "跳过公证时禁止上传；请同时传入 --skip-upload"
      end
      if !@options[:skip_upload] && !@options[:skip_update_metadata] && ENV.fetch("SOMEIM_ADMIN_TOKEN", "").strip.empty?
        raise ReleaseError, "上传发布时缺少 SOMEIM_ADMIN_TOKEN；如需仅上传产物请显式传入 --skip-update-metadata"
      end

      required_commands = %w[xcodebuild codesign security xcrun ditto hdiutil plutil]
      required_commands << @options[:ossutil] unless @options[:skip_upload]
      missing = required_commands.reject { |command| command_available?(command) }
      raise ReleaseError, "缺少命令：#{missing.join(', ')}" unless missing.empty?
    end

    def validate_metadata_only_configuration!
      raise ReleaseError, "--publish-metadata-only 不能与 --skip-update-metadata 同时使用" if @options[:skip_update_metadata]
      raise ReleaseError, "补发元数据时缺少 SOMEIM_ADMIN_TOKEN" if ENV.fetch("SOMEIM_ADMIN_TOKEN", "").strip.empty?
      raise ReleaseError, "DMG 不存在：#{@paths[:dmg]}" unless File.file?(@paths[:dmg])

      expected_name = "#{PRODUCT_NAME}-#{@version}.dmg"
      unless File.basename(@paths[:dmg]) == expected_name
        raise ReleaseError, "DMG 文件名必须与发布版本一致：期望 #{expected_name}"
      end

      required_commands = ["codesign", "xcrun", "hdiutil", @options[:ossutil]]
      missing = required_commands.reject { |command| command_available?(command) }
      raise ReleaseError, "缺少命令：#{missing.join(', ')}" unless missing.empty?
      raise ReleaseError, "找不到 Sparkle sign_update；请设置 SPARKLE_SIGN_UPDATE_BIN" unless sparkle_sign_update_path
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
        模式：#{metadata_only? ? '校验既有 DMG 并补发 appcast 元数据' : '完整发布'}
        测试：#{metadata_only? || @options[:skip_tests] ? '跳过' : '执行'}
        公证：#{metadata_only? ? '验证既有票据' : (@options[:skip_notarize] ? '跳过' : 'App + DMG')}
        上传：#{metadata_only? ? '验证既有版本对象' : (@options[:skip_upload] ? '跳过' : '版本文件 + latest')}
        更新元数据：#{@options[:skip_update_metadata] || (!metadata_only? && @options[:skip_upload]) ? '跳过' : @options[:control_plane_base_url]}
        Bundle version：#{@bundle_version}
      SUMMARY
    end

    def print_dry_run_plan
      version_key, latest_key = oss_keys
      puts "演练完成：未执行构建、签名、公证、上传或元数据写入。"
      puts "计划产物：#{@paths[:dmg]}"
      puts "版本对象：oss://#{@options[:oss_bucket]}/#{version_key}"
      puts "latest 对象：oss://#{@options[:oss_bucket]}/#{latest_key}" unless metadata_only?
      puts "Sparkle appcast：#{@options[:control_plane_base_url]}/public/app-updates/appcast.xml?app_id=willdeep&platform=macos&channel=stable"
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
            "-derivedDataPath", @paths[:derived_data],
            "-clonedSourcePackagesDirPath", @paths[:source_packages],
            "-allowProvisioningUpdates",
            "CODE_SIGN_STYLE=Automatic",
            "DEVELOPMENT_TEAM=#{@options[:team_id]}",
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
      verify_computer_use_helper_identity
      info_plist = File.join(@paths[:app], "Contents", "Info.plist")
      %w[WillDeepSomeIMClientLoginSecret AIPipeAPIKey].each do |key|
        _stdout, _stderr, status = Open3.capture3(
          "/usr/libexec/PlistBuddy",
          "-c", "Print :#{key}",
          info_plist
        )
        raise ReleaseError, "拒绝发布：#{key} 不应出现在 Info.plist" if status.success?
      end
    end

    def verify_computer_use_helper_identity
      helper_app = File.join(
        @paths[:app],
        "Contents", "Resources", "WillDeepComputerUseHelper.app"
      )
      helper_info = File.join(helper_app, "Contents", "Info.plist")
      bundle_id = @runner.capture!(
        ["/usr/libexec/PlistBuddy", "-c", "Print :CFBundleIdentifier", helper_info]
      ).strip
      unless bundle_id == "com.willdeep.computer-use-helper"
        raise ReleaseError, "拒绝发布：Computer Use Helper Bundle ID 发生变化（#{bundle_id}）"
      end

      signature = @runner.run!(["codesign", "--display", "--verbose=4", helper_app])
      team_identifier = signature[/^TeamIdentifier=(.+)$/, 1]&.strip
      unless team_identifier == @options[:team_id]
        raise ReleaseError,
              "拒绝发布：Computer Use Helper 签名团队不稳定（期望 #{@options[:team_id]}，实际 #{team_identifier || '缺失'}）"
      end
    end

    def resign_exported_app_for_notarization
      NOTARIZATION_NESTED_CODE_PATHS.each do |relative_path|
        path = File.join(@paths[:app], relative_path)
        raise ReleaseError, "发布包缺少需要签名的嵌套代码：#{path}" unless File.exist?(path)

        @runner.run!(distribution_codesign_arguments(path))
      end

      @runner.run!(
        distribution_codesign_arguments(
          @paths[:app],
          preserve_metadata: PRESERVED_APP_SIGNATURE_METADATA
        )
      )
    end

    def distribution_codesign_arguments(path, preserve_metadata: nil)
      arguments = [
        "codesign", "--force", "--sign", @identity,
        "--timestamp", "--options", "runtime"
      ]
      arguments << "--preserve-metadata=#{preserve_metadata}" if preserve_metadata
      arguments << path
      arguments
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
      return if command_available?("create-dmg")

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

    def sign_update_archive
      sign_update = sparkle_sign_update_path
      raise ReleaseError, "找不到 Sparkle sign_update；请先解析 Swift Package 或设置 SPARKLE_SIGN_UPDATE_BIN" unless sign_update

      output = @runner.capture!([sign_update, @paths[:dmg]])
      signature = output[/sparkle:edSignature="([^"]+)"/, 1]
      length = output[/\blength="(\d+)"/, 1]
      unless signature && length && Integer(length, exception: false) == File.size(@paths[:dmg])
        raise ReleaseError, "无法解析 Sparkle 更新签名：#{output.strip}"
      end

      @sparkle_ed_signature = signature
      @sparkle_file_size = length.to_i
    end

    def validate_existing_release_artifact
      measure(:artifact_validation) do
        @runner.run!(["codesign", "--verify", "--verbose=2", @paths[:dmg]])
        @runner.run!(["xcrun", "stapler", "validate", @paths[:dmg]])
        @runner.run!(["hdiutil", "verify", @paths[:dmg]])
      end
    end

    def verify_uploaded_version_artifact
      version_key, = oss_keys
      destination = "oss://#{@options[:oss_bucket]}/#{version_key}"
      measure(:remote_artifact_validation) do
        @runner.run!([@options[:ossutil], "stat", destination], allowed_secret_keys: OSS_SECRET_KEYS)
      end
    end

    def sparkle_sign_update_path
      candidates = [
        ENV.fetch("SPARKLE_SIGN_UPDATE_BIN", "").strip,
        File.join(@paths[:source_packages], "artifacts", "sparkle", "Sparkle", "bin", "sign_update"),
        File.join(REPO_ROOT, "build", "SourcePackages", "artifacts", "sparkle", "Sparkle", "bin", "sign_update")
      ].reject(&:empty?)
      candidates.find { |path| File.executable?(path) }
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

    def publish_update_metadata
      raise ReleaseError, "Sparkle 签名尚未生成" if @sparkle_ed_signature.to_s.empty?

      version_key, = oss_keys
      payload = {
        app_id: "willdeep",
        app_name: PRODUCT_NAME,
        platform: "macos",
        channel: "stable",
        latest_version: @version,
        bundle_version: @bundle_version,
        minimum_version: "",
        minimum_system_version: "13.7",
        download_url: public_url(version_key),
        release_notes_url: RELEASE_NOTES_URL,
        release_notes: release_notes_for_current_version,
        sha256: Digest::SHA256.file(@paths[:dmg]).hexdigest,
        ed_signature: @sparkle_ed_signature,
        file_size_bytes: @sparkle_file_size,
        enabled: true,
        # MySQL TIMESTAMP accepts this database-native form consistently;
        # RFC 3339 (`T...Z`) caused production inserts to fail.
        published_at: database_timestamp
      }
      existing = fetch_update_channel
      validate_existing_bundle_version!(existing) if existing
      path = existing ? "/admin/app-updates/#{URI.encode_www_form_component(existing.fetch('id'))}" : "/admin/app-updates"
      request = existing ? Net::HTTP::Patch.new(update_metadata_uri(path)) : Net::HTTP::Post.new(update_metadata_uri(path))
      request["Authorization"] = "Bearer #{ENV.fetch('SOMEIM_ADMIN_TOKEN')}"
      request["Content-Type"] = "application/json"
      request.body = JSON.generate(payload)
      response = perform_update_metadata_request(request)
      raise ReleaseError, "更新元数据发布失败：HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      @update_metadata_published = true
    end

    def fetch_update_channel
      query = URI.encode_www_form(app_id: "willdeep", platform: "macos", channel: "stable")
      request = Net::HTTP::Get.new(update_metadata_uri("/admin/app-updates?#{query}"))
      request["Authorization"] = "Bearer #{ENV.fetch('SOMEIM_ADMIN_TOKEN')}"
      response = perform_update_metadata_request(request)
      raise ReleaseError, "读取更新元数据失败：HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      decoded = JSON.parse(response.body)
      items = decoded.dig("data", "items") || decoded["items"] || []
      items.find do |item|
        item["app_id"] == "willdeep" && item["platform"] == "macos" && item["channel"] == "stable"
      end
    rescue JSON::ParserError
      raise ReleaseError, "无法解析更新元数据响应"
    end

    def validate_existing_bundle_version!(existing)
      existing_bundle_version = Integer(existing["bundle_version"], exception: false)
      return unless existing_bundle_version
      if @bundle_version < existing_bundle_version ||
          (existing["latest_version"] != @version && @bundle_version == existing_bundle_version)
        raise ReleaseError,
              "Bundle version #{@bundle_version} 必须大于已发布版本 #{existing_bundle_version}；请先递增 CURRENT_PROJECT_VERSION"
      end
    end

    def update_metadata_uri(path)
      base = @options[:control_plane_base_url].to_s.sub(%r{/+\z}, "")
      URI.parse("#{base}#{path}")
    rescue URI::InvalidURIError
      raise ReleaseError, "无效的 SOMEIM_CONTROL_PLANE_BASE_URL：#{@options[:control_plane_base_url]}"
    end

    def perform_update_metadata_request(request)
      uri = request.uri
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 10, read_timeout: 30) do |http|
        http.request(request)
      end
    rescue StandardError => e
      raise ReleaseError, "更新元数据请求失败：#{e.class}"
    end

    def release_notes_for_current_version
      changelog = File.read(File.join(REPO_ROOT, "CHANGELOG.md"), encoding: "UTF-8")
      section = changelog[/^## #{Regexp.escape(@version)}\b.*?\n(.*?)(?=^## |\z)/m, 1].to_s.strip
      return "WillDeep #{@version}" if section.empty?

      sections = section.scan(/^###\s+(.+?)\s*$\n(.*?)(?=^###\s+|\z)/m).to_h
      curated = sections["用户可见变化"] || sections["Highlights"]
      return "### 更新亮点\n\n#{curated.strip}"[0, 8_000] if curated && !curated.strip.empty?

      user_facing_labels = {
        "Added" => "新功能",
        "Changed" => "体验改进",
        "Fixed" => "问题修复",
        "Security" => "安全更新",
        "Removed" => "功能调整",
        "Deprecated" => "功能调整"
      }
      notes = user_facing_labels.filter_map do |source, label|
        body = sections[source].to_s.strip
        next if body.empty?

        "### #{label}\n\n#{body}"
      end.join("\n\n")
      notes.empty? ? "WillDeep #{@version}" : notes[0, 8_000]
    end

    def database_timestamp(time = Time.now.utc)
      time.utc.strftime("%Y-%m-%d %H:%M:%S")
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
        mode: metadata_only? ? "metadata-only" : "full-release",
        script_version: SCRIPT_VERSION,
        app: PRODUCT_NAME,
        version: @version,
        bundle_version: @bundle_version,
        generated_at: Time.now.iso8601,
        dmg_path: @paths[:dmg],
        dmg_sha256: Digest::SHA256.file(@paths[:dmg]).hexdigest,
        sparkle_ed_signature: @sparkle_ed_signature,
        sparkle_file_size_bytes: @sparkle_file_size,
        notarized: metadata_only? || !@options[:skip_notarize],
        submission_ids: @submission_ids,
        uploaded: metadata_only? || !@options[:skip_upload],
        update_metadata_published: !!@update_metadata_published,
        download_url: (!metadata_only? && @options[:skip_upload]) ? nil : public_url(version_key),
        latest_url: metadata_only? || @options[:skip_upload] ? nil : public_url(latest_key),
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
        - Mode: #{report[:mode]}
        - Version: #{report[:version]}
        - Bundle version: #{report[:bundle_version]}
        - DMG: `#{report[:dmg_path]}`
        - SHA-256: `#{report[:dmg_sha256]}`
        - Sparkle Ed25519 signature: `#{report[:sparkle_ed_signature]}`
        - App and DMG notarized: #{report[:notarized]}
        - Uploaded to OSS: #{report[:uploaded]}
        - Update metadata published: #{report[:update_metadata_published]}
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
        Sparkle Ed25519：#{@sparkle_ed_signature}
        版本下载：#{(!metadata_only? && @options[:skip_upload]) ? '未上传' : public_url(version_key)}
        latest：#{metadata_only? || @options[:skip_upload] ? '未变更' : public_url(latest_key)}
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
        skip_upload: false,
        skip_update_metadata: false
      }

      parser = OptionParser.new do |opts|
        opts.banner = "Usage: ruby scripts/release_mac_app.rb [options]"
        opts.on("--dry-run", "只校验配置并展示计划") { options[:dry_run] = true }
        opts.on("--clean", "删除缓存并完整重建") { options[:clean] = true }
        opts.on("--skip-tests", "跳过 XeditTests") { options[:skip_tests] = true }
        opts.on("--skip-notarize", "跳过 App/DMG 公证，仅供本地验证") { options[:skip_notarize] = true }
        opts.on("--skip-upload", "不上传 OSS") { options[:skip_upload] = true }
        opts.on("--skip-update-metadata", "不把 Sparkle 更新元数据发布到 some.im") { options[:skip_update_metadata] = true }
        opts.on("--publish-metadata-only PATH", "校验已公证并上传的 DMG，只补发 appcast 元数据") do |value|
          options[:publish_metadata_only] = File.expand_path(value)
        end
        opts.on("--release-version VERSION", "补发元数据时指定 DMG 的语义版本") { |value| options[:release_version] = value }
        opts.on("--bundle-version NUMBER", Integer, "补发元数据时指定严格递增的构建号") do |value|
          options[:bundle_version] = value
        end
        opts.on("--build-root PATH", "指定构建目录") { |value| options[:build_root] = File.expand_path(value) }
        opts.on("--notary-profile NAME", "指定 notarytool Keychain profile") { |value| options[:notary_profile] = value }
        opts.on("--team-id ID", "指定 Apple Developer Team ID") { |value| options[:team_id] = value }
        opts.on("--oss-bucket NAME", "指定 OSS bucket") { |value| options[:oss_bucket] = value }
        opts.on("--oss-prefix PREFIX", "指定 OSS 对象前缀") { |value| options[:oss_prefix] = value }
        opts.on("--oss-public-base-url URL", "指定公开下载域名") { |value| options[:oss_public_base_url] = value }
        opts.on("--ossutil PATH", "指定 ossutil 可执行文件") { |value| options[:ossutil] = value }
        opts.on("--control-plane-base-url URL", "指定 some.im 管理 API 根地址") { |value| options[:control_plane_base_url] = value }
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
