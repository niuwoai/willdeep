#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "digest"
require "json"
require "time"

# Pinned like the sibling guards: these read UTF-8 repo files, and a shell
# without LANG leaves Ruby on US-ASCII, which turns any non-ASCII byte into
# an Encoding::InvalidByteSequenceError instead of a real check result.
Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

ROOT_DIR = File.expand_path("..", __dir__)
ACCEPTANCE_JSON = File.expand_path(ARGV[0] || "build/ci/short_drama_mvp_acceptance_report.json", ROOT_DIR)
OUT_MD = File.expand_path(ARGV[1] || "build/ci/short_drama_mvp_handoff_bundle.md", ROOT_DIR)
OUT_JSON = File.expand_path(ARGV[2] || "build/ci/short_drama_mvp_handoff_bundle.json", ROOT_DIR)

def read_json(path)
  JSON.parse(File.read(path, encoding: "UTF-8"))
rescue Errno::ENOENT, JSON::ParserError => e
  {
    "status" => "missing",
    "error" => e.message,
    "path" => path
  }
end

def array_values(value)
  value.is_a?(Array) ? value : []
end

def hash_value(value)
  value.is_a?(Hash) ? value : {}
end

def relative_path(path)
  path.to_s.sub(%r{\A#{Regexp.escape(ROOT_DIR)}/?}, "")
end

def handoff_file_metadata(label, path)
  metadata = {
    "label" => label,
    "path" => path,
    "relative_path" => relative_path(path),
    "exists" => File.exist?(path)
  }
  if File.file?(path)
    metadata.merge(
      "kind" => "file",
      "size_bytes" => File.size(path),
      "sha256" => Digest::SHA256.file(path).hexdigest
    )
  elsif File.directory?(path)
    file_count = Dir.glob(File.join(path, "**", "*"), File::FNM_DOTMATCH).count do |entry|
      File.file?(entry)
    end
    metadata.merge(
      "kind" => "directory",
      "file_count" => file_count
    )
  else
    metadata.merge("kind" => "missing")
  end
end

def todo_phase(kind)
  case kind.to_s
  when /machine|rerun_acceptance/
    "machine_gate"
  when /provider/
    "provider_smoke"
  when /manual|package_manual/
    "manual_smoke"
  when /sensitive|redact|evidence/
    "evidence"
  when /release/
    "release"
  else
    "handoff"
  end
end

def todo_command(kind)
  case kind.to_s
  when /provider/
    "Fill provider-api-smoke-template.json with redacted evidence, then run short_drama_mvp_smoke_evidence_report.rb."
  when /manual|package_manual/
    "Fill manual-smoke-results-template.json with pass/fail evidence, then run short_drama_mvp_smoke_evidence_report.rb."
  when /sensitive|redact|evidence/
    "Redact blocked evidence values, then rerun short_drama_mvp_smoke_evidence_report.rb."
  when /release/
    "Review short_drama_mvp_handoff_bundle.md and release from the tagged commit only after CI is green."
  else
    "Run scripts/run_tests.sh, then regenerate short_drama_mvp_acceptance_report.rb and short_drama_mvp_handoff_bundle.rb."
  end
end

def todo_verification_command(kind)
  case kind.to_s
  when /provider|manual|sensitive|redact|evidence/
    "ruby scripts/short_drama_mvp_smoke_evidence_report.rb build/ci/short_drama_mvp_tryout_package build/ci/short_drama_mvp_smoke_evidence_report.md build/ci/short_drama_mvp_smoke_evidence_report.json"
  when /release/
    "ruby scripts/short_drama_mvp_handoff_bundle_contract_test.rb build/ci/short_drama_mvp_handoff_bundle_contract_report.md build/ci/short_drama_mvp_handoff_bundle_contract_report.json"
  else
    "scripts/run_tests.sh"
  end
end

def todo_evidence_labels(kind)
  case kind.to_s
  when /provider/
    ["Provider API smoke JSON", "Provider API smoke Markdown", "Smoke evidence redaction guide", "Smoke evidence report JSON"]
  when /manual|package_manual/
    ["Manual smoke results JSON", "Manual smoke results Markdown", "Manual smoke checklist", "Smoke evidence report JSON"]
  when /sensitive|redact|evidence/
    ["Smoke evidence redaction guide", "Smoke evidence report JSON", "Smoke evidence contract JSON"]
  when /release/
    ["Handoff index JSON", "Acceptance runbook JSON", "Smoke evidence report JSON", "Cutoff", "Tryout guide", "Manual queue"]
  else
    ["Version report", "Smoke evidence report JSON", "Smoke evidence contract JSON", "Cutoff"]
  end
end

def todo_evidence_paths(kind, evidence_by_label)
  todo_evidence_labels(kind).map do |label|
    path = evidence_by_label[label].to_s
    next if path.empty?

    {
      "label" => label,
      "path" => path,
      "relative_path" => relative_path(path)
    }
  end.compact
end

def todo_payload(kind, title:, detail:, items:, evidence_by_label:)
  {
    "phase" => todo_phase(kind),
    "kind" => kind,
    "title" => title,
    "detail" => detail,
    "command" => todo_command(kind),
    "verification_command" => todo_verification_command(kind),
    "evidence_paths" => todo_evidence_paths(kind, evidence_by_label),
    "items" => items
  }
end

def build_handoff_todos(machine_passed:, ready_for_release:, next_actions:, handoff_files:, evidence_by_label:)
  todos = []
  if ready_for_release
    todos << todo_payload(
      "release_candidate_handoff",
      title: "Hand off release candidate",
      detail: "Machine gates passed and smoke evidence is complete; verify CI and tagged commit before release.",
      items: handoff_files.map { |item| item["relative_path"].to_s }.reject(&:empty?),
      evidence_by_label: evidence_by_label
    ).merge("phase" => "release")
  elsif machine_passed
    next_actions.each do |action|
      kind = action["kind"].to_s
      todos << todo_payload(
        kind,
        title: action["title"].to_s,
        detail: action["detail"].to_s,
        items: array_values(action["items"]),
        evidence_by_label: evidence_by_label
      )
    end
  else
    todos << todo_payload(
      "fix_machine_acceptance",
      title: "Fix machine acceptance before handoff",
      detail: "The acceptance report did not pass; fix failing checks before using this as a trial package.",
      items: [ACCEPTANCE_JSON],
      evidence_by_label: evidence_by_label
    ).merge("phase" => "machine_gate")
  end

  unless ready_for_release
    todos << {
      "phase" => "verify",
      "kind" => "regenerate_acceptance_and_handoff",
      "title" => "Regenerate acceptance and handoff bundle",
      "detail" => "After evidence changes, regenerate the acceptance report and handoff bundle so the JSON/Markdown artifacts match the current package.",
      "command" => "ruby scripts/short_drama_mvp_acceptance_report.rb build/ci/short_drama_mvp_acceptance_report.md build/ci/short_drama_mvp_acceptance_report.json && ruby scripts/short_drama_mvp_handoff_bundle.rb build/ci/short_drama_mvp_acceptance_report.json build/ci/short_drama_mvp_handoff_bundle.md build/ci/short_drama_mvp_handoff_bundle.json",
      "verification_command" => "ruby scripts/short_drama_mvp_handoff_bundle_contract_test.rb build/ci/short_drama_mvp_handoff_bundle_contract_report.md build/ci/short_drama_mvp_handoff_bundle_contract_report.json",
      "evidence_paths" => todo_evidence_paths("verify", evidence_by_label),
      "items" => ["build/ci/short_drama_mvp_acceptance_report.json", "build/ci/short_drama_mvp_handoff_bundle.json"]
    }
  end

  todos.each_with_index.map { |todo, index| todo.merge("order" => index + 1) }
end

def build_handoff_todo_summary(todos)
  phases = todos.each_with_object(Hash.new(0)) do |todo, result|
    result[todo["phase"].to_s] += 1
  end
  {
    "total_count" => todos.length,
    "phase_counts" => phases.sort.to_h,
    "manual_smoke_count" => phases["manual_smoke"].to_i,
    "provider_smoke_count" => phases["provider_smoke"].to_i,
    "verify_count" => phases["verify"].to_i,
    "release_count" => phases["release"].to_i,
    "evidence_path_count" => todos.sum { |todo| array_values(todo["evidence_paths"]).length },
    "verification_command_count" => todos.count { |todo| !todo["verification_command"].to_s.empty? },
    "missing_evidence_path_todo_count" => todos.count { |todo| array_values(todo["evidence_paths"]).empty? },
    "machine_replay_required" => todos.any? { |todo| todo["phase"].to_s == "verify" },
    "release_ready_todo_present" => todos.any? { |todo| todo["phase"].to_s == "release" }
  }
end

acceptance = read_json(ACCEPTANCE_JSON)
handoff_readiness = hash_value(acceptance["handoff_readiness"])
pending_reasons = array_values(acceptance["handoff_pending_reasons"])
remaining_risks = array_values(acceptance["remaining_risks"])
evidence = array_values(acceptance["evidence"])
checks = array_values(acceptance["checks"])
smoke_next_actions = array_values(acceptance["smoke_evidence_next_actions"])
handoff_index = hash_value(acceptance["handoff_index"])
acceptance_runbook = hash_value(acceptance["acceptance_runbook"])

machine_status = handoff_readiness["machine_status"].to_s
manual_status = handoff_readiness["manual_status"].to_s
overall = handoff_readiness["overall"].to_s
machine_passed = acceptance["status"].to_s == "pass" && checks.all? { |check| check["ok"] }
ready_for_release = machine_passed && overall == "ready"
trial_package = machine_passed && %w[manual_pending manual_failed blocked].include?(overall)
handoff_mode =
  if ready_for_release
    "ready_release_candidate"
  elsif trial_package
    "trial_package_with_explicit_pending_reasons"
  else
    "blocked_machine_handoff"
  end

required_evidence_labels = [
  "Tryout package",
  "Handoff index Markdown",
  "Handoff index JSON",
  "Acceptance runbook Markdown",
  "Acceptance runbook JSON",
  "Manual smoke results JSON",
  "Provider API smoke JSON",
  "Smoke evidence report JSON",
  "Smoke evidence contract JSON",
  "Cutoff",
  "Tryout guide",
  "Manual queue"
]

evidence_by_label = evidence.to_h { |item| [item["label"].to_s, item["path"].to_s] }
missing_evidence_labels = required_evidence_labels.reject do |label|
  path = evidence_by_label[label].to_s
  !path.empty? && File.exist?(path)
end

handoff_files = required_evidence_labels.map do |label|
  path = evidence_by_label[label].to_s
  next if path.empty?

  handoff_file_metadata(label, path)
end.compact

blocking_items = []
unless machine_passed
  failed_checks = checks.reject { |check| check["ok"] }.map { |check| check["name"].to_s }
  blocking_items << {
    "severity" => "high",
    "kind" => "machine_checks_failed",
    "title" => "Fix failing machine checks",
    "items" => failed_checks.empty? ? [acceptance["error"].to_s].reject(&:empty?) : failed_checks
  }
end
unless missing_evidence_labels.empty?
  blocking_items << {
    "severity" => "high",
    "kind" => "handoff_evidence_missing",
    "title" => "Regenerate missing handoff evidence files",
    "items" => missing_evidence_labels
  }
end
if %w[manual_failed blocked].include?(overall)
  blocking_items << {
    "severity" => "high",
    "kind" => "handoff_not_release_ready",
    "title" => "Resolve non-ready handoff state",
    "items" => pending_reasons.map { |reason| reason["title"].to_s }.reject(&:empty?)
  }
end

next_actions = []
if ready_for_release
  next_actions << {
    "priority" => "low",
    "kind" => "release_candidate_ready",
    "title" => "Release candidate can be handed off as ready",
    "detail" => "Machine gates passed, manual/provider smoke evidence is complete, and no blocking risk is reported."
  }
elsif machine_passed
  pending_reasons.each do |reason|
    next_actions << {
      "priority" => reason["severity"].to_s.empty? ? "medium" : reason["severity"].to_s,
      "kind" => reason["kind"].to_s,
      "title" => reason["title"].to_s,
      "detail" => reason["detail"].to_s,
      "items" => array_values(reason["items"])
    }
  end
else
  next_actions << {
    "priority" => "high",
    "kind" => "rerun_acceptance",
    "title" => "Fix acceptance report before handoff",
    "detail" => "The acceptance report is missing or failed; run scripts/run_tests.sh or regenerate the short-drama reports.",
    "items" => [ACCEPTANCE_JSON]
  }
end

next_actions.concat(
  smoke_next_actions.map do |action|
    {
      "priority" => action["priority"].to_s,
      "kind" => "smoke_evidence_#{action["kind"]}",
      "title" => action["title"].to_s,
      "detail" => action["detail"].to_s,
      "items" => array_values(action["items"])
    }
  end
)

handoff_todos = build_handoff_todos(
  machine_passed: machine_passed,
  ready_for_release: ready_for_release,
  next_actions: next_actions,
  handoff_files: handoff_files,
  evidence_by_label: evidence_by_label
)
handoff_todo_summary = build_handoff_todo_summary(handoff_todos)

checks_for_bundle = [
  {
    "name" => "acceptance report is readable",
    "ok" => acceptance["status"].to_s != "missing",
    "detail" => "short_drama_mvp_handoff_bundle reads the acceptance JSON."
  },
  {
    "name" => "acceptance machine checks passed",
    "ok" => machine_passed,
    "detail" => "Acceptance report status is pass and every embedded check is ok."
  },
  {
    "name" => "handoff readiness is explicit",
    "ok" => %w[ready manual_pending manual_failed blocked].include?(overall),
    "detail" => "Handoff bundle must not hide readiness behind a generic pass/fail."
  },
  {
    "name" => "handoff evidence files exist",
    "ok" => missing_evidence_labels.empty?,
    "detail" => "Required handoff files should exist before uploading CI artifacts."
  },
  {
    "name" => "remaining risks are preserved",
    "ok" => remaining_risks.any?,
    "detail" => "The bundle should keep external API/manual smoke risks visible."
  },
  {
    "name" => "handoff file fingerprints are generated",
    "ok" => handoff_files.any? &&
            handoff_files.select { |item| item["kind"] == "file" }.all? do |item|
              item["size_bytes"].is_a?(Integer) && item["size_bytes"].positive? &&
                item["sha256"].to_s.match?(/\A[0-9a-f]{64}\z/)
            end &&
            handoff_files.select { |item| item["kind"] == "directory" }.all? do |item|
              item["file_count"].is_a?(Integer) && item["file_count"].positive?
            end,
    "detail" => "Handoff files should include file sizes, SHA-256 hashes, or directory file counts for artifact traceability."
  },
  {
    "name" => "handoff todos are generated",
    "ok" => handoff_todos.any? &&
            handoff_todos.all? do |todo|
              todo["order"].is_a?(Integer) &&
                !todo["phase"].to_s.empty? &&
                !todo["kind"].to_s.empty? &&
                !todo["title"].to_s.empty? &&
                !todo["command"].to_s.empty? &&
                !todo["verification_command"].to_s.empty? &&
                array_values(todo["evidence_paths"]).any?
            end &&
            (ready_for_release || handoff_todos.any? { |todo| todo["phase"] == "verify" }),
    "detail" => "Handoff bundle should convert readiness and smoke evidence next actions into ordered operator todos with evidence paths and verification commands."
  },
  {
    "name" => "handoff todo summary is generated",
    "ok" => handoff_todo_summary["total_count"] == handoff_todos.length &&
            handoff_todo_summary["evidence_path_count"].is_a?(Integer) &&
            handoff_todo_summary["evidence_path_count"].positive? &&
            handoff_todo_summary["verification_command_count"] == handoff_todos.length &&
            handoff_todo_summary["missing_evidence_path_todo_count"].zero? &&
            (ready_for_release || handoff_todo_summary["machine_replay_required"] == true),
    "detail" => "Handoff bundle should summarize operator todo counts, evidence coverage, and replay requirements."
  },
  {
    "name" => "runbook and handoff index are included",
    "ok" => array_values(handoff_index["start_here"]).any? &&
            array_values(acceptance_runbook["commands"]).any?,
    "detail" => "The bundle should point at the package-local handoff index and acceptance runbook."
  }
]

bundle_pass = checks_for_bundle.all? { |check| check["ok"] }
report = {
  "status" => bundle_pass ? "pass" : "fail",
  "generated_at" => Time.now.utc.iso8601,
  "version" => acceptance["version"].to_s,
  "acceptance_report_path" => ACCEPTANCE_JSON,
  "handoff_mode" => handoff_mode,
  "ready_for_release" => ready_for_release,
  "machine_passed" => machine_passed,
  "readiness" => {
    "machine_status" => machine_status,
    "manual_status" => manual_status,
    "overall" => overall,
    "note" => handoff_readiness["note"].to_s
  },
  "checks" => checks_for_bundle,
  "blocking_items" => blocking_items,
  "next_actions" => next_actions,
  "handoff_todo_summary" => handoff_todo_summary,
  "handoff_todos" => handoff_todos,
  "handoff_files" => handoff_files,
  "remaining_risks" => remaining_risks
}

FileUtils.mkdir_p(File.dirname(OUT_JSON))
FileUtils.mkdir_p(File.dirname(OUT_MD))
File.write(OUT_JSON, "#{JSON.pretty_generate(report)}\n")
File.write(
  OUT_MD,
  [
    "# Short Drama MVP Handoff Bundle",
    "",
    "**Status:** #{report.fetch("status")}",
    "",
    "- Version: `#{report.fetch("version")}`",
    "- Handoff mode: #{handoff_mode}",
    "- Ready for release: #{ready_for_release}",
    "- Machine passed: #{machine_passed}",
    "- Overall readiness: #{overall}",
    "- Acceptance report: `#{ACCEPTANCE_JSON}`",
    "",
    "## Checks",
    "",
    *checks_for_bundle.map { |check| "- #{check.fetch("ok") ? "[x]" : "[ ]"} #{check.fetch("name")} — #{check.fetch("detail")}" },
    "",
    "## Blocking Items",
    "",
    *(blocking_items.empty? ? ["- No blocking machine items."] : blocking_items.flat_map do |item|
      [
        "- [#{item.fetch("severity")}] #{item.fetch("title")} (#{item.fetch("kind")})",
        *array_values(item["items"]).map { |entry| "  - #{entry}" }
      ]
    end),
    "",
    "## Handoff Todos",
    "",
    "- Total: #{handoff_todo_summary.fetch("total_count")}",
    "- Phase counts: #{handoff_todo_summary.fetch("phase_counts").map { |phase, count| "#{phase}=#{count}" }.join(", ")}",
    "- Evidence paths: #{handoff_todo_summary.fetch("evidence_path_count")}",
    "- Verification commands: #{handoff_todo_summary.fetch("verification_command_count")}",
    "- Machine replay required: #{handoff_todo_summary.fetch("machine_replay_required")}",
    "- Release todo present: #{handoff_todo_summary.fetch("release_ready_todo_present")}",
    "",
    *handoff_todos.flat_map do |todo|
      [
        "- #{todo.fetch("order")}. [#{todo.fetch("phase")}] #{todo.fetch("title")} (#{todo.fetch("kind")}) — #{todo.fetch("detail")}",
        "  - Command: `#{todo.fetch("command")}`",
        "  - Verify: `#{todo.fetch("verification_command")}`",
        *array_values(todo["evidence_paths"]).map { |item| "  - Evidence: #{item.fetch("label")}: `#{item.fetch("path")}`" },
        *array_values(todo["items"]).map { |item| "  - #{item}" }
      ]
    end,
    "",
    "## Next Actions",
    "",
    *next_actions.flat_map do |action|
      [
        "- [#{action.fetch("priority")}] #{action.fetch("title")} — #{action.fetch("detail")}",
        *array_values(action["items"]).map { |item| "  - #{item}" }
      ]
    end,
    "",
    "## Handoff Files",
    "",
    *handoff_files.map do |item|
      suffix =
        if item["kind"] == "file"
          "size=#{item["size_bytes"]} sha256=#{item["sha256"].to_s[0, 12]}"
        elsif item["kind"] == "directory"
          "files=#{item["file_count"]}"
        else
          "missing"
        end
      "- #{item.fetch("label")}: `#{item.fetch("path")}` #{suffix}"
    end,
    "",
    "## Remaining Risks",
    "",
    *remaining_risks.map { |risk| "- #{risk}" },
    ""
  ].join("\n")
)

puts "short_drama_mvp_handoff_bundle: #{report.fetch("status")} mode=#{handoff_mode} ready=#{ready_for_release}"
exit(bundle_pass ? 0 : 1)
