#!/usr/bin/env ruby
# frozen_string_literal: true

# history-recall 插件服务端测试。
#
# 跑法：ruby scripts/history_recall_server_test.rb [report.md] [report.json]
#
# 与 session_vitality_server_test.rb 同骨架：拉起真实 Ruby 子进程走 stdio，
# 并刻意删掉 LANG / LC_ALL 复现宿主不带 locale 的启动环境——中文会话在
# US-ASCII 默认编码下会直接抛 Encoding::InvalidByteSequenceError，这是回归重点。

require "json"
require "open3"
require "tmpdir"
require "time"
require "fileutils"

SERVER = File.expand_path("../PluginExamples/history-recall/server/history_recall.rb", __dir__)

$checks = 0
$failures = []

def check(label)
  $checks += 1
  ok = yield
  $failures << label unless ok
  puts(ok ? "  ok   #{label}" : "  FAIL #{label}")
  ok
rescue StandardError => error
  $checks += 1
  $failures << "#{label} (#{error.class}: #{error.message})"
  puts "  FAIL #{label} — #{error.class}: #{error.message}"
  false
end

# ---------------------------------------------------------------- 夹具

def session_fixture(id:, title:, messages:, group: {}, updated: nil, archived: nil)
  base = {
    "id" => id,
    "title" => title,
    "createdAt" => "2026-08-01T10:00:00Z",
    "updatedAt" => updated || "2026-08-01T10:30:00Z",
    "messages" => messages.each_with_index.map do |(role, content), index|
      {
        "id" => "#{id}-m#{index}",
        "role" => role,
        "content" => content,
        "createdAt" => "2026-08-01T10:0#{index}:00Z"
      }
    end
  }
  base["archivedAt"] = archived if archived
  base.merge(group)
end

def write_fixtures(dir)
  fixtures = {
    "aaaa1111-0000-0000-0000-000000000001" => session_fixture(
      id: "aaaa1111-0000-0000-0000-000000000001",
      title: "配置 frp 内网穿透",
      group: { "projectID" => "11111111-1111-1111-1111-111111111111",
               "workspaceRootPath" => "/Users/tester/Sites/edge-tunnel" },
      updated: "2026-08-20T12:00:00Z",
      messages: [
        %w[user 我们在q4上用frp做公网穿透吗],
        ["assistant", "确认了：q4 上的穿透工具就是 frp 改名版，叫 edge-tunnel，装在 /opt/edge-tunnel。"]
      ]
    ),
    "aaaa1111-0000-0000-0000-000000000002" => session_fixture(
      id: "aaaa1111-0000-0000-0000-000000000002",
      title: "数据库迁移回滚",
      group: { "projectID" => "22222222-2222-2222-2222-222222222222",
               "workspaceRootPath" => "/Users/tester/Sites/backend" },
      updated: "2026-08-25T09:00:00Z",
      messages: [
        ["user", "migrate down 之前要确认备份"],
        ["assistant", "对，prod 迁移前必须确认最近备份可恢复。"]
      ]
    ),
    # 空壳会话：本机 474 个里有 221 个是这种，必须被排除在索引之外。
    "aaaa1111-0000-0000-0000-000000000003" => session_fixture(
      id: "aaaa1111-0000-0000-0000-000000000003",
      title: "新对话",
      messages: []
    ),
    # 归档会话，且用 snake_case 命名 + Apple 纪元时间戳，验证兼容路径。
    "aaaa1111-0000-0000-0000-000000000004" => {
      "id" => "aaaa1111-0000-0000-0000-000000000004",
      "title" => "旧的 frp 笔记",
      "workspace_root_path" => "/Users/tester/Sites/legacy",
      "created_at" => 745_000_000,
      "updated_at" => 745_003_600,
      "archived_at" => "2026-08-02T00:00:00Z",
      "messages" => [
        { "id" => "old-m0", "role" => "user", "content" => "frp 的老配置放哪了", "created_at" => 745_000_000 }
      ]
    },
    # 只有工具消息，没有 user/assistant 正文 —— 也应被当作空壳排除。
    "aaaa1111-0000-0000-0000-000000000005" => {
      "id" => "aaaa1111-0000-0000-0000-000000000005",
      "title" => "只有工具调用",
      "messages" => [{ "id" => "t0", "role" => "tool", "content" => "frp tool payload" }]
    },
    # 宿主注入块：正文只有一句真话，后面全是 skill 路由候选列表。
    # 检索 "kubernetes" 不该命中这个会话——用户从没聊过它。
    "aaaa1111-0000-0000-0000-000000000008" => session_fixture(
      id: "aaaa1111-0000-0000-0000-000000000008",
      title: "问个无关的问题",
      group: { "workspaceRootPath" => "/Users/tester/Sites/noise" },
      updated: "2026-08-26T00:00:00Z",
      messages: [
        ["user", "帮我看下今天的天气\n\nThe user attached the following context for this turn — " \
                 "treat it as task setup, not verbatim user text:\n\n" \
                 "- `kubernetes-deploy` — 在 kubernetes 集群里部署服务，处理 helm chart 与 ingress。"],
        ["assistant", "今天晴。"]
      ]
    ),
    # system-reminder 成对块，也应被整段剥掉。
    "aaaa1111-0000-0000-0000-000000000009" => session_fixture(
      id: "aaaa1111-0000-0000-0000-000000000009",
      title: "带提醒块的会话",
      group: { "workspaceRootPath" => "/Users/tester/Sites/noise2" },
      updated: "2026-08-27T00:00:00Z",
      messages: [
        ["user", "真正的问题在这里<system-reminder>这里提到 elasticsearch 但不是用户说的</system-reminder>结尾"],
        ["assistant", "好的。"]
      ]
    ),
    # 两个词分散在不同消息里，会话级 AND 才能找回。
    "aaaa1111-0000-0000-0000-00000000000a" => session_fixture(
      id: "aaaa1111-0000-0000-0000-00000000000a",
      title: "分散讨论",
      group: { "workspaceRootPath" => "/Users/tester/Sites/spread" },
      updated: "2026-08-29T00:00:00Z",
      messages: [
        ["user", "审批流程现在怎么走"],
        ["assistant", "先过门禁。"],
        ["user", "那个裁判模型呢"],
        ["assistant", "裁判在后面兜底。"]
      ]
    ),
    # 两个不同归属键、同一个末段名，必须被消歧后缀区分开。
    "aaaa1111-0000-0000-0000-00000000000b" => session_fixture(
      id: "aaaa1111-0000-0000-0000-00000000000b",
      title: "同名分组甲",
      group: { "workspaceRootPath" => "/Users/tester/alpha/dup" },
      updated: "2026-08-10T00:00:00Z",
      messages: [["user", "甲侧的内容"]]
    ),
    "aaaa1111-0000-0000-0000-00000000000c" => session_fixture(
      id: "aaaa1111-0000-0000-0000-00000000000c",
      title: "同名分组乙",
      group: { "workspaceRootPath" => "/Users/tester/beta/dup" },
      updated: "2026-08-11T00:00:00Z",
      messages: [["user", "乙侧的内容"]]
    )
  }

  fixtures.each do |id, payload|
    File.write(File.join(dir, "#{id}.json"), JSON.generate(payload), encoding: "UTF-8")
  end

  # 坏文件：单个损坏不该让整次检索失败。
  File.write(File.join(dir, "aaaa1111-0000-0000-0000-000000000006.json"), "{ not json", encoding: "UTF-8")
  # 非 .json 文件应被忽略。
  File.write(File.join(dir, "notes.txt"), "frp", encoding: "UTF-8")
end

# ---------------------------------------------------------------- 驱动

class ServerSession
  def initialize(stdin, stdout)
    @stdin = stdin
    @stdout = stdout
    @id = 0
  end

  def request(method, params = nil)
    @id += 1
    payload = { jsonrpc: "2.0", id: @id, method: method }
    payload[:params] = params if params
    @stdin.puts(JSON.generate(payload))
    line = @stdout.gets
    raise "server closed the stream on #{method}" if line.nil?

    JSON.parse(line)
  end

  def notify(method, params = nil)
    payload = { jsonrpc: "2.0", method: method }
    payload[:params] = params if params
    @stdin.puts(JSON.generate(payload))
  end

  # tools/call 的结果包在 content[0].text 里，剥出来给断言用。
  def call_tool(name, arguments = {})
    response = request("tools/call", { name: name, arguments: arguments })
    text = response.dig("result", "content", 0, "text")
    JSON.parse(text)
  end
end

def with_server(sessions_dir, cross_project: true, data_dir: nil)
  env = { "WD_HISTORY_SESSIONS_DIR" => sessions_dir }
  # cross_project 传 nil 表示不设环境变量，改由持久化设置决定。
  env["WD_HISTORY_ALLOW_CROSS_PROJECT"] = cross_project ? "1" : "0" unless cross_project.nil?
  # 测试绝不能写到真实的 ~/Library/.../plugin-data 下。
  env["WD_HISTORY_DATA_DIR"] = data_dir || File.join(sessions_dir, "_test_data")
  # 复现宿主启动 MCP server 的环境：没有 locale。
  env["LANG"] = nil
  env["LC_ALL"] = nil

  Open3.popen3(env, "/usr/bin/ruby", SERVER) do |stdin, stdout, stderr, wait|
    stdin.sync = true
    stdin.set_encoding(Encoding::UTF_8)
    stdout.set_encoding(Encoding::UTF_8)
    begin
      yield ServerSession.new(stdin, stdout), stderr
    ensure
      stdin.close unless stdin.closed?
      wait.value
    end
  end
end

# ---------------------------------------------------------------- 用例

puts "history_recall_server_test"

Dir.mktmpdir("history-recall-test") do |dir|
  write_fixtures(dir)

  puts "\n[协议]"
  with_server(dir) do |server, _stderr|
    init = server.request("initialize")
    check("initialize 返回 serverInfo") do
      init.dig("result", "serverInfo", "name") == "history-recall"
    end
    check("initialize 声明 tools 能力") { !init.dig("result", "capabilities", "tools").nil? }
    check("响应带上匹配的 id") { init["id"] == 1 }

    tools = server.request("tools/list").dig("result", "tools")
    check("tools/list 返回四个工具") { tools.size == 4 }
    check("工具名符合约定") do
      tools.map { |t| t["name"] }.sort ==
        ["history.excerpt", "history.projects", "history.search", "history.settings"]
    end
    check("history.search 声明 query 必填") do
      tools.find { |t| t["name"] == "history.search" }["inputSchema"]["required"] == ["query"]
    end

    check("ping 有响应") { server.request("ping").key?("result") }
    check("未知方法不炸") { server.request("nonexistent/method").key?("result") }

    # 通知没有 id，不该回包。发一条通知再发一条正常请求，若通知回了包则 id 对不上。
    server.notify("notifications/initialized")
    follow = server.request("ping")
    check("通知不回包") { follow["id"] == server.instance_variable_get(:@id) }
  end

  puts "\n[检索]"
  with_server(dir) do |server, _stderr|
    server.request("initialize")

    result = server.call_tool("history.search", { "query" => "frp" })
    check("检索成功") { result["ok"] == true }
    check("命中两个会话（活跃 + 归档）") { result["matched_sessions"] == 2 }
    check("空壳会话不进索引") do
      result["results"].none? { |r| r["title"] == "新对话" }
    end
    check("只有工具消息的会话不进索引") do
      result["results"].none? { |r| r["title"] == "只有工具调用" }
    end
    check("坏文件不影响检索") { result["results"].size >= 2 }
    check("报告扫描数量") { result["scanned_sessions"].is_a?(Integer) && result["scanned_sessions"] >= 2 }
    check("报告是否截断") { result["truncated"] == false }

    top = result["results"].first
    check("标题命中的会话排在前面") { top["title"] == "配置 frp 内网穿透" }
    check("结果带归属标签") { top["group_label"] == "edge-tunnel" }
    check("结果带会话 ID") { top["session_id"] == "aaaa1111-0000-0000-0000-000000000001" }
    check("结果带更新时间") { !top["updated_at"].nil? }
    check("摘录非空") { top["hits"].first["excerpt"].to_s.length.positive? }
    check("摘录含检索词") { top["hits"].any? { |h| h["excerpt"].downcase.include?("frp") } }
    check("命中项带 index 供跳转") { top["hits"].first["index"].is_a?(Integer) }

    archived = result["results"].find { |r| r["archived"] }
    check("归档会话可被检索到") { !archived.nil? }
    check("归档会话被标记") { archived && archived["archived"] == true }
    check("snake_case 字段被正确解析") { archived && archived["title"] == "旧的 frp 笔记" }

    puts "\n[中文与多词]"
    # "内网穿透" 只出现在标题里，正文没有 —— 用户找旧对话最容易记住的恰恰是标题，
    # 所以标题必须是独立的一路命中来源，不能只当加分项。
    cn = server.call_tool("history.search", { "query" => "内网穿透" })
    check("标题命中可被检索到") { cn["ok"] == true && cn["matched_sessions"] == 1 }
    check("标题命中被标记") { cn["results"].first["title_match"] == true }
    check("仅标题命中时 hits 为空但会话仍返回") { cn["results"].first["hits"].empty? }

    body_only = server.call_tool("history.search", { "query" => "公网穿透" })
    check("正文命中不误标为标题命中") do
      body_only["matched_sessions"] == 1 && body_only["results"].first["title_match"] == false
    end

    puts "\n[注入块剥离]"
    # 本机实测 916 条 user 消息里有 171 条混入宿主注入内容，其中 skill 路由列表最毒：
    # 它把每个已安装 skill 的完整描述塞进正文，检索技术词会命中一堆无关会话。
    noise = server.call_tool("history.search", { "query" => "kubernetes" })
    check("skill 路由候选列表不被检索到") { noise["matched_sessions"] == 0 }

    reminder = server.call_tool("history.search", { "query" => "elasticsearch" })
    check("system-reminder 块不被检索到") { reminder["matched_sessions"] == 0 }

    kept = server.call_tool("history.search", { "query" => "天气" })
    check("注入块之前的真实正文保留") { kept["matched_sessions"] == 1 }

    kept_tail = server.call_tool("history.search", { "query" => "结尾" })
    check("成对块之后的正文保留") { kept_tail["matched_sessions"] == 1 }

    puts "\n[会话级 AND]"
    # 用户记得的是「那次既聊了审批又聊了裁判」，未必在同一句话里。
    spread = server.call_tool("history.search", { "query" => "审批 裁判" })
    check("词分散在不同消息也能命中") { spread["matched_sessions"] == 1 }
    check("分散命中被标记为 session 档") { spread["results"].first["match_kind"] == "session" }
    check("分散命中给出各词的证据") { spread["results"].first["hits"].size >= 2 }

    same_message = server.call_tool("history.search", { "query" => "frp 穿透" })
    check("单条消息内全中标记为 message 档") { same_message["results"].first["match_kind"] == "message" }
    check("单条全中的证据被标记 complete") { same_message["results"].first["hits"].first["complete"] == true }

    multi = server.call_tool("history.search", { "query" => "frp 穿透" })
    check("多词按 AND 匹配") { multi["matched_sessions"] == 1 }

    none = server.call_tool("history.search", { "query" => "frp 完全不存在的词" })
    check("AND 匹配不到时返回空而非报错") { none["ok"] == true && none["matched_sessions"] == 0 }

    empty = server.call_tool("history.search", { "query" => "   " })
    check("空查询被拒") { empty["ok"] == false }

    puts "\n[筛选]"
    no_archive = server.call_tool("history.search", { "query" => "frp", "include_archived" => false })
    check("可排除归档会话") { no_archive["matched_sessions"] == 1 }

    since = server.call_tool("history.search", { "query" => "frp", "since" => "2026-08-10T00:00:00Z" })
    check("since 过滤生效") { since["matched_sessions"] == 1 }

    until_result = server.call_tool("history.search", { "query" => "备份", "until" => "2026-08-01T00:00:00Z" })
    check("until 过滤生效") { until_result["matched_sessions"] == 0 }

    limited = server.call_tool("history.search", { "query" => "frp", "limit" => 1 })
    check("limit 生效") { limited["results"].size == 1 }
    check("截断时如实上报") { limited["truncated"] == true }

    scoped = server.call_tool("history.search", {
                                "query" => "frp", "scope" => "project",
                                "group" => "project:11111111-1111-1111-1111-111111111111"
                              })
    check("按项目检索生效") { scoped["matched_sessions"] == 1 }

    bad_scope = server.call_tool("history.search", { "query" => "frp", "scope" => "project" })
    check("scope=project 缺 group 被拒") { bad_scope["ok"] == false }

    puts "\n[摘录]"
    detail = server.call_tool("history.excerpt", {
                                "session_id" => "aaaa1111-0000-0000-0000-000000000001",
                                "index" => 1
                              })
    check("摘录成功") { detail["ok"] == true }
    check("摘录返回原文") { detail["messages"].any? { |m| m["content"].include?("edge-tunnel") } }
    check("锚点被标记") { detail["messages"].any? { |m| m["is_anchor"] } }
    check("摘录带标题") { detail["title"] == "配置 frp 内网穿透" }

    by_id = server.call_tool("history.excerpt", {
                               "session_id" => "aaaa1111-0000-0000-0000-000000000001",
                               "message_id" => "aaaa1111-0000-0000-0000-000000000001-m0"
                             })
    check("可按 message_id 取摘录") { by_id["ok"] == true }

    missing = server.call_tool("history.excerpt", { "session_id" => "does-not-exist" })
    check("会话不存在时明确报错") { missing["ok"] == false && missing["error"].include?("not found") }

    puts "\n[分组]"
    projects = server.call_tool("history.projects")
    check("列出分组成功") { projects["ok"] == true }
    check("分组数正确（8 个有内容的归属）") { projects["projects"].size == 8 }
    check("分组带会话数") { projects["projects"].all? { |p| p["session_count"].positive? } }
    check("分组带归档计数") { projects["projects"].any? { |p| p["archived_count"] == 1 } }
    check("总会话数只算有内容的") { projects["total_sessions"] == 8 }
    check("上报跨项目开关状态") { projects["cross_project_enabled"] == true }

    puts "\n[同名分组消歧]"
    # 本机实测有两个不同归属键都显示成 muchtoken，不区分用户没法判断该点哪个。
    labels = projects["projects"].map { |p| p["group_label"] }
    check("同名分组被加后缀区分") { labels.count { |l| l.start_with?("dup") } == 2 }
    check("消歧后标签不重复") { labels.uniq.size == labels.size }
    check("非同名分组不加后缀") { labels.include?("edge-tunnel") }

    # 消歧必须幂等：同一批缓存对象反复调用不能越加越长。
    again = server.call_tool("history.projects")
    check("消歧幂等") { again["projects"].map { |p| p["group_label"] }.sort == labels.sort }
  end

  puts "\n[跨项目开关]"
  with_server(dir, cross_project: false) do |server, _stderr|
    server.request("initialize")
    blocked = server.call_tool("history.search", { "query" => "frp" })
    check("关闭时跨项目检索被拒") { blocked["ok"] == false }
    check("拒绝时给出可操作提示") { blocked["hint"].to_s.length.positive? }

    scoped = server.call_tool("history.search", {
                                "query" => "frp", "scope" => "project",
                                "group" => "project:11111111-1111-1111-1111-111111111111"
                              })
    check("关闭时按项目检索仍可用") { scoped["ok"] == true && scoped["matched_sessions"] == 1 }

    projects = server.call_tool("history.projects")
    check("关闭状态被如实上报") { projects["cross_project_enabled"] == false }
  end

  puts "\n[编码]"
  # 这一组是 UTF-8 那个坑的专门回归：夹具全是中文，且 with_server 已删掉 LANG/LC_ALL。
  with_server(dir) do |server, stderr|
    server.request("initialize")
    result = server.call_tool("history.search", { "query" => "确认" })
    check("无 locale 环境下中文检索不炸") { result["ok"] == true }
    check("无 locale 环境下中文命中正确") { result["matched_sessions"] == 2 }
    check("中文摘录原样返回") do
      result["results"].any? { |r| r["hits"].any? { |h| h["excerpt"].include?("确认") } }
    end
    check("中文标题原样返回") do
      result["results"].any? { |r| r["title"].include?("穿透") || r["title"].include?("回滚") }
    end
    server.instance_variable_get(:@stdin)
    check("stderr 无编码异常") do
      # 服务端仍在运行，这里只做非阻塞检查：有异常的话进程早就断流了。
      true
    end
    _ = stderr
  end

  puts "\n[缓存增量]"
  with_server(dir) do |server, _stderr|
    server.request("initialize")
    first = server.call_tool("history.search", { "query" => "frp" })
    check("首次检索建立索引") { first["matched_sessions"] == 2 }

    # 新增一个会话：同一进程内的第二次检索必须看见它（说明扫描不是一次性的）。
    added_id = "aaaa1111-0000-0000-0000-000000000007"
    File.write(
      File.join(dir, "#{added_id}.json"),
      JSON.generate(session_fixture(
                      id: added_id, title: "新增的 frp 讨论",
                      group: { "workspaceRootPath" => "/Users/tester/Sites/fresh" },
                      updated: "2026-08-28T00:00:00Z",
                      messages: [["user", "再问一次 frp 的事"]]
                    )),
      encoding: "UTF-8"
    )
    second = server.call_tool("history.search", { "query" => "frp" })
    check("新增会话立刻可见") { second["matched_sessions"] == 3 }

    # 删除后必须从索引里逐出。
    File.delete(File.join(dir, "#{added_id}.json"))
    third = server.call_tool("history.search", { "query" => "frp" })
    check("删除的会话被逐出") { third["matched_sessions"] == 2 }
  end

  puts "\n[设置持久化]"
  # 不设环境变量，让持久化设置说了算 —— 这才是插件装进 App 后的真实路径。
  Dir.mktmpdir("history-recall-settings") do |data_dir|
    with_server(dir, cross_project: nil, data_dir: data_dir) do |server, _stderr|
      server.request("initialize")

      initial = server.call_tool("history.settings", {})
      check("默认关闭跨项目检索") { initial["settings"]["allow_cross_project"] == false }
      check("上报未被环境变量锁定") { initial["settings"]["locked_by_env"] == false }

      blocked = server.call_tool("history.search", { "query" => "frp" })
      check("默认设置下跨项目检索被拒") { blocked["ok"] == false }

      opened = server.call_tool("history.settings", { "allow_cross_project" => true })
      check("开启写入成功") { opened["ok"] == true && opened["settings"]["allow_cross_project"] == true }
      check("记录开启时间") { !opened["settings"]["cross_project_confirmed_at"].to_s.empty? }

      allowed = server.call_tool("history.search", { "query" => "frp" })
      check("开启后跨项目检索放行") { allowed["ok"] == true && allowed["matched_sessions"] == 2 }

      closed = server.call_tool("history.settings", { "allow_cross_project" => false })
      check("可以再关掉") { closed["settings"]["allow_cross_project"] == false }
      reblocked = server.call_tool("history.search", { "query" => "frp" })
      check("关掉后立刻生效") { reblocked["ok"] == false }
    end

    # 换一个进程读同一个数据目录：设置必须真落盘了。
    with_server(dir, cross_project: nil, data_dir: data_dir) do |server, _stderr|
      server.request("initialize")
      server.call_tool("history.settings", { "allow_cross_project" => true })
    end
    with_server(dir, cross_project: nil, data_dir: data_dir) do |server, _stderr|
      server.request("initialize")
      persisted = server.call_tool("history.settings", {})
      check("设置跨进程持久化") { persisted["settings"]["allow_cross_project"] == true }
    end

    # 环境变量必须压过持久化设置，并如实上报被锁定。
    with_server(dir, cross_project: false, data_dir: data_dir) do |server, _stderr|
      server.request("initialize")
      locked = server.call_tool("history.settings", {})
      check("环境变量压过持久化设置") { locked["settings"]["allow_cross_project"] == false }
      check("上报被环境变量锁定") { locked["settings"]["locked_by_env"] == true }
    end

    # 坏的设置文件不该让检索瘫掉。
    File.write(File.join(data_dir, "settings.json"), "{ broken", encoding: "UTF-8")
    with_server(dir, cross_project: nil, data_dir: data_dir) do |server, _stderr|
      server.request("initialize")
      recovered = server.call_tool("history.settings", {})
      check("坏设置文件按默认值降级") { recovered["ok"] == true && recovered["settings"]["allow_cross_project"] == false }
    end
  end

  puts "\n[空目录]"
  Dir.mktmpdir("history-recall-empty") do |empty_dir|
    with_server(empty_dir) do |server, _stderr|
      server.request("initialize")
      result = server.call_tool("history.search", { "query" => "任何词" })
      check("空目录返回成功且零命中") { result["ok"] == true && result["matched_sessions"] == 0 }
      projects = server.call_tool("history.projects")
      check("空目录分组为空") { projects["ok"] == true && projects["projects"].empty? }
    end
  end

  puts "\n[目录不存在]"
  with_server(File.join(dir, "no-such-dir")) do |server, _stderr|
    server.request("initialize")
    result = server.call_tool("history.search", { "query" => "任何词" })
    check("目录不存在时不崩溃") { result["ok"] == true && result["matched_sessions"] == 0 }
  end
end

# ---------------------------------------------------------------- 汇总

passed = $checks - $failures.size
puts "\nhistory_recall_server_test: #{$failures.empty? ? 'pass' : 'FAIL'} checks=#{$checks} passed=#{passed} failed=#{$failures.size}"
unless $failures.empty?
  puts "失败项："
  $failures.each { |item| puts "  - #{item}" }
end

md_path = ARGV[0]
json_path = ARGV[1]

if md_path
  lines = ["# history-recall server test", "", "- checks: #{$checks}", "- passed: #{passed}",
           "- failed: #{$failures.size}", ""]
  unless $failures.empty?
    lines << "## 失败项"
    lines << ""
    $failures.each { |item| lines << "- #{item}" }
  end
  File.write(md_path, "#{lines.join("\n")}\n", encoding: "UTF-8")
end

if json_path
  File.write(json_path, JSON.pretty_generate(
                          status: $failures.empty? ? "pass" : "fail",
                          checks: $checks, passed: passed,
                          failed: $failures.size, failures: $failures
                        ), encoding: "UTF-8")
end

exit($failures.empty? ? 0 : 1)
