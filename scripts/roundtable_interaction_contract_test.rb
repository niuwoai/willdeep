#!/usr/bin/env ruby
# frozen_string_literal: true

# Guards the Expert Roundtable interaction contract. This source-level suite
# complements Swift behavior tests by pinning the native AppKit/SwiftUI wiring
# that is easiest to accidentally simplify during later visual refactors.

require "json"
require "fileutils"
require "time"

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

repo_root = File.expand_path("..", __dir__)
markdown_path = ARGV[0] || "build/roundtable_interaction_contract/report.md"
json_path = ARGV[1] || "build/roundtable_interaction_contract/report.json"

def read_file(repo_root, relative)
  File.read(File.join(repo_root, relative), encoding: "UTF-8")
end

def includes_all?(source, tokens)
  tokens.all? { |token| source.include?(token) }
end

window_source = read_file(repo_root, "Xedit/RoundtableWindow.swift")
discussion_source = read_file(repo_root, "Xedit/RoundtableDiscussionView.swift")
components_source = read_file(repo_root, "Xedit/RoundtableDiscussionComponents.swift")
engine_source = read_file(repo_root, "Xedit/AgentRoundtableEngine.swift")
model_source = read_file(repo_root, "Xedit/AgentRoundtable.swift")
app_state_source = read_file(repo_root, "Xedit/AppStateAgentRoundtable.swift")
run_tests_source = read_file(repo_root, "scripts/run_tests.sh")
workflow_source = read_file(repo_root, ".github/workflows/test.yml")

checks = []
add_check = lambda do |name, ok, detail|
  checks << { name: name, ok: ok == true, detail: detail }
end

add_check.call(
  "home composer submits with Return",
  includes_all?(
    window_source + components_source,
    [
      "RoundtableComposerTextView(",
      "onSubmit: start",
      "#selector(NSResponder.insertNewline(_:))",
      "onSubmit()"
    ]
  ),
  "The home topic editor must route unmodified Return through the same start action as the primary button."
)

add_check.call(
  "modified Return keeps multiline editing",
  includes_all?(
    components_source,
    [
      "modifiers.contains(.shift)",
      "modifiers.contains(.option)",
      "modifiers.contains(.control)",
      "guard !wantsLineBreak else { return false }"
    ]
  ),
  "Shift/Option/Control + Return must remain available for deliberate line breaks."
)

add_check.call(
  "active expert is persisted before model work and cleared afterward",
  engine_source.match?(
    /mutate \{ \$0\.activeExpert = role \}.*?let payload = try await runExpert.*?mutate \{ \$0\.activeExpert = nil \}/m
  ),
  "The report must expose the expert who is organizing a response before their model call begins."
)

add_check.call(
  "discussion presents a named expert speaking notice",
  includes_all?(
    discussion_source,
    [
      "if let activeExpert = report?.activeExpert",
      "activeSpeakerBanner(activeExpert)",
      "L10n.Roundtable.expertWillSpeakFormat",
      "role.personalName",
      "ProgressView()"
    ]
  ),
  "The active expert state must produce a visible name, portrait, and progress notice."
)

avatar_assets_present = %w[
  RoundtableProduct
  RoundtableArchitecture
  RoundtableFinance
  RoundtableRisk
  RoundtableStrategy
  RoundtablePsychology
].all? do |asset|
  model_source.include?(asset) &&
    File.file?(File.join(repo_root, "Xedit/Assets.xcassets/#{asset}.imageset/#{asset}.png"))
end

add_check.call(
  "six distinct generated avatar assets back the expert identities",
  avatar_assets_present,
  "Every expert role must resolve to a real raster portrait in Assets.xcassets."
)

add_check.call(
  "stance and dashboard visuals use semantic status encoding",
  includes_all?(
    discussion_source + components_source,
    [
      "stancePill(",
      "RoundtableVisuals.symbol(for: stance)",
      "RoundtableVisuals.color(for: stance)",
      "spectrumCard",
      "expertsCard",
      "signalsCard"
    ]
  ),
  "Each stance needs icon, color, and label reinforcement, and the right rail must remain data-bearing."
)

add_check.call(
  "composer reserves roughly three text lines",
  discussion_source.include?(".frame(height: 76)") &&
    window_source.include?(".frame(height: 78)"),
  "Both entry and in-discussion composers must remain multiline-sized rather than collapsing to a single row."
)

add_check.call(
  "whole-message and selected-text quotes reach persisted user replies",
  includes_all?(
    discussion_source + components_source + app_state_source + model_source,
    [
      "RoundtableSelectableMessageText(",
      "onSelectionChange:",
      "onQuote(message.content, false)",
      "onQuote(selectedExcerpt, true)",
      "quote: quoteDraft",
      "RoundtableQuoteReference",
      "quote: RoundtableQuoteReference?"
    ]
  ),
  "Users must be able to quote a whole expert message or a native text selection, and the quote must be stored."
)

add_check.call(
  "local and CI runners execute roundtable contract",
  includes_all?(
    run_tests_source + workflow_source,
    [
      "scripts/roundtable_interaction_contract_test.rb",
      "roundtable_interaction_contract_report.md",
      "roundtable_interaction_contract_report.json"
    ]
  ),
  "The contract must run locally and in GitHub Actions with Markdown and JSON evidence."
)

failures = checks.reject { |check| check[:ok] }
report = {
  ok: failures.empty?,
  generated_at: Time.now.utc.iso8601,
  checks: checks,
  failures: failures
}

[markdown_path, json_path].each do |path|
  directory = File.dirname(File.expand_path(path, repo_root))
  FileUtils.mkdir_p(directory) unless Dir.exist?(directory)
end

File.write(File.expand_path(json_path, repo_root), JSON.pretty_generate(report))

status = failures.empty? ? "PASS" : "FAIL"
markdown = +"# Expert Roundtable Interaction Contract\n\n"
markdown << "**Status:** #{status}\n\n"
markdown << "- Checks: #{checks.length}\n"
markdown << "- Failures: #{failures.length}\n\n"
markdown << "| Check | Status | Detail |\n"
markdown << "| --- | --- | --- |\n"
checks.each do |check|
  markdown << "| #{check[:name]} | #{check[:ok] ? "PASS" : "FAIL"} | #{check[:detail]} |\n"
end
File.write(File.expand_path(markdown_path, repo_root), markdown)

puts "roundtable_interaction_contract: #{status.downcase} checks=#{checks.length} failures=#{failures.length}"
exit(failures.empty? ? 0 : 1)
