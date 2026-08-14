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
# The L10n layer is split across many files (and gets re-split whenever one
# crosses the 3000-line limit), so glob the whole layer instead of pinning the
# handful of files that happened to hold these keys when the check was written.
l10n = Dir.glob(File.join(repo_root, "Xedit", "L10n*.swift"))
          .sort
          .map { |path| File.read(path, encoding: "UTF-8") }
          .join("\n")

checks = [
  check("terminal backed by SwiftTerm", "Agent terminal uses SwiftTerm LocalProcessTerminalView") {
    terminal.include?("import SwiftTerm") &&
      terminal.include?("LocalProcessTerminalView") &&
      terminal.include?("startProcess(")
  },
  check("local shell is the default tab", "openLocalTab launches the login shell, no SSH required") {
    terminal.include?("func openLocalTab") &&
      terminal.include?("case .localShell:") &&
      terminal.include?("loginShellPath(settings.shellPath)") &&
      terminal.include?('args: ["-l"]')
  },
  check("SSH remains available", "openSSHTab still launches /usr/bin/ssh with -tt") {
    terminal.include?("func openSSHTab") &&
      terminal.include?('"/usr/bin/ssh"') && terminal.include?('"-tt"')
  },
  check("multiple tabs supported", "Controller manages a tabs array with active selection") {
    terminal.include?("var tabs: [AgentTerminalTab]") &&
      terminal.include?("var activeTabID") &&
      terminal.include?("func closeTab(")
  },
  check("tabs remember their origin session", "AgentTerminalTab records originAgentSessionID") {
    terminal.include?("originAgentSessionID") &&
      terminal_view.include?("originAgentSessionID: appState.activeAgentSessionID")
  },
  check("idle tabs auto-exit", "Idle reaper terminates tabs past idleTimeout") {
    terminal.include?("idleTimeout") &&
      terminal.include?("startIdleReaper") &&
      terminal.include?("idleSeconds(now:")
  },
  check("terminal tools registered", "snapshot/send_command/send_control are exposed") {
    %w[terminal_snapshot terminal_send_command terminal_send_control].all? { |name| tools.include?(name) && runner.include?(name) }
  },
  check("terminal writes require approval", "send command/control go through workspace-write approval") {
    terminal_command_requires_approval = policy.match?(
      /case "terminal_send_command":.*?requiresUserApproval: true/m
    )
    terminal_control_requires_approval = policy.match?(
      /case "rename_session".*?"terminal_send_control".*?requiresUserApproval: true/m
    )
    terminal_command_requires_approval && terminal_control_requires_approval
  },
  check("running session exposes manual controls", "Status menu exposes interrupt, telnet escape, EOF, and stop") {
    terminal_view.include?("sessionStatusPill") &&
      terminal_view.include?("sendUserControl(.ctrlC") &&
      terminal_view.include?("sendUserControl(.ctrlRightBracket") &&
      terminal_view.include?("sendUserControl(.ctrlD") &&
      terminal_view.include?("controller.stopTab")
  },
  check("PTY termination cleans the process tree", "Termination snapshots descendants and uses the shared TERM/KILL cleanup") {
    terminal.include?("process.shellPid") &&
      terminal.include?("AgentProcessSupport.terminateProcessTree(rootPID: rootPID)") &&
      runner.include?("descendantPIDs(of: rootPID)") &&
      runner.include?("Darwin.kill(identity.pid, SIGKILL)")
  },
  check("side panel has terminal kind", "AgentSidePanelKind exposes .terminal") {
    side_panel.include?("case terminal") && side_panel.include?("AgentSidePanelTerminalView()")
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
