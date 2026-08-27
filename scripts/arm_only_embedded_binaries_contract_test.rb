#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "pathname"
require "time"

repo_root = Pathname(__dir__).parent
project_path = repo_root.join("Xedit.xcodeproj/project.pbxproj")
markdown_path = repo_root.join(ARGV[0] || "build/ci/arm_only_embedded_binaries_contract_test.md")
json_path = repo_root.join(ARGV[1] || "build/ci/arm_only_embedded_binaries_contract_test.json")
project = project_path.read
results = []

check = lambda do |name, condition, detail|
  results << { name: name, ok: condition, detail: detail }
end

phase_name = "Thin embedded executables for ARM-only builds"
phase_reference = "7E2F8B7A2F9E4A1C9E0B1005 /* #{phase_name} */"
target_phase_list = project[/buildPhases = \(.*?\n\s*\);/m].to_s
helper_index = target_phase_list.index("Build WillDeep Computer Use Helper")
thin_index = target_phase_list.index(phase_reference)

check.call(
  "ARM 裁剪阶段位于内置程序构建之后",
  helper_index && thin_index && thin_index > helper_index,
  "helper_index=#{helper_index.inspect}, thin_index=#{thin_index.inspect}"
)
check.call(
  "仅纯 ARM 构建触发裁剪",
  project.include?('requested_archs=\" ${ARCHS:-} \"') &&
    project.include?('!= *\" arm64 \"*') &&
    project.include?('== *\" x86_64 \"*'),
  "通用架构构建必须跳过裁剪"
)
check.call(
  "Agent 与 Computer Use Helper 均裁剪为 arm64",
  project.include?('agent=\"$resources/willdeep-agent\"') &&
    project.include?('helper=\"$helper_app/Contents/MacOS/WillDeepComputerUseHelper\"') &&
    project.include?('/usr/bin/lipo \"$binary\" -thin arm64'),
  "两个嵌入式可执行文件必须共用 arm64 裁剪函数"
)
check.call(
  "裁剪后重新签名并验证 Helper",
  project.include?('/usr/bin/codesign --force --sign') &&
    project.include?('/usr/bin/codesign --verify --deep --strict'),
  "避免裁剪使嵌套 Helper 签名失效"
)

passed = results.count { |result| result[:ok] }
report = {
  generated_at: Time.now.utc.iso8601,
  passed: passed,
  total: results.length,
  results: results
}

markdown_path.dirname.mkpath
json_path.dirname.mkpath
json_path.write(JSON.pretty_generate(report))
markdown_path.write(<<~MARKDOWN)
  # ARM-only embedded binaries contract

  - Result: #{passed}/#{results.length} passed

  #{results.map { |result| "- #{result[:ok] ? 'PASS' : 'FAIL'}: #{result[:name]} — #{result[:detail]}" }.join("\n")}
MARKDOWN

puts JSON.generate(report)
exit(passed == results.length ? 0 : 1)
