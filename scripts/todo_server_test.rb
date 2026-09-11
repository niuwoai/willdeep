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
PAGE = File.join(ROOT, "PluginExamples", "todo", "ui", "index.html")

results = []

def check(condition, message, results)
  results << { "ok" => condition, "message" => message }
end

page_source = File.read(PAGE)
check(page_source.include?("repeat(auto-fill, minmax(min(100%, 400px), 1fr))"),
      "待办分组按页面可用宽度自动填充卡片列，窄栏自然回到单列。", results)

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
    check(init&.dig("result", "serverInfo", "version") == "1.4.0",
          "MCP 服务端版本与待办插件版本一致。", results)

    names = (call.call("tools/list", {})&.dig("result", "tools") || []).map { |t| t["name"] }.sort
    check(names == ["todo.add", "todo.attach", "todo.attachment_preview", "todo.detach", "todo.list", "todo.quick_add",
                    "todo.remove", "todo.restore", "todo.settings", "todo.stats",
                    "todo.toggle", "todo.update"],
          "tools/list 暴露十二个工具。", results)

    attached = tool.call("todo.add", { "text" => "带附件的待办" })
    attach = tool.call("todo.attach", {
      "id" => attached["item"]["id"], "name" => "shot.png",
      "mimeType" => "image/png", "dataBase64" => ["hello".b].pack("m0")
    })
    check(attach && attach["ok"] == true && attach["item"]["attachments"].length == 1,
          "附件挂上去了，条目里记着它。", results)
    stored = attach && attach["attachment"]
    check(stored && File.file?(stored["path"]) && File.binread(stored["path"]) == "hello",
          "附件字节落到了磁盘上。", results)
    check(stored && stored["size"] == 5, "附件记的是解码后的字节数。", results)

    pasted_source = File.join(dir, "区域截图.png")
    pasted_bytes = "\x89PNG\r\n\x1A\n".b + "pasted-image"
    File.binwrite(pasted_source, pasted_bytes)
    pasted = tool.call("todo.attach", {
      "id" => attached["item"]["id"], "name" => File.basename(pasted_source),
      "mimeType" => "image/png", "sourcePath" => pasted_source
    })
    pasted_entry = pasted && pasted["attachment"]
    check(pasted_entry && File.binread(pasted_entry["path"]) == pasted_bytes,
          "剪贴板只给图片路径时，服务端复制为待办附件。", results)
    queued_preview = tool.call("todo.attachment_preview", { "sourcePath" => pasted_source })
    check(queued_preview && queued_preview["mimeType"] == "image/png" &&
          queued_preview["dataBase64"].unpack1("m") == pasted_bytes,
          "待上传的路径图片可读取为真实缩略图数据。", results)
    stored_preview = tool.call("todo.attachment_preview", {
      "id" => attached["item"]["id"], "attachmentID" => pasted_entry["id"]
    })
    check(stored_preview && stored_preview["mimeType"] == "image/png" &&
          stored_preview["dataBase64"].unpack1("m") == pasted_bytes,
          "已保存图片附件可读取为缩略图和完整预览数据。", results)
    File.delete(pasted_entry["path"])
    File.symlink(pasted_source, pasted_entry["path"])
    symlink_preview = tool.call("todo.attachment_preview", {
      "id" => attached["item"]["id"], "attachmentID" => pasted_entry["id"]
    })
    check(symlink_preview && symlink_preview["error"] == "attachment_path_not_allowed",
          "附件目录里的符号链接也不能把预览读取带到目录外。", results)
    File.delete(pasted_entry["path"])
    File.binwrite(pasted_entry["path"], pasted_bytes)
    missing_preview = tool.call("todo.attachment_preview", {
      "id" => attached["item"]["id"], "attachmentID" => "missing"
    })
    check(missing_preview && missing_preview["error"] == "attachment_not_found",
          "图片预览不能越过条目和附件 id 读取其他文件。", results)
    check(File.binread(pasted_source) == pasted_bytes,
          "复制路径附件不会移动或删除剪贴板源文件。", results)
    fake_image = File.join(dir, "伪装图片.png")
    File.binwrite(fake_image, File.binread(File.expand_path(__FILE__)))
    rejected_path = tool.call("todo.attach", {
      "id" => attached["item"]["id"], "name" => "伪装图片.png", "sourcePath" => fake_image
    })
    check(rejected_path && rejected_path["error"] == "attachment_not_image",
          "路径粘贴通道校验图片内容，不被伪装成 .png 的普通文件骗过。", results)

    # 文件名来自页面，是不可信输入：不能写出附件目录之外去
    escaping = tool.call("todo.attach", {
      "id" => attached["item"]["id"], "name" => "../../escape.txt",
      "dataBase64" => ["x".b].pack("m0")
    })
    escaped_path = escaping && escaping["attachment"] && escaping["attachment"]["path"]
    check(escaped_path && !escaped_path.include?("/../"),
          "带 ../ 的文件名被清洗，写不出附件目录。", results)

    large_bytes = "\x89PNG\r\n\x1a\n".b + "x".b * (10 * 1024 * 1024 - 8)
    large_attachment = tool.call("todo.attach", {
      "id" => attached["item"]["id"], "name" => "large.png", "mimeType" => "image/png",
      "dataBase64" => [large_bytes].pack("m0")
    })
    large_path = large_attachment && large_attachment.dig("attachment", "path")
    check(large_attachment && large_attachment["ok"] == true && large_path && File.binread(large_path) == large_bytes,
          "10 MiB 附件经 MCP JSON 传输后完整落盘。", results)

    oversize = tool.call("todo.attach", {
      "id" => attached["item"]["id"], "name" => "big.bin",
      "dataBase64" => ["a".b * (10 * 1024 * 1024 + 1)].pack("m0")
    })
    check(oversize && oversize["ok"] == false && oversize["error"] == "attachment_too_large",
          "超过 10 MiB 的附件被拒。", results)

    detached = tool.call("todo.detach", {
      "id" => attached["item"]["id"], "attachmentID" => stored["id"]
    })
    check(detached && detached["ok"] == true &&
          detached["item"]["attachments"].none? { |a| a["id"] == stored["id"] },
          "取消附件后条目里不再有它。", results)
    check(!File.exist?(stored["path"]), "取消附件会把文件一起删掉。", results)
    tool.call("todo.remove", { "id" => attached["item"]["id"] })

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

    # 「其他项目…」里用户会直接打 `~/Sites/Xedit`。存的是裸字符串、筛选是
    # 拿它和工作区根比字面量，不展开就永远匹配不上，任务看着存下来了却一条
    # 都筛不出来。
    tilde = tool.call("todo.quick_add", { "text" => "验一下波浪号", "projectPath" => "~/todo-tilde-fixture" })
    expected_tilde = File.expand_path("~/todo-tilde-fixture")
    check(tilde && tilde["item"]["projectPath"] == expected_tilde,
          "projectPath 里的 ~ 在落盘前展开成绝对路径。", results)
    check(tilde && tilde["item"]["project"] == "todo-tilde-fixture",
          "展开之后项目名仍取目录名，不是带波浪号的那一段。", results)

    # 相对路径刻意不展开：服务端的 cwd 和用户心里那个目录没有关系，猜出来的
    # 绝对路径比原样存着更糟。
    relative = tool.call("todo.quick_add", { "text" => "相对路径原样留着", "projectPath" => "Sites/Xedit" })
    check(relative && relative["item"]["projectPath"] == "Sites/Xedit",
          "相对路径不按 cwd 展开，原样留着。", results)

    updated = tool.call("todo.update", { "id" => tilde["item"]["id"], "projectPath" => "~/todo-tilde-moved" })
    check(updated && updated["item"]["projectPath"] == File.expand_path("~/todo-tilde-moved"),
          "update 改 projectPath 时同样展开 ~，两条写入路径口径一致。", results)

    stats = tool.call("todo.stats")
    check(stats["buckets"]["done"] >= 0 && stats["projects"].is_a?(Array),
          "stats 给分组与项目分布。", results)
  end

  check(File.exist?(store), "存储文件按需创建（含中间目录）。", results)
  stored = JSON.parse(File.read(store))
  check(stored["version"] == 2 && stored["items"].is_a?(Array) && stored["settings"].is_a?(Hash),
        "存储文件是 {version, settings, items} 结构。", results)
  check(stored["items"].first.keys.sort ==
          %w[allDay attachments createdAt done doneAt due id note priority project projectPath
             source tags text updatedAt],
        "落盘的每条待办字段齐整。", results)
  check(!Dir.glob(File.join(File.dirname(store), "*.tmp")).any?,
        "写盘用的临时文件已经 rename 掉，不留残骸。", results)

  # 设置写入之后待办不能丢——save_settings 与 save_items 共用同一个文件
  with_server(store) do |_call, tool|
    before = tool.call("todo.list")["count"]
    tool.call("todo.settings", { "parser" => "ai" })
    check(tool.call("todo.list")["count"] == before, "改设置不会顺手把待办清空。", results)
  end

  with_server(File.join(dir, "labels.json")) do |call, tool|
    a = tool.call("todo.add", { "text" => "修复项目切换", "tags" => [" 界面 ", "#修复", "界面", "Bug", "bug"], "projectPath" => project })["item"]
    b = tool.call("todo.add", { "text" => "完善卡片", "tags" => ["界面"], "projectPath" => project })["item"]
    c = tool.call("todo.add", { "text" => "补测试", "tags" => ["测试"], "projectPath" => "/tmp/workspaces/beta" })["item"]
    d = tool.call("todo.quick_add", { "text" => "明天整理资料", "tags" => ["文档"] })["item"]
    untagged = tool.call("todo.add", { "text" => "无标签任务" })["item"]
    check(a["tags"] == ["界面", "修复", "Bug"], "标签去空白、去前缀并按大小写无关去重。", results)
    check(d["tags"] == ["文档"], "快速添加也保留显式标签。", results)
    check(untagged["tags"] == [], "缺失 tags 默认为空数组。", results)
    check(tool.call("todo.list", { "tags" => ["界面", "测试"] })["count"] == 3, "多标签默认命中任一。", results)
    check(tool.call("todo.list", { "tags" => ["界面", "修复"], "tagMode" => "all" })["items"].map { |item| item["id"] } == [a["id"]], "同时包含要求所有标签命中。", results)
    check(tool.call("todo.list", { "tags" => ["BUG"] })["count"] == 1, "标签筛选大小写无关。", results)
    check(tool.call("todo.list", { "tags" => ["不存在"] })["count"] == 0, "未知标签产生空结果而非放宽范围。", results)
    check(tool.call("todo.list", { "withoutTags" => true })["items"].map { |item| item["id"] } == [untagged["id"]], "无标签只匹配空数组。", results)
    check(tool.call("todo.list", { "withoutTags" => true, "tags" => ["界面"] })["count"] == 1, "无标签优先于已选标签。", results)
    check(tool.call("todo.list", { "scope" => "project", "projectPath" => project, "tags" => ["测试"] })["count"] == 0, "项目与标签采用交集。", results)
    check(tool.call("todo.list", { "query" => "修复", "tags" => ["界面"] })["count"] == 1, "关键词与标签采用交集。", results)
    check(tool.call("todo.list", { "query" => "Bug" })["count"] == 1, "关键词检索包含标签。", results)
    facets = tool.call("todo.list", { "scope" => "project", "projectPath" => project, "tags" => ["修复"] })
    check(facets["tags"].find { |entry| entry["name"] == "界面" }["count"] == 2, "标签计数基于项目和状态范围，不被标签本身收窄。", results)
    check(facets["allTags"].any? { |entry| entry["name"] == "文档" }, "编辑建议包含其他项目的标签。", results)
    changed = tool.call("todo.update", { "id" => a["id"], "projectPath" => "/tmp/workspaces/beta", "due" => "2026-08-31T18:00:00+08:00", "allDay" => true, "tags" => ["测试", "发布"] })["item"]
    check(changed["project"] == "beta" && changed["tags"] == ["测试", "发布"], "一次保存可以同时切换项目和标签。", results)
    check(tool.call("todo.update", { "id" => a["id"], "text" => "保留标签" })["item"]["tags"] == ["测试", "发布"], "仅改标题不丢标签。", results)
    cleared = tool.call("todo.update", { "id" => a["id"], "due" => "", "projectPath" => "" })["item"]
    check(cleared["due"].nil? && cleared["allDay"] == false, "无终止时间清除 due 与全天标记。", results)
    check(cleared["projectPath"].nil? && cleared["project"].nil?, "可重新设为未归项目。", results)
    check(tool.call("todo.update", { "id" => b["id"], "tags" => [] })["item"]["tags"] == [], "空标签数组可清空标签。", results)
    tool.call("todo.toggle", { "id" => a["id"] })
    check(tool.call("todo.list", { "status" => "done", "tags" => ["发布"] })["count"] == 1, "已完成状态与标签筛选叠加。", results)
    removed = tool.call("todo.remove", { "id" => a["id"] })["item"]
    restored = tool.call("todo.restore", { "item" => removed })["item"]
    check(restored["tags"] == ["测试", "发布"] && restored["done"], "删除撤销恢复标签与完成状态。", results)
    tool.call("todo.settings", { "parser" => "local" })
    check(tool.call("todo.list", { "status" => "done", "tags" => ["发布"] })["count"] == 1, "修改设置不丢标签。", results)
    ["bad", [1], Array.new(21, "标签"), ["a" * 41], ["bad\nlabel"]].each do |invalid|
      check(tool.call("todo.update", { "id" => c["id"], "tags" => invalid })["ok"] == false, "非法标签输入被拒绝：#{invalid.class}。", results)
    end
    check(tool.call("todo.list", { "tags" => "测试" })["ok"] == false, "非法筛选类型不静默放宽查询。", results)
    check(tool.call("todo.list", { "tags" => ["测试"] })["items"].any? { |item| item["id"] == c["id"] }, "被拒绝的保存不会破坏旧标签。", results)
    tools = call.call("tools/list")["result"]["tools"]
    check(%w[todo.add todo.quick_add todo.update todo.list].all? { |name| tools.find { |entry| entry["name"] == name }["inputSchema"]["properties"].key?("tags") }, "MCP 工具 schema 完整暴露标签字段。", results)
  end

  legacy = File.join(dir, "legacy.json")
  File.write(legacy, JSON.generate({ version: 1, settings: { parser: "local" }, items: [{ id: "legacy", text: "旧待办", note: "备注", projectPath: project, priority: "high", allDay: true }] }))
  with_server(legacy) do |_call, tool|
    old = tool.call("todo.list")["items"].first
    check(old["id"] == "legacy" && old["tags"] == [] && old["note"] == "备注", "v1 数据读取兼容且不改变旧任务内容。", results)
    tool.call("todo.update", { "id" => "legacy", "tags" => ["迁移"] })
  end
  migrated = JSON.parse(File.read(legacy))
  check(migrated["version"] == 2 && migrated["settings"]["parser"] == "local" && migrated["items"].first["tags"] == ["迁移"], "保存时迁移至 v2 并保留设置。", results)

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
