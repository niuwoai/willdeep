#!/usr/bin/env ruby
# frozen_string_literal: true

require "English"
require "fileutils"
require "json"
require "rbconfig"
require "time"

ROOT = File.expand_path("..", __dir__)
RUBY = RbConfig.ruby

def report_paths(output_dir, stem)
  [
    File.join(output_dir, "#{stem}_report.md"),
    File.join(output_dir, "#{stem}_report.json")
  ]
end

def command(script, *arguments)
  [RUBY, File.join(ROOT, "scripts", script), *arguments]
end

def guard_groups(output_dir)
  complexity_md, complexity_json = report_paths(output_dir, "complexity")
  version_md, version_json = report_paths(output_dir, "version")
  i18n_md, i18n_json = report_paths(output_dir, "i18n")
  i18n_locale_md, i18n_locale_json = report_paths(output_dir, "i18n_locale")
  i18n_add_keys_md, i18n_add_keys_json = report_paths(output_dir, "i18n_add_keys_contract")
  bump_version_md, bump_version_json = report_paths(output_dir, "bump_version_contract")
  fast_entry_md, fast_entry_json = report_paths(output_dir, "fast_test_entry_contract")
  bundled_rules_md, bundled_rules_json = report_paths(output_dir, "bundled_agent_rules_contract")

  computer_use_md, computer_use_json = report_paths(output_dir, "computer_use_helper_contract")
  chrome_md, chrome_json = report_paths(output_dir, "chrome_extension_contract")
  widget_md, widget_json = report_paths(output_dir, "widget_side_panel")
  plugin_command_md, plugin_command_json = report_paths(output_dir, "plugin_command")
  roundtable_md, roundtable_json = report_paths(output_dir, "roundtable_interaction_contract")
  image_edit_md, image_edit_json = report_paths(output_dir, "image_edit")
  media_refresh_md, media_refresh_json = report_paths(output_dir, "media_task_refresh")
  media_import_md, media_import_json = report_paths(output_dir, "media_import_context")
  fixture_lifetime_md, fixture_lifetime_json = report_paths(
    output_dir,
    "test_fixture_process_lifetime"
  )

  short_drama_md, short_drama_json = report_paths(output_dir, "short_drama_media")
  production_gap_md, production_gap_json = report_paths(output_dir, "production_gap_actions")
  tryout_md, tryout_json = report_paths(output_dir, "short_drama_mvp_tryout_package")
  smoke_md, smoke_json = report_paths(output_dir, "short_drama_mvp_smoke_evidence")
  smoke_contract_md, smoke_contract_json = report_paths(
    output_dir,
    "short_drama_mvp_smoke_evidence_contract"
  )
  acceptance_md, acceptance_json = report_paths(output_dir, "short_drama_mvp_acceptance")
  handoff_md = File.join(output_dir, "short_drama_mvp_handoff_bundle.md")
  handoff_json = File.join(output_dir, "short_drama_mvp_handoff_bundle.json")
  handoff_contract_md, handoff_contract_json = report_paths(
    output_dir,
    "short_drama_mvp_handoff_bundle_contract"
  )
  tryout_dir = File.join(output_dir, "short_drama_mvp_tryout_package")

  {
    "quality" => [
      ["complexity", command("complexity_guard.rb", complexity_md, complexity_json)],
      ["version", command("version_consistency.rb", version_md, version_json)],
      ["i18n", command("i18n_coverage_guard.rb", i18n_md, i18n_json)],
      [
        "i18n-locale",
        command("i18n_locale_registration_guard.rb", i18n_locale_md, i18n_locale_json)
      ],
      [
        "i18n-add-keys",
        command("i18n_add_keys_contract_test.rb", i18n_add_keys_md, i18n_add_keys_json)
      ],
      [
        "bump-version",
        command("bump_version_contract_test.rb", bump_version_md, bump_version_json)
      ],
      [
        "fast-test-entry",
        command("fast_test_entry_contract_test.rb", fast_entry_json, fast_entry_md)
      ],
      [
        "bundled-agent-rules",
        command("bundled_agent_rules_contract_test.rb", bundled_rules_md, bundled_rules_json)
      ],
      [
        "test-fixture-process-lifetime",
        command(
          "test_fixture_process_lifetime_contract_test.rb",
          fixture_lifetime_md,
          fixture_lifetime_json
        )
      ],
      ["project-build-guard", command("project_build_guard_contract_test.rb")]
    ],
    "interaction" => [
      [
        "computer-use-helper",
        command("computer_use_helper_contract_test.rb", computer_use_md, computer_use_json)
      ],
      ["chrome-extension", command("chrome_extension_contract_test.rb", chrome_md, chrome_json)],
      ["widget-side-panel", command("widget_side_panel_contract_test.rb", widget_md, widget_json)],
      [
        "plugin-command",
        command("plugin_command_contract_test.rb", plugin_command_md, plugin_command_json)
      ],
      [
        "roundtable-interaction",
        command("roundtable_interaction_contract_test.rb", roundtable_md, roundtable_json)
      ],
      ["image-edit", command("image_edit_contract_test.rb", image_edit_md, image_edit_json)],
      [
        "media-task-refresh",
        command("media_task_refresh_contract_test.rb", media_refresh_md, media_refresh_json)
      ],
      [
        "media-import-context",
        command("media_import_context_contract_test.rb", media_import_md, media_import_json)
      ]
    ],
    "short-drama" => [
      ["version", command("version_consistency.rb", version_md, version_json)],
      [
        "short-drama-media",
        command("short_drama_media_contract_test.rb", short_drama_md, short_drama_json)
      ],
      [
        "production-gap-actions",
        command("production_gap_actions_contract_test.rb", production_gap_md, production_gap_json)
      ],
      [
        "tryout-package",
        command("short_drama_mvp_tryout_package.rb", tryout_dir, tryout_md, tryout_json)
      ],
      [
        "smoke-evidence",
        command("short_drama_mvp_smoke_evidence_report.rb", tryout_dir, smoke_md, smoke_json)
      ],
      [
        "smoke-evidence-contract",
        command(
          "short_drama_mvp_smoke_evidence_contract_test.rb",
          smoke_contract_md,
          smoke_contract_json
        )
      ],
      [
        "acceptance",
        command("short_drama_mvp_acceptance_report.rb", acceptance_md, acceptance_json)
      ],
      [
        "handoff-bundle",
        command(
          "short_drama_mvp_handoff_bundle.rb",
          acceptance_json,
          handoff_md,
          handoff_json
        )
      ],
      [
        "handoff-bundle-contract",
        command(
          "short_drama_mvp_handoff_bundle_contract_test.rb",
          handoff_contract_md,
          handoff_contract_json
        )
      ]
    ]
  }
end

group_name = ARGV.fetch(0) do
  abort "Usage: ruby scripts/run_ci_guard_group.rb <quality|interaction|short-drama> [output-dir]"
end
output_dir = File.expand_path(ARGV[1] || "build/ci", ROOT)
FileUtils.mkdir_p(output_dir)

groups = guard_groups(output_dir)
steps = groups[group_name]
abort "Unknown guard group #{group_name.inspect}; expected #{groups.keys.join(", ")}" unless steps

group_started_at = Time.now.utc
results = []

steps.each do |step_name, step_command|
  started_at = Time.now.utc
  monotonic_started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  puts "▶ [#{group_name}] #{step_name}"
  success = system(*step_command, chdir: ROOT)
  duration_seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - monotonic_started_at
  exit_status = $CHILD_STATUS&.exitstatus || 1
  results << {
    "name" => step_name,
    "status" => success ? "passed" : "failed",
    "exit_status" => exit_status,
    "duration_seconds" => duration_seconds.round(3),
    "started_at" => started_at.iso8601,
    "finished_at" => Time.now.utc.iso8601
  }
  break unless success
end

ok = results.length == steps.length && results.all? { |result| result["status"] == "passed" }
report = {
  "ok" => ok,
  "group" => group_name,
  "started_at" => group_started_at.iso8601,
  "finished_at" => Time.now.utc.iso8601,
  "duration_seconds" => results.sum { |result| result["duration_seconds"] }.round(3),
  "steps" => results
}

json_path = File.join(output_dir, "ci_guard_#{group_name}_report.json")
markdown_path = File.join(output_dir, "ci_guard_#{group_name}_report.md")
File.write(json_path, "#{JSON.pretty_generate(report)}\n")

markdown = [
  "# CI Guard Group: #{group_name}",
  "",
  "- Status: **#{ok ? "PASS" : "FAIL"}**",
  "- Duration: #{report["duration_seconds"]}s",
  "",
  "| Step | Status | Duration |",
  "| --- | --- | ---: |"
]
results.each do |result|
  markdown << "| #{result["name"]} | #{result["status"]} | #{result["duration_seconds"]}s |"
end
File.write(markdown_path, "#{markdown.join("\n")}\n")

if (summary_path = ENV["GITHUB_STEP_SUMMARY"]) && !summary_path.empty?
  File.open(summary_path, "a") do |summary|
    summary.write("\n")
    summary.write(File.read(markdown_path, encoding: "UTF-8"))
  end
end

puts(ok ? "✅ Guard group #{group_name} passed" : "❌ Guard group #{group_name} failed")
exit(ok ? 0 : 1)
