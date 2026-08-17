# frozen_string_literal: true
# 校验翻译批次:key 是否齐全、格式占位符是否与原文一致。
#
# 两种批次布局:
#   * 旧的 zh-Hans 布局(i18n_extract_missing.rb 产出):
#       missing_batch_<n>.json  = { key => en 原文 }
#       translated_batch_<n>.json
#     用法: ruby scripts/i18n_validate_translations.rb <dir>
#   * 多语言布局(i18n_locale_batches.rb 产出):
#       missing_<locale>_<n>.json = { key => { "en" =>…, "zh" =>… } }
#       translated_<locale>_<n>.json
#     用法: ruby scripts/i18n_validate_translations.rb <dir> <locale>
#
# 占位符对不上就是运行时崩溃的前夜(`String(format:)` 拿 %@ 去读一个不存在
# 的参数),所以这一步不能省。
require "json"

dir = ARGV[0] or abort "need dir"
locale = ARGV[1]
problems = []
total = 0

# 抽取格式占位符多重集合(%@ %lld %lf %1$@ 等)。
#
# 转换符必须精确匹配,不能用 `[@a-zA-Z]+` 贪婪吃后面的字母:"Used %@x" 里
# 的 x 是英文单词的一部分(times 的缩写),不是占位符,贪婪匹配会把它算进
# 占位符,然后误判每一条合理的译文。
FORMAT_SPEC = /%(?:(\d+)\$)?((?:ll|l|h|hh|q|z|t|j|L)?[@diouxXeEfgGaAcsp%])/

def specs(str)
  str.to_s.scan(FORMAT_SPEC).map { |position, conversion| "#{position}$#{conversion}" }.sort
end

# 位置化占位符(%1$@)与非位置化(%@)在语序调整时可以互换,只要「按顺序展开
# 后的类型序列」一致即可。%1$@ 和 %@ 都是一个对象参数。
def spec_types(str)
  str.to_s.scan(FORMAT_SPEC).map { |_position, conversion| conversion }.sort
end

pattern = locale ? "missing_#{locale}_*.json" : "missing_batch_*.json"
regexp = locale ? /missing_#{Regexp.escape(locale)}_(\d+)\.json/ : /missing_batch_(\d+)\.json/

files = Dir.glob(File.join(dir, pattern)).sort
abort "在 #{dir} 下没找到 #{pattern}" if files.empty?

files.each do |src|
  idx = src[regexp, 1]
  dst = File.join(dir, locale ? "translated_#{locale}_#{idx}.json" : "translated_batch_#{idx}.json")
  unless File.exist?(dst)
    problems << "batch #{idx}: 缺翻译文件 #{dst}"
    next
  end

  source = JSON.parse(File.read(src, encoding: "UTF-8"))
  translated = begin
    JSON.parse(File.read(dst, encoding: "UTF-8"))
  rescue JSON::ParserError => e
    problems << "batch #{idx}: 译文不是合法 JSON — #{e.message[0, 120]}"
    next
  end

  (source.keys - translated.keys).each { |k| problems << "batch #{idx}: 缺 key #{k.inspect}" }
  (translated.keys - source.keys).each { |k| problems << "batch #{idx}: 多出 key #{k.inspect}" }

  source.each do |key, value|
    next unless translated.key?(key)
    en = value.is_a?(Hash) ? value["en"] : value
    zh = value.is_a?(Hash) ? value["zh"] : nil
    # 占位符基准优先取 zh-Hans:catalog 里有一批 key 的 en 字段是坏数据
    # (值等于 key 名本身,或干脆是中文),而 zh 是线上真正在用的译文,占位符
    # 一定是对的。没有 zh 时才退回 en。
    reference = if zh && (en.to_s == key || en.to_s.strip.empty?)
                  zh
                else
                  en
                end
    out = translated[key]
    total += 1

    unless out.is_a?(String)
      problems << "batch #{idx}: 译文不是字符串 key=#{key.inspect} → #{out.class}"
      next
    end
    if out.strip.empty? && !reference.to_s.strip.empty?
      problems << "batch #{idx}: 译文为空 key=#{key.inspect}"
      next
    end
    next if specs(reference) == specs(out)
    # 顺序可以变(语序不同),类型多重集合不能变。
    next if spec_types(reference) == spec_types(out)
    problems << "batch #{idx}: 占位符不匹配 key=#{key.inspect}\n    ref=#{reference.inspect}\n    out=#{out.inspect}"
  end
end

puts "校验条目: #{total}#{locale ? " (locale=#{locale})" : ''}"
if problems.empty?
  puts "OK: 全部 key 齐全、占位符一致"
  exit 0
else
  puts "发现 #{problems.size} 个问题:"
  problems.first(60).each { |p| puts "  - #{p}" }
  exit 1
end
