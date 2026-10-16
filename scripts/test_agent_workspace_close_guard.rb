#!/usr/bin/env ruby
# frozen_string_literal: true
require "json"
require "fileutils"
require "open3"
require "digest"

root = File.expand_path("..", __dir__)
out = File.join(root, "build/agent-workspace-close-guard")
FileUtils.mkdir_p(out)
source = File.join(root, "Xedit/AgentWorkspaceCloseIntent.swift")
test = File.join(root, "scripts/tests/agent_workspace_close_intent_test.swift")
binary = File.join(out, "probe")
command = ["xcrun", "swiftc", "-parse-as-library", "-module-cache-path", File.join(out, "ModuleCache"), source, test, "-o", binary]
compile_log, compile_status = Open3.capture2e(*command)
File.write(File.join(out, "compile.log"), compile_log)
output, status = compile_status.success? ? Open3.capture2e(binary) : ["", compile_status]
result = status.success? ? JSON.parse(output) : {"passed" => false, "assertions" => 0}
report = result.merge("compile_exit_code" => compile_status.exitstatus, "test_exit_code" => status.exitstatus,
  "production_source_sha256" => Digest::SHA256.file(source).hexdigest,
  "test_source_sha256" => Digest::SHA256.file(test).hexdigest,
  "scope" => "Production close intent state machine; AppKit dialog and draft retention require real UI verification")
File.write(File.join(out, "report.json"), JSON.pretty_generate(report) + "\n")
File.write(File.join(out, "report.md"), "# 工作区关闭意图免费回归\n\n直接编译生产 AgentWorkspaceCloseIntent，无实现副本。\n\n通过：#{report['passed']}；断言：#{report['assertions']}；编译退出码：#{report['compile_exit_code']}；执行退出码：#{report['test_exit_code']}。\n\n覆盖干净关闭、脏编辑确认、取消、明确放弃及不可重复消费、账号变化撤销旧意图。AppKit 窗口代理和文字保留由真实界面另外验收，不能用本测试替代。真实模型请求为零。\n")
puts JSON.generate(report)
exit(report["passed"] == true && report["assertions"] == 18 ? 0 : 1)
