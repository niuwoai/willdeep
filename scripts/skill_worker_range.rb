#!/usr/bin/env ruby
# frozen_string_literal: true

# 小上下文工种的实弹靶场驱动器（与 willdeep-rs 的同名脚本同源）。
#
# 干三件事：取出凭据、跑 XeditTests 里的 live-fire suite、把结果渲染成
# JSON + Markdown 两份报告。
#
# 它花真钱：每个样本都会真的调用 Provider。没有凭据时 suite 自己跳过。
#
#   ruby scripts/skill_worker_range.rb
#   ruby scripts/skill_worker_range.rb --cases build_missing_var,scout_finds_the_symbol
#   ruby scripts/skill_worker_range.rb --report-only     # 不花钱，重渲染已有结果
#
# 凭据只在进程内传给 xcodebuild，不打印、不写进报告。

require 'json'
require 'fileutils'
require 'optparse'

options = {
  model: ENV['XEDIT_RANGE_MODEL'] || 'someim-32b',
  cases: ENV['XEDIT_RANGE_CASES'],
  config: File.join(ENV['WILLDEEP_HOME'] || File.join(Dir.home, '.willdeep'), 'config.toml'),
  out: File.join(Dir.pwd, 'build', 'skill-worker-range')
}

OptionParser.new do |parser|
  parser.banner = 'Usage: ruby scripts/skill_worker_range.rb [options]'
  parser.on('--model MODEL', '派工用的模型，默认 someim-32b（与标准档 Worker 一致）') { |value| options[:model] = value }
  parser.on('--cases LIST', '只跑这些样本，逗号分隔') { |value| options[:cases] = value }
  parser.on('--config PATH', '取凭据的 willdeep 配置文件') { |value| options[:config] = value }
  parser.on('--out DIR', '报告输出目录') { |value| options[:out] = value }
  parser.on('--report-only', '不派工，只重新渲染已有的 range.json') { options[:report_only] = true }
end.parse!

# 凭据来源：环境变量优先，其次同机 willdeep CLI 的配置——两边连的是同一个
# 网关、同一批账号，让靶场自己再存一份 key 只会多一个泄漏面。
def credentials(config_path)
  key = ENV['XEDIT_RANGE_API_KEY']
  base = ENV['XEDIT_RANGE_API_BASE']
  return [base || 'https://api.niuwoai.com/v1', key] if key && !key.empty?

  raise "没有 XEDIT_RANGE_API_KEY，且配置文件不存在：#{config_path}" unless File.exist?(config_path)

  # 配置里有中文注释，按 UTF-8 读，别看外部编码脸色。
  text = File.read(config_path, encoding: 'UTF-8')
  default = text[/^\s*default_provider\s*=\s*"([^"]+)"/, 1]
  raise "#{config_path} 里没有 default_provider" unless default

  section = text[/^\s*\[providers\.#{Regexp.escape(default)}\]\s*$(.*?)(?=^\s*\[|\z)/m, 1]
  raise "#{config_path} 里没有 [providers.#{default}] 段" unless section

  [
    base || section[/^\s*api_base\s*=\s*"([^"]+)"/, 1],
    section[/^\s*api_key\s*=\s*"([^"]+)"/, 1]
  ]
end

options[:out] = File.expand_path(options[:out])
FileUtils.mkdir_p(options[:out])
json_path = File.join(options[:out], 'range.json')
md_path = File.join(options[:out], 'range.md')

unless options[:report_only]
  api_base, api_key = credentials(options[:config])
  raise '拿不到 API Key' if api_key.to_s.strip.empty?

  puts "base:  #{api_base}"
  puts "model: #{options[:model]}"
  puts "cases: #{options[:cases] || 'all'}"
  puts '开跑。每个样本都会真的调用 Provider，慢是正常的。'

  # xcodebuild 不会把自己的环境原样递给测试进程；带 `TEST_RUNNER_` 前缀的
  # 变量才会被剥掉前缀注入进去。两份都设：脚本自己用不带前缀的那份。
  values = {
    'XEDIT_RANGE_API_BASE' => api_base,
    'XEDIT_RANGE_API_KEY' => api_key,
    'XEDIT_RANGE_MODEL' => options[:model],
    'XEDIT_RANGE_OUT' => json_path
  }
  values['XEDIT_RANGE_CASES'] = options[:cases] if options[:cases]
  env = values.merge(values.transform_keys { |key| "TEST_RUNNER_#{key}" })

  # `--force`：结果缓存按源码输入取哈希，而靶场每一轮的变量是凭据与样本
  # 选择，不在哈希里。不强制的话第二轮会命中缓存，报告一个没跑过的绿。
  ok = system(env, 'ruby', 'scripts/run_tests_fast.rb', '--force',
              '-only-testing:XeditTests/AgentSubagentLiveFireRangeTests')

  unless File.exist?(json_path)
    warn "靶场没有产出报告（测试退出状态：#{ok.inspect}）。上面的输出就是原因。"
    exit 1
  end
end

abort "没有可渲染的报告：#{json_path}" unless File.exist?(json_path)

report = JSON.parse(File.read(json_path, encoding: 'UTF-8'))
cases = report['cases']
verified_cases = cases.reject { |row| row['report_only'] }
report_cases = cases.select { |row| row['report_only'] }
verified = verified_cases.count { |row| row['verifier_passed'] && row['api_intact'] }
cheated = verified_cases.count { |row| row['verifier_passed'] && !row['api_intact'] }
mis_seeded = cases.reject { |row| row['seeded_red'] }.map { |row| row['case'] }
claims = report_cases.map { |row| row['claims_checked'].to_i }.sum
bad_claims = report_cases.map { |row| row['claims_unverifiable'].to_i }.sum
answered = report_cases.count { |row| row['expectation_met'] }
seconds = cases.map { |row| row['seconds'].to_f }.sum

def ratio(part, total)
  # 分母为 0 打 `-`：什么都没跑和什么都没通过是两件事。
  total.zero? ? '-' : format('%d/%d (%.0f%%)', part, total, part * 100.0 / total)
end

lines = []
lines << '# 小上下文工种实弹靶场（Xedit）'
lines << ''
lines << "- 模型：`#{report['model']}`"
lines << "- 样本：#{cases.size}（可验证 #{verified_cases.size} · 只读 #{report_cases.size}）"
lines << "- **Worker Verified Success**：#{ratio(verified, verified_cases.size)}（verifier 通过**且**公开 API 还在）"
lines << "- verifier 通过但把靶子搬走了（作弊）：#{cheated}"
lines << "- **只读工种引用准确率**：#{ratio(claims - bad_claims, claims)}（报告点名的路径/行号/commit 里，真实存在的）"
lines << "- **只读工种答对率**：#{ratio(answered, report_cases.size)}（引用真实 ≠ 答对，这一项单独算）"
lines << "- 总耗时：#{format('%.1f', seconds)}s"
lines << "- 派工前 verifier 未变红的样本（无效样本）：#{mis_seeded.empty? ? '无' : mis_seeded.join(', ')}"
lines << ''
lines << '| 样本 | 工种 | 判定 | 尝试 | API 未被搬走 | 引用核对 | 答对 | 秒 | 错误 |'
lines << '|---|---|---|---:|---|---|---|---:|---|'
cases.each do |row|
  verdict = if row['report_only']
              '— 只读'
            elsif row['verifier_passed']
              '✅ passed'
            else
              '❌ failed'
            end
  checked = row['claims_checked'].to_i
  citations = checked.zero? ? '-' : "#{checked - row['claims_unverifiable'].to_i}/#{checked}"
  answer = row['report_only'] ? (row['expectation_met'] ? '是' : '**否**') : '-'
  error = row['error'].to_s.gsub(/\s+/, ' ')[0, 80]
  lines << format('| `%s` | %s | %s | %d | %s | %s | %s | %.1f | %s |',
                  row['case'], row['profile'], verdict, row['attempts'],
                  row['report_only'] ? '-' : (row['api_intact'] ? '是' : '**否**'),
                  citations, answer, row['seconds'].to_f,
                  error.empty? ? '' : "`#{error}`")
end
lines << ''

File.write(md_path, lines.join("\n"))
puts lines.join("\n")
puts
puts "JSON: #{json_path}"
puts "Markdown: #{md_path}"
