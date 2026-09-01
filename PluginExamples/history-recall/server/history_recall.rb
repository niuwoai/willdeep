#!/usr/bin/env ruby
# frozen_string_literal: true

# 历史回溯（history-recall）MCP 服务端。
#
# 跨项目检索本机全部 Agent 会话，帮用户找回「那段话是在哪个会话里聊的」。
# 会话平铺在 ~/Library/Application Support/WillDeep/agent-sessions/，归属靠字段不靠目录。
#
# 设计要点见 docs/CROSS_PROJECT_HISTORY_RECALL_DESIGN.md：
#   - 不建持久索引：474 个文件 79MB 全量解析实测 494ms，内存内检索 38ms
#   - 进程内缓存 + (mtime,size) 增量，不落盘
#   - 0 消息的空壳会话直接丢弃（本机 474 个里有 221 个是这种）
#
# 协议：JSON-RPC over stdio，NDJSON 行分帧（与 session-vitality / todo 同构）。

require "json"
require "time"
require "fileutils"

# 宿主用 /usr/bin/ruby 拉起本进程且不保证带 locale，默认外部编码会退成 US-ASCII，
# 读中文会话立刻抛 Encoding::InvalidByteSequenceError。必须在任何读盘之前钉死 UTF-8。
$stdout.sync = true
Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8
$stdout.set_encoding(Encoding::UTF_8)
$stderr.set_encoding(Encoding::UTF_8)

module HistoryRecall
  SERVER_NAME = "history-recall"
  SERVER_VERSION = "1.0.0"
  PROTOCOL_VERSION = "2025-06-18"

  # 与 session-vitality 同口径：超大会话跳过，避免单个异常文件拖垮整次扫描。
  MAX_FILE_BYTES = 32 * 1024 * 1024

  # 摘录窗口：命中词前后各取多少字符。
  EXCERPT_RADIUS = 90
  # 单个会话最多回多少条命中，避免一个会话刷屏。
  MAX_MATCHES_PER_SESSION = 3
  # 检索结果默认/最大会话数。
  DEFAULT_LIMIT = 12
  MAX_LIMIT = 50

  # Apple 纪元（2001-01-01）到 Unix 纪元的秒差。会话里的时间戳两种形态都出现过。
  APPLE_EPOCH_OFFSET = 978_307_200

  module_function

  def sessions_dir
    override = ENV["WD_HISTORY_SESSIONS_DIR"]
    return override if override && !override.empty?

    File.expand_path("~/Library/Application Support/WillDeep/agent-sessions")
  end

  # 设置落在插件数据目录下。刻意不用 manifest 的 settings + ${setting:} 通道：
  # 那条路只在 mcp.json 的 env / headers 里展开，且仓库里没有任何在用的先例，
  # 一旦展开不出来整条 MCP 服务会被拒载，插件直接哑掉。自己存这份状态更稳，
  # 开关也就摆在插件页面里，用户改完立刻生效。
  def data_dir
    override = ENV["WD_HISTORY_DATA_DIR"]
    return override if override && !override.empty?

    File.expand_path("~/Library/Application Support/WillDeep/plugin-data/history-recall")
  end

  def settings_path
    File.join(data_dir, "settings.json")
  end

  def load_settings
    return {} unless File.file?(settings_path)

    parsed = JSON.parse(File.read(settings_path, encoding: "UTF-8"))
    parsed.is_a?(Hash) ? parsed : {}
  rescue JSON::ParserError, Errno::ENOENT, Errno::EACCES
    # 坏的设置文件按默认值走，不让它挡住检索。
    {}
  end

  def save_settings(settings)
    FileUtils.mkdir_p(data_dir)
    temp = "#{settings_path}.tmp"
    File.write(temp, JSON.pretty_generate(settings), encoding: "UTF-8")
    File.rename(temp, settings_path)
    true
  rescue SystemCallError
    false
  end

  # 跨项目检索是否放行。宿主的 search_sessions 把 scope=all 归为写风险要走审批卡，
  # 插件直接读盘绕过了那道门，所以这里自带一个默认关闭的开关。
  #
  # 环境变量优先于持久化设置，供测试和高级用户使用。
  def cross_project_enabled?
    env_value = ENV["WD_HISTORY_ALLOW_CROSS_PROJECT"].to_s.strip.downcase
    return %w[1 true yes on].include?(env_value) unless env_value.empty?

    load_settings["allow_cross_project"] == true
  end

  def update_settings(allow_cross_project:)
    settings = load_settings
    settings["allow_cross_project"] = allow_cross_project == true
    # 记下首次开启的时间，页面据此决定还要不要再弹一次确认。
    settings["cross_project_confirmed_at"] = Time.now.utc.iso8601 if allow_cross_project == true
    ok = save_settings(settings)
    { "ok" => ok, "error" => ok ? nil : "failed to persist settings", "settings" => current_settings }
  end

  def current_settings
    {
      "allow_cross_project" => cross_project_enabled?,
      "cross_project_confirmed_at" => load_settings["cross_project_confirmed_at"],
      # 环境变量在场时页面上的开关是无效的，必须如实告诉页面，否则用户会对着
      # 一个点了没反应的开关发火。
      "locked_by_env" => !ENV["WD_HISTORY_ALLOW_CROSS_PROJECT"].to_s.strip.empty?,
      "sessions_dir" => sessions_dir,
      "data_dir" => data_dir
    }
  end

  # ---------------------------------------------------------------- 字段兼容

  # 本机实测 474 个会话全是 camelCase，但夹具和旧版落盘可能是 snake_case，两种都认。
  def pick(hash, *keys)
    return nil unless hash.is_a?(Hash)

    keys.each do |key|
      value = hash[key]
      value = hash[key.to_sym] if value.nil?
      return value unless value.nil?
    end
    nil
  end

  def parse_time(raw)
    case raw
    when Numeric
      seconds = raw.to_f
      return nil if seconds <= 0

      # 小于 2001-09 的值按 Apple 纪元解释，否则按 Unix 纪元。
      seconds < 1_000_000_000 ? Time.at(seconds + APPLE_EPOCH_OFFSET) : Time.at(seconds)
    when String
      return nil if raw.strip.empty?

      begin
        Time.parse(raw)
      rescue ArgumentError, TypeError
        nil
      end
    end
  end

  # 复刻宿主 AgentSession.workspaceSidebarGroupKey（Xedit/AgentModels.swift:427-449）的优先级。
  # 必须照这个顺序取，否则 worktree 里的会话会被算成独立项目而不是归到主项目。
  def group_key(session)
    project_id = pick(session, "projectID", "project_id")
    return "project:#{project_id}" if project_id && !project_id.to_s.empty?

    sidebar_root = pick(session, "sidebarWorkspaceRootPath", "sidebar_workspace_root_path")
    return sidebar_root if sidebar_root && !sidebar_root.to_s.empty?

    location = pick(session, "workspaceLocation", "workspace_location")
    if location.is_a?(Hash)
      kind = pick(location, "kind")
      path = pick(location, "path")
      runtime = pick(location, "runtimeID", "runtime_id")
      if kind.to_s == "remote" && runtime
        return "remote:#{runtime}:#{path}"
      elsif path && !path.to_s.empty?
        return path
      end
    end

    root = pick(session, "workspaceRootPath", "workspace_root_path")
    return root if root && !root.to_s.empty?

    "_no_workspace_"
  end

  # 归属键给人看的名字。projectID 只是 UUID，项目真名在宿主的 AgentProject 里，
  # 插件读不到，所以退而用路径末段；纯 UUID 分组就显示短 UUID。
  def group_label(key, fallback_path)
    return "未归属" if key == "_no_workspace_"

    if key.start_with?("project:")
      return File.basename(fallback_path) if fallback_path && !fallback_path.to_s.empty?

      return "项目 #{key.sub('project:', '')[0, 8]}"
    end
    return key.sub(%r{\Aremote:[^:]+:}, "") if key.start_with?("remote:")

    File.basename(key)
  end

  # ---------------------------------------------------------------- 注入块剥离

  # 宿主会把若干上下文块追加进 user 消息的正文里。本机实测 916 条 user 消息中有 171 条
  # （18.7%）含这类内容，其中 skill 路由候选列表最毒——它把每个已安装 skill 的完整描述
  # 都塞进正文，检索「SwiftUI 卡死」会命中一堆根本没聊过这个话题的会话。
  #
  # 这些都是宿主生成的固定文案，按标记截断是安全的；用户自己写出这些整句的概率可以忽略。
  TRUNCATE_MARKERS = [
    "The user attached the following context for this turn",
    "[周期任务 · 无人值守执行边界]"
  ].freeze

  # 成对包裹的块整段移除。
  WRAPPED_BLOCKS = [
    ["<system-reminder>", "</system-reminder>"],
    ["<local-command-caveat>", "</local-command-caveat>"]
  ].freeze

  module_function

  def strip_injected_context(content)
    text = content.to_s

    WRAPPED_BLOCKS.each do |open_tag, close_tag|
      loop do
        start = text.index(open_tag)
        break if start.nil?

        finish = text.index(close_tag, start)
        if finish.nil?
          # 只有开标签没有闭标签，从开标签处截断，避免留下半截噪声。
          text = text[0, start].to_s
          break
        end
        text = text[0, start].to_s + text[(finish + close_tag.length)..-1].to_s
      end
    end

    TRUNCATE_MARKERS.each do |marker|
      position = text.index(marker)
      text = text[0, position].to_s unless position.nil?
    end

    text.strip
  end

  # ---------------------------------------------------------------- 扫描与缓存

  # path => { "signature" => "<mtime>:<size>", "digest" => {...} }
  # 纯进程内，不落盘：正文缓存的体积就等于原始数据，落盘只省下一次解析却换来
  # 一致性、占用与损坏降级三份复杂度。
  @cache = {}

  def cache
    @cache
  end

  def session_files
    dir = sessions_dir
    return [] unless File.directory?(dir)

    begin
      Dir.children(dir).each_with_object([]) do |name, list|
        list << File.join(dir, name) if name.end_with?(".json")
      end
    rescue Errno::EACCES, Errno::ENOENT
      []
    end
  end

  # 返回全部有内容的会话摘要。变化的文件才重解，删掉的文件逐出缓存。
  def all_digests
    files = session_files
    seen = {}

    digests = files.map do |path|
      begin
        stat = File.stat(path)
      rescue Errno::ENOENT, Errno::EACCES
        next nil
      end
      next nil if stat.size > MAX_FILE_BYTES

      signature = "#{stat.mtime.to_i}:#{stat.size}"
      seen[path] = true
      cached = @cache[path]
      if cached && cached["signature"] == signature
        cached["digest"]
      else
        digest = build_digest(path)
        @cache[path] = { "signature" => signature, "digest" => digest }
        digest
      end
    end

    @cache.keys.each { |path| @cache.delete(path) unless seen[path] }
    digests.compact
  end

  # 单个会话 JSON → 检索用摘要。空壳会话（0 条有效消息）返回 nil，不进索引。
  def build_digest(path)
    raw = File.read(path, encoding: "UTF-8")
    session = JSON.parse(raw)
    return nil unless session.is_a?(Hash)

    messages = pick(session, "messages") || []
    return nil unless messages.is_a?(Array)

    # 只留用户和助手的正文。工具调用的 payload 噪声大且多为机器内容，检索价值低，
    # 与宿主 AgentSessionSearch 的口径一致（只搜 .user / .assistant）。
    entries = []
    messages.each_with_index do |message, index|
      next unless message.is_a?(Hash)

      role = pick(message, "role").to_s
      next unless role == "user" || role == "assistant"

      content = strip_injected_context(pick(message, "content"))
      next if content.empty?

      entries << {
        "index" => index,
        "id" => pick(message, "id").to_s,
        "role" => role,
        "at" => parse_time(pick(message, "createdAt", "created_at")),
        "content" => content,
        "haystack" => content.downcase
      }
    end
    return nil if entries.empty?

    key = group_key(session)
    workspace_path = pick(session, "workspaceRootPath", "workspace_root_path") ||
                     pick(pick(session, "workspaceLocation", "workspace_location") || {}, "path")
    updated = parse_time(pick(session, "updatedAt", "updated_at")) ||
              parse_time(pick(session, "createdAt", "created_at"))

    title = pick(session, "title").to_s

    {
      "session_id" => pick(session, "id").to_s,
      "title" => title,
      "title_haystack" => title.downcase,
      "group_key" => key,
      # base 是消歧前的原始标签，disambiguate_labels 每次从它重算 group_label。
      "group_label_base" => group_label(key, workspace_path),
      "group_label" => group_label(key, workspace_path),
      "workspace_path" => workspace_path.to_s,
      "archived" => !pick(session, "archivedAt", "archived_at").nil?,
      "created_at" => parse_time(pick(session, "createdAt", "created_at")),
      "updated_at" => updated,
      "message_count" => entries.size,
      "entries" => entries
    }
  rescue JSON::ParserError, Errno::ENOENT, Errno::EACCES, ArgumentError
    # 单个坏文件不该让整次检索失败。
    nil
  end

  # 同名分组消歧。本机实测有两个不同归属键都叫 muchtoken（一个按 projectID 分组、
  # 一个按路径分组），不加区分用户没法判断该点哪个。
  # 每次都从不变的 group_label_base 重算，所以对同一批缓存对象反复调用是幂等的。
  def disambiguate_labels(digests)
    keys_by_label = {}
    digests.each do |digest|
      base = digest["group_label_base"]
      (keys_by_label[base] ||= {})[digest["group_key"]] = true
    end

    digests.each do |digest|
      base = digest["group_label_base"]
      unless keys_by_label[base] && keys_by_label[base].size > 1
        digest["group_label"] = base
        next
      end

      key = digest["group_key"].to_s
      suffix = if key.start_with?("project:")
                 key.sub("project:", "")[0, 8]
               else
                 parent = File.basename(File.dirname(key))
                 parent.empty? || parent == "." ? key[0, 8] : parent
               end
      digest["group_label"] = "#{base} · #{suffix}"
    end
    digests
  end

  # ---------------------------------------------------------------- 检索

  # 查询串按空白拆词，逐词 AND 子串匹配。
  # 中文不需要分词——连续子串天然可搜；"SSH 穿透" 这类多词查询才需要拆。
  def parse_terms(query)
    query.to_s.split(/\s+/).each_with_object([]) do |term, list|
      cleaned = term.strip.downcase
      list << cleaned unless cleaned.empty?
    end
  end

  def matches_all_terms?(haystack, terms)
    terms.all? { |term| haystack.include?(term) }
  end

  # 命中评分：匹配强度为主，新鲜度为辅。
  #
  # 纯按时间倒序正是宿主 search_sessions 那个 40 条窗口的病根——旧会话永远排不进来。
  # 这里让强匹配能压过新鲜度，同时给近期会话一点加权。
  def score(digest, hits, kind, terms, now)
    term_hits = hits.sum { |hit| hit["hit_count"] }
    # 标题命中是很强的信号：用户往往记得大概主题。
    title_bonus = matches_all_terms?(digest["title_haystack"].to_s, terms) ? 6.0 : 0.0
    # 覆盖度：命中了几条不同消息，比在一条里重复出现更有意义。
    spread = hits.size.to_f
    # 词分散在不同消息里的会话级命中，证据弱得多，压到三分之一。
    kind_weight = kind == "session" ? 0.33 : 1.0

    updated = digest["updated_at"]
    recency = if updated.is_a?(Time)
                days = (now - updated) / 86_400.0
                # 半衰期 30 天，最多贡献 3 分，不足以压过内容匹配。
                3.0 * (0.5**(days / 30.0))
              else
                0.0
              end

    (Math.log(1 + term_hits) * 2.0 + spread * 1.5) * kind_weight + title_bonus + recency
  end

  # position 是在 downcase 后的 haystack 上算出来的，用在原文上。ASCII 与 CJK 的
  # downcase 不改变长度，但少数 Unicode 字符会（土耳其语 İ 之类），那时索引会偏。
  # 后果只是摘录窗口挪几个字符，不值得为它保一份映射表，越界夹一下即可。
  def excerpt_around(content, position, length)
    position = 0 if position.nil? || position.negative? || position > content.length
    start = [position - EXCERPT_RADIUS, 0].max
    finish = [position + length + EXCERPT_RADIUS, content.length].min
    text = content[start...finish].to_s.gsub(/\s+/, " ").strip
    text = "…#{text}" if start.positive?
    text = "#{text}…" if finish < content.length
    text
  end

  def build_hit(entry, matched, all_terms)
    # 摘录锚在命中词里最长的那个上——它通常最具体，摘出来的上下文更有辨识度。
    anchor = matched.max_by(&:length)
    position = entry["haystack"].index(anchor) || 0
    hit_count = matched.sum { |term| entry["haystack"].scan(Regexp.escape(term)).size }

    {
      "message_id" => entry["id"],
      "index" => entry["index"],
      "role" => entry["role"],
      "at" => entry["at"] ? entry["at"].utc.iso8601 : nil,
      "excerpt" => excerpt_around(entry["content"], position, anchor.length),
      "hit_count" => hit_count,
      "matched_terms" => matched,
      "complete" => matched.size == all_terms.size
    }
  end

  # 命中分两档：
  #   full    —— 单条消息里所有词都出现，最强的信号
  #   partial —— 词分散在会话的不同消息里，只要会话整体覆盖了全部词也算命中
  #
  # 只认单条消息内 AND 会漏掉一大类真实需求：用户记得的是「那次既聊了审批又聊了裁判」，
  # 而不是某一句话里同时出现两个词。会话级覆盖把这类找回来，排序再保证强匹配在前。
  def collect_hits(digest, terms)
    full = []
    partial = []
    covered = {}

    digest["entries"].each do |entry|
      matched = terms.select { |term| entry["haystack"].include?(term) }
      next if matched.empty?

      matched.each { |term| covered[term] = true }
      if matched.size == terms.size
        full << build_hit(entry, matched, terms) if full.size < MAX_MATCHES_PER_SESSION
      elsif partial.size < MAX_MATCHES_PER_SESSION
        partial << build_hit(entry, matched, terms)
      end
    end

    return { "kind" => "message", "hits" => full } unless full.empty?
    return { "kind" => "session", "hits" => partial } if terms.all? { |term| covered[term] }

    { "kind" => "none", "hits" => [] }
  end

  def search(query:, scope: "all", group: nil, since: nil, until_time: nil, limit: DEFAULT_LIMIT,
             include_archived: true)
    terms = parse_terms(query)
    return { "ok" => false, "error" => "query is empty" } if terms.empty?

    if scope == "all" && !cross_project_enabled?
      return {
        "ok" => false,
        "error" => "cross-project search is disabled",
        "hint" => "在插件设置里打开「允许跨项目检索」，或改用 scope=\"project\" 加 group 参数。"
      }
    end

    if scope == "project" && (group.nil? || group.to_s.empty?)
      return { "ok" => false, "error" => "scope=\"project\" requires a group key" }
    end

    since_time = since ? parse_time(since) : nil
    until_at = until_time ? parse_time(until_time) : nil
    capped = [[limit.to_i, 1].max, MAX_LIMIT].min
    now = Time.now

    scanned = 0
    results = []
    disambiguate_labels(all_digests).each do |digest|
      next if scope == "project" && digest["group_key"] != group
      next if !include_archived && digest["archived"]

      updated = digest["updated_at"]
      next if since_time && updated.is_a?(Time) && updated < since_time
      next if until_at && updated.is_a?(Time) && updated > until_at

      scanned += 1
      collected = collect_hits(digest, terms)
      hits = collected["hits"]
      kind = collected["kind"]
      # 标题单独算一路命中：用户找旧对话时最容易记住的往往正是标题，
      # 而标题里的词不一定在正文出现过（宿主侧栏搜的也正是标题）。
      title_match = matches_all_terms?(digest["title_haystack"].to_s, terms)
      next if kind == "none" && !title_match

      kind = "title" if kind == "none"
      updated = digest["updated_at"]
      results << {
        "session_id" => digest["session_id"],
        "title" => digest["title"],
        "title_match" => title_match,
        # message = 单条消息内全中；session = 词分散在会话各处；title = 只有标题命中。
        "match_kind" => kind,
        "group_key" => digest["group_key"],
        "group_label" => digest["group_label"],
        "archived" => digest["archived"],
        "updated_at" => updated ? updated.utc.iso8601 : nil,
        "message_count" => digest["message_count"],
        "score" => score(digest, hits, kind, terms, now).round(3),
        "hits" => hits
      }
    end

    results.sort_by! { |item| -item["score"] }
    truncated = results.size > capped

    {
      "ok" => true,
      "query" => query,
      "terms" => terms,
      "scope" => scope,
      # 报清楚扫了多少、命中多少、有没有截断——用户必须能区分「确实没聊过」
      # 和「聊过但没显示出来」，这正是宿主 search_sessions 缺的那一环。
      "scanned_sessions" => scanned,
      "matched_sessions" => results.size,
      "truncated" => truncated,
      "results" => results.first(capped)
    }
  end

  # 取某条命中前后的原文，供「展开看看」。
  def excerpt(session_id:, index: nil, message_id: nil, radius: 2)
    digest = disambiguate_labels(all_digests).find { |item| item["session_id"] == session_id }
    return { "ok" => false, "error" => "session not found: #{session_id}" } unless digest

    entries = digest["entries"]
    anchor = if message_id && !message_id.to_s.empty?
               entries.index { |entry| entry["id"] == message_id }
             elsif !index.nil?
               entries.index { |entry| entry["index"] == index.to_i }
             end
    return { "ok" => false, "error" => "message not found in session" } if anchor.nil?

    span = [[radius.to_i, 0].max, 10].min
    from = [anchor - span, 0].max
    to = [anchor + span, entries.size - 1].min

    {
      "ok" => true,
      "session_id" => session_id,
      "title" => digest["title"],
      "group_label" => digest["group_label"],
      "archived" => digest["archived"],
      "messages" => entries[from..to].map do |entry|
        {
          "index" => entry["index"],
          "message_id" => entry["id"],
          "role" => entry["role"],
          "at" => entry["at"]&.utc&.iso8601,
          "content" => entry["content"],
          "is_anchor" => entry["index"] == entries[anchor]["index"]
        }
      end
    }
  end

  def list_projects
    groups = {}
    disambiguate_labels(all_digests).each do |digest|
      key = digest["group_key"]
      bucket = groups[key] ||= {
        "group_key" => key,
        "group_label" => digest["group_label"],
        "session_count" => 0,
        "archived_count" => 0,
        "message_count" => 0,
        "latest_at" => nil
      }
      bucket["session_count"] += 1
      bucket["archived_count"] += 1 if digest["archived"]
      bucket["message_count"] += digest["message_count"]
      updated = digest["updated_at"]
      bucket["latest_at"] = updated if updated.is_a?(Time) && (bucket["latest_at"].nil? || updated > bucket["latest_at"])
    end

    listed = groups.values.sort_by { |item| [item["latest_at"] ? -item["latest_at"].to_i : 0, -item["session_count"]] }
    listed.each { |item| item["latest_at"] = item["latest_at"]&.utc&.iso8601 }

    {
      "ok" => true,
      "cross_project_enabled" => cross_project_enabled?,
      "total_sessions" => listed.sum { |item| item["session_count"] },
      "projects" => listed
    }
  end
end

# ---------------------------------------------------------------- MCP 协议层

module HistoryRecall
  TOOLS = [
    {
      name: "history.search",
      description: "跨项目检索本机全部 Agent 会话历史，找回某段对话在哪个会话里。" \
                   "返回命中会话、摘录、归属项目与时间，并报告扫描与截断情况。",
      inputSchema: {
        type: "object",
        properties: {
          query: { type: "string", description: "检索词。多个词按空白分隔，逐词 AND 匹配。中文无需分词。" },
          scope: { type: "string", enum: %w[all project], description: "检索范围，默认 all（需已开启跨项目检索）。" },
          group: { type: "string", description: "scope=project 时的归属键，取自 history.projects。" },
          since: { type: "string", description: "只看这个时间之后更新的会话，ISO 8601。" },
          until: { type: "string", description: "只看这个时间之前更新的会话，ISO 8601。" },
          include_archived: { type: "boolean", description: "是否包含已归档会话，默认 true。" },
          limit: { type: "integer", description: "最多返回多少个会话，默认 12，上限 50。" }
        },
        required: ["query"]
      }
    },
    {
      name: "history.excerpt",
      description: "取某个会话中某条消息前后的原文，用于展开查看命中的上下文。",
      inputSchema: {
        type: "object",
        properties: {
          session_id: { type: "string", description: "会话 UUID，取自 history.search 结果。" },
          index: { type: "integer", description: "消息在会话中的下标，取自命中项的 index。" },
          message_id: { type: "string", description: "消息 ID，与 index 二选一。" },
          radius: { type: "integer", description: "前后各取多少条，默认 2，上限 10。" }
        },
        required: ["session_id"]
      }
    },
    {
      name: "history.projects",
      description: "列出全部会话归属分组及其会话数与最近活动时间，供筛选与 scope=project 取值。",
      inputSchema: { type: "object", properties: {} }
    },
    {
      name: "history.settings",
      description: "读取或修改历史回溯的设置。不带参数时只读；带 allow_cross_project 时写入。" \
                   "跨项目检索默认关闭，开启后本插件可以读取全部项目的历史会话正文。",
      inputSchema: {
        type: "object",
        properties: {
          allow_cross_project: { type: "boolean", description: "是否允许跨项目检索。省略则只读当前设置。" }
        }
      }
    }
  ].freeze

  module_function

  def call_tool(name, arguments)
    args = arguments.is_a?(Hash) ? arguments : {}
    case name
    when "history.search"
      search(
        query: args["query"],
        scope: (args["scope"] || "all").to_s,
        group: args["group"],
        since: args["since"],
        until_time: args["until"],
        limit: args["limit"] || DEFAULT_LIMIT,
        include_archived: args.fetch("include_archived", true) != false
      )
    when "history.excerpt"
      excerpt(
        session_id: args["session_id"].to_s,
        index: args["index"],
        message_id: args["message_id"],
        radius: args["radius"] || 2
      )
    when "history.projects"
      list_projects
    when "history.settings"
      if args.key?("allow_cross_project")
        update_settings(allow_cross_project: args["allow_cross_project"])
      else
        { "ok" => true, "settings" => current_settings }
      end
    else
      { "ok" => false, "error" => "unknown tool #{name}" }
    end
  rescue StandardError => error
    # 业务错误一律走 result 里的 ok:false，不返回 JSON-RPC error 对象，
    # 与仓库其它插件服务端口径一致；页面侧的 unwrap() 负责转成异常。
    { "ok" => false, "error" => "#{error.class}: #{error.message}" }
  end

  def handle(request)
    case request["method"]
    when "initialize"
      {
        protocolVersion: PROTOCOL_VERSION,
        capabilities: { tools: {} },
        serverInfo: { name: SERVER_NAME, version: SERVER_VERSION }
      }
    when "tools/list"
      { tools: TOOLS }
    when "tools/call"
      payload = call_tool(request.dig("params", "name"), request.dig("params", "arguments"))
      { content: [{ type: "text", text: JSON.generate(payload) }] }
    when "ping"
      {}
    else
      {}
    end
  end
end

# 行分帧（NDJSON）：宿主按行读，不用 Content-Length。
if $PROGRAM_NAME == __FILE__
  ARGF.each_line do |line|
    begin
      request = JSON.parse(line)
    rescue JSON::ParserError => error
      warn error.message
      next
    end
    # 通知没有 id，按 JSON-RPC 规范不回包。
    next unless request["id"]

    result = HistoryRecall.handle(request)
    puts JSON.generate(jsonrpc: "2.0", id: request["id"], result: result)
  end
end
