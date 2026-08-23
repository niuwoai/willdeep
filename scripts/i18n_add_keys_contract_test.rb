#!/usr/bin/env ruby
# frozen_string_literal: true

# i18n_add_keys_contract_test.rb — 守 scripts/i18n_add_keys.rb 的落点与落盘校验。
#
# 为什么要有这一份:2026-08-23(1.287.0-rc1)那次事故里,脚本把新 key 的紧凑单行
# 插到了多行前驱条目的**首行之后**,也就是插进了邻居的对象体内。文件依旧是合法
# JSON、`git diff --numstat` 依旧「1 增 0 删」,两道常规体检全绿,可新 key 根本不
# 在 `strings.<key>` 上,UI 静默回落 Swift defaultValue,邻居条目还平白多出一个
# 成员。所以这里全部用**行为测试**:拿真脚本去改临时目录里的 fixture catalog,
# 再按 JSON 语义断言结果——不做源码字符串断言,等价重构不该让这份守卫变红。
#
# 用法:
#   ruby scripts/i18n_add_keys_contract_test.rb
#   ruby scripts/i18n_add_keys_contract_test.rb build/ci/i18n_add_keys_contract_report.md \
#                                               build/ci/i18n_add_keys_contract_report.json

require "English"
require "digest"
require "fileutils"
require "json"
require "rbconfig"
require "tmpdir"
require "time"

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

REPO_ROOT = File.expand_path("..", __dir__)
SCRIPT_PATH = File.join(REPO_ROOT, "scripts", "i18n_add_keys.rb")

# 把脚本当库加载(它的 main 有 `__FILE__ == $PROGRAM_NAME` 门禁),这样
# verification_failures / write_verified 这些纯逻辑可以直接喂构造出来的坏数据。
require_relative "i18n_add_keys"

markdown_path = ARGV[0] || "build/i18n_add_keys_contract/report.md"
json_path = ARGV[1] || "build/i18n_add_keys_contract/report.json"

# ---------------------------------------------------------------- fixture 构造

# 紧凑单行条目,复刻 catalog 里被脚本写过的那一半。
def fixture_compact_entry(key, localizations)
  units = localizations.map do |language, value|
    "#{language.to_json}:{\"stringUnit\":{\"state\":\"translated\",\"value\":#{value.to_json}}}"
  end
  "    #{key.to_json} : {\"localizations\":{#{units.join(',')}}}"
end

# 展开多行条目,复刻 catalog 里被 Xcode 写过的另一半。
def fixture_expanded_entry(key, localizations)
  blocks = localizations.map do |language, value|
    [
      "        #{language.to_json} : {",
      "          \"stringUnit\" : {",
      "            \"state\" : \"translated\",",
      "            \"value\" : #{value.to_json}",
      "          }",
      "        }"
    ].join("\n")
  end
  [
    "    #{key.to_json} : {",
    "      \"extractionState\" : \"manual\",",
    "      \"localizations\" : {",
    blocks.join(",\n"),
    "      }",
    "    }"
  ].join("\n")
end

# entries: [[key, { locale => 文案 }, :compact | :expanded], ...],按给定顺序落到文件里。
def fixture_catalog_text(entries)
  bodies = entries.map do |key, localizations, style|
    if style == :compact
      fixture_compact_entry(key, localizations)
    else
      fixture_expanded_entry(key, localizations)
    end
  end
  text = +"{\n"
  text << "  \"sourceLanguage\" : \"en\",\n"
  text << "  \"strings\" : {\n"
  text << bodies.join(",\n") << "\n"
  text << "  },\n"
  text << "  \"version\" : \"1.0\"\n"
  text << "}\n"
  text
end

APPROVAL_FIXTURE = [
  ["plugins.actions", { "en" => "Plugin Actions", "zh-Hans" => "插件操作" }, :compact],
  ["approval-mode.picker-help", { "en" => "Pick a mode.", "zh-Hans" => "选择模式。" }, :expanded],
  ["approval-mode.request-every-time", { "en" => "Ask every time", "zh-Hans" => "每次询问" }, :expanded],
  [
    "approval-mode.request-every-time.summary",
    { "en" => "Ask before risky writes.", "zh-Hans" => "危险写入前询问。" },
    :expanded
  ],
  ["approval-mode.smart", { "en" => "Smart", "zh-Hans" => "智能" }, :expanded]
].freeze

SILENT_LOCALIZATIONS = {
  "en" => "Silent mode",
  "zh-Hans" => "静默模式",
  "ja" => "サイレントモード",
  "es" => "Modo silencioso",
  "fr" => "Mode silencieux"
}.freeze

# ---------------------------------------------------------------- 运行脚本

def fixture_write(dir, name, text)
  path = File.join(dir, name)
  File.binwrite(path, text)
  path
end

def run_script(catalog_path, requested, *extra)
  dir = File.dirname(catalog_path)
  keys_path = File.join(dir, "keys-#{Digest::SHA256.hexdigest(requested.keys.join(','))[0, 8]}.json")
  File.binwrite(keys_path, JSON.generate(requested))
  command = [RbConfig.ruby, SCRIPT_PATH, keys_path, "--catalog", catalog_path, *extra]
  output = IO.popen(command, "r", err: %i[child out], &:read)
  [$CHILD_STATUS.exitstatus, output]
end

def catalog_strings(path)
  JSON.parse(File.binread(path).force_encoding("UTF-8")).fetch("strings")
end

def locale_value(entry, language)
  entry&.dig("localizations", language, "stringUnit", "value")
end

# 找出 key 所在的行号(0-based);顶层条目的行一定以 4 空格 + 引号开头。
def entry_row(lines, key)
  needle = "    #{key.to_json} :"
  lines.index { |line| line.start_with?(needle) }
end

# ---------------------------------------------------------------- 检查框架

checks = []

def check(checks, name)
  detail = yield
  checks << { name: name, ok: detail.nil?, detail: detail || "ok" }
rescue StandardError => e
  checks << { name: name, ok: false, detail: "抛异常: #{e.class}: #{e.message}" }
end

catalog_digest_before = Digest::SHA256.hexdigest(File.binread(DEFAULT_CATALOG))

Dir.mktmpdir("i18n_add_keys_contract") do |tmp|
  # 1. 事故本体:新 key 必须落在多行前驱条目的**末行之后**,而不是它的对象体内。
  check(checks, "新 key 落在多行前驱条目之后,而不是插进它的对象体内") do
    original = fixture_catalog_text(APPROVAL_FIXTURE)
    path = fixture_write(tmp, "regression.xcstrings", original)
    before = JSON.parse(original).fetch("strings")

    status, output = run_script(path, { "approval-mode.silent" => SILENT_LOCALIZATIONS })
    next "脚本非零退出(#{status}):#{output}" unless status.zero?

    after = catalog_strings(path)
    entry = after["approval-mode.silent"]
    next "新 key 在 strings.<key> 上读不出来(正是事故形状):#{output}" if entry.nil?

    missing = SILENT_LOCALIZATIONS.reject { |language, value| locale_value(entry, language) == value }
    next "新 key 缺 locale 或值不对: #{missing.keys.join(', ')}" unless missing.empty?

    victim = "approval-mode.request-every-time.summary"
    next "前驱条目 #{victim} 被改动了: #{JSON.generate(after[victim])}" if after[victim] != before[victim]

    others = before.keys.reject { |key| after[key] == before[key] }
    next "以下既有条目被改动了: #{others.join(', ')}" unless others.empty?

    expected_keys = (before.keys + ["approval-mode.silent"]).sort
    next "key 集合不对: #{after.keys.sort - expected_keys} / #{expected_keys - after.keys.sort}" if after.keys.sort != expected_keys

    # 版式:新行前面必须是前驱条目的收尾行,后面必须是下一个顶层条目的起始行。
    lines = File.binread(path).force_encoding("UTF-8").lines
    row = entry_row(lines, "approval-mode.silent")
    next "找不到新 key 所在的顶层条目行" if row.nil?
    previous = lines[row - 1].strip
    following = lines[row + 1] || ""
    next "新行前一行是 #{previous.inspect},不是前驱条目的收尾 `},`" unless previous == "},"
    unless following.start_with?("    \"approval-mode.smart\" :")
      next "新行后一行是 #{following.strip.inspect},不是下一个顶层条目"
    end

    # 零删除:原文一行不少,只多出插入的那一行。
    original_lines = original.lines
    next "行数不对: #{lines.length} != #{original_lines.length + 1}" if lines.length != original_lines.length + 1
    next "除插入行外原文被改动了" if (lines[0...row] + lines[(row + 1)..]) != original_lines

    nil
  end

  # 2. 自己的命名空间没有兄弟时,逐级回退父命名空间而不是 abort。
  check(checks, "命名空间没有兄弟时回退父命名空间,而不是拒绝放置") do
    entries = [
      ["plugins.actions", { "en" => "Plugin Actions" }, :compact],
      ["approval-mode.silent", { "en" => "Silent mode", "zh-Hans" => "静默模式" }, :expanded],
      ["approval-mode.smart", { "en" => "Smart", "zh-Hans" => "智能" }, :expanded]
    ]
    original = fixture_catalog_text(entries)
    path = fixture_write(tmp, "namespace-fallback.xcstrings", original)
    before = JSON.parse(original).fetch("strings")

    requested = { "approval-mode.silent.summary" => { "en" => "Never ask.", "zh-Hans" => "从不询问。" } }
    status, output = run_script(path, requested)
    next "脚本非零退出(#{status}):#{output}" unless status.zero?

    after = catalog_strings(path)
    entry = after["approval-mode.silent.summary"]
    next "新 key 在 strings.<key> 上读不出来:#{output}" if entry.nil?
    bad = requested.values.first.reject { |language, value| locale_value(entry, language) == value }
    next "新 key 缺 locale 或值不对: #{bad.keys.join(', ')}" unless bad.empty?

    others = before.keys.reject { |key| after[key] == before[key] }
    next "以下既有条目被改动了: #{others.join(', ')}" unless others.empty?

    lines = File.binread(path).force_encoding("UTF-8").lines
    row = entry_row(lines, "approval-mode.silent.summary")
    next "找不到新 key 所在的顶层条目行" if row.nil?
    next "新行前一行是 #{lines[row - 1].strip.inspect},不是前驱条目的收尾 `},`" unless lines[row - 1].strip == "},"
    nil
  end

  # 3. 连同前缀的兄弟都没有时,回退全局字母序,依然要落在条目之间。
  check(checks, "完全没有同前缀兄弟时回退全局字母序") do
    entries = [
      ["plugins.actions", { "en" => "Plugin Actions" }, :compact],
      ["approval-mode.smart", { "en" => "Smart", "zh-Hans" => "智能" }, :expanded]
    ]
    original = fixture_catalog_text(entries)
    path = fixture_write(tmp, "global-fallback.xcstrings", original)
    before = JSON.parse(original).fetch("strings")

    requested = { "zzz-orphan.title" => { "en" => "Orphan", "zh-Hans" => "孤儿" } }
    status, output = run_script(path, requested)
    next "脚本非零退出(#{status}):#{output}" unless status.zero?

    after = catalog_strings(path)
    entry = after["zzz-orphan.title"]
    next "新 key 在 strings.<key> 上读不出来:#{output}" if entry.nil?
    next "新 key 的 en 值不对: #{locale_value(entry, 'en').inspect}" if locale_value(entry, "en") != "Orphan"

    others = before.keys.reject { |key| after[key] == before[key] }
    next "以下既有条目被改动了: #{others.join(', ')}" unless others.empty?
    nil
  end

  # 4. 追加到最后一条之后时,尾逗号要归位(旧的最后一条补逗号,新的最后一条不带)。
  check(checks, "追加到最后一条之后会补好尾逗号,文件仍是合法 JSON") do
    entries = [
      ["alpha.one", { "en" => "One" }, :compact],
      ["alpha.two", { "en" => "Two", "zh-Hans" => "二" }, :expanded]
    ]
    original = fixture_catalog_text(entries)
    path = fixture_write(tmp, "tail-append.xcstrings", original)
    before = JSON.parse(original).fetch("strings")

    requested = { "zulu.last" => { "en" => "Last", "zh-Hans" => "最后" } }
    status, output = run_script(path, requested)
    next "脚本非零退出(#{status}):#{output}" unless status.zero?

    after = catalog_strings(path)
    next "新 key 在 strings.<key> 上读不出来:#{output}" if after["zulu.last"].nil?
    next "新 key 的 zh-Hans 值不对" if locale_value(after["zulu.last"], "zh-Hans") != "最后"

    others = before.keys.reject { |key| after[key] == before[key] }
    next "以下既有条目被改动了: #{others.join(', ')}" unless others.empty?

    lines = File.binread(path).force_encoding("UTF-8").lines
    row = entry_row(lines, "zulu.last")
    next "找不到新 key 所在的顶层条目行" if row.nil?
    next "作为最后一条,新行不该带尾逗号" if lines[row].rstrip.end_with?(",")
    next "旧的最后一条没补上尾逗号: #{lines[row - 1].strip.inspect}" unless lines[row - 1].strip == "},"
    nil
  end

  # 5. 校验逻辑本身:把 1.287.0-rc1 那种「插进邻居体内」的文本喂进去,必须报红。
  check(checks, "落盘校验能抓出「插进邻居对象体内」的坏插法") do
    original = fixture_catalog_text(APPROVAL_FIXTURE)
    before_catalog = JSON.parse(original)
    victim = "approval-mode.request-every-time.summary"

    lines = original.lines
    anchor = entry_row(lines, victim)
    next "fixture 里找不到 #{victim}" if anchor.nil?
    expected = merged_entry(nil, SILENT_LOCALIZATIONS)
    # 复刻旧逻辑:插到前驱条目的**首行**之后 —— 也就是它的对象体内。
    lines.insert(anchor + 1, entry_line("approval-mode.silent", expected))
    corrupted = lines.join

    still_valid_json = begin
      JSON.parse(corrupted)
      true
    rescue JSON::ParserError
      false
    end
    next "坏文本居然解析不了,那这条断言就没意义了(事故的杀伤力正在于它仍是合法 JSON)" unless still_valid_json

    failures = verification_failures(
      before_catalog, corrupted,
      { "approval-mode.silent" => expected }, ["approval-mode.silent"]
    )
    next "校验没报红,事故会再次溜过去" if failures.empty?
    joined = failures.join("\n")
    next "报红了但没点出读不出来的新 key: #{joined}" unless joined.include?("approval-mode.silent")
    next "报红了但没点出被改动的邻居条目: #{joined}" unless joined.include?(victim)
    nil
  end

  # 6. 校验不通过时必须还原原文件。
  check(checks, "落盘校验不通过时会还原原文件") do
    original = fixture_catalog_text(APPROVAL_FIXTURE)
    path = fixture_write(tmp, "restore.xcstrings", original)
    before_catalog = JSON.parse(original)
    victim = "approval-mode.request-every-time.summary"

    lines = original.lines
    expected = merged_entry(nil, SILENT_LOCALIZATIONS)
    lines.insert(entry_row(lines, victim) + 1, entry_line("approval-mode.silent", expected))

    failures = write_verified(
      path, original, lines.join, before_catalog,
      { "approval-mode.silent" => expected }, ["approval-mode.silent"]
    )
    next "校验没报红" if failures.empty?

    restored = File.binread(path).force_encoding("UTF-8")
    next "文件没有被还原成改动前的内容" if restored != original
    next "没有报告还原结果: #{failures.join('; ')}" unless failures.join("\n").include?("还原")
    nil
  end

  # 7. 版式超出假设(结构扫描和 JSON 解析对不上)时,拒绝下笔且一字不动。
  check(checks, "版式对不上时拒绝下笔,catalog 一字不动") do
    original = +"{\n  \"sourceLanguage\" : \"en\",\n"
    original << "  \"strings\" : { \"alpha.one\" : {\"localizations\":{}}, \"alpha.two\" : {\"localizations\":{}} },\n"
    original << "  \"version\" : \"1.0\"\n}\n"
    path = fixture_write(tmp, "weird-layout.xcstrings", original)

    status, output = run_script(path, { "alpha.three" => { "en" => "Three" } })
    next "脚本居然成功了(#{status}),这种版式本该拒绝:#{output}" if status.zero?

    current = File.binread(path).force_encoding("UTF-8")
    next "拒绝下笔却动了文件" if current != original
    nil
  end

  # 8. 重复跑同一份 keys.json 是无变化的,不能每跑一次多一条。
  check(checks, "重复执行不产生二次改动") do
    original = fixture_catalog_text(APPROVAL_FIXTURE)
    path = fixture_write(tmp, "idempotent.xcstrings", original)

    status, output = run_script(path, { "approval-mode.silent" => SILENT_LOCALIZATIONS })
    next "首次执行非零退出(#{status}):#{output}" unless status.zero?
    first = File.binread(path)

    status, output = run_script(path, { "approval-mode.silent" => SILENT_LOCALIZATIONS })
    next "二次执行非零退出(#{status}):#{output}" unless status.zero?
    next "二次执行改了文件" if File.binread(path) != first
    next "二次执行没报告「无变化」:#{output}" unless output.match?(/无变化:\s*1/)
    nil
  end

  # 9. 紧凑条目就地合并:补新 locale,既有 locale 和其他成员都不能丢。
  check(checks, "紧凑单行条目就地合并 locale,不丢既有内容") do
    original = fixture_catalog_text(APPROVAL_FIXTURE)
    path = fixture_write(tmp, "compact-merge.xcstrings", original)
    before = JSON.parse(original).fetch("strings")

    status, output = run_script(path, { "plugins.actions" => { "ja" => "プラグイン操作" } })
    next "脚本非零退出(#{status}):#{output}" unless status.zero?

    after = catalog_strings(path)
    entry = after["plugins.actions"]
    next "ja 没写进去" if locale_value(entry, "ja") != "プラグイン操作"
    next "en 丢了" if locale_value(entry, "en") != "Plugin Actions"
    next "zh-Hans 丢了" if locale_value(entry, "zh-Hans") != "插件操作"

    others = before.keys.reject { |key| key == "plugins.actions" || after[key] == before[key] }
    next "以下无关条目被改动了: #{others.join(', ')}" unless others.empty?
    next "key 数量变了: #{after.keys.length} != #{before.keys.length}" if after.keys.length != before.keys.length
    nil
  end

  # 10. 多行条目一律不就地改,报告为跳过且文件不动。
  check(checks, "多行条目不就地改写,报告为跳过且文件不动") do
    original = fixture_catalog_text(APPROVAL_FIXTURE)
    path = fixture_write(tmp, "multiline-skip.xcstrings", original)

    status, output = run_script(path, { "approval-mode.smart" => { "ja" => "スマート" } })
    next "脚本非零退出(#{status}):#{output}" unless status.zero?
    next "没报告跳过多行条目:#{output}" unless output.include?("跳过(多行条目")
    next "跳过了却动了文件" if File.binread(path).force_encoding("UTF-8") != original
    nil
  end

  # 11. --dry-run 不写盘。
  check(checks, "--dry-run 不写盘") do
    original = fixture_catalog_text(APPROVAL_FIXTURE)
    path = fixture_write(tmp, "dry-run.xcstrings", original)

    status, output = run_script(path, { "approval-mode.silent" => SILENT_LOCALIZATIONS }, "--dry-run")
    next "脚本非零退出(#{status}):#{output}" unless status.zero?
    next "dry-run 动了文件" if File.binread(path).force_encoding("UTF-8") != original
    next "dry-run 没说自己没写盘:#{output}" unless output.include?("dry-run")
    nil
  end
end

# 12. 整轮跑下来,仓库里那份真 catalog 一个字节都不该被动过。
check(checks, "测试全程不碰仓库里的真 catalog") do
  after = Digest::SHA256.hexdigest(File.binread(DEFAULT_CATALOG))
  next "Xedit/Localizable.xcstrings 被这份测试改了" if after != catalog_digest_before
  nil
end

# ---------------------------------------------------------------- 报告

failures = checks.reject { |check| check[:ok] }
ok = failures.empty?
report = {
  ok: ok,
  generated_at: Time.now.utc.iso8601,
  checks: checks,
  failures: failures
}

[markdown_path, json_path].each do |path|
  directory = File.dirname(File.expand_path(path, REPO_ROOT))
  FileUtils.mkdir_p(directory) unless Dir.exist?(directory)
end

File.write(File.expand_path(json_path, REPO_ROOT), JSON.pretty_generate(report))

status = ok ? "PASS" : "FAIL"
md = +"# i18n_add_keys Contract Report\n\n"
md << "**Status:** #{status}\n\n"
md << "- Checks: #{checks.length}\n"
md << "- Failures: #{failures.length}\n\n"

if failures.empty?
  md << "所有落点与落盘校验断言通过。\n\n"
else
  md << "## Failures\n\n"
  failures.each { |failure| md << "- #{failure[:name]}: #{failure[:detail]}\n" }
  md << "\n"
end

md << "## Checks\n\n"
md << "| Check | Status | Detail |\n"
md << "| --- | --- | --- |\n"
checks.each do |check|
  detail = check[:detail].to_s.gsub("\n", " ").gsub("|", "\\|")
  md << "| #{check[:name]} | #{check[:ok] ? "PASS" : "FAIL"} | #{detail} |\n"
end

File.write(File.expand_path(markdown_path, REPO_ROOT), md)

puts "i18n_add_keys_contract: #{status.downcase} checks=#{checks.length} failures=#{failures.length}"
failures.each { |failure| puts "  ✗ #{failure[:name]}: #{failure[:detail]}" }
exit(ok ? 0 : 1)
