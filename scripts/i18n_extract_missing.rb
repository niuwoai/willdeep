# frozen_string_literal: true
# 抽出 Localizable.xcstrings 中缺少 zh-Hans 翻译的 key 及其 en 原文。
# 输出按批次切分的 JSON 文件,便于并行翻译。用法:
#   ruby scripts/i18n_extract_missing.rb <out_dir> <batch_count>
require "json"

xcstrings = File.join(__dir__, "..", "Xedit", "Localizable.xcstrings")
data = JSON.parse(File.read(xcstrings, encoding: "UTF-8"))
strings = data["strings"]

missing = {}
skipped = []
strings.each do |key, entry|
  loc = entry["localizations"] || {}
  next if loc.key?("zh-Hans")
  # en 原文:优先 en localization,否则用 key 本身(catalog 里 key==en 的情况)
  en = loc.dig("en", "stringUnit", "value") || key
  # 过滤纯符号/格式串:去掉 %@ / %lld 等占位与所有标点/数字/空白后,
  # 若不含任何字母,说明它在任何语言下显示都一样(如 ":"、"%lld"、"·"),
  # 不需要翻译,跳过。
  stripped = en.gsub(/%(\d+\$)?[@a-zA-Z]+|%(\d+\$)?lld|%(\d+\$)?lf/, "")
  if stripped !~ /[A-Za-z]/
    skipped << key
    next
  end
  missing[key] = en
end

out_dir = ARGV[0] || "."
batch_count = (ARGV[1] || "3").to_i
require "fileutils"
FileUtils.mkdir_p(out_dir)

keys = missing.keys
slice = (keys.size.to_f / batch_count).ceil
keys.each_slice(slice).with_index do |chunk, i|
  batch = chunk.each_with_object({}) { |k, h| h[k] = missing[k] }
  File.write(File.join(out_dir, "missing_batch_#{i}.json"),
             JSON.pretty_generate(batch))
end

puts "translatable missing zh-Hans: #{missing.size}"
puts "skipped (symbol/format-only, no translation needed): #{skipped.size}"
puts "batches: #{batch_count} (~#{slice} each) -> #{out_dir}"
