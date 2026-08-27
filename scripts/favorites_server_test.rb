#!/usr/bin/env ruby
# frozen_string_literal: true

# favorites_server_test.rb -- 收藏夹插件 MCP 服务端的回归守卫。
#
# 覆盖：initialize / tools/list 的契约、收藏 → 列出 → 删除的闭环、
# 空文本拒绝、存储文件的落盘格式，以及「存储文件损坏时不崩、按空列表继续」。
#
# 用法: ruby scripts/favorites_server_test.rb [report.md] [report.json]

require "json"
require "open3"
require "tmpdir"

ROOT = File.expand_path("..", __dir__)
SERVER = File.join(ROOT, "PluginExamples", "favorites", "server", "favorites.rb")

results = []

def check(condition, message, results)
  results << { "ok" => condition, "message" => message }
end

# 起一个服务端，把 lambda 交给块用；存储文件位置由调用方给。
def with_server(store_path)
  # 复现宿主的启动方式：系统 Ruby、不带 UTF-8 locale
  env = { "WD_FAVORITES_FILE" => store_path }
  env.delete("LANG")
  env.delete("LC_ALL")
  Open3.popen3(env, "/usr/bin/ruby", SERVER) do |stdin, stdout, _stderr, _wait|
    stdin.sync = true
    next_id = 0
    call = lambda do |method, params = {}|
      id = (next_id += 1)
      stdin.puts JSON.generate(jsonrpc: "2.0", id: id, method: method, params: params)
      loop do
        line = stdout.gets
        return nil if line.nil?
        begin
          message = JSON.parse(line)
        rescue JSON::ParserError
          next
        end
        return message if message["id"] == id
      end
    end
    tool = lambda do |name, arguments = {}|
      response = call.call("tools/call", { "name" => name, "arguments" => arguments })
      text = response&.dig("result", "content", 0, "text")
      text ? JSON.parse(text) : nil
    end
    yield call, tool
    stdin.close
  end
end

Dir.mktmpdir do |dir|
  store = File.join(dir, "nested", "favorites.json")

  with_server(store) do |call, tool|
    init = call.call("initialize", {})
    check(init&.dig("result", "serverInfo", "name") == "favorites",
          "initialize 返回 favorites 服务端信息。", results)

    tools = call.call("tools/list", {})&.dig("result", "tools") || []
    names = tools.map { |item| item["name"] }.sort
    check(names == ["favorites.add", "favorites.list", "favorites.remove"],
          "tools/list 暴露 add / list / remove 三个工具。", results)

    empty = tool.call("favorites.list")
    check(empty && empty["ok"] == true && empty["items"] == [],
          "存储文件还不存在时，list 返回空列表而不是报错。", results)

    added = tool.call("favorites.add", { "text" => "  选中的一段中文  ", "source" => "chat.selection" })
    check(added && added["ok"] == true, "add 收下文本并返回 ok。", results)
    item = added && added["item"]
    check(item && item["text"] == "选中的一段中文", "add 会去掉首尾空白。", results)
    check(item && item["source"] == "chat.selection", "add 记下来源。", results)
    check(item && !item["id"].to_s.empty?, "add 生成 id。", results)
    check(item && !item["createdAt"].to_s.empty?, "add 记下时间戳。", results)

    rejected = tool.call("favorites.add", { "text" => "   " })
    check(rejected && rejected["ok"] == false, "空文本被拒绝。", results)

    tool.call("favorites.add", { "text" => "第二条" })
    listed = tool.call("favorites.list")
    check(listed && listed["count"] == 2, "list 返回两条。", results)
    check(listed && listed["items"][0]["text"] == "第二条", "新收藏排在最前面。", results)

    removed = tool.call("favorites.remove", { "id" => item["id"] })
    check(removed && removed["removed"] == 1 && removed["count"] == 1,
          "remove 按 id 删掉一条。", results)
    check(tool.call("favorites.remove", { "id" => "" })&.fetch("ok") == false,
          "缺 id 时 remove 拒绝执行。", results)

    after = tool.call("favorites.list")
    check(after && after["count"] == 1 && after["items"][0]["text"] == "第二条",
          "删完之后剩下的那条还在。", results)
  end

  check(File.exist?(store), "存储文件按需创建（含中间目录）。", results)
  stored = JSON.parse(File.read(store))
  check(stored["version"] == 1 && stored["items"].is_a?(Array),
        "存储文件是 {version, items} 结构。", results)
  check(!Dir.glob(File.join(File.dirname(store), "*.tmp")).any?,
        "写盘用的临时文件已经 rename 掉，不留残骸。", results)

  # 存储被写坏时不该崩：按空列表继续，新收藏照样能存
  File.write(store, "{ not json")
  with_server(store) do |_call, tool|
    listed = tool.call("favorites.list")
    check(listed && listed["ok"] == true && listed["items"] == [],
          "存储损坏时按空列表继续，不崩。", results)
    added = tool.call("favorites.add", { "text" => "坏文件之后仍可收藏" })
    check(added && added["ok"] == true, "存储损坏后仍能写入新收藏。", results)
  end
end

failed = results.reject { |result| result["ok"] }
markdown_path = ARGV[0]
json_path = ARGV[1]
if json_path
  File.write(json_path, JSON.pretty_generate("ok" => failed.empty?, "checks" => results))
end
if markdown_path
  lines = ["# Favorites Server Contract", "", "- Status: #{failed.empty? ? "pass" : "fail"}", "", "## Checks", ""]
  results.each { |result| lines << "- #{result["ok"] ? "PASS" : "FAIL"}: #{result["message"]}" }
  File.write(markdown_path, "#{lines.join("\n")}\n")
end

abort failed.map { |result| result["message"] }.join("\n") unless failed.empty?
puts "favorites_server_test: pass checks=#{results.length}"
