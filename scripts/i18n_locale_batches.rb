#!/usr/bin/env ruby
# frozen_string_literal: true

# i18n_locale_batches.rb — 把某个语言缺的翻译切成批次文件,便于并行翻译。
#
# 和 i18n_extract_missing.rb 的区别:那个脚本把 zh-Hans 写死了(当年只补中文)。
# 加日/西/法之后需要按语言取,顺带把 zh-Hans 译文一起带出来当消歧参考——
# 光看 "Run"、"Open" 这种孤零零的英文,翻译方很容易猜错语境。
#
# 用法:
#   ruby scripts/i18n_locale_batches.rb <locale> <out_dir> [batch_size]
#
# 产出 <out_dir>/missing_<locale>_<n>.json,形如:
#   { "settings.language.title": { "en": "Language", "zh": "语言设置" } }

require "json"
require "fileutils"

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

XCSTRINGS = File.join(__dir__, "..", "Xedit", "Localizable.xcstrings")

locale = ARGV[0] or abort "用法: ruby scripts/i18n_locale_batches.rb <locale> <out_dir> [batch_size]"
out_dir = ARGV[1] or abort "需要 <out_dir>"
batch_size = (ARGV[2] || "300").to_i

data = JSON.parse(File.read(XCSTRINGS, encoding: "UTF-8"))
strings = data["strings"]

# 纯符号/格式串(":"、"%lld"、"·"、"/bin/zsh")在任何语言下都一样,不需要翻译。
# 口径与 i18n_coverage_guard.rb 保持一致。
def translatable?(text)
  text.gsub(/%(\d+\$)?[@a-zA-Z]+|%(\d+\$)?lld|%(\d+\$)?lf/, "").match?(/[A-Za-z]/)
end

missing = {}
strings.sort.each do |key, entry|
  loc = entry["localizations"] || {}
  next if loc.dig(locale, "stringUnit", "value").to_s != ""

  en = loc.dig("en", "stringUnit", "value") || key
  next unless translatable?(en)

  item = { "en" => en }
  zh = loc.dig("zh-Hans", "stringUnit", "value")
  item["zh"] = zh if zh
  missing[key] = item
end

FileUtils.mkdir_p(out_dir)
Dir.glob(File.join(out_dir, "missing_#{locale}_*.json")).each { |f| File.delete(f) }

batches = missing.keys.each_slice(batch_size).to_a
batches.each_with_index do |chunk, i|
  payload = chunk.each_with_object({}) { |k, h| h[k] = missing[k] }
  File.write(
    File.join(out_dir, format("missing_%s_%02d.json", locale, i)),
    JSON.pretty_generate(payload) + "\n"
  )
end

puts "locale=#{locale} missing=#{missing.size} batches=#{batches.size} (每批 ≤#{batch_size}) → #{out_dir}"
