# frozen_string_literal: true
# 校验翻译批次:key 是否齐全、格式占位符是否与原文一致。
# 用法: ruby scripts/i18n_validate_translations.rb <dir>
require "json"

dir = ARGV[0] or abort "need dir"
problems = []
total = 0

# 抽取格式占位符多重集合(%@ %lld %lf %1$@ 等)
def specs(str)
  str.scan(/%(?:\d+\$)?[@a-zA-Z]+|\\n|\\t/).sort
end

Dir.glob(File.join(dir, "missing_batch_*.json")).sort.each do |src|
  idx = src[/missing_batch_(\d+)\.json/, 1]
  dst = File.join(dir, "translated_batch_#{idx}.json")
  unless File.exist?(dst)
    problems << "batch #{idx}: 缺翻译文件 #{dst}"
    next
  end
  en = JSON.parse(File.read(src, encoding: "UTF-8"))
  zh = JSON.parse(File.read(dst, encoding: "UTF-8"))
  (en.keys - zh.keys).each { |k| problems << "batch #{idx}: 缺 key #{k.inspect}" }
  (zh.keys - en.keys).each { |k| problems << "batch #{idx}: 多出 key #{k.inspect}" }
  en.each do |k, ev|
    next unless zh.key?(k)
    total += 1
    if specs(ev) != specs(zh[k])
      problems << "batch #{idx}: 占位符不匹配 key=#{k.inspect}\n    en=#{ev.inspect}\n    zh=#{zh[k].inspect}"
    end
  end
end

puts "校验条目: #{total}"
if problems.empty?
  puts "OK: 全部 key 齐全、占位符一致"
else
  puts "发现 #{problems.size} 个问题:"
  problems.first(60).each { |p| puts "  - #{p}" }
end
