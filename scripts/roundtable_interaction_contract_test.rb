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
preparation_source = read_file(repo_root, "Xedit/RoundtablePreparationView.swift")
selection_source = read_file(repo_root, "Xedit/RoundtableExpertSelectionView.swift")
streaming_source = read_file(repo_root, "Xedit/RoundtableStreamingSupport.swift")
# 1.235.0-rc1 起圆桌输入框收敛到与调度台共用的 SubmitOnReturnTextView，
# Return 提交 / 修饰键换行 / 输入法组字保护都住在这里。
submit_source = read_file(repo_root, "Xedit/SubmitOnReturnTextView.swift")
subagents_source = read_file(repo_root, "Xedit/AgentSubagents.swift")
l10n_source = read_file(repo_root, "Xedit/L10n+RoundtableSetup.swift")
strings_source = read_file(repo_root, "Xedit/Localizable.xcstrings")
run_tests_source = read_file(repo_root, "scripts/run_tests.sh")
workflow_source = read_file(repo_root, ".github/workflows/test.yml")

checks = []
add_check = lambda do |name, ok, detail|
  checks << { name: name, ok: ok == true, detail: detail }
end

add_check.call(
  "home composer submits with Return",
  includes_all?(
    window_source + submit_source,
    [
      "SubmitOnReturnTextView(",
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
    submit_source,
    [
      "flags.contains(.shift)",
      "flags.contains(.option)",
      "flags.contains(.control)",
      "return !wantsLineBreak",
      "guard !hasMarkedText else { return false }"
    ]
  ),
  "Shift/Option/Control + Return must remain available for deliberate line breaks."
)

add_check.call(
  "active expert is persisted before model work and cleared afterward",
  includes_all?(
    engine_source,
    [
      "$0.activeExpert = role",
      "$0.activeExpertDraft = nil",
      "let payload = try await runExpert",
      "$0.activeExpert = nil"
    ]
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

roundtable_avatar_assets = %w[
  RoundtableProduct
  RoundtableArchitecture
  RoundtableFinance
  RoundtableRisk
  RoundtableStrategy
  RoundtablePsychology
  RoundtableLegal
  RoundtableResearch
  RoundtableGrowth
  RoundtableOperations
]
avatar_assets_present = roundtable_avatar_assets.all? do |asset|
  asset_directory = File.join(repo_root, "Xedit/Assets.xcassets/#{asset}.imageset")
  model_source.include?(asset) &&
    File.file?(File.join(asset_directory, "Contents.json")) &&
    !Dir.glob(File.join(asset_directory, "#{asset}.{png,svg}")).empty?
end

add_check.call(
  "ten distinct avatar assets back the expert identities",
  avatar_assets_present,
  "Every built-in expert role must resolve to a real PNG or SVG portrait in Assets.xcassets."
)

add_check.call(
  "new topics enter a persisted preparation flow before discussion",
  includes_all?(
    window_source + app_state_source + model_source,
    [
      "case preparation(runtimeID: UUID, reportID: UUID)",
      "phase: .clarifying",
      "RoundtablePreparation(originalTopic: trimmed)",
      "driveRoundtablePreparation(",
      "case clarifying",
      "case selectingExperts"
    ]
  ),
  "Submitting a topic must route into clarification and expert selection rather than silently starting the formal discussion."
)

add_check.call(
  "expert confirmation strictly gates phase and two-to-six unique experts",
  includes_all?(
    app_state_source + selection_source,
    [
      "let uniqueExperts = experts.filter { seen.insert($0).inserted }",
      "uniqueExperts.count >= RoundtablePreparation.minimumExpertCount",
      "uniqueExperts.count <= RoundtablePreparation.maximumExpertCount",
      "roundtable.phase == .selectingExperts",
      "selection.count < RoundtablePreparation.maximumExpertCount",
      ".disabled(isBusy || !isValidSelection)"
    ]
  ),
  "The UI and AppState entry point must reject fewer than two, more than six, or confirmation from the wrong phase."
)

add_check.call(
  "preparation UI exposes framework, clarification, recommendations, and refinement",
  includes_all?(
    preparation_source + selection_source,
    [
      "frameworkCard",
      "clarificationQuestions",
      "clarificationConversation",
      "recommendationCard",
      "SubmitOnReturnTextView(",
      "ForEach(AgentRoundtableExpertRole.allCases)",
      "recommendationReason(for: role)"
    ]
  ),
  "Users must be able to inspect and refine the framework, see recommendation reasons, and adjust the full built-in panel."
)

add_check.call(
  "expert speech is true free-text streaming followed by separate analysis",
  includes_all?(
    engine_source + subagents_source + streaming_source,
    [
      "AgentSubagentRunner.runStreamingText(",
      "guard case let .textDelta(delta) = event",
      "draftBuffer.append(delta)",
      "AgentRoundtablePromptBuilder.analyzeExpertSpeech(",
      "outputSchema: AgentRoundtablePromptBuilder.expertAnalysisSchema",
      "attachingSpeech(speech)",
      "tools: []",
      "case .reasoningDelta(let delta):",
      "await publishExpertDraft(draftBuffer.reset())",
      "$0.activeExpertDraftIsComplete = publication.text.isEmpty"
    ]
  ),
  "Visible provider deltas must stream independently from reasoning, then feed a second structured analysis without rewriting the speech."
)

add_check.call(
  "stream completion, cancellation, and failure clear transient draft state",
  includes_all?(
    engine_source + app_state_source,
    [
      "$0.activeExpertDraftIsComplete = publication.text.isEmpty",
      "$0.activeExpertDraftIsComplete = nil",
      "detail.activeExpertDraftIsComplete = nil",
      "catch is CancellationError",
      "catch {"
    ]
  ),
  "The UI may distinguish streaming from analysis, but every terminal or abandoned path must clear both the draft and its completion marker."
)

add_check.call(
  "streaming draft refresh and persistence are independently throttled",
  includes_all?(
    streaming_source + engine_source,
    [
      "defaultUIInterval: Duration = .milliseconds(80)",
      "defaultCheckpointInterval: Duration = .seconds(1)",
      "shouldRefreshUI",
      "shouldCheckpoint",
      "mutate(persist: publication.shouldCheckpoint)"
    ]
  ),
  "Token-level UI updates must not turn into token-level session-store writes."
)

add_check.call(
  "discussion renders live expert draft and speaking status",
  includes_all?(
    discussion_source + model_source + l10n_source,
    [
      "activeExpertDraft",
      "RoundtableStreamingMessageBubble(",
      "draft: draft",
      "activeExpertDraftIsComplete",
      "expertSpeaking(role.personalName)",
      "expertFinishedSpeaking(role.personalName)",
      "expertSpeakingDetail",
      "liveSpeaking",
      "analyzingStance"
    ]
  ),
  "The active expert's real text must appear in the transcript and dashboard while it is generated."
)

new_expert_localization_present = %w[
  legal
  research
  growth
  operations
].all? do |role|
  strings_source.include?("\"roundtable.expert.#{role}.name\"") &&
    strings_source.include?("\"roundtable.expert.#{role}.role\"") &&
    strings_source.include?("\"roundtable.setup.expert.#{role}.expertise\"")
end

add_check.call(
  "new expert identities and expertise are localized",
  new_expert_localization_present &&
    strings_source.include?("\"zh-Hans\"") &&
    strings_source.include?("\"en\""),
  "Legal, research, growth, and operations experts need localized names, titles, and expertise in both supported languages."
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
  "selectable message sizing cannot write back into SwiftUI layout",
  includes_all?(
    components_source,
    [
      "func sizeThatFits(",
      "context.coordinator.sizeThatFits(textView, width: width)",
      "func invalidateMeasurement()"
    ]
  ) &&
    !components_source.include?("@Binding var measuredHeight") &&
    !components_source.include?("DispatchQueue.main.async") &&
    !discussion_source.include?("@State private var measuredTextHeight") &&
    !discussion_source.include?(".frame(height: measuredTextHeight)"),
  "Read-only AppKit text must answer SwiftUI's size proposal directly, without an async height Binding feedback loop."
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
