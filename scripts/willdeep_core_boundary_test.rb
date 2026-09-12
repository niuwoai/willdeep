# frozen_string_literal: true
# WillDeepCore 的边界守卫。
#
# 这个包存在的唯一理由是编译与测试成本（见 docs/BUILD_MODULARIZATION_DESIGN.md）。
# 一旦有人往里面塞 SwiftUI、AppKit 或 AppState，它就会重新依赖 App 模块，分层
# 白做，而且不会有任何编译错误来提醒——包仍然编得过，只是不再独立。所以这条
# 靠守卫拦，不靠约定。
require "json"

ROOT = File.expand_path("..", __dir__)
SOURCES = File.join(ROOT, "Packages/WillDeepCore/Sources/WillDeepCore")
TESTS = File.join(ROOT, "Packages/WillDeepCore/Tests/WillDeepCoreTests")

FORBIDDEN = {
  "import SwiftUI" => "包不得依赖 SwiftUI——它一旦进来，包就跟着 App 的 UI 层一起重编。",
  "import AppKit" => "包不得依赖 AppKit，理由同 SwiftUI。",
  "AppState" => "包不得引用 AppState。它是 App 模块的宿主类型，引用它等于反向依赖。",
  "@MainActor" => "包里不写 @MainActor。主工程默认 MainActor 隔离，包里的纯逻辑刻意留在 nonisolated。"
}.freeze

failures = []
checks = []

raise "包源码目录不存在：#{SOURCES}" unless Dir.exist?(SOURCES)

files = Dir.glob(File.join(SOURCES, "*.swift")) + Dir.glob(File.join(TESTS, "*.swift"))
raise "包里一个 swift 文件都没有，守卫失去意义" if files.empty?

files.each do |path|
  body = File.read(path, encoding: "UTF-8")
  # 去掉注释：注释里提到 AppState 是说明设计取舍，不是依赖。
  code = body.gsub(%r{/\*.*?\*/}m, "").lines.map { |line| line.sub(%r{//.*$}, "") }.join
  FORBIDDEN.each do |needle, reason|
    next unless code.include?(needle)
    failures << "#{File.basename(path)} 命中「#{needle}」：#{reason}"
  end
end
checks << { "ok" => failures.empty?, "message" => "包内 #{files.length} 个文件均无 SwiftUI / AppKit / AppState / @MainActor" }

# 测试必须 import 包本身，而不是 App 模块。
Dir.glob(File.join(TESTS, "*.swift")).each do |path|
  body = File.read(path, encoding: "UTF-8")
  next unless body.include?("@testable import WillDeep\n")
  failures << "#{File.basename(path)} 还在 `@testable import WillDeep`——包测试要 import WillDeepCore。"
end
checks << { "ok" => failures.empty?, "message" => "包测试都 import WillDeepCore" }

markdown_path = ARGV[0]
json_path = ARGV[1]
if json_path
  File.write(json_path, JSON.pretty_generate("ok" => failures.empty?, "checks" => checks, "failures" => failures))
end
if markdown_path
  lines = ["# WillDeepCore Boundary", "", "- Status: #{failures.empty? ? "pass" : "fail"}", ""]
  failures.each { |f| lines << "- FAIL: #{f}" }
  checks.each { |c| lines << "- #{c["ok"] ? "PASS" : "FAIL"}: #{c["message"]}" }
  File.write(markdown_path, "#{lines.join("\n")}\n")
end

abort failures.join("\n") unless failures.empty?
puts "willdeep_core_boundary: pass files=#{files.length}"
