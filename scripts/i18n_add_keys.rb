#!/usr/bin/env ruby
# frozen_string_literal: true

# i18n_add_keys.rb — 往 Localizable.xcstrings 里增删改**少量** key 的多语言值。
#
# 为什么不复用 scripts/i18n_apply_translations.rb:那个脚本 parse → 全量
# dump,而 catalog 现在是「紧凑单行条目 + 展开多行条目」混排(被 Xcode 和
# 脚本轮流写过),全量 dump 会把三万多行全部重排,真正的改动淹没在 diff 里。
# `i18n_apply_translations.rb --verify` 现在就是红的,正是这个原因。
#
# 这里改成**文本级**编辑:
#   * 新 key → 按字母序插到同命名空间(key 去掉最后一段)的兄弟条目之间;
#   * 已有 key → 只有当它是紧凑单行条目时才就地合并 locale,多行条目一律
#     跳过并报告(交给人工/Xcode 处理),绝不猜着改。
# 其余字节一个不动。
#
# 用法:
#   ruby scripts/i18n_add_keys.rb <keys.json> [--dry-run]
#
# keys.json 形如:
#   {
#     "settings.language.french": { "en": "Français", "zh-Hans": "Français" },
#     "settings.language.later":  { "en": "Later", "zh-Hans": "稍后", "ja": "後で" }
#   }

require "json"

XCSTRINGS = File.join(__dir__, "..", "Xedit", "Localizable.xcstrings")
ENTRY_LINE = /^    "((?:[^"\\]|\\.)*)" : /

# 复刻 catalog 里紧凑条目的排版:`{ "a" : 1, "b" : 2 }`,非 ASCII 不转义。
def compact_dump(value)
  case value
  when Hash
    return "{ }" if value.empty?
    "{ #{value.map { |k, v| "#{k.to_json} : #{compact_dump(v)}" }.join(', ')} }"
  when Array
    return "[ ]" if value.empty?
    "[ #{value.map { |v| compact_dump(v) }.join(', ')} ]"
  else
    value.to_json
  end
end

def string_unit(value)
  { "stringUnit" => { "state" => "translated", "value" => value } }
end

def entry_hash(localizations)
  {
    "extractionState" => "manual",
    # locale 按字母序,和 catalog 里既有条目的排法一致(en / ja / zh-Hans)。
    "localizations" => localizations.sort.to_h.transform_values { |v| string_unit(v) },
  }
end

def entry_line(key, localizations)
  "    #{key.to_json} : #{compact_dump(entry_hash(localizations))},\n"
end

keys_path = ARGV[0] or abort "用法: ruby scripts/i18n_add_keys.rb <keys.json> [--dry-run]"
dry_run = ARGV.include?("--dry-run")
requested = JSON.parse(File.read(keys_path, encoding: "UTF-8"))

lines = File.readlines(XCSTRINGS, encoding: "UTF-8")

# key → 行号(只认顶层条目行,缩进恰好 4 空格)
index = {}
lines.each_with_index do |line, i|
  m = ENTRY_LINE.match(line)
  index[JSON.parse("\"#{m[1]}\"")] = i if m
end

created = []
updated = []
skipped_multiline = []
unchanged = []

# 逐条处理,倒序落笔:先算好所有插入点再从后往前改,行号才不会互相错位。
inserts = []   # [插入行号, 文本]
replaces = []  # [行号, 文本]

requested.each do |key, locs|
  if (line_no = index[key])
    line = lines[line_no]
    # 紧凑单行条目才就地改:整行必须是 `    "key" : {...},`
    body = line.sub(ENTRY_LINE, "").rstrip.sub(/,\z/, "")
    entry = begin
      JSON.parse(body)
    rescue JSON::ParserError
      nil
    end
    if entry.nil?
      skipped_multiline << key
      next
    end
    existing = entry["localizations"] || {}
    merged = existing.each_with_object({}) do |(lang, unit), h|
      h[lang] = unit.dig("stringUnit", "value")
    end
    additions = locs.reject { |lang, value| merged[lang] == value }
    if additions.empty?
      unchanged << key
      next
    end
    replaces << [line_no, entry_line(key, merged.merge(locs))]
    updated << key
    next
  end

  # 新 key:插到同命名空间兄弟里,按字母序。
  namespace = key.include?(".") ? key[0..key.rindex(".")] : nil
  siblings = namespace ? index.keys.select { |k| k.start_with?(namespace) } : []
  if siblings.empty?
    abort "无法为新 key #{key.inspect} 找到同命名空间的兄弟条目;请先手动放置一条再跑本脚本。"
  end
  after = siblings.select { |k| k < key }.max
  target = after ? index[after] + 1 : index[siblings.min]
  inserts << [target, entry_line(key, locs)]
  created << key
end

# 同一插入点上有多条时,保持它们彼此的字母序。
inserts.sort_by! { |line_no, text| [line_no, text] }
replaces.each { |line_no, text| lines[line_no] = text }
inserts.reverse_each { |line_no, text| lines.insert(line_no, text) }

File.write(XCSTRINGS, lines.join) unless dry_run

puts "新增 key: #{created.size}#{created.empty? ? '' : " (#{created.join(', ')})"}"
puts "更新 key: #{updated.size}#{updated.empty? ? '' : " (#{updated.join(', ')})"}"
puts "无变化:   #{unchanged.size}"
unless skipped_multiline.empty?
  puts "跳过(多行条目,需手工处理): #{skipped_multiline.size} → #{skipped_multiline.join(', ')}"
end
puts "(dry-run,未写盘)" if dry_run
