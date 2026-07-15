#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "optparse"
require "shellwords"
require "tmpdir"

module WillDeepDevInstall
  SECRET_KEY = "WILLDEEP_CLIENT_LOGIN_SECRET"
  DEFAULT_TEAM_ID = "ZH2S7D6PL6"
  DEFAULT_APPLICATIONS_DIR = "/Applications"

  class InstallError < StandardError; end

  module_function

  def unquote_dotenv_value(raw)
    value = raw.to_s.strip
    return value if value.length < 2

    quote = value[0]
    return value unless ["\"", "'"].include?(quote) && value[-1] == quote

    quote == "\"" ? JSON.parse(value) : value[1...-1]
  rescue JSON::ParserError
    raise InstallError, "#{SECRET_KEY} in .env.local has invalid quoting"
  end

  def load_secret!(path)
    raise InstallError, "missing #{path}; create it with #{SECRET_KEY}=..." unless File.file?(path)

    secret = nil
    File.readlines(path, chomp: true).each do |line|
      stripped = line.strip
      next if stripped.empty? || stripped.start_with?("#")

      assignment = stripped.sub(/\Aexport\s+/, "")
      key, raw_value = assignment.split("=", 2)
      next unless key&.strip == SECRET_KEY && raw_value

      secret = unquote_dotenv_value(raw_value)
    end

    raise InstallError, "#{SECRET_KEY} is missing or empty in #{path}" if secret.to_s.strip.empty?

    warn "WARN: #{path} is readable by group or others" unless (File.stat(path).mode & 0o077).zero?
    secret
  end

  def run!(argv)
    root = File.expand_path(__dir__)
    options = parse_options(argv, root)
    env_path = File.join(root, ".env.local")
    project_path = File.join(root, "Xedit.xcodeproj")
    raise InstallError, "Xcode project not found: #{project_path}" unless File.directory?(project_path)

    secret = load_secret!(env_path)
    build_root = options.fetch(:build_root)
    built_app = File.join(build_root, "Build", "Products", "Debug", "WillDeep.app")
    installed_app = File.join(options.fetch(:applications_dir), "WillDeep.app")

    if options.fetch(:dry_run)
      puts "Dry run passed"
      puts "- source: #{root}"
      puts "- secret source: #{env_path} (value hidden)"
      puts "- destination: #{installed_app}"
      return
    end

    FileUtils.rm_rf(build_root) if options.fetch(:clean)
    FileUtils.mkdir_p(build_root)
    build!(
      root: root,
      project_path: project_path,
      build_root: build_root,
      secret: secret,
      options: options
    )
    raise InstallError, "built app not found: #{built_app}" unless File.directory?(built_app)

    built_version = bundle_version!(built_app)
    verify_code_signature!(built_app)
    verify_secret_injection!(build_root: build_root, app_path: built_app, expected_secret: secret)

    installed_version = nil
    install_atomically!(built_app: built_app, installed_app: installed_app) do |installed_path|
      installed_version = bundle_version!(installed_path)
      unless installed_version == built_version
        raise InstallError, "installed version does not match the built app"
      end

      verify_code_signature!(installed_path)
      verify_secret_injection!(build_root: build_root, app_path: installed_path, expected_secret: secret)
    end
    secret.clear

    puts "Debug install summary"
    puts "- WillDeep #{installed_version} Debug -> #{installed_app}"
    puts "- code signature valid: true"
    puts "- client-login secret injection match: true"
    puts "- fully quit and relaunch WillDeep to use the installed build"
  end

  def parse_options(argv, root)
    options = {
      applications_dir: ENV.fetch("MAC_DEBUG_APPLICATIONS_DIR", DEFAULT_APPLICATIONS_DIR),
      build_root: ENV.fetch("WILLDEEP_DEV_BUILD_ROOT", File.join(Dir.tmpdir, "willdeep-dev-install")),
      clean: true,
      dry_run: false,
      team_id: ENV.fetch("APPLE_TEAM_ID", DEFAULT_TEAM_ID)
    }

    parser = OptionParser.new do |opts|
      opts.banner = "Usage: ruby dev_install.rb [options]"
      opts.on("--applications-dir PATH", "Install directory (default: /Applications)") do |value|
        options[:applications_dir] = File.expand_path(value, root)
      end
      opts.on("--build-root PATH", "DerivedData directory") do |value|
        options[:build_root] = File.expand_path(value, root)
      end
      opts.on("--team-id TEAM_ID", "Apple development team ID") { |value| options[:team_id] = value }
      opts.on("--no-clean", "Reuse DerivedData instead of starting clean") { options[:clean] = false }
      opts.on("--dry-run", "Validate configuration without building or installing") { options[:dry_run] = true }
    end
    parser.parse!(argv)

    options[:applications_dir] = File.expand_path(options.fetch(:applications_dir), root)
    options[:build_root] = File.expand_path(options.fetch(:build_root), root)
    options
  end

  def build!(root:, project_path:, build_root:, secret:, options:)
    args = [
      "xcodebuild", "build",
      "-project", project_path,
      "-scheme", "Xedit",
      "-configuration", "Debug",
      "-destination", "platform=macOS",
      "-derivedDataPath", build_root,
      "-clonedSourcePackagesDirPath", File.join(build_root, "SourcePackages"),
      "-allowProvisioningUpdates",
      "CODE_SIGN_STYLE=Automatic",
      "DEVELOPMENT_TEAM=#{options.fetch(:team_id)}"
    ]

    puts "$ #{args.shelljoin}"
    success = false
    Open3.popen2e({ SECRET_KEY => secret }, *args, chdir: root) do |_stdin, output, wait_thread|
      output.each_line { |line| print line }
      success = wait_thread.value.success?
    end
    raise InstallError, "xcodebuild failed" unless success
  end

  def install_atomically!(built_app:, installed_app:)
    FileUtils.mkdir_p(File.dirname(installed_app))
    staging_app = "#{installed_app}.installing-#{Process.pid}"
    backup_app = "#{installed_app}.backup-#{Process.pid}"
    installed_replaced = false
    FileUtils.rm_rf(staging_app)
    FileUtils.rm_rf(backup_app)
    FileUtils.cp_r(built_app, staging_app)
    verify_code_signature!(staging_app)

    FileUtils.mv(installed_app, backup_app) if File.exist?(installed_app)
    FileUtils.mv(staging_app, installed_app)
    installed_replaced = true
    yield installed_app
    FileUtils.rm_rf(backup_app)
  rescue StandardError
    FileUtils.rm_rf(installed_app) if installed_replaced && File.exist?(installed_app)
    if File.exist?(backup_app) && !File.exist?(installed_app)
      FileUtils.mv(backup_app, installed_app)
    end
    raise
  ensure
    FileUtils.rm_rf(staging_app) if defined?(staging_app) && File.exist?(staging_app)
  end

  def bundle_version!(app_path)
    plist = File.join(app_path, "Contents", "Info.plist")
    stdout, _stderr, status = Open3.capture3(
      "/usr/bin/plutil", "-extract", "CFBundleShortVersionString", "raw", "-o", "-", plist
    )
    version = stdout.strip
    raise InstallError, "could not read installed app version" unless status.success? && !version.empty?

    version
  end

  def verify_code_signature!(app_path)
    _stdout, stderr, status = Open3.capture3(
      "/usr/bin/codesign", "--verify", "--deep", "--strict", app_path
    )
    return if status.success?

    detail = stderr.to_s.lines.first.to_s.strip
    raise InstallError, ["code signature verification failed", detail].reject(&:empty?).join(": ")
  end

  def verify_secret_injection!(build_root:, app_path:, expected_secret:)
    generated_source = Dir.glob(
      File.join(build_root, "**", "SomeIMClientLoginSecret.generated.swift")
    ).max_by { |path| File.mtime(path) }
    raise InstallError, "generated client-login source was not found" unless generated_source

    generated_line = File.readlines(generated_source).find { |line| line.include?("static let value =") }
    generated_literal = generated_line.to_s.split("=", 2).last.to_s.strip
    generated_secret = JSON.parse(generated_literal)
    raise InstallError, "generated client-login secret does not match .env.local" unless generated_secret == expected_secret

    debug_dylib = File.join(app_path, "Contents", "MacOS", "WillDeep.debug.dylib")
    raise InstallError, "Debug dylib was not found" unless File.file?(debug_dylib)
    raise InstallError, "client-login secret was not found in Debug dylib" unless File.binread(debug_dylib).include?(generated_secret.b)
  rescue JSON::ParserError
    raise InstallError, "generated client-login source is invalid"
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    WillDeepDevInstall.run!(ARGV)
  rescue WillDeepDevInstall::InstallError, OptionParser::ParseError => e
    warn "ERROR: #{e.message}"
    exit 1
  end
end
