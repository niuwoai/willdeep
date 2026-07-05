#!/usr/bin/env ruby
# frozen_string_literal: true

# image_edit_contract_test.rb -- guard the image mask editor handoff contract.
# The editor must let generic images and short-drama anchored images hand off a
# real mask path to chat/skills, not only a placeholder.
#
# Usage:
#   ruby scripts/image_edit_contract_test.rb
#   ruby scripts/image_edit_contract_test.rb build/ci/image_edit_report.md build/ci/image_edit_report.json

require "json"
require "fileutils"
require "time"

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

repo_root = File.expand_path("..", __dir__)
markdown_path = ARGV[0] || "build/image_edit_contract/report.md"
json_path = ARGV[1] || "build/image_edit_contract/report.json"

def read_file(repo_root, relative)
  File.read(File.join(repo_root, relative), encoding: "UTF-8")
end

def includes_all?(source, tokens)
  tokens.all? { |token| source.include?(token) }
end

panel_source = read_file(repo_root, "Xedit/AgentImageEditPanel.swift")
submission_source = read_file(repo_root, "Xedit/AgentImageEditSubmission.swift")
media_handoff_source = read_file(repo_root, "Xedit/AgentMediaTaskChatHandoff.swift")
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
  "generic image editor shows chat handoff card",
  includes_all?(
    panel_source,
    [
      "Text(rows.isEmpty ? L10n.AgentImageEditor.contextCardGeneric : L10n.AgentImageEditor.contextCardAnchors)",
      "L10n.AgentImageEditor.genericEditHint",
      "appendImageEditorContextToChat(imageInfo: imageInfo)"
    ]
  ),
  "The image editor should expose a send-to-chat handoff even when there is no short-drama anchor."
)

add_check.call(
  "send-to-chat exports current mask when needed",
  includes_all?(
    panel_source,
    [
      "let currentMaskURL = lastMaskURL ?? (hasMaskSelection ? exportMask() : nil)",
      "let currentMaskPath = currentMaskURL?.path",
      "current_mask_path: \\(currentMaskPath)",
      "last_mask_path: \\(currentMaskPath)"
    ]
  ),
  "The staged chat context must include a concrete mask path after the user has drawn a mask."
)

add_check.call(
  "edit_image_with_mask arguments use the concrete mask path",
  includes_all?(
    panel_source,
    [
      "private func imageEditorSubmitArguments(imagePath: String, maskPath: String?, operation: ImageEditOperation) -> String",
      "mask_path=\\(maskPath ?? \"<mask_path>\")",
      "submit_with_existing_mask_arguments: \\(currentSubmitArguments)",
      "submit_inpaint_arguments: \\(imageEditorSubmitArguments(imagePath: imageInfo.url.path, maskPath: currentMaskPath, operation: .inpaint))",
      "submit_erase_arguments: \\(imageEditorSubmitArguments(imagePath: imageInfo.url.path, maskPath: currentMaskPath, operation: .erase))"
    ]
  ),
  "Chat/skill handoff should be directly runnable when a mask exists, while still showing a placeholder when none exists."
)

add_check.call(
  "submitted image edit tasks retain source and mask paths",
  includes_all?(
    panel_source + submission_source + media_handoff_source,
    [
      "sourceImagePath: imageInfo.url.path",
      "maskPath: maskURL.path",
      "appState.recordAgentImageEditSubmission(task: submittedTask)",
      "source_image_path: \\(sourceImagePath)",
      "mask_path: \\(maskPath)",
      "reopen_editor_tool: open_image_editor",
      "reopen_editor_arguments: \\(arguments)"
    ]
  ),
  "Submitted Replicate/some.im edit tasks must remain recoverable from media tasks and system prompt context."
)

add_check.call(
  "local and CI runners execute image edit contract",
  includes_all?(
    run_tests_source + workflow_source,
    [
      "scripts/image_edit_contract_test.rb",
      "image_edit_report.md",
      "image_edit_report.json"
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
md = +"# Image Edit Contract Report\n\n"
md << "**Status:** #{status}\n\n"
md << "- Checks: #{checks.length}\n"
md << "- Failures: #{failures.length}\n\n"

if failures.empty?
  md << "All image edit handoff checks passed.\n\n"
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

puts "image_edit_contract: #{status.downcase} checks=#{checks.length} failures=#{failures.length}"
exit(ok ? 0 : 1)
