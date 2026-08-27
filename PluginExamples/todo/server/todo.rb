#!/usr/bin/env ruby
# frozen_string_literal: true

# Todo — WillDeep 待办插件的 MCP stdio 服务端。
#
# 工具：
#   - todo.add        新建待办（字段自己给全）
#   - todo.quick_add  一句话新建：服务端从这句话里解析计划时间与优先级
#   - todo.list       列出待办（按项目/状态过滤，附带分组统计与项目直方图）
#   - todo.update     改标题 / 备注 / 计划时间 / 优先级 / 归属项目
#   - todo.toggle     打勾 / 取消打勾
#   - todo.remove     删一条，并把整条回传（页面据此做撤销）
#   - todo.restore    把整条塞回去（撤销删除）
#   - todo.stats      概览：未完成、逾期、今天到期、按项目分布
#
# 两条「一句话变待办」的路子：
#   1. 页面里的快速输入走 `todo.quick_add`，由本文件的确定性解析器就地识别
#      「明天下午三点」「很急」这类说法——即时、不烧 token、断网也能用。
#   2. 在聊天里说「记个待办：…」时，Agent 直接调 `todo.add` 并自己把时间与
#      优先级算好——模型理解得更宽，代价是一次模型调用。
#   两条路写进同一份存储，字段完全一致。
#
# 存储：单个 JSON 文件，默认
# ~/Library/Application Support/WillDeep/plugin-data/todos.json，
# 可用 WD_TODO_FILE 覆盖（测试与沙箱用）。写盘走「临时文件 + rename」。
#
# 注意：宿主用系统 /usr/bin/ruby（2.6）启动本文件，只用 2.6 就有的语法与方法。

require "json"
require "fileutils"
require "securerandom"
require "time"
require "date"

$stdout.sync = true

# 宿主用 /usr/bin/ruby 起服务端时不带 UTF-8 locale，待办正文多是中文，先钉死编码。
Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8
$stdout.set_encoding(Encoding::UTF_8)
$stderr.set_encoding(Encoding::UTF_8)

STORE_VERSION = 1
MAX_ITEMS = 1_000
MAX_TEXT_BYTES = 4_000
MAX_NOTE_BYTES = 4_000
PRIORITIES = %w[urgent high normal low].freeze
PRIORITY_RANK = { "urgent" => 0, "high" => 1, "normal" => 2, "low" => 3 }.freeze

def store_path
  ENV["WD_TODO_FILE"] ||
    File.expand_path("~/Library/Application Support/WillDeep/plugin-data/todos.json")
end

def clip(value, limit)
  string = value.to_s
  return string if string.bytesize <= limit
  string.byteslice(0, limit).scrub("")
end

def now_iso
  Time.now.utc.iso8601
end

def parse_time(raw)
  return nil if raw.nil?
  string = raw.to_s.strip
  return nil if string.empty?
  begin
    Time.parse(string)
  rescue ArgumentError, TypeError
    nil
  end
end

def normalize_priority(raw)
  value = raw.to_s.strip.downcase
  PRIORITIES.include?(value) ? value : nil
end

# 项目名取工作区目录名；路径原样留着，页面用来做 tooltip 与去重。
def project_name_for(path, fallback = nil)
  name = fallback.to_s.strip
  return name unless name.empty?
  return nil if path.to_s.strip.empty?
  File.basename(path.to_s.sub(%r{/+\z}, ""))
end

def normalize_item(raw)
  return nil unless raw.is_a?(Hash)
  text = clip(raw["text"], MAX_TEXT_BYTES).strip
  return nil if text.empty?

  created = parse_time(raw["createdAt"]) || Time.now
  due = parse_time(raw["due"])
  path = raw["projectPath"].to_s.strip
  {
    "id" => (raw["id"].to_s.strip.empty? ? SecureRandom.uuid : raw["id"].to_s.strip[0, 64]),
    "text" => text,
    "note" => clip(raw["note"], MAX_NOTE_BYTES).strip,
    "project" => project_name_for(path, raw["project"]),
    "projectPath" => path.empty? ? nil : path,
    "due" => due ? due.utc.iso8601 : nil,
    "allDay" => raw["allDay"] == true,
    "priority" => normalize_priority(raw["priority"]),
    "done" => raw["done"] == true,
    "doneAt" => parse_time(raw["doneAt"]) ? parse_time(raw["doneAt"]).utc.iso8601 : nil,
    "source" => clip(raw["source"], 200).strip,
    "createdAt" => created.utc.iso8601,
    "updatedAt" => (parse_time(raw["updatedAt"]) || created).utc.iso8601
  }
end

# ── 一句话解析 ─────────────────────────────────────────────
# 只认确定性的说法，认不出来就老老实实什么都不填——宁可少认，
# 也不要把「下周汇报的材料」猜成下周一到期。

# 顺序即优先级判定顺序，别随手调换：否定说法必须先出手，否则
# 「不急」里的那个「急」会被 high 那条吃掉，实测就栽在这里。
PRIORITY_PATTERNS = [
  [/(不急|不着急|不紧急|不重要|低优先级|低优|有空再|有空|闲时|随缘|p3|later|low priority)/i, "low"],
  [/(十万火急|火急|紧急|超急|特急|马上|立刻|立即|asap|urgent)/i, "urgent"],
  [/(很急|挺急|急着|尽快|赶紧|优先处理|高优先级|高优|重要|要紧|急|p0|p1|!{2,}|high priority)/i, "high"],
  [/(一般|普通|正常|p2|normal priority)/i, "normal"]
].freeze

# 「三点」「十点半」这类中文数字小时；不做完整中文数字解析，只覆盖 0-24 点
CHINESE_HOURS = {
  "零" => 0, "一" => 1, "两" => 2, "二" => 2, "三" => 3, "四" => 4, "五" => 5, "六" => 6,
  "七" => 7, "八" => 8, "九" => 9, "十" => 10, "十一" => 11, "十二" => 12,
  "十三" => 13, "十四" => 14, "十五" => 15, "十六" => 16, "十七" => 17, "十八" => 18,
  "十九" => 19, "二十" => 20, "二十一" => 21, "二十二" => 22, "二十三" => 23
}.freeze
CHINESE_MINUTES = { "十" => 10, "十五" => 15, "二十" => 20, "三十" => 30, "四十" => 40, "四十五" => 45, "五十" => 50 }.freeze
# 说「今晚」「明早」时，时段信息在日期短语里，得带给时钟解析用
PERIOD_HINTS = { "晚" => "晚上", "早" => "上午", "夜" => "晚上" }.freeze

WEEKDAYS = {
  "一" => 1, "二" => 2, "三" => 3, "四" => 4, "五" => 5, "六" => 6, "日" => 7, "天" => 7,
  "1" => 1, "2" => 2, "3" => 3, "4" => 4, "5" => 5, "6" => 6, "7" => 7
}.freeze

ENGLISH_WEEKDAYS = {
  "monday" => 1, "mon" => 1, "tuesday" => 2, "tue" => 2, "wednesday" => 3, "wed" => 3,
  "thursday" => 4, "thu" => 4, "friday" => 5, "fri" => 5,
  "saturday" => 6, "sat" => 6, "sunday" => 7, "sun" => 7
}.freeze

class NaturalParse
  attr_accessor :text, :due, :all_day, :priority, :matched

  def initialize(text)
    @text = text
    @due = nil
    @all_day = true
    @priority = nil
    @matched = []
  end
end

def strip_phrase(text, phrase)
  return text if phrase.nil? || phrase.empty?
  text.sub(phrase, " ")
end

# 剥时间短语时把紧跟其后的「之前 / 前 / 之后」一并收走：
# 「下周五之前把文档补完」剥完得是「把文档补完」，不是「之前把文档补完」。
# 只吃紧挨着的那个——不能按行首去猜，否则「前端页面 明天做」会被啃成「端页面」。
def strip_time_phrase(text, phrase)
  return text if phrase.nil? || phrase.empty?
  text.sub(/#{Regexp.escape(phrase)}\s*(之前|以前|之后|以后|前|后)?/, " ")
end

def tidy(text)
  text.gsub(/[[:space:]]+/, " ")
      .gsub(/\A[[:space:],，、。:：\-]+/, "")
      .gsub(/[[:space:],，、。:：\-]+\z/, "")
      .strip
end

def parse_natural(raw_text, now = Time.now)
  parse = NaturalParse.new(raw_text.to_s)
  working = parse.text.dup

  PRIORITY_PATTERNS.each do |pattern, level|
    match = working.match(pattern)
    next unless match
    parse.priority = level
    parse.matched << match[0]
    working = strip_phrase(working, match[0])
    break
  end

  date, date_phrase = parse_date(working, now)
  period_hint = nil
  if date_phrase
    parse.matched << date_phrase
    PERIOD_HINTS.each { |needle, period| period_hint ||= period if date_phrase.include?(needle) }
    working = strip_time_phrase(working, date_phrase)
  end

  hour, minute, time_phrase = parse_clock(working, period_hint)
  if time_phrase
    parse.matched << time_phrase
    working = strip_time_phrase(working, time_phrase)
  end

  if date || time_phrase
    day = date || Date.new(now.year, now.month, now.day)
    if hour
      parse.due = Time.local(day.year, day.month, day.day, hour, minute || 0, 0)
      parse.all_day = false
      # 「三点」已经过去了就顺延到明天，除非说话人明确点了日期
      parse.due += 86_400 if date.nil? && parse.due <= now
    else
      parse.due = Time.local(day.year, day.month, day.day, 23, 59, 0)
      parse.all_day = true
    end
  end

  parse.text = tidy(working)
  parse.text = tidy(parse.text.sub(/\A(记[个一]?待办|待办|todo|提醒我|记得)[:：,，]?/i, ""))
  parse.text = raw_text.to_s.strip if parse.text.empty?
  parse
end

def parse_date(text, now)
  today = Date.new(now.year, now.month, now.day)

  if (m = text.match(/(\d{4})\s*[-\/年]\s*(\d{1,2})\s*[-\/月]\s*(\d{1,2})\s*日?/))
    return [safe_date(m[1].to_i, m[2].to_i, m[3].to_i), m[0]]
  end
  if (m = text.match(/(\d{1,2})\s*[月\/]\s*(\d{1,2})\s*[日号]?/))
    date = safe_date(now.year, m[1].to_i, m[2].to_i)
    date = safe_date(now.year + 1, m[1].to_i, m[2].to_i) if date && date < today
    return [date, m[0]]
  end
  if (m = text.match(/(\d+)\s*(天|日)后/))
    return [today + m[1].to_i, m[0]]
  end
  if (m = text.match(/in\s+(\d+)\s+days?/i))
    return [today + m[1].to_i, m[0]]
  end
  if (m = text.match(/(下下周|下下星期|下周|下星期|本周|这周|这星期)\s*([一二三四五六日天1-7])/))
    base = case m[1]
           when "下下周", "下下星期" then 2
           when "下周", "下星期" then 1
           else 0
           end
    return [weekday_in_week(today, WEEKDAYS[m[2]], base), m[0]]
  end
  if (m = text.match(/(周|星期|礼拜)\s*([一二三四五六日天1-7])/))
    return [next_weekday(today, WEEKDAYS[m[2]]), m[0]]
  end
  if (m = text.match(/next\s+(monday|tuesday|wednesday|thursday|friday|saturday|sunday|mon|tue|wed|thu|fri|sat|sun)/i))
    return [weekday_in_week(today, ENGLISH_WEEKDAYS[m[1].downcase], 1), m[0]]
  end
  if (m = text.match(/\b(monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b/i))
    return [next_weekday(today, ENGLISH_WEEKDAYS[m[1].downcase]), m[0]]
  end
  if (m = text.match(/(大后天)/))
    return [today + 3, m[0]]
  end
  if (m = text.match(/(后天|day after tomorrow)/i))
    return [today + 2, m[0]]
  end
  if (m = text.match(/(明天|明日|明早|明晚|tomorrow)/i))
    return [today + 1, m[0]]
  end
  if (m = text.match(/(今天|今日|今晚|今早|today|tonight)/i))
    return [today, m[0]]
  end
  if (m = text.match(/(本月底|月底|end of month)/i))
    return [Date.new(today.year, today.month, -1), m[0]]
  end
  if (m = text.match(/(下周|下星期|next week)/i))
    return [weekday_in_week(today, 1, 1), m[0]]
  end
  [nil, nil]
end

def safe_date(year, month, day)
  Date.new(year, month, day)
rescue ArgumentError, Date::Error
  nil
end

# 下一个「周 X」：今天就是周 X 时算下周的那个，免得把「周五交」理解成刚过去的周五
def next_weekday(today, weekday)
  return nil if weekday.nil?
  delta = (weekday - today.cwday) % 7
  delta = 7 if delta.zero?
  today + delta
end

# 本周/下周/下下周的周 X（周一为一周之始）
def weekday_in_week(today, weekday, week_offset)
  return nil if weekday.nil?
  monday = today - (today.cwday - 1)
  monday + (week_offset * 7) + (weekday - 1)
end

def parse_clock(text, period_hint = nil)
  if (m = text.match(/(上午|早上|中午|下午|傍晚|晚上|凌晨)?\s*([零一两二三四五六七八九十]{1,3})\s*[点时]\s*([零一两二三四五六七八九十]{1,3})?\s*(分|半)?/))
    period = m[1] || period_hint
    hour = CHINESE_HOURS[m[2]]
    return [nil, nil, nil] if hour.nil?
    minute = m[4] == "半" ? 30 : (m[3] ? (CHINESE_MINUTES[m[3]] || 0) : 0)
    hour += 12 if %w[下午 傍晚 晚上].include?(period) && hour < 12
    hour = 0 if period == "凌晨" && hour == 12
    return [nil, nil, nil] if hour > 23 || minute > 59
    return [hour, minute, m[0]]
  end
  if (m = text.match(/(上午|早上|中午|下午|傍晚|晚上|凌晨)?\s*(\d{1,2})\s*[:：点时]\s*(\d{1,2})?\s*(分|半)?/))
    period = m[1] || period_hint
    hour = m[2].to_i
    minute = m[3] ? m[3].to_i : (m[4] == "半" ? 30 : 0)
    hour += 12 if %w[下午 傍晚 晚上].include?(period) && hour < 12
    hour = 0 if period == "凌晨" && hour == 12
    hour = 12 if period == "中午" && hour == 12
    return [nil, nil, nil] if hour > 23 || minute > 59
    return [hour, minute, m[0]]
  end
  if (m = text.match(/\b(\d{1,2})(?::(\d{2}))?\s*(am|pm)\b/i))
    hour = m[1].to_i
    minute = m[2] ? m[2].to_i : 0
    hour += 12 if m[3].downcase == "pm" && hour < 12
    hour = 0 if m[3].downcase == "am" && hour == 12
    return [nil, nil, nil] if hour > 23 || minute > 59
    return [hour, minute, m[0]]
  end
  [nil, nil, nil]
end

# ── 存储 ───────────────────────────────────────────────────
DEFAULT_SETTINGS = { "parser" => "ai", "providerID" => nil, "model" => nil }.freeze

# 设置跟待办放同一个文件：页面要在「用 AI 解析」和「用本地规则」之间切，
# 还要能钉一个 provider / 模型（比如换成本机 Ollama）。宿主的插件设置项
# 读不到页面里，所以由服务端自己存。
def load_settings
  raw = File.read(store_path)
  data = JSON.parse(raw)
  stored = data.is_a?(Hash) ? data["settings"] : nil
  return DEFAULT_SETTINGS.dup unless stored.is_a?(Hash)
  settings = DEFAULT_SETTINGS.merge(stored)
  settings["parser"] = "ai" unless %w[ai local].include?(settings["parser"])
  settings["providerID"] = settings["providerID"].to_s.strip
  settings["providerID"] = nil if settings["providerID"].empty?
  settings["model"] = settings["model"].to_s.strip
  settings["model"] = nil if settings["model"].empty?
  settings
rescue Errno::ENOENT, JSON::ParserError, SystemCallError
  DEFAULT_SETTINGS.dup
end

def save_settings(settings)
  items = load_items
  FileUtils.mkdir_p(File.dirname(store_path))
  payload = JSON.pretty_generate(
    { "version" => STORE_VERSION, "settings" => settings, "items" => ordered(items).first(MAX_ITEMS) }
  )
  temporary = "#{store_path}.tmp"
  File.write(temporary, payload)
  File.rename(temporary, store_path)
  settings
end

def load_items
  raw = File.read(store_path)
  data = JSON.parse(raw)
  items = data.is_a?(Hash) ? data["items"] : data
  return [] unless items.is_a?(Array)
  normalized = []
  items.each { |item| normalized << normalize_item(item) }
  normalized.compact
rescue Errno::ENOENT
  []
rescue JSON::ParserError, SystemCallError => error
  warn "todo: unreadable store (#{error.message}); starting empty"
  []
end

def save_items(items)
  kept = ordered(items).first(MAX_ITEMS)
  FileUtils.mkdir_p(File.dirname(store_path))
  payload = JSON.pretty_generate(
    { "version" => STORE_VERSION, "settings" => load_settings, "items" => kept }
  )
  temporary = "#{store_path}.tmp"
  File.write(temporary, payload)
  File.rename(temporary, store_path)
  kept
end

# 未完成在前；再按「有计划时间的先来、早的先来」，然后优先级，最后创建时间。
# 全序，不依赖排序算法是否稳定。
def ordered(items)
  items.each_with_index.sort_by do |item, index|
    [
      item["done"] ? 1 : 0,
      item["due"] ? 0 : 1,
      item["due"] ? sort_key(item["due"]) : 0,
      PRIORITY_RANK[item["priority"]] || 2,
      -sort_key(item["createdAt"]),
      index
    ]
  end.map { |pair| pair[0] }
end

def sort_key(iso)
  time = parse_time(iso)
  time ? time.to_f : 0
end

# ── 工具实现 ───────────────────────────────────────────────
def build_item(arguments, parsed = nil)
  normalize_item(
    "text" => parsed ? parsed.text : arguments["text"],
    "note" => arguments["note"],
    "project" => arguments["project"],
    "projectPath" => arguments["projectPath"] || arguments["workspace"],
    "due" => arguments["due"] || (parsed && parsed.due ? parsed.due.utc.iso8601 : nil),
    "allDay" => arguments.key?("allDay") ? arguments["allDay"] == true : (parsed ? parsed.all_day : false),
    "priority" => arguments["priority"] || (parsed ? parsed.priority : nil),
    "source" => arguments["source"],
    "createdAt" => now_iso
  )
end

def add_item(arguments)
  item = build_item(arguments)
  return { "ok" => false, "error" => "empty text" } if item.nil?
  saved = save_items([item] + load_items)
  { "ok" => true, "item" => item, "count" => saved.length }
end

def quick_add(arguments)
  raw = arguments["text"].to_s
  return { "ok" => false, "error" => "empty text" } if raw.strip.empty?
  parsed = parse_natural(raw)
  item = build_item(arguments, parsed)
  return { "ok" => false, "error" => "empty text" } if item.nil?
  saved = save_items([item] + load_items)
  {
    "ok" => true,
    "item" => item,
    "count" => saved.length,
    # 页面拿它显示「已识别：明天 18:00 · 高」，让用户一眼看出机器理解成了什么
    "parsed" => {
      "text" => parsed.text,
      "due" => parsed.due ? parsed.due.utc.iso8601 : nil,
      "allDay" => parsed.all_day,
      "priority" => parsed.priority,
      "matched" => parsed.matched
    }
  }
end

def update_item(arguments)
  id = arguments["id"].to_s
  return { "ok" => false, "error" => "missing id" } if id.empty?
  items = load_items
  index = items.index { |item| item["id"] == id }
  return { "ok" => false, "error" => "not found" } if index.nil?

  item = items[index]
  item["text"] = clip(arguments["text"], MAX_TEXT_BYTES).strip if arguments.key?("text") && !arguments["text"].to_s.strip.empty?
  item["note"] = clip(arguments["note"], MAX_NOTE_BYTES).strip if arguments.key?("note")
  if arguments.key?("due")
    due = parse_time(arguments["due"])
    item["due"] = due ? due.utc.iso8601 : nil
    item["allDay"] = arguments.key?("allDay") ? arguments["allDay"] == true : item["allDay"]
  end
  item["priority"] = normalize_priority(arguments["priority"]) if arguments.key?("priority")
  if arguments.key?("projectPath") || arguments.key?("project")
    path = (arguments["projectPath"] || "").to_s.strip
    item["projectPath"] = path.empty? ? nil : path
    item["project"] = project_name_for(path, arguments["project"])
  end
  item["updatedAt"] = now_iso
  save_items(items)
  { "ok" => true, "item" => item }
end

def toggle_item(arguments)
  id = arguments["id"].to_s
  return { "ok" => false, "error" => "missing id" } if id.empty?
  items = load_items
  index = items.index { |item| item["id"] == id }
  return { "ok" => false, "error" => "not found" } if index.nil?

  item = items[index]
  done = arguments.key?("done") ? (arguments["done"] == true || arguments["done"].to_s == "true") : !item["done"]
  item["done"] = done
  item["doneAt"] = done ? now_iso : nil
  item["updatedAt"] = now_iso
  save_items(items)
  { "ok" => true, "item" => item }
end

def remove_item(arguments)
  id = arguments["id"].to_s
  return { "ok" => false, "error" => "missing id" } if id.empty?
  items = load_items
  removed = items.find { |item| item["id"] == id }
  remaining = items.reject { |item| item["id"] == id }
  saved = save_items(remaining)
  { "ok" => true, "removed" => removed.nil? ? 0 : 1, "item" => removed, "count" => saved.length }
end

def restore_item(arguments)
  payload = arguments["item"] || arguments
  item = normalize_item(payload)
  return { "ok" => false, "error" => "empty text" } if item.nil?
  items = load_items.reject { |existing| existing["id"] == item["id"] }
  saved = save_items(items + [item])
  { "ok" => true, "item" => item, "count" => saved.length }
end

def matches_scope?(item, scope, project_path)
  case scope
  when "project"
    return false if project_path.to_s.empty?
    item["projectPath"] == project_path
  when "inbox"
    item["projectPath"].nil?
  else
    true
  end
end

def matches_status?(item, status)
  case status
  when "done" then item["done"]
  when "all" then true
  else !item["done"]
  end
end

def list_items(arguments)
  items = ordered(load_items)
  scope = arguments["scope"].to_s
  scope = "all" if scope.empty?
  status = arguments["status"].to_s
  status = "open" if status.empty?
  project_path = (arguments["projectPath"] || arguments["workspace"]).to_s
  query = clip(arguments["query"], 200).strip.downcase

  filtered = items.select do |item|
    next false unless matches_scope?(item, scope, project_path)
    next false unless matches_status?(item, status)
    next true if query.empty?
    [item["text"], item["note"], item["project"]].join("\n").downcase.include?(query)
  end

  {
    "ok" => true,
    "total" => items.length,
    "count" => filtered.length,
    "items" => filtered,
    "projects" => project_histogram(items),
    "buckets" => bucket_counts(items),
    "storePath" => store_path,
    "settings" => load_settings,
    "now" => now_iso
  }
end

def project_histogram(items)
  counts = {}
  items.each do |item|
    next if item["done"]
    key = item["projectPath"] || ""
    entry = (counts[key] ||= { "name" => item["project"], "path" => item["projectPath"], "count" => 0 })
    entry["count"] += 1
  end
  counts.values.sort_by { |entry| [-entry["count"], entry["name"].to_s] }
end

# 逾期 / 今天 / 明天 / 本周内 / 以后 / 没定时间，页面按这套分组渲染
def bucket_counts(items)
  now = Time.now
  today = Date.new(now.year, now.month, now.day)
  counts = { "overdue" => 0, "today" => 0, "tomorrow" => 0, "week" => 0, "later" => 0, "someday" => 0, "done" => 0 }
  items.each do |item|
    if item["done"]
      counts["done"] += 1
      next
    end
    due = parse_time(item["due"])
    unless due
      counts["someday"] += 1
      next
    end
    local = due.getlocal
    day = Date.new(local.year, local.month, local.day)
    if due < now
      counts["overdue"] += 1
    elsif day == today
      counts["today"] += 1
    elsif day == today + 1
      counts["tomorrow"] += 1
    elsif day <= today + 7
      counts["week"] += 1
    else
      counts["later"] += 1
    end
  end
  counts
end

def stats(_arguments)
  items = load_items
  { "ok" => true, "total" => items.length, "buckets" => bucket_counts(items),
    "projects" => project_histogram(items) }
end

def settings_tool(arguments)
  settings = load_settings
  if arguments.key?("parser") || arguments.key?("providerID") || arguments.key?("model")
    settings["parser"] = arguments["parser"].to_s if %w[ai local].include?(arguments["parser"].to_s)
    if arguments.key?("providerID")
      value = arguments["providerID"].to_s.strip
      settings["providerID"] = value.empty? ? nil : value
    end
    if arguments.key?("model")
      value = arguments["model"].to_s.strip
      settings["model"] = value.empty? ? nil : value
    end
    save_settings(settings)
  end
  { "ok" => true, "settings" => settings }
end

def call_tool(name, arguments)
  case name
  when "todo.add" then add_item(arguments)
  when "todo.quick_add" then quick_add(arguments)
  when "todo.list" then list_items(arguments)
  when "todo.update" then update_item(arguments)
  when "todo.toggle" then toggle_item(arguments)
  when "todo.remove" then remove_item(arguments)
  when "todo.restore" then restore_item(arguments)
  when "todo.stats" then stats(arguments)
  when "todo.settings" then settings_tool(arguments)
  else { "ok" => false, "error" => "unknown tool #{name}" }
  end
end

PRIORITY_SCHEMA = { type: "string", enum: PRIORITIES, description: "Optional priority." }.freeze
DUE_SCHEMA = { type: "string", description: "Optional planned completion time (ISO 8601)." }.freeze

TOOLS = [
  {
    name: "todo.add",
    description: "Create a todo with explicit fields. Prefer this from chat: work out the " \
                 "due date and priority yourself, then pass them here.",
    inputSchema: {
      type: "object",
      properties: {
        text: { type: "string", description: "What to do." },
        note: { type: "string", description: "Optional note." },
        projectPath: { type: "string", description: "Workspace path this todo belongs to. Omit for an unfiled todo." },
        due: DUE_SCHEMA,
        allDay: { type: "boolean", description: "True when only a date was given." },
        priority: PRIORITY_SCHEMA,
        source: { type: "string", description: "Where the todo came from." }
      },
      required: ["text"]
    }
  },
  {
    name: "todo.quick_add",
    description: "Create a todo from one sentence. The server parses the planned time and " \
                 "priority out of the sentence deterministically (no model call).",
    inputSchema: {
      type: "object",
      properties: {
        text: { type: "string", description: "One sentence, e.g. 明天下午三点前把发布验一遍，很急." },
        projectPath: { type: "string", description: "Workspace path this todo belongs to." },
        source: { type: "string", description: "Where the todo came from." }
      },
      required: ["text"]
    }
  },
  {
    name: "todo.list",
    description: "List todos with grouping counts and a per-project histogram.",
    inputSchema: {
      type: "object",
      properties: {
        scope: { type: "string", enum: %w[all project inbox], description: "all / this project / unfiled." },
        projectPath: { type: "string", description: "Workspace path, required when scope is project." },
        status: { type: "string", enum: %w[open done all], description: "Defaults to open." },
        query: { type: "string", description: "Keyword filter." }
      }
    }
  },
  {
    name: "todo.update",
    description: "Update the text, note, due date, priority or project of one todo.",
    inputSchema: {
      type: "object",
      properties: {
        id: { type: "string" }, text: { type: "string" }, note: { type: "string" },
        due: DUE_SCHEMA, allDay: { type: "boolean" }, priority: PRIORITY_SCHEMA,
        projectPath: { type: "string" }
      },
      required: ["id"]
    }
  },
  {
    name: "todo.toggle",
    description: "Mark a todo done or not done.",
    inputSchema: {
      type: "object",
      properties: { id: { type: "string" }, done: { type: "boolean" } },
      required: ["id"]
    }
  },
  {
    name: "todo.remove",
    description: "Remove one todo by id and return the removed record.",
    inputSchema: { type: "object", properties: { id: { type: "string" } }, required: ["id"] }
  },
  {
    name: "todo.restore",
    description: "Put a previously removed todo back, keeping its id and timestamps.",
    inputSchema: { type: "object", properties: { item: { type: "object" } }, required: ["item"] }
  },
  {
    name: "todo.settings",
    description: "Read or update the plugin's own preferences: whether one-sentence input is " \
                 "parsed by a model or by the built-in rules, and which provider/model to use.",
    inputSchema: {
      type: "object",
      properties: {
        parser: { type: "string", enum: %w[ai local] },
        providerID: { type: "string" },
        model: { type: "string" }
      }
    }
  },
  {
    name: "todo.stats",
    description: "Return counts by bucket (overdue / today / tomorrow / this week / later / someday) and by project.",
    inputSchema: { type: "object", properties: {} }
  }
].freeze

ARGF.each_line do |line|
  request = JSON.parse(line)
  next unless request["id"]

  result = case request["method"]
           when "initialize"
             { protocolVersion: "2025-06-18",
               capabilities: { tools: {} },
               serverInfo: { name: "todo", version: "1.0.0" } }
           when "tools/list"
             { tools: TOOLS }
           when "tools/call"
             arguments = request.dig("params", "arguments") || {}
             payload = call_tool(request.dig("params", "name"), arguments)
             { content: [{ type: "text", text: JSON.generate(payload) }] }
           else
             {}
           end

  puts JSON.generate(jsonrpc: "2.0", id: request["id"], result: result)
rescue JSON::ParserError => error
  warn error.message
end
