#!/usr/bin/env ruby
# frozen_string_literal: true

# i18n_merge_locale.rb — 把翻译好的批次合并回 Localizable.xcstrings。
#
# 为什么又是文本级编辑:catalog 现在是混排格式(867 条紧凑单行 + 2534 条
# 展开多行,被 Xcode 和历史脚本轮流写过)。JSON parse → 全量 dump 会把三万
# 多行整体重排,真实改动全被淹没,也让并发会话的 merge 无从下手。这里只往
# 每个条目的 localizations 里插入新语言那几行,其余字节一个不动。
#
# 用法:
#   ruby scripts/i18n_merge_locale.rb <locale> <translated_dir> [--dry-run]
#
# translated_dir 下的 translated_<locale>_*.json 形如:
#   { "settings.language.title": "Idioma" }

require "json"

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

XCSTRINGS = File.join(__dir__, "..", "Xedit", "Localizable.xcstrings")
ENTRY_LINE = /^    "((?:[^"\\]|\\.)*)" : /

# 只数**字符串字面量之外**的花括号。译文里出现 `{` / `}`(JSON 片段、代码
# 示例、`${VAR}` 占位)非常常见,把它们算进嵌套深度会让条目边界整体错位——
# 第一版就是这么把 catalog 写坏的:1858 条 key 找不到,文件也不再是合法 JSON。
def brace_delta(line)
  delta = 0
  in_string = false
  escaped = false
  line.each_char do |ch|
    if escaped
      escaped = false
      next
    end
    case ch
    when "\\" then escaped = true if in_string
    when '"' then in_string = !in_string
    when "{" then delta += 1 unless in_string
    when "}" then delta -= 1 unless in_string
    end
  end
  delta
end

locale = ARGV[0] or abort "用法: ruby scripts/i18n_merge_locale.rb <locale> <translated_dir> [--dry-run]"
translated_dir = ARGV[1] or abort "需要 <translated_dir>"
dry_run = ARGV.include?("--dry-run")

translations = {}
files = Dir.glob(File.join(translated_dir, "translated_#{locale}_*.json")).sort
abort "在 #{translated_dir} 下没找到 translated_#{locale}_*.json" if files.empty?
files.each do |path|
  JSON.parse(File.read(path, encoding: "UTF-8")).each do |key, value|
    translations[key] = value
  end
end

lines = File.readlines(XCSTRINGS, encoding: "UTF-8")

# ---- 定位每个顶层 key 条目的行范围 ----
entries = {}   # key => [起始行, 结束行]
open_key = nil
start_line = nil
depth = 0
lines.each_with_index do |line, i|
  if open_key.nil?
    next unless (m = ENTRY_LINE.match(line))
    open_key = JSON.parse("\"#{m[1]}\"")
    start_line = i
    depth = brace_delta(line)
    if depth <= 0            # 紧凑单行条目,当场闭合
      entries[open_key] = [start_line, i]
      open_key = nil
    end
  else
    depth += brace_delta(line)
    if depth <= 0
      entries[open_key] = [start_line, i]
      open_key = nil
    end
  end
end

def string_unit_hash(value)
  { "stringUnit" => { "state" => "translated", "value" => value } }
end

# 紧凑条目的排版:`{ "a" : 1, "b" : 2 }`,非 ASCII 不转义(与文件一致)。
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

# 展开条目里一个 locale 块长这样(localizations 内缩进 8 空格):
#         "es" : {
#           "stringUnit" : {
#             "state" : "translated",
#             "value" : "…"
#           }
#         }
def expanded_locale_block(locale, value, trailing_comma)
  [
    "        #{locale.to_json} : {\n",
    "          \"stringUnit\" : {\n",
    "            \"state\" : \"translated\",\n",
    "            \"value\" : #{value.to_json}\n",
    "          }\n",
    "        }#{trailing_comma ? ',' : ''}\n",
  ]
end

applied = 0
skipped_missing_key = []
skipped_existing = []
skipped_unknown_shape = []
edits = []   # [起始行, 结束行, 新行数组]

translations.each do |key, value|
  range = entries[key]
  if range.nil?
    skipped_missing_key << key
    next
  end
  from, to = range

  if from == to
    # 紧凑单行:整行重建。
    line = lines[from]
    body = line.sub(ENTRY_LINE, "").rstrip.sub(/,\z/, "")
    entry = JSON.parse(body)
    localizations = entry["localizations"] ||= {}
    if localizations.dig(locale, "stringUnit", "value").to_s != ""
      skipped_existing << key
      next
    end
    localizations[locale] = string_unit_hash(value)
    entry["localizations"] = localizations.sort.to_h
    edits << [from, to, ["    #{key.to_json} : #{compact_dump(entry)},\n"]]
    applied += 1
    next
  end

  # 展开多行:在 localizations 块里按字母序插入一个 locale 块。
  block = lines[from..to]
  loc_start = block.index { |l| l.start_with?("      \"localizations\" : {") }
  if loc_start.nil?
    skipped_missing_key << key
    next
  end
  # 第三种形态:条目本身是多行,但 localizations 整块压在一行里——
  #     "computer-use-preview.close" : {
  #       "localizations" : { "zh-Hans" : { … } }
  #     },
  # 这一行自己开合括号(净深度 0),没有可插入的 locale 子块,按展开格式硬
  # 插进去会把结构撑坏。整行重建即可。
  if brace_delta(block[loc_start]).zero?
    prefix = "      \"localizations\" : "
    rest = block[loc_start][prefix.length..].to_s.rstrip
    trailing_comma = rest.end_with?(",")
    body = trailing_comma ? rest[0..-2] : rest
    inline = begin
      JSON.parse(body)
    rescue JSON::ParserError
      nil
    end
    if inline.nil?
      skipped_missing_key << key
      next
    end
    if inline.dig(locale, "stringUnit", "value").to_s != ""
      skipped_existing << key
      next
    end
    inline[locale] = string_unit_hash(value)
    block[loc_start] = prefix + compact_dump(inline.sort.to_h) + (trailing_comma ? "," : "") + "\n"
    edits << [from, to, block]
    applied += 1
    next
  end

  # localizations 内的直接子项就是各 locale,缩进恰好 8 空格。
  locale_lines = {}   # locale => 块内相对行号
  depth = 0
  (loc_start...block.size).each do |i|
    line = block[i]
    if i > loc_start && depth == 1 && (m = /^        "([^"]+)" : \{/.match(line))
      locale_lines[m[1]] = i
    end
    depth += brace_delta(line)
    break if depth <= 0 && i > loc_start
  end

  if locale_lines.key?(locale)
    skipped_existing << key
    next
  end
  # 一个 locale 子块都没认出来 = 遇到了没见过的排版。宁可漏掉这一条也不
  # 要瞎插——上一版就是猜着插,把整个 catalog 写成了非法 JSON。
  if locale_lines.empty?
    skipped_unknown_shape << key
    next
  end

  after = locale_lines.keys.select { |l| l < locale }.max
  if after
    # 插到 after 这个块的结尾之后:该块结束行是它的 `        }` / `        },`
    depth = 0
    insert_at = nil
    (locale_lines[after]...block.size).each do |i|
      depth += brace_delta(block[i])
      if depth <= 0
        insert_at = i + 1
        # 前一个块原本是最后一个(没有逗号)的话,得给它补上逗号。
        lines_ref = block[i]
        block[i] = lines_ref.sub(/\}\s*\z/, "},\n") unless lines_ref.rstrip.end_with?(",")
        break
      end
    end
    new_block = expanded_locale_block(locale, value, false)
    # 新块后面还有别的 locale 就要带逗号。
    following = block[insert_at]
    trailing = following && /^        "/.match?(following)
    new_block = expanded_locale_block(locale, value, trailing)
    block.insert(insert_at, *new_block)
  else
    # 排在最前面:插到 localizations 开括号之后,并给原第一个块带上逗号。
    new_block = expanded_locale_block(locale, value, true)
    block.insert(loc_start + 1, *new_block)
  end

  edits << [from, to, block]
  applied += 1
end

# 倒序落笔,行号不互相错位。
edits.sort_by! { |from, _to, _block| -from }
edits.each { |from, to, block| lines[from..to] = block }

File.write(XCSTRINGS, lines.join) unless dry_run

puts "locale=#{locale} 合并: #{applied} 条(来自 #{files.size} 个批次文件)"
puts "跳过(已有译文): #{skipped_existing.size}" unless skipped_existing.empty?
unless skipped_unknown_shape.empty?
  puts "跳过(排版不认识,需人工处理): #{skipped_unknown_shape.size} → #{skipped_unknown_shape.first(5).join(', ')}"
end
unless skipped_missing_key.empty?
  puts "跳过(catalog 里没有该 key): #{skipped_missing_key.size} → #{skipped_missing_key.first(5).join(', ')}"
end
puts "(dry-run,未写盘)" if dry_run
