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
#   * 新 key → 按字母序插到同命名空间(key 去掉最后一段)的兄弟条目**之间**;
#   * 已有 key → 只有当它是紧凑单行条目时才就地合并 locale,多行条目一律
#     跳过并报告(交给人工/Xcode 处理),绝不猜着改。
# 其余字节一个不动。
#
# 事故记录(2026-08-23,1.287.0-rc1):插入点原本取「字母序前驱条目的**首行**
# +1」。前驱是多行条目时(`approval-mode.request-every-time.summary` 之于
# `approval-mode.silent`),这一行落在它的对象**体内**——文件依旧是合法 JSON,
# `git diff --numstat` 依旧 1 增 0 删,于是「解析得动」「零删除」两道体检全绿,
# 但新 key 根本不在 `strings.<key>` 上(UI 静默回落 Swift defaultValue),邻居
# 条目还平白多出一个成员。所以现在有三道硬约束:
#   1. 结构化扫描(字符串/转义感知的花括号深度)算出每个顶层条目的
#      [首行, 末行],插入点只允许落在某条目的**末行之后**或首行之前;
#   2. 同命名空间没有兄弟时逐级回退父命名空间,最后回退全局字母序,不再 abort;
#   3. 落盘后**重新解析**校验:请求的每个 key 必须能在 `strings.<key>` 上按请求
#      的每个 locale 读出来,未涉及的条目必须逐一深度相等;任何一条不满足就
#      还原原文件并以非零码退出。
#
# 用法:
#   ruby scripts/i18n_add_keys.rb <keys.json> [--dry-run] [--catalog PATH]
#
# keys.json 形如:
#   {
#     "settings.language.french": { "en": "Français", "zh-Hans": "Français" },
#     "settings.language.later":  { "en": "Later", "zh-Hans": "稍后", "ja": "後で" }
#   }

require "json"

DEFAULT_CATALOG = File.expand_path(File.join(__dir__, "..", "Xedit", "Localizable.xcstrings"))
USAGE = "用法: ruby scripts/i18n_add_keys.rb <keys.json> [--dry-run] [--catalog PATH]"

# 顶层条目行:`    "some.key" : ...`。缩进宽度不写死,真正判定条目身份的是
# scan_catalog 里的花括号深度,这个正则只负责把 key 抠出来。
ENTRY_LINE = /\A[ \t]*"((?:[^"\\]|\\.)*)"[ \t]*:[ \t]*/
ENTRY_INDENT = "    "

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

def deep_dup(value)
  JSON.parse(JSON.generate(value))
end

# 把请求的 locale 合并进既有条目。既有条目的其余成员(comment、
# shouldTranslate、没被请求覆盖的 locale……)原样保留,只有被请求的 locale 会被
# 改写成 translated。新条目才补 extractionState。
def merged_entry(existing, localizations)
  entry = existing ? deep_dup(existing) : { "extractionState" => "manual" }
  units = entry["localizations"].is_a?(Hash) ? entry["localizations"] : {}
  localizations.each do |language, value|
    unit = units[language].is_a?(Hash) ? units[language] : {}
    string_unit = unit["stringUnit"].is_a?(Hash) ? unit["stringUnit"] : {}
    units[language] = unit.merge(
      "stringUnit" => string_unit.merge("state" => "translated", "value" => value)
    )
  end
  # locale 按字母序,和 catalog 里既有条目的排法一致(en / es / fr / ja / zh-Hans)。
  entry["localizations"] = units.sort.to_h
  entry
end

def entry_line(key, entry)
  "#{ENTRY_INDENT}#{key.to_json} : #{compact_dump(entry)},\n"
end

# 结构化扫描:xcstrings 是 JSON,只要把字符串和转义处理对,花括号深度就是可靠的
# 结构信号。根对象 depth 1,"strings" 对象内部 depth 2,顶层条目从 depth 2 开始、
# 回到 depth 2 结束。返回 [entries, strings_close_row],entries 每项是
# { "key" =>, "start" =>, "end" => },start/end 都是 0-based 行号。
def scan_catalog(lines)
  depth = 0
  in_string = false
  escaped = false
  buffer = +""
  last_string = nil
  member_depth = nil
  strings_close_row = nil
  entries = []
  open_entry = nil

  lines.each_with_index do |line, row|
    if member_depth && depth == member_depth
      # 上一条目的值不是对象/数组(深度没抬起来),就在上一行收尾。
      if open_entry
        open_entry["end"] = row - 1
        entries << open_entry
        open_entry = nil
      end
      if (match = ENTRY_LINE.match(line))
        open_entry = { "key" => JSON.parse(%("#{match[1]}")), "start" => row }
      end
    end

    line.each_char do |char|
      if in_string
        if escaped
          buffer << char
          escaped = false
        elsif char == "\\"
          buffer << char
          escaped = true
        elsif char == '"'
          in_string = false
          last_string = buffer.dup
        else
          buffer << char
        end
        next
      end

      case char
      when '"'
        in_string = true
        buffer = +""
      when "{", "["
        depth += 1
        member_depth = depth if member_depth.nil? && char == "{" && depth == 2 && last_string == "strings"
      when "}", "]"
        depth -= 1
        next unless member_depth
        if depth == member_depth && open_entry
          open_entry["end"] = row
          entries << open_entry
          open_entry = nil
        elsif depth == member_depth - 1 && strings_close_row.nil?
          strings_close_row = row
        end
      end
    end
  end

  if open_entry
    open_entry["end"] = lines.length - 1
    entries << open_entry
  end

  [entries, strings_close_row]
end

# 新 key 的落点。命名空间自内向外回退:`a.b.c` → `a.b.` → `a.` → 全局字母序。
# 返回 [插入行号, 说明],插入行号一定是「某条目末行之后」或「某条目首行之前」,
# 绝不会落在条目体内。
def placement_for(key, entries, strings_close_row)
  if entries.empty?
    return [strings_close_row, "空 catalog,插到 strings 对象末尾"] if strings_close_row
    return [nil, "catalog 里一个条目都没有,且找不到 strings 对象的收尾行"]
  end

  namespaces = []
  head = key
  while (dot = head.rindex("."))
    head = head[0...dot]
    namespaces << "#{head}."
  end
  namespaces << nil # 全局兜底

  namespaces.each do |namespace|
    candidates = namespace ? entries.select { |e| e["key"].start_with?(namespace) } : entries
    next if candidates.empty?

    scope = namespace ? "命名空间 #{namespace.inspect}" : "全局字母序(该 key 没有任何同前缀兄弟)"
    predecessor = candidates.select { |e| e["key"] < key }.max_by { |e| e["key"] }
    if predecessor
      return [predecessor["end"] + 1, "#{scope},插在 #{predecessor['key'].inspect} 之后"]
    end

    successor = candidates.min_by { |e| e["key"] }
    return [successor["start"], "#{scope},插在 #{successor['key'].inspect} 之前"]
  end

  [nil, "找不到落点"]
end

# 尾逗号归位:strings 对象里除最后一条外都要有尾逗号,最后一条不能有。只有真正
# 需要改的行会被动到(通常就是「原来的最后一条」在我们追加之后需要补一个逗号)。
def normalize_entry_commas!(lines)
  entries, = scan_catalog(lines)
  entries.each_with_index do |entry, position|
    row = entry["end"]
    line = lines[row]
    next if line.nil?
    newline = line[/\r?\n\z/] || ""
    body = line.sub(/\r?\n\z/, "").rstrip
    wants_comma = position < entries.length - 1
    has_comma = body.end_with?(",")
    next if wants_comma == has_comma
    body = wants_comma ? "#{body}," : body.sub(/,\z/, "")
    lines[row] = "#{body}#{newline}"
  end
  lines
end

# 落盘校验的核心:把改完的文本重新解析一遍,逐条比对。返回失败说明数组,空数组
# 表示通过。expected_entries 是我们**主动重写过**的 key → 期望的条目内容;其余
# 所有 key 必须和改动前深度相等。
def verification_failures(before_catalog, new_text, expected_entries, created)
  failures = []

  after_catalog = begin
    JSON.parse(new_text)
  rescue JSON::ParserError => e
    return ["改动后的 catalog 不是合法 JSON: #{e.message}"]
  end

  after_strings = after_catalog["strings"]
  unless after_strings.is_a?(Hash)
    return ["改动后的 catalog 缺少 strings 对象(或它不是对象)"]
  end

  before_strings = before_catalog["strings"]
  expected_keys = (before_strings.keys + created).uniq.sort
  actual_keys = after_strings.keys.sort
  unless expected_keys == actual_keys
    (expected_keys - actual_keys).each { |key| failures << "key 丢失: #{key.inspect}" }
    (actual_keys - expected_keys).each { |key| failures << "冒出计划外的 key: #{key.inspect}" }
  end

  expected_entries.each do |key, expected|
    actual = after_strings[key]
    if actual.nil?
      failures << "新增/更新的 key #{key.inspect} 在 strings.<key> 上读不出来(多半又插进别人的对象体里了)"
      next
    end
    next if actual == expected
    failures << "key #{key.inspect} 落盘内容和预期不一致:\n    期望 #{JSON.generate(expected)}\n    实际 #{JSON.generate(actual)}"
  end

  before_strings.each do |key, before_entry|
    next if expected_entries.key?(key)
    after_entry = after_strings[key]
    next if after_entry == before_entry
    failures << "未涉及的 key #{key.inspect} 被改动了(增减了成员或改了值):\n    改前 #{JSON.generate(before_entry)}\n    改后 #{JSON.generate(after_entry)}"
  end

  # 结构化扫描看到的条目数必须和 JSON 解析出来的一致,否则说明有条目没落在
  # 顶层(正是 1.287.0-rc1 那种「插进别人体内」的形状)。
  scanned, = scan_catalog(new_text.lines)
  if scanned.length != after_strings.length
    failures << "结构扫描到 #{scanned.length} 个顶层条目,JSON 解析出 #{after_strings.length} 个,版式对不上"
  end

  failures
end

# 写盘 + 落盘复验 + 失败还原。从磁盘读回来再验一遍是有意为之:verification_failures
# 上一次验的是内存里的字符串,这一遍才排除写盘本身出岔子(编码转换、被别的进程
# 截胡)。返回失败说明数组,空数组表示写盘成功且校验通过;非空时原文件已被还原。
def write_verified(catalog_path, original_text, new_text, before_catalog, expected_entries, created)
  File.binwrite(catalog_path, new_text)
  written = File.binread(catalog_path).force_encoding("UTF-8")

  failures = []
  failures << "写回磁盘的字节和预期不一致" unless written == new_text
  failures.concat(verification_failures(before_catalog, written, expected_entries, created))
  return failures if failures.empty?

  File.binwrite(catalog_path, original_text)
  restored = File.binread(catalog_path).force_encoding("UTF-8")
  if restored == original_text
    failures << "已还原 #{catalog_path} 到改动前的内容。"
  else
    failures << "!!! 还原也失败了,#{catalog_path} 现在的内容不可信,请立即 git checkout 该文件。"
  end
  failures
end

def parse_arguments(argv)
  args = argv.dup
  dry_run = false
  catalog = DEFAULT_CATALOG
  positional = []
  while (arg = args.shift)
    case arg
    when "--dry-run"
      dry_run = true
    when "--catalog"
      catalog = args.shift or abort "--catalog 需要一个路径参数\n#{USAGE}"
    when /\A--catalog=(.+)\z/
      catalog = Regexp.last_match(1)
    when /\A--/
      abort "未知参数 #{arg.inspect}\n#{USAGE}"
    else
      positional << arg
    end
  end
  keys_path = positional.shift or abort USAGE
  abort "多余的参数: #{positional.join(', ')}\n#{USAGE}" unless positional.empty?
  [keys_path, File.expand_path(catalog), dry_run]
end

def run(argv)
  keys_path, catalog_path, dry_run = parse_arguments(argv)
  requested = JSON.parse(File.read(keys_path, encoding: "UTF-8"))
  abort "keys.json 顶层必须是 { key => { locale => 文案 } } 的对象" unless requested.is_a?(Hash)

  original_text = File.binread(catalog_path).force_encoding("UTF-8")
  before_catalog = begin
    JSON.parse(original_text)
  rescue JSON::ParserError => e
    abort "catalog 本身就不是合法 JSON,先修好再跑本脚本: #{e.message}"
  end
  before_strings = before_catalog["strings"]
  abort "catalog 缺少 strings 对象" unless before_strings.is_a?(Hash)

  lines = original_text.lines
  entries, strings_close_row = scan_catalog(lines)
  # 结构扫描和 JSON 解析必须对得上,对不上说明这个文件的版式不是本脚本假设的
  # 「一条目一起一止」,那就不碰。
  if entries.length != before_strings.length
    abort "catalog 版式超出本脚本假设:结构扫描到 #{entries.length} 个顶层条目," \
          "JSON 解析出 #{before_strings.length} 个。请改用 Xcode 或手工处理。"
  end
  by_key = entries.to_h { |entry| [entry["key"], entry] }

  created = []
  updated = []
  skipped_multiline = []
  unchanged = []
  placements = []
  expected_entries = {}

  # 逐条处理,倒序落笔:先算好所有插入点再从后往前改,行号才不会互相错位。
  inserts = []  # [插入行号, 文本]
  replaces = [] # [行号, 文本]

  requested.each do |key, localizations|
    unless localizations.is_a?(Hash) && !localizations.empty?
      abort "key #{key.inspect} 的值必须是非空的 { locale => 文案 } 对象"
    end

    if (entry = by_key[key])
      before_entry = before_strings[key]
      current = (before_entry["localizations"] || {}).transform_values do |unit|
        unit.dig("stringUnit", "value")
      end
      if localizations.all? { |language, value| current[language] == value }
        unchanged << key
        next
      end
      # 紧凑单行条目才就地改;多行条目一律不碰。
      if entry["start"] != entry["end"]
        skipped_multiline << key
        next
      end
      merged = merged_entry(before_entry, localizations)
      replaces << [entry["start"], entry_line(key, merged)]
      expected_entries[key] = merged
      updated << key
      next
    end

    row, explanation = placement_for(key, entries, strings_close_row)
    abort "无法为新 key #{key.inspect} 找到落点:#{explanation}" if row.nil?
    merged = merged_entry(nil, localizations)
    inserts << [row, entry_line(key, merged)]
    expected_entries[key] = merged
    created << key
    placements << "#{key} → #{explanation}"
  end

  # 同一插入点上有多条时,保持它们彼此的字母序。
  inserts.sort_by! { |row, text| [row, text] }
  replaces.each { |row, text| lines[row] = text }
  inserts.reverse_each { |row, text| lines.insert(row, text) }
  normalize_entry_commas!(lines)

  new_text = lines.join

  failures = verification_failures(before_catalog, new_text, expected_entries, created)

  if dry_run
    report(created, updated, unchanged, skipped_multiline, placements)
    unless failures.empty?
      warn "\n校验未通过(dry-run,本来也没写盘):"
      failures.each { |failure| warn "  - #{failure}" }
      exit 1
    end
    puts "(dry-run,未写盘;校验通过)"
    return 0
  end

  unless failures.empty?
    warn "校验未通过,已放弃写盘,catalog 保持原样:"
    failures.each { |failure| warn "  - #{failure}" }
    exit 1
  end

  disk_failures = write_verified(
    catalog_path, original_text, new_text, before_catalog, expected_entries, created
  )
  unless disk_failures.empty?
    warn "落盘校验未通过:"
    disk_failures.each { |failure| warn "  - #{failure}" }
    exit 1
  end

  report(created, updated, unchanged, skipped_multiline, placements)
  puts "校验通过:#{expected_entries.size} 个 key 均可在 strings.<key> 上按请求的 locale 读出,其余条目未被改动。"
  0
end

def report(created, updated, unchanged, skipped_multiline, placements)
  puts "新增 key: #{created.size}#{created.empty? ? '' : " (#{created.join(', ')})"}"
  puts "更新 key: #{updated.size}#{updated.empty? ? '' : " (#{updated.join(', ')})"}"
  puts "无变化:   #{unchanged.size}"
  unless skipped_multiline.empty?
    puts "跳过(多行条目,需手工处理): #{skipped_multiline.size} → #{skipped_multiline.join(', ')}"
  end
  return if placements.empty?
  puts "落点:"
  placements.each { |placement| puts "  #{placement}" }
end

exit(run(ARGV) || 0) if __FILE__ == $PROGRAM_NAME
