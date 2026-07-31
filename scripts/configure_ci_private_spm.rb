#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "open3"

deploy_key = ENV.fetch("SOMEIM_DEPLOY_KEY", "").strip
if deploy_key.empty?
  warn "::warning::SOMEIM_DEPLOY_KEY is not set — the private SomeIMSharedSession package will fail to resolve."
  exit 0
end

ssh_dir = File.join(Dir.home, ".ssh")
key_path = File.join(ssh_dir, "someim_deploy_key")
known_hosts_path = File.join(ssh_dir, "known_hosts")
config_path = File.join(ssh_dir, "config")
FileUtils.mkdir_p(ssh_dir)
File.chmod(0o700, ssh_dir)

File.write(key_path, "#{deploy_key}\n")
File.chmod(0o600, key_path)

known_hosts_output, known_hosts_error, known_hosts_status = Open3.capture3(
  "ssh-keyscan",
  "-t",
  "ed25519,rsa",
  "github.com"
)
unless known_hosts_status.success?
  abort "ssh-keyscan github.com failed: #{known_hosts_error.strip}"
end

existing_known_hosts = File.file?(known_hosts_path) ? File.readlines(known_hosts_path, chomp: true) : []
merged_known_hosts = (existing_known_hosts + known_hosts_output.lines(chomp: true)).reject(&:empty?).uniq
File.write(known_hosts_path, "#{merged_known_hosts.join("\n")}\n")
File.chmod(0o600, known_hosts_path)

host_block = <<~SSH_CONFIG
  Host github.com
    HostName github.com
    User git
    IdentityFile ~/.ssh/someim_deploy_key
    IdentitiesOnly yes
SSH_CONFIG
existing_config = File.file?(config_path) ? File.read(config_path, encoding: "UTF-8") : ""
unless existing_config.include?("IdentityFile ~/.ssh/someim_deploy_key")
  separator = existing_config.empty? || existing_config.end_with?("\n") ? "" : "\n"
  File.write(config_path, "#{existing_config}#{separator}#{host_block}")
end
File.chmod(0o600, config_path)

rewrite_key = "url.git@github.com:xurenlu/SomeIMSharedSession.insteadOf"
rewrite_value = "https://github.com/xurenlu/SomeIMSharedSession"
success = system("git", "config", "--global", rewrite_key, rewrite_value)
abort "Failed to configure private SomeIMSharedSession URL rewrite" unless success

puts "Configured private SomeIMSharedSession access."
