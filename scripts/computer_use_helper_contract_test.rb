#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "pathname"

# Pinned like the sibling guards: these read UTF-8 repo files, and a shell
# without LANG leaves Ruby on US-ASCII, which turns any non-ASCII byte into
# an Encoding::InvalidByteSequenceError instead of a real check result.
Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

ROOT = Pathname.new(__dir__).parent
HELPER = ROOT.join("ComputerUseHelper", "main.swift")
TOOLS = ROOT.join("Xedit", "AgentComputerUseTools.swift")
POLICY = ROOT.join("Xedit", "AgentComputerUsePolicy.swift")
STATUS = ROOT.join("Xedit", "AgentComputerUseFloatingPanel.swift")
DEFAULT_MARKDOWN_REPORT = "/tmp/xedit-computer-use-helper-contract.md"
DEFAULT_JSON_REPORT = "/tmp/xedit-computer-use-helper-contract.json"

markdown_path = Pathname.new(ARGV[0] || DEFAULT_MARKDOWN_REPORT)
json_path = Pathname.new(ARGV[1] || DEFAULT_JSON_REPORT)
helper_source = HELPER.read
tools_source = TOOLS.read
policy_source = POLICY.read
status_source = STATUS.read
checks = []

record = lambda do |name, ok, detail|
  checks << { name: name, ok: ok, detail: detail }
end

record.call(
  "protocol-v6",
  helper_source.include?('protocolVersion = "willdeep-computer-use.v6"'),
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
  tools_source.include?("AgentComputerUsePolicy.validateBeforeHelper") &&
    policy_source.include?('action == "select_text"') &&
    policy_source.include?("likelySensitiveText(candidate)"),
  "selection shares the Computer Use secret guard"
)

record.call(
  "accessibility-only-state",
  helper_source.include?('let includeScreenshot = bool(arguments, "include_screenshot", default: false)') &&
    helper_source.include?('"include_screenshot": false') &&
    helper_source.include?('result["screenshot"] = NSNull()') &&
    tools_source.include?('safeArguments["include_screenshot"] = .bool(false)'),
  "state reads and post-action refreshes are AX-first without Screen Recording"
)

record.call(
  "condition-wait",
  %w[ref_exists value_contains title_contains].all? { |condition| helper_source.include?(%Q{"#{condition}"}) },
  "Accessibility polling conditions"
)

record.call(
  "single-status-and-local-preview",
  helper_source.include?('case "capture_control_preview"') &&
    helper_source.include?('"preserved_active_snapshot": true') &&
    helper_source.include?(".optionIncludingWindow") &&
    status_source.include?("AgentComputerUseStatusController") &&
    status_source.include?("NSStatusItem") &&
    status_source.include?("cursorarrow.rays") &&
    !status_source.include?("NSPanel") &&
    !status_source.include?("AgentComputerUseFloatingControlBar"),
  "one in-chat control card is paired with a target-app menu-bar badge and non-invalidating background preview"
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
