#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"

root = File.expand_path("..", __dir__)
markdown_path = File.expand_path(ARGV[0] || "build/agent_settings_responsiveness/report.md", root)
json_path = File.expand_path(ARGV[1] || "build/agent_settings_responsiveness/report.json", root)

sources = {
  skills_view: File.read(File.join(root, "Xedit", "AgentSkillSettingsView.swift")),
  skills_directory: File.read(File.join(root, "Xedit", "AgentSkillDirectory.swift")),
  mcp_view: File.read(File.join(root, "Xedit", "AgentMCPSettingsView.swift")),
  mcp_directory: File.read(File.join(root, "Xedit", "AgentMCPServerDirectory.swift")),
  mcp_models: File.read(File.join(root, "Xedit", "AgentMCPModels.swift")),
  rules_view: File.read(File.join(root, "Xedit", "AgentGlobalRulesSettingsView.swift")),
  rules_store: File.read(File.join(root, "Xedit", "AgentGlobalRulesStore.swift")),
  memory_view: File.read(File.join(root, "Xedit", "AgentMemorySettingsView.swift")),
  memory_store: File.read(File.join(root, "Xedit", "AgentMemoryStore.swift")),
  review_view: File.read(File.join(root, "Xedit", "AgentLearningReviewSettingsView.swift")),
  review_store: File.read(File.join(root, "Xedit", "AgentLearningReviewStore.swift"))
}

checks = {
  "skills_view_has_lightweight_initial_state" =>
    sources[:skills_view].include?("@State private var skills: [AgentSkillEntry] = []") &&
      !sources[:skills_view].match?(/@State[^\n]+AgentSkillDirectory\.list/),
  "skills_discovery_runs_off_main_actor" =>
    sources[:skills_directory].include?("nonisolated enum AgentSkillDirectory") &&
      sources[:skills_directory].include?("static func listAsync") &&
      sources[:skills_directory].include?("Task.detached(priority: .userInitiated)"),
  "skills_refreshes_are_coalesced" =>
    sources[:skills_view].include?("needsSkillReload") &&
      sources[:skills_view].include?("repeat {") &&
      sources[:skills_view].include?("await reloadSkills()"),
  "mcp_view_has_lightweight_initial_state" =>
    sources[:mcp_view].include?("@State private var servers: [AgentMCPServerConfig] = []") &&
      !sources[:mcp_view].match?(/@State[^\n]+AgentMCPServerDirectory\.list/),
  "mcp_discovery_runs_off_main_actor" =>
    sources[:mcp_directory].include?("nonisolated enum AgentMCPServerDirectory") &&
      sources[:mcp_directory].include?("static func listAsync") &&
      sources[:mcp_directory].include?("Task.detached(priority: .userInitiated)") &&
      sources[:mcp_models].include?("nonisolated struct AgentMCPServerConfig"),
  "mcp_refreshes_are_coalesced" =>
    sources[:mcp_view].include?("needsServerReload") &&
      sources[:mcp_view].include?("await reloadServers()"),
  "rules_file_loading_runs_off_main_actor" =>
    sources[:rules_view].include?("@State private var settings = AgentGlobalRulesSettings.default") &&
      sources[:rules_store].include?("nonisolated enum AgentGlobalRulesStore") &&
      sources[:rules_store].include?("static func loadEditorSnapshot") &&
      sources[:rules_store].include?("Task.detached(priority: .userInitiated)"),
  "memory_persistence_loading_runs_off_main_actor" =>
      sources[:memory_view].include?("AgentMemoryState(settings: .default, memories: [])") &&
      sources[:memory_view].include?("if isLoadingMemory") &&
      sources[:memory_store].include?("nonisolated enum AgentMemorySettingsStore") &&
      sources[:memory_store].include?("nonisolated enum AgentMemoryKeywordExtractor") &&
      sources[:memory_store].include?("nonisolated enum AgentMemorySanitizer") &&
      sources[:memory_store].include?("nonisolated enum AgentMemoryEngine") &&
      sources[:memory_store].include?("func reloadFromStore() async") &&
      sources[:memory_store].include?("Task.detached(priority: .userInitiated)"),
  "learning_review_loading_runs_off_main_actor" =>
      sources[:review_view].include?("AgentLearningReviewState(items: [])") &&
      sources[:review_view].include?("await reviewState.reloadFromStore()") &&
      sources[:review_store].include?("nonisolated enum AgentLearningReviewStore") &&
      sources[:review_store].include?("static func loadAsync() async") &&
      sources[:review_store].include?("Task.detached(priority: .userInitiated)")
}

failures = checks.select { |_name, passed| !passed }.keys
report = {
  status: failures.empty? ? "passed" : "failed",
  checks: checks.map { |name, passed| { name: name, status: passed ? "passed" : "failed" } },
  failures: failures
}

FileUtils.mkdir_p(File.dirname(markdown_path))
FileUtils.mkdir_p(File.dirname(json_path))
File.write(json_path, JSON.pretty_generate(report) + "\n")

markdown = [
  "# AI Agents Settings Responsiveness Contract",
  "",
  "- Status: `#{report[:status]}`",
  "- Checks: `#{checks.count}`",
  "- Failures: `#{failures.count}`",
  "",
  "## Results",
  ""
]
checks.each do |name, passed|
  markdown << "- #{passed ? '[x]' : '[ ]'} `#{name}`"
end
File.write(markdown_path, markdown.join("\n") + "\n")

puts "agent_settings_responsiveness: #{report[:status]} checks=#{checks.count} failures=#{failures.count}"
exit(failures.empty? ? 0 : 1)
