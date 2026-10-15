#!/usr/bin/env ruby
# frozen_string_literal: true

# Compiles and runs the real native Worker harness without opening the GUI.
# Optional HTTP integration accepts only a local synthetic-session receipt;
# credentials stay in that external 0600 file and are never printed.
require "json"
require "fileutils"
require "optparse"
require "time"
require "open3"

root = File.expand_path("..", __dir__)
options = {}
OptionParser.new do |parser|
  parser.banner = "Usage: ruby scripts/agent_rsi_acceptance.rb [--service-receipt PATH]"
  parser.on("--service-receipt PATH") { |value| options[:receipt] = File.expand_path(value) }
  parser.on("--peer-experiment ID") { |value| options[:peer] = value }
  parser.on("--registry-binary PATH") { |value| options[:registry_binary] = File.expand_path(value) }
  parser.on("-h", "--help") { puts parser; exit }
end.parse!
abort "--registry-binary requires the isolated service receipt" if options[:registry_binary] && !options[:receipt]
directory = File.join(root, "build", "rsi-offline-acceptance")
configuration = File.join(root, "build", "rsi-service-acceptance.json")
FileUtils.mkdir_p(directory, mode: 0o700)
if options[:receipt]
  receipt = JSON.parse(File.read(options[:receipt]))
  abort "Only an isolated localhost fixture is permitted" unless receipt["mock_only"] && receipt["origin"].match?(%r{\Ahttp://(?:127\.0\.0\.1|localhost):\d+\z})
  File.write(configuration, JSON.generate({ receipt_path: options[:receipt], peer_experiment: options[:peer], registry_binary: options[:registry_binary] }), mode: "w", perm: 0o600)
elsif File.exist?(configuration)
  abort "Remove the previous isolated service configuration before running local-only acceptance"
end
started = Time.now
command = ["ruby", File.join(root, "scripts", "run_tests_fast.rb"),
           "-only-testing:XeditTests/AgentRSITests", "-only-testing:XeditTests/AgentDefinitionRegistryTests",
           "-only-testing:XeditTests/AgentRSIWorkerEvidenceTests",
           "-only-testing:XeditTests/AgentRegistryCrossClientTests",
           "-only-testing:XeditTests/AgentRegistryConflictResolutionTests",
           "-only-testing:XeditTests/AgentGoalHostVerificationTests", "-parallel-testing-enabled", "NO", "-jobs", "2"]
success = system(*command, chdir: root)
reports = Dir[File.join(directory, "*", "report.json")].select { |path| File.mtime(path) >= started }
report_path = reports.max_by { |path| File.mtime(path) }
report = report_path && JSON.parse(File.read(report_path))
complete = success && report && report["complete"] == true && report["evidence"].size == 6
http_passed = report_path && File.exist?(File.join(File.dirname(report_path), "service-receipt.json"))
complete &&= http_passed if options[:receipt]
interop = Dir[File.join(root, "build/rsi-registry-interop/*/report.json")].find { |path| File.mtime(path) >= started }
complete &&= interop && JSON.parse(File.read(interop))["passed"] == true if options[:registry_binary]
summary = { schema: "willdeep.agent-rsi.acceptance.v1", passed: !!complete, paid_provider_requests: 0,
            scope: "mock_contract_fidelity_only", native_report: report_path,
            native_evidence_count: report ? report["evidence"].size : 0,
            localhost_service: options[:receipt] ? !!http_passed : "not_requested",
            cross_client_registry_report: interop,
            elapsed_seconds: (Time.now - started).round(3), source_commit: Open3.capture2("git", "rev-parse", "HEAD", chdir: root).first.strip,
            test_report: File.join(root, "build", "fast-tests", "report.json") }
File.write(File.join(directory, "acceptance.json"), JSON.pretty_generate(summary) + "\n")
markdown = "# Mac RSI P4a/P4b 离线验收\n\n通过：#{!!complete}\n\n仅验证原生执行链、共享契约和可选 localhost API；不代表真实模型质量提升。\n\n" \
           "- 真实 Provider 请求：0\n- 原生证据：#{summary[:native_evidence_count]}\n- 本地 HTTP：#{summary[:localhost_service]}\n" \
           "- 原生报告：#{report_path}\n- 测试报告：#{summary[:test_report]}\n"
File.write(File.join(directory, "acceptance.md"), markdown)
File.delete(configuration) if options[:receipt] && File.exist?(configuration)
puts JSON.generate({ passed: !!complete, report: File.join(directory, "acceptance.json") })
exit(complete ? 0 : 1)
