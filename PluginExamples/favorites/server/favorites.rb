#!/usr/bin/env ruby
# frozen_string_literal: true

# Favorites — WillDeep 收藏夹插件的 MCP stdio 服务端。
#
# 提供三个工具：
#   - favorites.add    收藏一段文字（聊天里选中文字 → 气泡「收藏」会打到这里）
#   - favorites.list   返回全部收藏（JSON，供插件页面渲染）
#   - favorites.remove 按 id 删除一条
#
# 存储：单个 JSON 文件，默认 ~/Library/Application Support/WillDeep/plugin-data/favorites.json，
# 可用 WD_FAVORITES_FILE 覆盖（测试与沙箱用）。写入走「临时文件 + rename」，
# 中途被杀不会留下半截文件。

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

MAX_ITEMS = 500
MAX_TEXT_BYTES = 20_000

def store_path
  ENV["WD_FAVORITES_FILE"] ||
    File.expand_path("~/Library/Application Support/WillDeep/plugin-data/favorites.json")
end

def load_items
  raw = File.read(store_path)
  data = JSON.parse(raw)
  items = data.is_a?(Hash) ? data["items"] : data
  items.is_a?(Array) ? items.select { |item| item.is_a?(Hash) } : []
rescue Errno::ENOENT
  []
rescue JSON::ParserError, SystemCallError => error
  warn "favorites: unreadable store (#{error.message}); starting empty"
  []
end

def save_items(items)
  FileUtils.mkdir_p(File.dirname(store_path))
  payload = JSON.pretty_generate({ "version" => 1, "items" => items.first(MAX_ITEMS) })
  temporary = "#{store_path}.tmp"
  File.write(temporary, payload)
  File.rename(temporary, store_path)
  items
end

def clip(text)
  string = text.to_s
  return string if string.bytesize <= MAX_TEXT_BYTES
  string.byteslice(0, MAX_TEXT_BYTES).scrub("")
end

def add_item(arguments)
  text = clip(arguments["text"]).strip
  return { "ok" => false, "error" => "empty text" } if text.empty?

  items = load_items
  item = {
    "id" => SecureRandom.uuid,
    "text" => text,
    "note" => clip(arguments["note"]).strip,
    "source" => arguments["source"].to_s,
    "createdAt" => Time.now.utc.iso8601
  }
  save_items([item] + items)
  { "ok" => true, "item" => item, "count" => [items.length + 1, MAX_ITEMS].min }
end

def remove_item(arguments)
  id = arguments["id"].to_s
  return { "ok" => false, "error" => "missing id" } if id.empty?

  items = load_items
  remaining = items.reject { |item| item["id"] == id }
  save_items(remaining)
  { "ok" => true, "removed" => items.length - remaining.length, "count" => remaining.length }
end

def list_items
  items = load_items
  { "ok" => true, "count" => items.length, "items" => items }
end

def call_tool(name, arguments)
  case name
  when "favorites.add" then add_item(arguments)
  when "favorites.remove" then remove_item(arguments)
  when "favorites.list" then list_items
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
        source: { type: "string", description: "Where the snippet came from." }
      },
      required: ["text"]
    }
  },
  {
    name: "favorites.list",
    description: "Return every saved favorite as JSON, newest first.",
    inputSchema: { type: "object", properties: {} }
  },
  {
    name: "favorites.remove",
    description: "Remove one favorite by id.",
    inputSchema: {
      type: "object",
      properties: { id: { type: "string", description: "Favorite id." } },
      required: ["id"]
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
               serverInfo: { name: "favorites", version: "1.0.0" } }
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
