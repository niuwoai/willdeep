# frozen_string_literal: true
require 'json'
require 'open3'
require 'fileutils'
require 'tmpdir'

root = File.expand_path('..', __dir__)
baseline = ARGV.fetch(0, '5c2f789e')
output = File.expand_path(ARGV.fetch(1, 'build/perf-usage-incremental'), root)
FileUtils.mkdir_p(output)
before, status = Open3.capture2('git', '-C', root, 'show', "#{baseline}:Xedit/AgentUsageDatabase.swift")
abort 'Cannot read benchmark baseline' unless status.success?
main = <<~'SWIFT'
  import Foundation
  @main struct Benchmark {
      static func main() throws {
          let database = AgentUsageDatabase(url: URL(fileURLWithPath: CommandLine.arguments[1]))!
          let count = Int(CommandLine.arguments[2])!
          let now = Date(timeIntervalSince1970: 1700000000)
          let messages = (0..<count).map { index in
              AgentUsageMessageSnapshot(id: UUID(), role: .assistant,
                  contentCharacterCount: 200, reasoningCharacterCount: 20, imageCount: 0,
                  toolCallNames: ["read_file", "run_command"],
                  toolCallExternalIDs: ["read-\(index)", "run-\(index)"],
                  promptTokens: 123, completionTokens: 20, createdAt: now)
          }
          var snapshot = AgentUsageSessionSnapshot(id: UUID(), modelID: "fixture", providerID: "fixture",
              providerDisplayName: "fixture", createdAt: now, updatedAt: now, messages: messages)
          var times: [Double] = []
          for iteration in 0..<21 {
              snapshot.messages[count - 1].contentCharacterCount += 1
              snapshot.updatedAt = now.addingTimeInterval(Double(iteration))
              let stamp = AgentUsageSourceStamp(fileSize: UInt64(iteration + 1), modificationTime: Double(iteration))
              let start = ProcessInfo.processInfo.systemUptime
              precondition(database.upsert(snapshot, signature: stamp))
              let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
              if iteration > 0 { times.append(elapsed) }
              precondition(database.loadAll() == [snapshot])
              precondition(database.storedSignatures()[snapshot.id] == stamp)
          }
          let data = try JSONSerialization.data(withJSONObject: ["samples_ms": times,
              "median_ms": times.sorted()[times.count / 2], "exact_round_trips": 21], options: [.sortedKeys])
          print(String(decoding: data, as: UTF8.self))
      }
  }
SWIFT
Dir.mktmpdir('usage-incremental-') do |temporary|
  File.write(File.join(temporary, 'Before.swift'), before)
  File.write(File.join(temporary, 'Benchmark.swift'), main)
  binaries = {}
  { before: File.join(temporary, 'Before.swift'), after: File.join(root, 'Xedit/AgentUsageDatabase.swift') }.each do |label, source|
    binary = File.join(temporary, label.to_s)
    log, status = Open3.capture2e('xcrun', 'swiftc', '-O', '-o', binary,
      File.join(root, 'scripts/fixtures/usage_benchmark_models.swift'), source, File.join(temporary, 'Benchmark.swift'))
    abort log unless status.success?
    binaries[label] = binary
  end
  rows = [100, 2000, 5000].map do |count|
    row = { messages: count, tool_calls: count * 2 }
    binaries.each do |label, binary|
      result, status = Open3.capture2e(binary, File.join(temporary, "#{label}-#{count}.sqlite"), count.to_s)
      abort result unless status.success?
      row[label] = JSON.parse(result)
    end
    row[:speedup] = row[:before]['median_ms'] / row[:after]['median_ms']
    row
  end
  File.write(File.join(output, 'report.json'), JSON.pretty_generate(baseline: baseline, workload: 'one streaming tail change per transaction; 20 warm samples; scalar fixture models', rows: rows) + "\n")
  lines = ['# 长会话统计增量保存基准', '', '同机优化编译；每组首写后 20 次尾消息变化，逐次核对完整快照与源文件签名。嵌套 Worker 数据为空夹具。5000 条超过缓存上限，验证回退路径；仅衡量统计库写入，不代表整个 App CPU 降幅。', '', '| 消息/工具记录 | 修复前 ms | 修复后 ms | 加速 |', '| --- | ---: | ---: | ---: |']
  rows.each { |row| lines << format('| %d / %d | %.3f | %.3f | %.2fx |', row[:messages], row[:tool_calls], row[:before]['median_ms'], row[:after]['median_ms'], row[:speedup]) }
  File.write(File.join(output, 'report.md'), lines.join("\n") + "\n")
  puts lines.join("\n")
end
