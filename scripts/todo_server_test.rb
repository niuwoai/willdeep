#!/usr/bin/env ruby
# frozen_string_literal: true

# todo_server_test.rb -- 待办插件 MCP 服务端的回归守卫。
#
# 覆盖两件事：
#   1. CRUD 闭环：一句话新建 → 列出（按项目/状态过滤、分组计数）→ 改时间与
#      优先级 → 打勾 → 删除 → 撤销；落盘格式与损坏降级。
#   2. 本地解析器：它是「模型不可用时的兜底」，所以每一条识别规则都要钉住。
#      页面首选交给模型（见 ui/index.html 的 parseWithModel），这里守的是
#      断网、没配 provider、模型答非所问时那条路还站得住。
#
# 用法: ruby scripts/todo_server_test.rb [report.md] [report.json]

require "json"
require "open3"
require "tmpdir"
require "time"

# 测试自己也可能跑在没有 LANG 的 shell（本机与 CI 都会），先钉死 UTF-8，
# 否则中文待办会被按 US-ASCII 读成非法字节。
Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

ROOT = File.expand_path("..", __dir__)
SERVER = File.join(ROOT, "PluginExamples", "todo", "server", "todo.rb")

results = []

def check(condition, message, results)
  results << { "ok" => condition, "message" => message }
end

def with_server(store_path)
  # 复现宿主的启动方式：系统 Ruby、不带 UTF-8 locale
  env = { "WD_TODO_FILE" => store_path }
  env.delete("LANG")
  env.delete("LC_ALL")
  Open3.popen3(env, "/usr/bin/ruby", SERVER) do |stdin, stdout, _stderr, _wait|
    stdin.sync = true
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

def local_time(iso)
  Time.parse(iso).getlocal
end

Dir.mktmpdir do |dir|
  store = File.join(dir, "nested", "todos.json")
  project = "/tmp/workspaces/alpha"

  with_server(store) do |call, tool|
    init = call.call("initialize", {})
    check(init&.dig("result", "serverInfo", "name") == "todo",
          "initialize 返回 todo 服务端信息。", results)

    names = (call.call("tools/list", {})&.dig("result", "tools") || []).map { |t| t["name"] }.sort
    check(names == ["todo.add", "todo.list", "todo.quick_add", "todo.remove", "todo.restore",
                    "todo.settings", "todo.stats", "todo.toggle", "todo.update"],
          "tools/list 暴露九个工具。", results)

    empty = tool.call("todo.list")
    check(empty && empty["ok"] == true && empty["items"] == [],
          "存储还不存在时 list 返回空列表而不是报错。", results)

    # ── 一句话解析（模型不可用时的兜底路径）──
    parsed = tool.call("todo.quick_add",
                       { "text" => "明天下午三点前把发布验一遍，很急", "projectPath" => project })
    item = parsed && parsed["item"]
    check(item && item["text"] == "把发布验一遍",
          "解析后标题里不再留时间词、优先级词和那个光杆「前」。", results)
    check(item && item["priority"] == "high", "「很急」认成 high。", results)
    due = item && item["due"] ? local_time(item["due"]) : nil
    check(due && due.hour == 15 && due.min.zero?, "「下午三点」认成 15:00（中文数字小时）。", results)
    check(due && due.to_date == Date.today + 1, "「明天」落在明天。", results)
    check(item && item["allDay"] == false, "给了具体钟点时不是全天。", results)
    check(item && item["project"] == "alpha" && item["projectPath"] == project,
          "带 projectPath 时归到该项目，项目名取目录名。", results)

    low = tool.call("todo.quick_add", { "text" => "整理桌面 不急" })
    check(low && low["item"]["priority"] == "low",
          "「不急」认成 low——否定说法必须先于「急」判定。", results)
    check(low && low["item"]["text"] == "整理桌面", "低优先级词也从标题里剥掉。", results)
    check(low && low["item"]["projectPath"].nil?,
          "不给 projectPath 的待办不属于任何项目。", results)

    tonight = tool.call("todo.quick_add", { "text" => "今晚 10 点半 跑一遍全量测试" })
    tonight_due = local_time(tonight["item"]["due"])
    check(tonight_due.hour == 22 && tonight_due.min == 30,
          "「今晚 10 点半」认成 22:30——时段提示要传给时钟解析。", results)

    weekday = tool.call("todo.quick_add", { "text" => "下周五之前把插件文档补完" })
    check(weekday["item"]["text"] == "把插件文档补完",
          "「之前」跟着时间短语一起剥掉。", results)
    check(local_time(weekday["item"]["due"]).to_date.cwday == 5, "「下周五」落在周五。", results)

    plain = tool.call("todo.quick_add", { "text" => "把这段话变成待办" })
    check(plain["item"]["due"].nil? && plain["item"]["priority"].nil?,
          "认不出时间和优先级就老实什么都不填，不瞎猜。", results)
    check(plain["item"]["text"] == "把这段话变成待办", "认不出时原样保留标题。", results)

    english = tool.call("todo.quick_add", { "text" => "review the PR tomorrow 9am" })
    english_due = local_time(english["item"]["due"])
    check(english_due.hour == 9 && english_due.to_date == Date.today + 1,
          "英文的 tomorrow 9am 也认。", results)

    # ── 显式字段：Agent / 页面里模型解析完走这条 ──
    explicit = tool.call("todo.add", {
      "text" => "提交季度报告",
      "due" => (Time.now + 3 * 86_400).iso8601,
      "priority" => "urgent",
      "projectPath" => project,
      "source" => "chat.selection"
    })
    check(explicit && explicit["item"]["priority"] == "urgent" && explicit["item"]["source"] == "chat.selection",
          "todo.add 原样收下模型算好的字段。", results)
    check(tool.call("todo.add", { "text" => "  " })&.fetch("ok") == false, "空标题被拒绝。", results)

    listed = tool.call("todo.list")
    check(listed["count"] == 7, "list 默认只给未完成的。", results)
    check(listed["items"].first["priority"] == "urgent" || listed["items"].first["due"],
          "排序：有计划时间的在前。", results)
    check(listed["buckets"].is_a?(Hash) && listed["buckets"].key?("overdue"),
          "list 附带分组计数（逾期/今天/明天/本周/以后/没时间/已完成）。", results)
    check(listed["projects"].any? { |p| p["name"] == "alpha" && p["count"] == 2 },
          "list 附带按项目的未完成计数。", results)

    check(tool.call("todo.list", { "scope" => "project", "projectPath" => project })["count"] == 2,
          "scope=project 只给这个项目的。", results)
    check(tool.call("todo.list", { "scope" => "inbox" })["count"] == 5,
          "scope=inbox 只给不属于任何项目的。", results)
    check(tool.call("todo.list", { "query" => "季度" })["count"] == 1, "关键词过滤生效。", results)

    # ── 改、打勾、删、撤销 ──
    target = explicit["item"]["id"]
    updated = tool.call("todo.update", { "id" => target, "priority" => "low", "due" => "" })
    check(updated["item"]["priority"] == "low" && updated["item"]["due"].nil?,
          "update 能改优先级，也能把计划时间清掉。", results)
    check(tool.call("todo.update", { "id" => "nope" })&.fetch("ok") == false,
          "update 找不到 id 时明确报错。", results)

    toggled = tool.call("todo.toggle", { "id" => target })
    check(toggled["item"]["done"] == true && !toggled["item"]["doneAt"].to_s.empty?,
          "toggle 打勾并记下完成时间。", results)
    check(tool.call("todo.list")["count"] == 6, "打过勾的不在默认列表里。", results)
    check(tool.call("todo.list", { "status" => "done" })["count"] == 1, "status=done 只给已完成。", results)
    check(tool.call("todo.toggle", { "id" => target })["item"]["done"] == false,
          "再 toggle 一次取消完成。", results)

    removed = tool.call("todo.remove", { "id" => target })
    check(removed["removed"] == 1 && removed["item"]["id"] == target,
          "remove 回传被删掉的整条，页面据此做撤销。", results)
    check(tool.call("todo.list")["count"] == 6, "删完少一条。", results)
    restored = tool.call("todo.restore", { "item" => removed["item"] })
    check(restored["ok"] == true && tool.call("todo.list")["count"] == 7,
          "restore 用原 id 放回去。", results)

    # ── 设置：页面用它在「交给模型」和「本地规则」之间切 ──
    defaults = tool.call("todo.settings")
    check(defaults["settings"]["parser"] == "ai",
          "默认交给模型解析（页面首选 AI，失败才回落本地规则）。", results)
    saved = tool.call("todo.settings", { "parser" => "local", "providerID" => "ollama", "model" => "gemma4:e4b-it-qat" })
    check(saved["settings"]["parser"] == "local" && saved["settings"]["providerID"] == "ollama",
          "settings 能钉住解析方式与 provider/模型。", results)
    check(tool.call("todo.settings", { "parser" => "乱写" })["settings"]["parser"] == "local",
          "非法的解析方式被忽略，不会把设置写坏。", results)
    check(tool.call("todo.list")["settings"]["parser"] == "local",
          "list 顺带把设置给页面，省一次往返。", results)

    stats = tool.call("todo.stats")
    check(stats["buckets"]["done"] >= 0 && stats["projects"].is_a?(Array),
          "stats 给分组与项目分布。", results)
  end

  check(File.exist?(store), "存储文件按需创建（含中间目录）。", results)
  stored = JSON.parse(File.read(store))
  check(stored["version"] == 1 && stored["items"].is_a?(Array) && stored["settings"].is_a?(Hash),
        "存储文件是 {version, settings, items} 结构。", results)
  check(stored["items"].first.keys.sort ==
          %w[allDay createdAt done doneAt due id note priority project projectPath source text updatedAt],
        "落盘的每条待办字段齐整。", results)
  check(!Dir.glob(File.join(File.dirname(store), "*.tmp")).any?,
        "写盘用的临时文件已经 rename 掉，不留残骸。", results)

  # 设置写入之后待办不能丢——save_settings 与 save_items 共用同一个文件
  with_server(store) do |_call, tool|
    before = tool.call("todo.list")["count"]
    tool.call("todo.settings", { "parser" => "ai" })
    check(tool.call("todo.list")["count"] == before, "改设置不会顺手把待办清空。", results)
  end

  File.write(store, "{ not json")
  with_server(store) do |_call, tool|
    listed = tool.call("todo.list")
    check(listed && listed["ok"] == true && listed["items"] == [],
          "存储损坏时按空列表继续，不崩。", results)
    check(tool.call("todo.quick_add", { "text" => "坏文件之后仍可记" })["ok"] == true,
          "存储损坏后仍能写入新待办。", results)
  end
end

failed = results.reject { |result| result["ok"] }
markdown_path = ARGV[0]
json_path = ARGV[1]
if json_path
  File.write(json_path, JSON.pretty_generate("ok" => failed.empty?, "checks" => results))
end
if markdown_path
  lines = ["# Todo Server Contract", "", "- Status: #{failed.empty? ? "pass" : "fail"}", "", "## Checks", ""]
  results.each { |result| lines << "- #{result["ok"] ? "PASS" : "FAIL"}: #{result["message"]}" }
  File.write(markdown_path, "#{lines.join("\n")}\n")
end

abort failed.map { |result| result["message"] }.join("\n") unless failed.empty?
puts "todo_server_test: pass checks=#{results.length}"
