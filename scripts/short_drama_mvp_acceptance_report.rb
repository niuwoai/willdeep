#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "time"

ROOT_DIR = File.expand_path("..", __dir__)
REPORT_MD = File.expand_path(ARGV[0] || "build/ci/short_drama_mvp_acceptance_report.md", ROOT_DIR)
REPORT_JSON = File.expand_path(ARGV[1] || "build/ci/short_drama_mvp_acceptance_report.json", ROOT_DIR)
REPORT_DIR = File.dirname(REPORT_JSON)

def read_text(relative)
  File.read(File.join(ROOT_DIR, relative), encoding: "UTF-8")
end

def read_json_file(path)
  JSON.parse(File.read(path, encoding: "UTF-8"))
rescue Errno::ENOENT, JSON::ParserError => e
  { "status" => "missing", "error" => e.message, "path" => path }
end

def semver_sort_key(version)
  core, rc = version.split("-rc", 2)
  major, minor, patch = core.split(".").map(&:to_i)
  [major, minor, patch, rc ? 0 : 1, rc.to_i]
end

def add_check(checks, name, ok, detail, path = nil)
  checks << {
    "name" => name,
    "ok" => ok,
    "detail" => detail,
    "path" => path
  }.compact
end

def extract_manual_section(source, version)
  return "" if version.empty?

  match = source.match(/^##\s+#{Regexp.escape(version)}\s+—\s+短剧.*?(?=^##\s|\z)/m)
  match ? match[0] : ""
end

def manual_item_titles(section, marker)
  section.scan(/^- #{Regexp.escape(marker)}\s+(.+?)(?:\n\s{2}.+?)*$/).flatten.map do |item|
    item.gsub(/\s+→.*/, "").strip
  end
end

def normalize_manual_result_status(status)
  normalized = status.to_s.strip.downcase
  return "pass" if %w[pass passed ok success].include?(normalized)
  return "fail" if %w[fail failed error].include?(normalized)
  return "pending" if %w[pending blocked].include?(normalized)

  "untested"
end

def manual_results_summary(path)
  data = read_json_file(path)
  steps = Array(data["steps"])
  statuses = steps.map { |step| normalize_manual_result_status(step["status"]) }
  evidence_required_steps = steps.select do |step|
    %w[pass fail].include?(normalize_manual_result_status(step["status"]))
  end
  evidence_present_steps = evidence_required_steps.select { |step| !step["evidence"].to_s.strip.empty? }
  evidence_missing_steps = evidence_required_steps - evidence_present_steps
  failed_items = steps.select { |step| normalize_manual_result_status(step["status"]) == "fail" }
                      .map { |step| step["title"].to_s.empty? ? step["id"].to_s : step["title"].to_s }
  pending_items = steps.select { |step| %w[pending untested].include?(normalize_manual_result_status(step["status"])) }
                       .map { |step| step["title"].to_s.empty? ? step["id"].to_s : step["title"].to_s }
  evidence_missing_items = evidence_missing_steps.map do |step|
    step["title"].to_s.empty? ? step["id"].to_s : step["title"].to_s
  end

  {
    "path" => path,
    "schema" => data["schema"].to_s,
    "overall_status" => normalize_manual_result_status(data["overall_status"]),
    "step_count" => steps.length,
    "passed_count" => statuses.count("pass"),
    "pending_count" => statuses.count("pending") + statuses.count("untested"),
    "failed_count" => statuses.count("fail"),
    "pending_items" => pending_items,
    "failed_items" => failed_items,
    "evidence_required_count" => evidence_required_steps.length,
    "evidence_present_count" => evidence_present_steps.length,
    "evidence_missing_count" => evidence_missing_steps.length,
    "evidence_missing_items" => evidence_missing_items
  }
end

def provider_api_smoke_summary(path)
  data = read_json_file(path)
  steps = Array(data["steps"])
  statuses = steps.map { |step| normalize_manual_result_status(step["status"]) }
  evidence_required_steps = steps.select do |step|
    %w[pass fail].include?(normalize_manual_result_status(step["status"]))
  end
  evidence_present_steps = evidence_required_steps.select { |step| !step["evidence"].to_s.strip.empty? }
  evidence_missing_steps = evidence_required_steps - evidence_present_steps
  failed_items = steps.select { |step| normalize_manual_result_status(step["status"]) == "fail" }
                      .map { |step| step["title"].to_s.empty? ? step["id"].to_s : step["title"].to_s }
  evidence_missing_items = evidence_missing_steps.map do |step|
    step["title"].to_s.empty? ? step["id"].to_s : step["title"].to_s
  end

  {
    "path" => path,
    "schema" => data["schema"].to_s,
    "overall_status" => normalize_manual_result_status(data["overall_status"]),
    "step_count" => steps.length,
    "provider_count" => steps.map { |step| step["provider"].to_s }.reject(&:empty?).uniq.length,
    "providers" => steps.map { |step| step["provider"].to_s }.reject(&:empty?).uniq.sort,
    "capabilities" => steps.map { |step| step["capability"].to_s }.reject(&:empty?).uniq.sort,
    "passed_count" => statuses.count("pass"),
    "pending_count" => statuses.count("pending") + statuses.count("untested"),
    "failed_count" => statuses.count("fail"),
    "failed_items" => failed_items,
    "evidence_required_count" => evidence_required_steps.length,
    "evidence_present_count" => evidence_present_steps.length,
    "evidence_missing_count" => evidence_missing_steps.length,
    "evidence_missing_items" => evidence_missing_items
  }
end

def extract_section_bullets(source, heading)
  section = source.match(/^##\s+#{Regexp.escape(heading)}\n\n(?<body>.*?)(?=^##\s|\z)/m)
  return [] unless section

  section[:body].scan(/^- (.+)$/).flatten.map(&:strip)
end

version_report_path = File.join(REPORT_DIR, "version_report.json")
tryout_report_path = File.join(REPORT_DIR, "short_drama_mvp_tryout_package_report.json")
version_report = read_json_file(version_report_path)
tryout_report = read_json_file(tryout_report_path)
cutoff = read_text("docs/SHORT_DRAMA_AI_MVP_CUTOFF.md")
tryout = read_text("docs/SHORT_DRAMA_AI_MVP_TRYOUT.md")
manual_queue = read_text("docs/MANUAL_TEST_QUEUE.md")

canonical_version = version_report["canonical_version"].to_s
manual_versions = manual_queue.scan(/^##\s+(\d+\.\d+\.\d+(?:-rc\d+)?)\s+—\s+短剧/m).flatten
latest_manual_version = manual_versions.max_by { |version| semver_sort_key(version) }
current_manual_section = extract_manual_section(manual_queue, canonical_version)
delivery_gate_names = Array(version_report["delivery_checks"]).map { |check| check["name"].to_s }
tryout_checks = Array(tryout_report["checks"])
manual_result_paths = [
  tryout_report["manual_smoke_results_md_path"],
  tryout_report["manual_smoke_results_json_path"]
].compact
provider_api_smoke_paths = [
  tryout_report["provider_api_smoke_md_path"],
  tryout_report["provider_api_smoke_json_path"]
].compact
handoff_index_paths = [
  tryout_report["handoff_index_md_path"],
  tryout_report["handoff_index_json_path"]
].compact
manual_results_json_path = tryout_report["manual_smoke_results_json_path"].to_s
manual_result_summary = manual_results_summary(manual_results_json_path)
manual_evidence_summary = {
  "required_count" => manual_result_summary.fetch("evidence_required_count"),
  "present_count" => manual_result_summary.fetch("evidence_present_count"),
  "missing_count" => manual_result_summary.fetch("evidence_missing_count"),
  "missing_items" => manual_result_summary.fetch("evidence_missing_items")
}
provider_api_smoke_json_path = tryout_report["provider_api_smoke_json_path"].to_s
provider_api_smoke = provider_api_smoke_summary(provider_api_smoke_json_path)
smoke_evidence_report_path = tryout_report["smoke_evidence_report_json_path"].to_s
smoke_evidence_report = read_json_file(smoke_evidence_report_path)
smoke_evidence_readiness = smoke_evidence_report.fetch("readiness", {})
smoke_evidence_next_actions = Array(smoke_evidence_report["next_actions"])
smoke_evidence_sensitive_findings = Array(smoke_evidence_report["sensitive_findings"])
handoff_index_json_path = tryout_report["handoff_index_json_path"].to_s
handoff_index = read_json_file(handoff_index_json_path)
remaining_risks = extract_section_bullets(cutoff, "当前剩余风险")

checks = []
add_check(
  checks,
  "version report passes",
  version_report["failures"].is_a?(Array) && version_report["failures"].empty? && !canonical_version.empty?,
  "version_report.json should pass and expose canonical_version.",
  version_report_path
)
add_check(
  checks,
  "delivery gates include manual smoke result templates",
  delivery_gate_names.include?("Tryout package preserves manual smoke result templates"),
  "version consistency should guard the tryout package manual smoke result templates.",
  version_report_path
)
add_check(
  checks,
  "delivery gates include handoff readiness summary",
  delivery_gate_names.include?("Short drama acceptance report preserves handoff readiness summary"),
  "version consistency should guard handoff readiness and remaining-risk summary output.",
  version_report_path
)
add_check(
  checks,
  "tryout package report passes",
  tryout_report["status"] == "pass" && tryout_checks.all? { |check| check["ok"] },
  "short_drama_mvp_tryout_package_report.json should pass all package checks.",
  tryout_report_path
)
add_check(
  checks,
  "tryout package exposes manual smoke result files",
  manual_result_paths.length == 2 && manual_result_paths.all? { |path| File.file?(path) },
  "tryout package should include Markdown and JSON manual smoke result templates.",
  manual_result_paths.join(", ")
)
add_check(
  checks,
  "tryout package exposes provider API smoke templates",
  provider_api_smoke_paths.length == 2 && provider_api_smoke_paths.all? { |path| File.file?(path) },
  "tryout package should include Markdown and JSON templates for optional real some.im / Replicate smoke evidence.",
  provider_api_smoke_paths.join(", ")
)
add_check(
  checks,
  "tryout package exposes handoff index",
  handoff_index_paths.length == 2 &&
    handoff_index_paths.all? { |path| File.file?(path) } &&
    handoff_index["schema"] == "willdeep.short_drama.tryout_handoff_index.v1" &&
    Array(handoff_index["start_here"]).length >= 5,
  "tryout package should include Markdown and JSON handoff index files with ordered start-here steps.",
  handoff_index_paths.join(", ")
)
add_check(
  checks,
  "manual smoke results JSON is summarized",
  manual_result_summary.fetch("schema") == "willdeep.short_drama.manual_smoke_results.v1" &&
    manual_result_summary.fetch("step_count").positive?,
  "acceptance report should parse the tryout package manual smoke results JSON so filled pass/fail evidence is visible during handoff.",
  manual_results_json_path
)
add_check(
  checks,
  "manual smoke evidence is summarized",
  manual_evidence_summary.fetch("missing_count").is_a?(Integer) &&
    manual_evidence_summary.fetch("required_count").is_a?(Integer),
  "acceptance report should count pass/fail manual smoke steps that still need evidence.",
  manual_results_json_path
)
add_check(
  checks,
  "provider API smoke template is summarized",
  provider_api_smoke.fetch("schema") == "willdeep.short_drama.provider_api_smoke.v1" &&
    provider_api_smoke.fetch("provider_count") >= 2 &&
    provider_api_smoke.fetch("capabilities").include?("video_generation") &&
    provider_api_smoke.fetch("capabilities").include?("image_inpaint"),
  "acceptance report should keep optional real provider smoke coverage visible without calling external APIs.",
  provider_api_smoke_json_path
)
add_check(
  checks,
  "provider API smoke evidence is summarized",
  provider_api_smoke.fetch("evidence_missing_count").is_a?(Integer) &&
    provider_api_smoke.fetch("evidence_required_count").is_a?(Integer),
  "acceptance report should count filled provider smoke pass/fail rows that still need evidence.",
  provider_api_smoke_json_path
)
add_check(
  checks,
  "smoke evidence report is generated",
  smoke_evidence_report["status"] == "pass" &&
    %w[ready manual_pending manual_failed blocked].include?(smoke_evidence_readiness["overall"].to_s) &&
    !smoke_evidence_next_actions.empty?,
  "acceptance report should read the standalone smoke evidence report so handoff users can verify filled manual/provider JSON without external API calls.",
  smoke_evidence_report_path
)
add_check(
  checks,
  "smoke evidence sensitive guard is summarized",
  smoke_evidence_report.key?("sensitive_findings") &&
    smoke_evidence_readiness.key?("sensitive_evidence_count") &&
    smoke_evidence_sensitive_findings.length == smoke_evidence_readiness["sensitive_evidence_count"].to_i,
  "acceptance report should expose whether manual/provider smoke evidence contains API keys, bearer tokens, webhook secrets, signed URLs, or private callback URLs.",
  smoke_evidence_report_path
)
add_check(
  checks,
  "cutoff documents manual smoke evidence path",
  cutoff.include?("manual-smoke-results-template.md/json"),
  "SHORT_DRAMA_AI_MVP_CUTOFF.md should tell handoff users where to record manual smoke evidence.",
  "docs/SHORT_DRAMA_AI_MVP_CUTOFF.md"
)
add_check(
  checks,
  "cutoff keeps explicit remaining risks",
  !remaining_risks.empty?,
  "SHORT_DRAMA_AI_MVP_CUTOFF.md should keep at least one explicit remaining-risk bullet so handoff cannot silently imply zero risk.",
  "docs/SHORT_DRAMA_AI_MVP_CUTOFF.md"
)
add_check(
  checks,
  "tryout points at latest manual queue section",
  !canonical_version.empty? &&
    tryout.include?("`#{canonical_version} —") &&
    latest_manual_version == canonical_version,
  "SHORT_DRAMA_AI_MVP_TRYOUT.md and MANUAL_TEST_QUEUE.md should agree on the current short-drama smoke section.",
  "docs/SHORT_DRAMA_AI_MVP_TRYOUT.md"
)
add_check(
  checks,
  "manual queue lists current short-drama handoff",
  !canonical_version.empty? &&
    current_manual_section.include?("## #{canonical_version} — 短剧"),
  "MANUAL_TEST_QUEUE.md should include the current short-drama handoff section.",
  "docs/MANUAL_TEST_QUEUE.md"
)

manual_smoke_summary = {
  "section_version" => canonical_version,
  "passed_count" => manual_item_titles(current_manual_section, "✅").length,
  "pending_count" => manual_item_titles(current_manual_section, "⏳").length,
  "failed_count" => manual_item_titles(current_manual_section, "❌").length,
  "pending_items" => manual_item_titles(current_manual_section, "⏳")
}

provider_api_smoke_evidence_missing = provider_api_smoke.fetch("evidence_missing_count").positive?
smoke_evidence_blocked = smoke_evidence_readiness["overall"].to_s == "blocked" ||
                         smoke_evidence_readiness["sensitive_evidence_count"].to_i.positive?
ok = checks.all? { |check| check.fetch("ok") }
manual_status =
  if smoke_evidence_blocked
    "blocked"
  elsif manual_smoke_summary.fetch("failed_count").positive? ||
     manual_result_summary.fetch("failed_count").positive? ||
     provider_api_smoke.fetch("failed_count").positive?
    "failed"
  elsif manual_smoke_summary.fetch("pending_count").positive? ||
        manual_result_summary.fetch("pending_count").positive? ||
        manual_evidence_summary.fetch("missing_count").positive? ||
        provider_api_smoke_evidence_missing ||
        smoke_evidence_readiness["overall"].to_s == "manual_pending" ||
        manual_result_summary.fetch("overall_status") != "pass"
    "pending"
  else
    "pass"
  end
handoff_overall =
  if !ok
    "blocked"
  elsif manual_status == "blocked"
    "blocked"
  elsif manual_status == "failed"
    "manual_failed"
  elsif manual_status == "pending"
    "manual_pending"
  else
    "ready"
  end
handoff_readiness = {
  "machine_status" => ok ? "pass" : "fail",
  "manual_status" => manual_status,
  "overall" => handoff_overall,
  "note" => "CI and local contract gates can pass while manual smoke remains pending; use overall to decide handoff readiness."
}
evidence = [
  { "label" => "Version report", "path" => File.join(REPORT_DIR, "version_report.md") },
  { "label" => "Tryout package report", "path" => File.join(REPORT_DIR, "short_drama_mvp_tryout_package_report.md") },
  { "label" => "Tryout package", "path" => tryout_report["package_directory"] },
  { "label" => "Manual smoke checklist", "path" => tryout_report["manual_smoke_checklist_path"] },
  { "label" => "Manual smoke results Markdown", "path" => tryout_report["manual_smoke_results_md_path"] },
  { "label" => "Manual smoke results JSON", "path" => tryout_report["manual_smoke_results_json_path"] },
  { "label" => "Provider API smoke Markdown", "path" => tryout_report["provider_api_smoke_md_path"] },
  { "label" => "Provider API smoke JSON", "path" => tryout_report["provider_api_smoke_json_path"] },
  { "label" => "Handoff index Markdown", "path" => tryout_report["handoff_index_md_path"] },
  { "label" => "Handoff index JSON", "path" => handoff_index_json_path },
  { "label" => "Smoke evidence report Markdown", "path" => tryout_report["smoke_evidence_report_md_path"] },
  { "label" => "Smoke evidence report JSON", "path" => smoke_evidence_report_path },
  { "label" => "Cutoff", "path" => File.join(ROOT_DIR, "docs", "SHORT_DRAMA_AI_MVP_CUTOFF.md") },
  { "label" => "Tryout guide", "path" => File.join(ROOT_DIR, "docs", "SHORT_DRAMA_AI_MVP_TRYOUT.md") },
  { "label" => "Manual queue", "path" => File.join(ROOT_DIR, "docs", "MANUAL_TEST_QUEUE.md") }
]

report = {
  "status" => ok ? "pass" : "fail",
  "generated_at" => Time.now.utc.iso8601,
  "version" => canonical_version,
  "checks" => checks,
  "manual_smoke_summary" => manual_smoke_summary,
  "manual_results_summary" => manual_result_summary,
  "manual_evidence_summary" => manual_evidence_summary,
  "provider_api_smoke_summary" => provider_api_smoke,
  "smoke_evidence_report" => smoke_evidence_report,
  "smoke_evidence_next_actions" => smoke_evidence_next_actions,
  "smoke_evidence_sensitive_findings" => smoke_evidence_sensitive_findings,
  "handoff_index" => handoff_index,
  "handoff_readiness" => handoff_readiness,
  "remaining_risks" => remaining_risks,
  "evidence" => evidence
}

FileUtils.mkdir_p(File.dirname(REPORT_MD))
File.write(REPORT_JSON, "#{JSON.pretty_generate(report)}\n")
File.write(
  REPORT_MD,
  [
    "# Short Drama MVP Acceptance Report",
    "",
    "**Status:** #{ok ? "pass" : "fail"}",
    "",
    "- Version: `#{canonical_version}`",
    "- Generated at: `#{report.fetch("generated_at")}`",
    "- Evidence items: #{evidence.length}",
    "",
    "## Handoff Readiness",
    "",
    "- Machine status: #{handoff_readiness.fetch("machine_status")}",
    "- Manual status: #{handoff_readiness.fetch("manual_status")}",
    "- Overall: #{handoff_readiness.fetch("overall")}",
    "- Note: #{handoff_readiness.fetch("note")}",
    "",
    "## Checks",
    "",
    *checks.map { |check| "- #{check.fetch("ok") ? "[x]" : "[ ]"} #{check.fetch("name")} — #{check.fetch("detail")}" },
    "",
    "## Manual Smoke Status",
    "",
    "- Passed: #{manual_smoke_summary.fetch("passed_count")}",
    "- Pending: #{manual_smoke_summary.fetch("pending_count")}",
    "- Failed: #{manual_smoke_summary.fetch("failed_count")}",
    "",
    *manual_smoke_summary.fetch("pending_items").map { |item| "- Pending: #{item}" },
    "",
    "## Manual Results File",
    "",
    "- Overall status: #{manual_result_summary.fetch("overall_status")}",
    "- Steps: #{manual_result_summary.fetch("step_count")}",
    "- Passed: #{manual_result_summary.fetch("passed_count")}",
    "- Pending or untested: #{manual_result_summary.fetch("pending_count")}",
    "- Failed: #{manual_result_summary.fetch("failed_count")}",
    "- Path: `#{manual_result_summary.fetch("path")}`",
    "",
    *manual_result_summary.fetch("failed_items").map { |item| "- Failed: #{item}" },
    *manual_result_summary.fetch("pending_items").map { |item| "- Pending/untested: #{item}" },
    "",
    "## Manual Evidence",
    "",
    "- Required for pass/fail steps: #{manual_evidence_summary.fetch("required_count")}",
    "- Present: #{manual_evidence_summary.fetch("present_count")}",
    "- Missing: #{manual_evidence_summary.fetch("missing_count")}",
    "",
    *manual_evidence_summary.fetch("missing_items").map { |item| "- Missing evidence: #{item}" },
    "",
    "## Provider API Smoke Templates",
    "",
    "- Overall status: #{provider_api_smoke.fetch("overall_status")}",
    "- Steps: #{provider_api_smoke.fetch("step_count")}",
    "- Providers: #{provider_api_smoke.fetch("providers").join(", ")}",
    "- Capabilities: #{provider_api_smoke.fetch("capabilities").join(", ")}",
    "- Passed: #{provider_api_smoke.fetch("passed_count")}",
    "- Pending or untested: #{provider_api_smoke.fetch("pending_count")}",
    "- Failed: #{provider_api_smoke.fetch("failed_count")}",
    "- Evidence required for pass/fail steps: #{provider_api_smoke.fetch("evidence_required_count")}",
    "- Evidence present: #{provider_api_smoke.fetch("evidence_present_count")}",
    "- Evidence missing: #{provider_api_smoke.fetch("evidence_missing_count")}",
    "- Path: `#{provider_api_smoke.fetch("path")}`",
    "",
    *provider_api_smoke.fetch("failed_items").map { |item| "- Failed provider smoke: #{item}" },
    *provider_api_smoke.fetch("evidence_missing_items").map { |item| "- Missing provider evidence: #{item}" },
    "",
    "## Smoke Evidence Report",
    "",
    "- Status: #{smoke_evidence_report["status"]}",
    "- Overall readiness: #{smoke_evidence_readiness["overall"]}",
    "- Failed steps: #{smoke_evidence_readiness["failed_count"]}",
    "- Missing evidence: #{smoke_evidence_readiness["missing_evidence_count"]}",
    "- Sensitive evidence findings: #{smoke_evidence_readiness["sensitive_evidence_count"]}",
    "- Pending or untested steps: #{smoke_evidence_readiness["pending_count"]}",
    "- Path: `#{smoke_evidence_report_path}`",
    "",
    "## Smoke Evidence Sensitive Guard",
    "",
    "- Sensitive findings: #{smoke_evidence_sensitive_findings.length}",
    "",
    *smoke_evidence_sensitive_findings.map do |finding|
      "- Sensitive evidence: #{finding["step"]} `#{finding["field"]}` #{finding["kind"]} (redacted)"
    end,
    "",
    "## Smoke Evidence Next Actions",
    "",
    *smoke_evidence_next_actions.flat_map do |action|
      [
        "- [#{action["priority"]}] #{action["title"]} — #{action["detail"]}",
        *Array(action["items"]).map { |item| "  - #{item}" }
      ]
    end,
    "",
    "## Handoff Index",
    "",
    "- Schema: #{handoff_index["schema"]}",
    "- Start-here steps: #{Array(handoff_index["start_here"]).length}",
    "- Key files: #{Array(handoff_index["files"]).length}",
    "- Path: `#{handoff_index_json_path}`",
    "",
    *Array(handoff_index["start_here"]).map { |step| "- Step #{step["order"]}: #{step["title"]}" },
    "",
    "## Remaining Risks",
    "",
    *(remaining_risks.empty? ? ["- No remaining risks found in cutoff document."] : remaining_risks.map { |risk| "- #{risk}" }),
    "",
    "## Evidence",
    "",
    *evidence.map { |item| "- #{item.fetch("label")}: `#{item["path"]}`" },
    ""
  ].join("\n")
)

puts "short_drama_mvp_acceptance_report: #{ok ? "pass" : "fail"} version=#{canonical_version} checks=#{checks.length}"
exit(ok ? 0 : 1)
