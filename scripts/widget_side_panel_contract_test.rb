#!/usr/bin/env ruby
# frozen_string_literal: true

# widget_side_panel_contract_test.rb -- guard the Widget side-panel handoff
# contract. The side panel can safely open local previews, but every clicked
# handoff/recommended action must also leave structured context for the chat
# loop through latest-widget-tool-action.
#
# Usage:
#   ruby scripts/widget_side_panel_contract_test.rb
#   ruby scripts/widget_side_panel_contract_test.rb build/ci/widget_side_panel_report.md build/ci/widget_side_panel_report.json

require "json"
require "fileutils"
require "time"

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

repo_root = File.expand_path("..", __dir__)
markdown_path = ARGV[0] || "build/widget_side_panel_contract/report.md"
json_path = ARGV[1] || "build/widget_side_panel_contract/report.json"

def read_file(repo_root, relative)
  File.read(File.join(repo_root, relative), encoding: "UTF-8")
end

def includes_all?(source, tokens)
  tokens.all? { |token| source.include?(token) }
end

side_panel_source = read_file(repo_root, "Xedit/AgentSidePanel.swift")
widget_action_source = read_file(repo_root, "Xedit/AgentWidgetToolAction.swift")
runtime_source = read_file(repo_root, "Xedit/AgentRuntime.swift")
loop_source = read_file(repo_root, "Xedit/AppStateAgentLoop.swift")
run_tests_source = read_file(repo_root, "scripts/run_tests.sh")
workflow_source = read_file(repo_root, ".github/workflows/test.yml")

checks = []

add_check = lambda do |name, status, detail|
  checks << {
    name: name,
    ok: status == true,
    detail: detail
  }
end

add_check.call(
  "side panel records structured handoff tool actions",
  includes_all?(
    side_panel_source,
    [
      "private func recordWidgetSidePanelToolAction(",
      "AgentWidgetToolAction(",
      "widgetID: widget.id",
      "widgetTitle: widget.title",
      "actionKey: action.key",
      "tool: action.tool",
      "arguments: action.arguments",
      "widgetContext: widget.contextBlock"
    ]
  ),
  "Widget side-panel action rows must create AgentWidgetToolAction records."
)

add_check.call(
  "side panel action note preserves safety instructions",
  includes_all?(
    side_panel_source,
    [
      "side_panel_action_label: \\(action.label)",
      "side_panel_action_hint:",
      "dry-run or user-confirmation requirements",
      "before executing provider or mutating tools"
    ]
  ),
  "Structured side-panel actions must remind the chat loop to preserve safety checks."
)

add_check.call(
  "handoff row click records latest-widget-tool-action context",
  side_panel_source.match?(
    /private func appendWidgetHandoffActionToChat\(_ action: AgentWidgetHandoffAction, widget: AgentWidget\) \{\s*recordWidgetSidePanelToolAction\(action, widget: widget, source: "widget_side_panel_handoff_action"\)/m
  ),
  "Clicking a handoff action must record the structured action before staging chat text."
)

add_check.call(
  "recommended row click records latest-widget-tool-action context",
  side_panel_source.match?(
    /private func appendWidgetRecommendedActionToChat\(_ action: AgentWidgetRecommendedAction, widget: AgentWidget\) \{\s*recordWidgetSidePanelToolAction\(\s*recommendedHandoffAction\(action\),\s*widget: widget,\s*source: "widget_side_panel_recommended_action"\s*\)/m
  ),
  "Clicking a recommended action must record the structured action before staging chat text."
)

add_check.call(
  "side panel still stages visible chat handoff blocks",
  includes_all?(
    side_panel_source,
    [
      "<widget-handoff-action>",
      "source: widget_side_panel_handoff_action",
      "<widget-recommended-action>",
      "source: widget_side_panel_recommended_action"
    ]
  ),
  "Structured runtime context must not replace the user-visible staged handoff prompt."
)

add_check.call(
  "latest widget tool action reaches the system prompt",
  includes_all?(
    widget_action_source + runtime_source + loop_source,
    [
      "var latestWidgetToolAction: AgentWidgetToolAction?",
      "func recordAgentWidgetToolAction(_ action: AgentWidgetToolAction)",
      "=== Latest Widget Tool Action ===",
      "<latest-widget-tool-action>",
      "latestWidgetToolAction.systemPromptBlock"
    ]
  ),
  "The recorded side-panel action must be available to the next model request."
)

add_check.call(
  "local and CI runners execute widget side-panel contract",
  includes_all?(
    run_tests_source + workflow_source,
    [
      "scripts/widget_side_panel_contract_test.rb",
      "widget_side_panel_report.md",
      "widget_side_panel_report.json"
    ]
  ),
  "Both local run_tests.sh and GitHub Actions should run and publish this contract."
)

failures = checks.reject { |check| check[:ok] }
ok = failures.empty?
report = {
  ok: ok,
  generated_at: Time.now.utc.iso8601,
  checks: checks,
  failures: failures
}

[markdown_path, json_path].each do |path|
  directory = File.dirname(File.expand_path(path, repo_root))
  FileUtils.mkdir_p(directory) unless Dir.exist?(directory)
end

File.write(File.expand_path(json_path, repo_root), JSON.pretty_generate(report))

status = ok ? "PASS" : "FAIL"
md = +"# Widget Side Panel Contract Report\n\n"
md << "**Status:** #{status}\n\n"
md << "- Checks: #{checks.length}\n"
md << "- Failures: #{failures.length}\n\n"

if failures.empty?
  md << "All widget side-panel handoff checks passed.\n\n"
else
  md << "## Failures\n\n"
  failures.each { |failure| md << "- #{failure[:name]}: #{failure[:detail]}\n" }
  md << "\n"
end

md << "## Checks\n\n"
md << "| Check | Status | Detail |\n"
md << "| --- | --- | --- |\n"
checks.each do |check|
  md << "| #{check[:name]} | #{check[:ok] ? "PASS" : "FAIL"} | #{check[:detail]} |\n"
end

File.write(File.expand_path(markdown_path, repo_root), md)

puts "widget_side_panel_contract: #{status.downcase} checks=#{checks.length} failures=#{failures.length}"
exit(ok ? 0 : 1)
