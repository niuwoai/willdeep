#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'

root = File.expand_path('..', __dir__)
output = File.expand_path(ARGV.fetch(0, 'build/perf-line-framer'), root)
FileUtils.mkdir_p(output)
source = <<~'SWIFT'
  import Foundation

  struct OriginalLineFramer {
      var buffer = Data()
      mutating func append(_ data: Data) -> [Data] {
          buffer.append(data)
          var lines: [Data] = []
          while let newline = buffer.firstIndex(of: 0x0A) {
              lines.append(Data(buffer.prefix(upTo: newline)))
              buffer.removeSubrange(buffer.startIndex...newline)
          }
          return lines
      }
  }

  @main struct Benchmark {
      static func run(bytes: Int, improved: Bool) -> Double {
          let input = Data(repeating: 0x61, count: bytes)
          var original = OriginalLineFramer()
          var current = AgentMCPLineFramer()
          let started = ProcessInfo.processInfo.systemUptime
          for start in stride(from: 0, to: bytes, by: 4096) {
              let chunk = input[start..<min(start + 4096, bytes)]
              let lines = improved ? current.append(chunk) : original.append(chunk)
              precondition(lines.isEmpty)
          }
          let lines = improved ? current.append(Data([0x0A])) : original.append(Data([0x0A]))
          precondition(lines == [input])
          return (ProcessInfo.processInfo.systemUptime - started) * 1000
      }

      static func main() throws {
          var rows: [[String: Any]] = []
          for bytes in [256 * 1024, 1024 * 1024, 4 * 1024 * 1024] {
              var before: [Double] = [], after: [Double] = []
              for _ in 0..<3 {
                  before.append(run(bytes: bytes, improved: false))
                  after.append(run(bytes: bytes, improved: true))
              }
              let old = before.sorted()[1], new = after.sorted()[1]
              rows.append(["bytes": bytes, "chunk_bytes": 4096,
                           "before_ms": old, "after_ms": new, "speedup": old / new,
                           "before_samples_ms": before, "after_samples_ms": after])
          }
          let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
          print(String(decoding: data, as: UTF8.self))
      }
  }
SWIFT

Dir.mktmpdir('mcp-framer-bench-') do |temporary|
  main = File.join(temporary, 'Benchmark.swift')
  executable = File.join(temporary, 'benchmark')
  File.write(main, source)
  compile, status = Open3.capture2e(
    'xcrun', 'swiftc', '-O', '-o', executable,
    File.join(root, 'Xedit/AgentMCPLineFramer.swift'), main
  )
  abort compile unless status.success?
  result, status = Open3.capture2e(executable)
  abort result unless status.success?
  rows = JSON.parse(result)
  File.write(File.join(output, 'report.json'), JSON.pretty_generate(rows) + "\n")
  markdown = [
    '# MCP 大消息分帧基准', '',
    '同机 Release 优化编译，每项三次取中位数，4 KiB 分块；校验重组结果逐字节相等。',
    '仅衡量分帧函数，不代表整个 App 的 CPU 降幅。', '',
    '| 消息大小 | 修复前 ms | 修复后 ms | 加速倍数 |',
    '| --- | ---: | ---: | ---: |'
  ]
  rows.each do |row|
    markdown << format('| %d KiB | %.3f | %.3f | %.1fx |', row['bytes'] / 1024,
                       row['before_ms'], row['after_ms'], row['speedup'])
  end
  File.write(File.join(output, 'report.md'), markdown.join("\n") + "\n")
  puts markdown.join("\n")
end
