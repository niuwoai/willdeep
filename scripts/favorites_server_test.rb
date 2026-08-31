#!/usr/bin/env ruby
# frozen_string_literal: true

# favorites_server_test.rb -- 收藏夹插件 MCP 服务端的回归守卫。
#
# 覆盖：initialize / tools/list 的契约、收藏 → 列出 → 改 → 删 → 撤销的闭环、
# 空文本拒绝、重复收藏合并、标签规范化与直方图、关键词过滤、置顶排序、
# 清空要显式确认、v1 存储的向后兼容、落盘格式，以及「存储文件损坏时不崩」。
#
# 用法: ruby scripts/favorites_server_test.rb [report.md] [report.json]

require "json"
require "open3"
require "tmpdir"

# 测试自己也可能跑在没有 LANG 的 shell（本机与 CI 都会），默认外部编码
# 会是 US-ASCII，读中文收藏就成了非法字节。先钉死 UTF-8。
Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

ROOT = File.expand_path("..", __dir__)
SERVER = File.join(ROOT, "PluginExamples", "favorites", "server", "favorites.rb")
PAGE = File.join(ROOT, "PluginExamples", "favorites", "ui", "index.html")

results = []

def check(condition, message, results)
  results << { "ok" => condition, "message" => message }
end

page_source = File.read(PAGE)
check(page_source.include?("repeat(auto-fill, minmax(min(100%, 400px), 1fr))"),
      "收藏卡按页面可用宽度自动填充列，单条内容不会横向拉满。", results)

# 起一个服务端，把 lambda 交给块用；存储文件位置由调用方给。
def with_server(store_path)
  # 复现宿主的启动方式：系统 Ruby、不带 UTF-8 locale
  env = { "WD_FAVORITES_FILE" => store_path }
  env.delete("LANG")
  env.delete("LC_ALL")
  Open3.popen3(env, "/usr/bin/ruby", SERVER) do |stdin, stdout, _stderr, _wait|
    stdin.sync = true
    # 这个测试进程自己也可能跑在没有 LANG 的 shell 里（CI 就是），
    # 管道默认按 US-ASCII 读会把中文收藏读成非法字节。两头都钉死 UTF-8。
    stdin.set_encoding(Encoding::UTF_8)
    stdout.set_encoding(Encoding::UTF_8)
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
    check(names == ["favorites.add", "favorites.clear", "favorites.list",
                    "favorites.remove", "favorites.restore", "favorites.update"],
          "tools/list 暴露 add / list / update / remove / restore / clear 六个工具。", results)

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

    # 撤销：remove 把整条回传，restore 原样塞回去（id 与创建时间不变）
    check(removed && removed["item"] && removed["item"]["id"] == item["id"],
          "remove 回传被删掉的整条，页面才能做撤销。", results)
    restored = tool.call("favorites.restore", { "item" => removed["item"] })
    check(restored && restored["ok"] == true && restored["item"]["id"] == item["id"],
          "restore 用原 id 把删掉的收藏放回去。", results)
    check(restored["item"]["createdAt"] == item["createdAt"],
          "restore 保留原来的创建时间，不伪造成刚收藏的。", results)
    check(tool.call("favorites.list")["count"] == 2, "撤销之后又变回两条。", results)

    # 重复收藏不再堆第二条，而是把老的顶上来
    duplicate = tool.call("favorites.add", { "text" => "第二条", "tags" => ["复用"] })
    check(duplicate && duplicate["duplicate"] == true && duplicate["count"] == 2,
          "同一段文字重复收藏时合并到已有那条，不新增。", results)
    check(duplicate["item"]["tags"] == ["复用"],
          "重复收藏会把新带来的标签并进去。", results)

    # 标签规范化：去空、去重（忽略大小写）、限长
    tagged = tool.call("favorites.update",
                       { "id" => item["id"], "tags" => ["Swift", "swift", "  ", "测试"] })
    check(tagged && tagged["item"]["tags"] == ["Swift", "测试"],
          "update 规范化标签：去空白、忽略大小写去重。", results)
    noted = tool.call("favorites.update", { "id" => item["id"], "note" => "  写点备注  " })
    check(noted && noted["item"]["note"] == "写点备注", "update 改备注并去掉首尾空白。", results)
    check(tool.call("favorites.update", { "id" => "no-such-id" })&.fetch("ok") == false,
          "update 找不到 id 时明确报错。", results)

    histogram = tool.call("favorites.list")
    check(histogram["tags"].map { |entry| entry["name"] }.sort == ["Swift", "复用", "测试"],
          "list 附带标签直方图。", results)
    check(tool.call("favorites.list", { "tag" => "swift" })["count"] == 1,
          "list 按标签过滤时忽略大小写。", results)
    check(tool.call("favorites.list", { "query" => "写点" })["count"] == 1,
          "list 的关键词过滤会搜到备注。", results)
    check(tool.call("favorites.list", { "query" => "对不上的词" })["count"] == 0,
          "关键词搜不到时返回 0 条而不是全部。", results)

    # 置顶永远排在最前，与更新时间无关
    tool.call("favorites.update", { "id" => item["id"], "pinned" => true })
    pinned = tool.call("favorites.list")
    check(pinned["items"][0]["id"] == item["id"] && pinned["pinned"] == 1,
          "置顶的收藏排在最前面。", results)

    check(tool.call("favorites.clear")&.fetch("ok") == false,
          "clear 不带 confirm 时拒绝执行。", results)
    cleared = tool.call("favorites.clear", { "confirm" => true })
    check(cleared && cleared["removed"] == 2 && cleared["count"] == 0,
          "clear 带 confirm 时清空全部。", results)
    tool.call("favorites.add", { "text" => "第二条" })
  end

  check(File.exist?(store), "存储文件按需创建（含中间目录）。", results)
  stored = JSON.parse(File.read(store))
  check(stored["version"] == 2 && stored["items"].is_a?(Array),
        "存储文件是 {version, items} 结构。", results)
  check(stored["items"].first.keys.sort ==
          %w[createdAt id note pinned source tags text updatedAt],
        "落盘的每条收藏字段齐整（含 tags / pinned / updatedAt）。", results)
  check(!Dir.glob(File.join(File.dirname(store), "*.tmp")).any?,
        "写盘用的临时文件已经 rename 掉，不留残骸。", results)

  # v1 存储（没有 tags / pinned / updatedAt）读进来要能直接用
  legacy = { "version" => 1, "items" => [
    { "id" => "legacy-1", "text" => "旧版存下来的收藏", "note" => "",
      "source" => "chat.selection", "createdAt" => "2026-08-01T10:00:00Z" }
  ] }
  File.write(store, JSON.pretty_generate(legacy))
  with_server(store) do |_call, tool|
    migrated = tool.call("favorites.list")
    first = migrated && migrated["items"] && migrated["items"][0]
    check(first && first["id"] == "legacy-1" && first["tags"] == [] && first["pinned"] == false,
          "v1 存储读进来自动补齐 tags / pinned，不丢原来的 id。", results)
    check(first && first["updatedAt"] == "2026-08-01T10:00:00Z",
          "v1 没有 updatedAt 时按创建时间兜底。", results)
  end

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
