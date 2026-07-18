#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "pathname"

ROOT = Pathname.new(__dir__).parent
HELPER = ROOT.join("ComputerUseHelper", "main.swift")
TOOLS = ROOT.join("Xedit", "AgentComputerUseTools.swift")
DEFAULT_MARKDOWN_REPORT = "/tmp/xedit-computer-use-helper-contract.md"
DEFAULT_JSON_REPORT = "/tmp/xedit-computer-use-helper-contract.json"

markdown_path = Pathname.new(ARGV[0] || DEFAULT_MARKDOWN_REPORT)
json_path = Pathname.new(ARGV[1] || DEFAULT_JSON_REPORT)
helper_source = HELPER.read
tools_source = TOOLS.read
checks = []

record = lambda do |name, ok, detail|
  checks << { name: name, ok: ok, detail: detail }
end

record.call(
  "protocol-v3",
  helper_source.include?('protocolVersion = "willdeep-computer-use.v3"'),
  "Computer Use helper protocol"
)

semantic_attributes = %w[
  kAXIdentifierAttribute kAXHelpAttribute kAXSelectedAttribute kAXExpandedAttribute
  kAXPositionAttribute kAXSizeAttribute
]
missing_attributes = semantic_attributes.reject { |attribute| helper_source.include?(attribute) }
record.call(
  "semantic-ax-tree",
  missing_attributes.empty? && helper_source.include?('result["frame"]') && helper_source.include?('result["center"]'),
  "missing=#{missing_attributes.join(",")}"
)

advanced_actions = %w[activate_app focus hover select_text wait_for]
missing_actions = advanced_actions.reject { |action| helper_source.include?(%Q{"#{action}"}) }
record.call(
  "advanced-actions",
  missing_actions.empty?,
  "missing=#{missing_actions.join(",")}"
)

record.call(
  "ax-click-coordinate-fallback",
  helper_source.include?("AXUIElementPerformAction(element, kAXPressAction") &&
    helper_source.include?("let center = CGPoint(x: frame.midX, y: frame.midY)"),
  "AXPress falls back to the element center"
)

record.call(
  "select-text-secret-guard",
  tools_source.include?('action == "select_text"') && tools_source.include?("rejectSensitiveText(arguments)"),
  "selection shares the Computer Use secret guard"
)

record.call(
  "accessibility-only-state",
  helper_source.include?('include_screenshot') && helper_source.include?('result["screenshot"] = NSNull()') &&
    tools_source.include?('safeArguments["include_screenshot"] = .bool(false)'),
  "semantic inspection can avoid Screen Recording"
)

record.call(
  "condition-wait",
  %w[ref_exists value_contains title_contains].all? { |condition| helper_source.include?(%Q{"#{condition}"}) },
  "Accessibility polling conditions"
)

status = checks.all? { |check| check[:ok] } ? "pass" : "fail"
payload = { status: status, checks: checks }
json_path.write(JSON.pretty_generate(payload) + "\n")

markdown = [
  "# Computer Use Helper Contract Report",
  "",
  "**Status:** #{status.upcase}",
  "",
  "| Check | Result | Detail |",
  "| --- | --- | --- |"
]
checks.each do |check|
  markdown << "| #{check[:name]} | #{check[:ok] ? "PASS" : "FAIL"} | #{check[:detail].to_s.gsub("|", "\\|")} |"
end
markdown_path.write(markdown.join("\n") + "\n")

puts "computer_use_helper_contract: #{status} checks=#{checks.length}"
exit(status == "pass" ? 0 : 1)
