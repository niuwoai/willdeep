#!/usr/bin/env ruby
# frozen_string_literal: true

# Favorites — WillDeep 收藏夹插件的 MCP stdio 服务端。
#
# 提供的工具：
#   - favorites.add     收藏一段文字（聊天里选中文字 → 气泡「收藏」会打到这里）
#   - favorites.list    返回收藏（支持关键词/标签过滤，附带标签直方图，供页面渲染）
#   - favorites.update  改备注、改标签、置顶/取消置顶
#   - favorites.remove  按 id 删除一条，并把删掉的整条原样回传（页面据此做撤销）
#   - favorites.restore 把整条塞回去（撤销删除，保留原 id 与创建时间）
#   - favorites.clear   清空（必须显式传 confirm=true，免得被 Agent 顺手调掉）
#
# 存储：单个 JSON 文件，默认 ~/Library/Application Support/WillDeep/plugin-data/favorites.json，
# 可用 WD_FAVORITES_FILE 覆盖（测试与沙箱用）。写入走「临时文件 + rename」，
# 中途被杀不会留下半截文件。
#
# 注意：宿主用系统 /usr/bin/ruby（2.6）启动本文件，所以这里只用 2.6 就有的语法与方法，
# 不要用 filter_map / tally / Hash#except 这些 2.7+ 的东西。

require "json"
require "fileutils"
require "securerandom"
require "time"

$stdout.sync = true

# 宿主用 /usr/bin/ruby 起服务端时不带 UTF-8 locale，收藏内容多是中文，先钉死编码。
Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8
$stdout.set_encoding(Encoding::UTF_8)
$stderr.set_encoding(Encoding::UTF_8)

STORE_VERSION = 3
MAX_ITEMS = 500
MAX_TEXT_BYTES = 20_000
MAX_NOTE_BYTES = 2_000
MAX_TAGS = 8
MAX_TAG_CHARS = 24
DEFAULT_LIST_LIMIT = 500

def store_path
  ENV["WD_FAVORITES_FILE"] ||
    File.expand_path("~/Library/Application Support/WillDeep/plugin-data/favorites.json")
end

# 单条收藏的规范形态。v1 只有 id/text/note/source/createdAt，缺的字段在这里补齐，
# 所以旧存储文件不需要单独的迁移步骤：读进来就是 v2。
def normalize_item(raw)
  return nil unless raw.is_a?(Hash)

  text = clip(raw["text"], MAX_TEXT_BYTES).strip
  return nil if text.empty?

  created = timestamp(raw["createdAt"])
  {
    "id" => valid_id(raw["id"]) || SecureRandom.uuid,
    "text" => text,
    "note" => clip(raw["note"], MAX_NOTE_BYTES).strip,
    "tags" => normalize_tags(raw["tags"]),
    "source" => clip(raw["source"], 200).strip,
    "sourceSessionID" => valid_id(raw["sourceSessionID"]),
    "sourceMessageID" => valid_id(raw["sourceMessageID"]),
    "sourceTurnID" => valid_id(raw["sourceTurnID"]),
    "pinned" => raw["pinned"] == true,
    "createdAt" => created,
    "updatedAt" => timestamp(raw["updatedAt"]) || created
  }
end

def valid_id(raw)
  id = raw.to_s.strip
  id.empty? || id.length > 64 ? nil : id
end

def timestamp(raw)
  return nil if raw.nil?
  string = raw.to_s.strip
  return nil if string.empty?
  begin
    Time.parse(string).utc.iso8601
  rescue ArgumentError, TypeError
    nil
  end
end

def now_iso
  Time.now.utc.iso8601
end

def normalize_tags(raw)
  list = case raw
         when Array then raw
         when String then raw.split(/[,，\s]+/)
         else []
         end
  seen = []
  list.each do |value|
    tag = value.to_s.strip.gsub(/\s+/, " ")
    next if tag.empty?
    tag = tag[0, MAX_TAG_CHARS]
    next if seen.any? { |existing| existing.casecmp(tag).zero? }
    seen << tag
    break if seen.length >= MAX_TAGS
  end
  seen
end

def clip(value, limit)
  string = value.to_s
  return string if string.bytesize <= limit
  string.byteslice(0, limit).scrub("")
end

def load_items
  raw = File.read(store_path)
  data = JSON.parse(raw)
  items = data.is_a?(Hash) ? data["items"] : data
  return [] unless items.is_a?(Array)
  normalized = []
  items.each do |item|
    normalized << normalize_item(item)
  end
  normalized.compact
rescue Errno::ENOENT
  []
rescue JSON::ParserError, SystemCallError => error
  # 存储被写坏时按空列表继续跑：页面还能用，下一次写入会重建文件。
  warn "favorites: unreadable store (#{error.message}); starting empty"
  []
end

def save_items(items)
  kept = ordered(items).first(MAX_ITEMS)
  FileUtils.mkdir_p(File.dirname(store_path))
  payload = JSON.pretty_generate({ "version" => STORE_VERSION, "items" => kept })
  temporary = "#{store_path}.tmp"
  File.write(temporary, payload)
  File.rename(temporary, store_path)
  kept
end

# 置顶的永远在前，其余按更新时间倒序；同一时间戳时按创建时间兜底，
# 保证列表顺序是一个确定的全序，不会因为排序不稳定而抖动。
def ordered(items)
  items.each_with_index.sort_by do |item, index|
    [
      item["pinned"] ? 0 : 1,
      -sort_key(item["updatedAt"] || item["createdAt"]),
      -sort_key(item["createdAt"]),
      index
    ]
  end.map { |pair| pair[0] }
end

def sort_key(iso)
  return 0 if iso.nil?
  begin
    Time.parse(iso).to_f
  rescue ArgumentError, TypeError
    0
  end
end

def tag_histogram(items)
  counts = {}
  items.each do |item|
    item["tags"].each do |tag|
      key = counts.keys.find { |existing| existing.casecmp(tag).zero? } || tag
      counts[key] = (counts[key] || 0) + 1
    end
  end
  counts.sort_by { |tag, count| [-count, tag] }.map { |tag, count| { "name" => tag, "count" => count } }
end

def matches?(item, query, tag)
  unless tag.nil? || tag.empty?
    return false unless item["tags"].any? { |value| value.casecmp(tag).zero? }
  end
  return true if query.nil? || query.empty?
  needle = query.downcase
  haystack = [item["text"], item["note"], item["source"], item["tags"].join(" ")].join("\n").downcase
  haystack.include?(needle)
end

def add_item(arguments)
  candidate = normalize_item(
    "text" => arguments["text"],
    "note" => arguments["note"],
    "tags" => arguments["tags"],
    "source" => arguments["source"],
    "sourceSessionID" => arguments["source_session_id"],
    "sourceMessageID" => arguments["source_message_id"],
    "sourceTurnID" => arguments["source_turn_id"],
    "pinned" => arguments["pinned"],
    "createdAt" => now_iso
  )
  return { "ok" => false, "error" => "empty text" } if candidate.nil?

  items = load_items
  # 同一段文字重复收藏不再堆一条新的：把老的顶上来，并告诉调用方这是重复。
  existing_index = items.index { |item| item["text"] == candidate["text"] }
  if existing_index
    existing = items[existing_index]
    existing["updatedAt"] = now_iso
    existing["note"] = candidate["note"] unless candidate["note"].empty?
    existing["tags"] = normalize_tags(existing["tags"] + candidate["tags"]) unless candidate["tags"].empty?
    existing["sourceSessionID"] = candidate["sourceSessionID"] unless candidate["sourceSessionID"].nil?
    existing["sourceMessageID"] = candidate["sourceMessageID"] unless candidate["sourceMessageID"].nil?
    existing["sourceTurnID"] = candidate["sourceTurnID"] unless candidate["sourceTurnID"].nil?
    saved = save_items(items)
    return { "ok" => true, "duplicate" => true, "item" => existing, "count" => saved.length }
  end

  saved = save_items([candidate] + items)
  { "ok" => true, "duplicate" => false, "item" => candidate, "count" => saved.length }
end

def restore_item(arguments)
  payload = arguments["item"]
  payload = arguments if payload.nil?
  candidate = normalize_item(payload)
  return { "ok" => false, "error" => "empty text" } if candidate.nil?

  items = load_items.reject { |item| item["id"] == candidate["id"] }
  saved = save_items(items + [candidate])
  { "ok" => true, "item" => candidate, "count" => saved.length }
end

def update_item(arguments)
  id = arguments["id"].to_s
  return { "ok" => false, "error" => "missing id" } if id.empty?

  items = load_items
  index = items.index { |item| item["id"] == id }
  return { "ok" => false, "error" => "not found" } if index.nil?

  item = items[index]
  item["note"] = clip(arguments["note"], MAX_NOTE_BYTES).strip if arguments.key?("note")
  item["tags"] = normalize_tags(arguments["tags"]) if arguments.key?("tags")
  item["pinned"] = arguments["pinned"] == true || arguments["pinned"].to_s == "true" if arguments.key?("pinned")
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
  # 把整条回传，页面才能用它做撤销（保留原 id 与创建时间）。
  { "ok" => true, "removed" => removed.nil? ? 0 : 1, "item" => removed, "count" => saved.length }
end

def clear_items(arguments)
  confirmed = arguments["confirm"] == true || arguments["confirm"].to_s == "true"
  return { "ok" => false, "error" => "clear requires confirm=true" } unless confirmed

  count = load_items.length
  save_items([])
  { "ok" => true, "removed" => count, "count" => 0 }
end

def list_items(arguments)
  items = ordered(load_items)
  query = clip(arguments["query"], 200).strip
  tag = clip(arguments["tag"], MAX_TAG_CHARS).strip
  limit = arguments["limit"].to_i
  limit = DEFAULT_LIST_LIMIT if limit <= 0
  filtered = items.select { |item| matches?(item, query, tag) }
  {
    "ok" => true,
    "total" => items.length,
    "count" => filtered.length,
    "pinned" => items.count { |item| item["pinned"] },
    "tags" => tag_histogram(items),
    "items" => filtered.first([limit, MAX_ITEMS].min),
    "storePath" => store_path
  }
end

def call_tool(name, arguments)
  case name
  when "favorites.add" then add_item(arguments)
  when "favorites.list" then list_items(arguments)
  when "favorites.update" then update_item(arguments)
  when "favorites.remove" then remove_item(arguments)
  when "favorites.restore" then restore_item(arguments)
  when "favorites.clear" then clear_items(arguments)
  else { "ok" => false, "error" => "unknown tool #{name}" }
  end
end

TOOLS = [
  {
    name: "favorites.add",
    description: "Save a snippet of text to the WillDeep favorites list.",
    inputSchema: {
      type: "object",
      properties: {
        text: { type: "string", description: "The snippet to save." },
        note: { type: "string", description: "Optional note." },
        tags: { type: "array", items: { type: "string" }, description: "Optional tags." },
        source: { type: "string", description: "Where the snippet came from." },
        source_session_id: { type: "string", description: "Stable source conversation id." },
        source_message_id: { type: "string", description: "Stable source message id." },
        source_turn_id: { type: "string", description: "Stable source user-turn id." }
      },
      required: ["text"]
    }
  },
  {
    name: "favorites.list",
    description: "Return saved favorites as JSON, pinned first, newest first.",
    inputSchema: {
      type: "object",
      properties: {
        query: { type: "string", description: "Filter by text, note, source or tag." },
        tag: { type: "string", description: "Keep only favorites carrying this tag." },
        limit: { type: "integer", description: "Maximum number of favorites to return." }
      }
    }
  },
  {
    name: "favorites.update",
    description: "Update the note, tags or pinned flag of one favorite.",
    inputSchema: {
      type: "object",
      properties: {
        id: { type: "string", description: "Favorite id." },
        note: { type: "string", description: "Replacement note." },
        tags: { type: "array", items: { type: "string" }, description: "Replacement tags." },
        pinned: { type: "boolean", description: "Pin or unpin the favorite." }
      },
      required: ["id"]
    }
  },
  {
    name: "favorites.remove",
    description: "Remove one favorite by id and return the removed record.",
    inputSchema: {
      type: "object",
      properties: { id: { type: "string", description: "Favorite id." } },
      required: ["id"]
    }
  },
  {
    name: "favorites.restore",
    description: "Put a previously removed favorite back, keeping its id and timestamps.",
    inputSchema: {
      type: "object",
      properties: { item: { type: "object", description: "The record returned by favorites.remove." } },
      required: ["item"]
    }
  },
  {
    name: "favorites.clear",
    description: "Remove every favorite. Requires confirm=true.",
    inputSchema: {
      type: "object",
      properties: { confirm: { type: "boolean", description: "Must be true." } },
      required: ["confirm"]
    }
  }
].freeze

ARGF.each_line do |line|
  request = JSON.parse(line)
  next unless request["id"]

  result = case request["method"]
           when "initialize"
             { protocolVersion: "2025-06-18",
               capabilities: { tools: {} },
               serverInfo: { name: "favorites", version: "2.1.0" } }
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
