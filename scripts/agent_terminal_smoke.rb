#!/usr/bin/env ruby
# frozen_string_literal: true

# Lightweight source-level smoke checks for the Agent-mode interactive
# terminal. The full behavior is covered by Swift tests; this script provides
# a cheap CI artifact with JSON and Markdown reports.

require "json"
require "fileutils"
require "time"

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

repo_root = File.expand_path("..", __dir__)
report_dir = File.join(repo_root, "build", "agent_terminal_smoke")
json_path = File.join(report_dir, "report.json")
md_path = File.join(report_dir, "report.md")

def read_source(repo_root, relative_path)
  File.read(File.join(repo_root, relative_path), encoding: "UTF-8")
end

def check(name, details)
  passed = yield
  { name: name, passed: passed, details: details }
rescue StandardError => e
  { name: name, passed: false, details: "#{details} (#{e.class}: #{e.message})" }
end

terminal = read_source(repo_root, "Xedit/AgentInteractiveTerminal.swift")
tools = read_source(repo_root, "Xedit/AgentToolRegistry.swift")
runner = read_source(repo_root, "Xedit/AgentTools.swift")
policy = read_source(repo_root, "Xedit/AgentToolAuthorization.swift")
side_panel = read_source(repo_root, "Xedit/AgentSidePanel.swift")
terminal_view = read_source(repo_root, "Xedit/AgentSidePanelTerminalView.swift")
runtime_settings = read_source(repo_root, "Xedit/AgentRuntimeSettingsView.swift")
l10n = read_source(repo_root, "Xedit/L10n.swift")

order_cd = terminal.index('commands.append("cd')
order_startup = terminal.index("commands.append(contentsOf: startupCommands)")
order_jump = terminal.index("commands.append(contentsOf: jumpCommands)")

checks = [
  check("interactive PTY uses openpty", "Agent terminal allocates a pseudo terminal") {
    terminal.include?("openpty(")
  },
  check("SSH launches real interactive session", "SSH command uses /usr/bin/ssh with -tt") {
    terminal.include?('"/usr/bin/ssh"') && terminal.include?('"-tt"')
  },
  check("startup commands precede jump commands", "Queue order is cd/startup before jump") {
    [order_cd, order_startup, order_jump].all? && order_cd < order_startup && order_startup < order_jump
  },
  check("terminal tools registered", "snapshot/send_command/send_control are exposed") {
    %w[terminal_snapshot terminal_send_command terminal_send_control].all? { |name| tools.include?(name) && runner.include?(name) }
  },
  check("terminal writes require approval", "send command/control go through workspace-write approval") {
    policy.include?('"terminal_send_command", "terminal_send_control"') &&
      policy.include?("requiresUserApproval: true")
  },
  check("side panel has terminal kind", "AgentSidePanelKind exposes .terminal") {
    side_panel.include?("case terminal") && side_panel.include?("AgentSidePanelTerminalView()")
  },
  check("service command menu exists", "Terminal panel exposes systemctl/journalctl/docker templates") {
    %w[systemctl journalctl docker].all? { |token| terminal_view.include?(token) }
  },
  check("runtime settings persist terminal profile", "Settings -> Runtimes writes terminalProfile") {
    runtime_settings.include?("terminalProfile") &&
      runtime_settings.include?("terminalStartupCommands") &&
      runtime_settings.include?("terminalJumpCommands")
  },
  check("visible strings use L10n", "Terminal strings are routed through L10n") {
    l10n.include?("enum AgentTerminal") && l10n.include?("settings.remote-runtimes.terminal-section")
  }
]

ok = checks.all? { |item| item[:passed] }
report = {
  ok: ok,
  generated_at: Time.now.utc.iso8601,
  checks: checks
}

FileUtils.mkdir_p(report_dir)
File.write(json_path, JSON.pretty_generate(report))

markdown = +"# Agent Terminal Smoke Report\n\n"
markdown << "**Status:** #{ok ? "PASS" : "FAIL"}\n\n"
markdown << "| Check | Result | Details |\n"
markdown << "| --- | --- | --- |\n"
checks.each do |item|
  markdown << "| #{item[:name]} | #{item[:passed] ? "PASS" : "FAIL"} | #{item[:details]} |\n"
end

File.write(md_path, markdown)
puts "agent_terminal_smoke: #{ok ? "pass" : "fail"} checks=#{checks.length}"
exit(ok ? 0 : 1)
