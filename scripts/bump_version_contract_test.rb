#!/usr/bin/env ruby
# frozen_string_literal: true

# bump_version_contract_test.rb — 守 scripts/bump_version.rb「散文文档只改登记位点」的行为。
#
# 为什么要有这一份:1.287.0-rc3 → rc4 那次 bump 踩过一个静默 bug。
# docs/AGENT_HARNESS_IMPROVEMENT_PRIORITIES.md 和 docs/MOBILE_GATEWAY_REQUIREMENTS.md
# 当时挂在 plain_files 里走整文件盲替换,而前者正文有两句是在陈述历史(「…于
# 1.287.0-rc3 再拆七个模型域」「1.287.0-rc3 拆完后请对着…」),盲替换把 rc3 一并改成
# rc4,于是「rc3 干的事」被记成「rc4 干的事」——把过去的事实改写成了假话。
# scripts/version_consistency.rb 对这两个文档只读 Current version: / Target version:
# 标识行(外加 mobile 文档的三个 header/health 字段),正文被改脏它照样报绿,所以这
# 个 bug 只能靠人肉发现、人肉回滚。
#
# 修复把两个文档从 plain_files 挪进了 targeted_docs 定点替换,但没有任何东西拦着以
# 后有人再把某个散文文档加回 plain_files。这份守卫就是那道拦。
#
# 全部写成行为测试:在临时目录里搭一个最小仓库骨架(bump_version.rb 会碰的那批文件
# 按真实相对路径复制),往散文文档正文里种几句人造的「历史版本」句子,跑一次真脚本,
# 再逐行 diff。不做源码字符串断言——等价重构不该让这份守卫变红或变绿。
#
# 骨架里的版本号刻意用 9.9.0-rc7 → 9.9.0-rc8 这种和仓库真版本无关的号,免得每次
# bump 都得跟着改这份测试。
#
# 新增登记位点时:先改 scripts/bump_version.rb 的 targeted_docs,再到
# scripts/version_consistency.rb 把 expected_count 调齐,最后到下面 skeleton_documents
# 的对应文档里补一行 site(...)。三处任缺一处,这份测试都会红并指名缺哪个。
#
# 用法:
#   ruby scripts/bump_version_contract_test.rb
#   ruby scripts/bump_version_contract_test.rb build/ci/bump_version_contract_report.md \
#                                              build/ci/bump_version_contract_report.json

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

markdown_path = ARGV[0] || "build/bump_version_contract/report.md"
json_path = ARGV[1] || "build/bump_version_contract/report.json"

# 骨架用的假版本号。OLDER 只出现在正文的历史陈述里,任何一次 bump 都不该碰它。
OLDER_VERSION = "9.9.0-rc6"
OLD_VERSION = "9.9.0-rc7"
NEW_VERSION = "9.9.0-rc8"
BADGE_OLD = OLD_VERSION.sub("-rc", "--rc")
BADGE_NEW = NEW_VERSION.sub("-rc", "--rc")
SKELETON_BUILD_NUMBER = 472

# 骨架里要跟着复制过去的脚本。version_consistency.rb 也复制,是为了在 bump 之后原地
# 跑一遍——两份脚本的登记表必须对得上,谁先漂移谁先红。
COPIED_SCRIPTS = %w[bump_version.rb version_consistency.rb].freeze

# 走 targeted_docs 定点替换的散文文档。这三个的正文必须一个字都不被碰。
PROSE_DOCS = [
  "product-overview.md",
  "docs/AGENT_HARNESS_IMPROVEMENT_PRIORITIES.md",
  "docs/MOBILE_GATEWAY_REQUIREMENTS.md"
].freeze

# ---------------------------------------------------------------- 骨架 fixture

# 每行一个三元组:
#   [:frozen, 原文]                       —— bump 之后必须一字不动
#   [:site,   原文]                       —— 登记位点,必须整行 old → new
#   [:site,   原文, 位点名, 写坏之后的样子] —— 同上,外加一份故障注入用的坏写法
#   [:build,  原文]                       —— 构建号位点,按自己的规则变(不含版本字符串)
def site(text, name = nil, mangled = nil)
  name ? [:site, text, name, mangled] : [:site, text]
end

def frozen(text)
  [:frozen, text]
end

def dotted_version(version)
  parts = version.match(/\A(\d+)\.(\d+)\.(\d+)(?:-rc(\d+))?\z/)
  [parts[1], parts[2], parts[3], parts[4] || "0"].join(".")
end

def skeleton_documents
  old = OLD_VERSION
  older = OLDER_VERSION
  {
    # ---- 散文文档:标识行走定点替换,正文里埋着描述过去的句子 ----
    "product-overview.md" => [
      frozen("# WillDeep Product Overview"),
      frozen(""),
      site(
        "> Last updated: 2026-08-23 | Current version: v#{old}",
        "product-overview 的 Current version 行",
        "> Last updated: 2026-08-23 | 当前版本: v#{old}"
      ),
      frozen(""),
      frozen("## 版本历史"),
      frozen(""),
      frozen("- 省心托管未登录时不再静默吞消息(#{old})。"),
      frozen("- 调度台投影不再把已完成节点抹成未启动(#{older})。"),
      frozen("")
    ],
    "docs/AGENT_HARNESS_IMPROVEMENT_PRIORITIES.md" => [
      frozen("# Agent Harness Improvement Priorities"),
      frozen(""),
      site(
        "> Last updated: 2026-08-23 | Current version: v#{old}",
        "harness 文档的 Current version 行",
        "> Last updated: 2026-08-23 | Version (current): v#{old}"
      ),
      frozen(""),
      frozen("## P0:复杂度与边界"),
      frozen(""),
      frozen(
        "`AgentModels.swift` 在 #{older} 涨回 3013 行、越过 3000 行硬阈值后于 #{old} 再拆七个模型域,已降到约 580 行。"
      ),
      frozen(""),
      frozen("这条在 #{older} 被违反过一次,#{old} 拆完后请对着 `AgentPlanGoalModels.swift` 等兄弟文件放新模型。"),
      frozen("")
    ],
    "docs/MOBILE_GATEWAY_REQUIREMENTS.md" => [
      frozen("# WillDeep Mobile Gateway Requirements"),
      frozen(""),
      site(
        "> Last updated: 2026-08-23 | Target version: v#{old}",
        "mobile 文档的 Target version 行",
        "> Last updated: 2026-08-23 | 目标版本: v#{old}"
      ),
      frozen(""),
      frozen("## Transport Modes"),
      frozen(""),
      frozen("Since v#{old} the gateway defaults to the public relay; v#{older} still required the LAN fallback."),
      frozen(""),
      frozen("## Handshake"),
      frozen(""),
      site(
        "- `X-App-Version: #{old}`",
        "mobile 文档的 X-App-Version",
        "- `X-App-Version = #{old}`"
      ),
      site(
        "- `X-Server-Version: #{old}`",
        "mobile 文档的 X-Server-Version",
        "- `X-Server-Version = #{old}`"
      ),
      frozen(""),
      frozen("```json"),
      frozen("{"),
      frozen("  \"version\": {"),
      site(
        "    \"version\": \"#{old}\",",
        "mobile 文档 health 响应的 version 字段",
        "    \"current_version\": \"#{old}\","
      ),
      frozen("    \"app_version\": \"#{old}\""),
      frozen("  }"),
      frozen("}"),
      frozen("```"),
      frozen("")
    ],

    # ---- README:只换 shields.io 的双横线 badge,单横线写法属于正文 ----
    "README.md" => [
      frozen("# WillDeep"),
      frozen(""),
      site("[![Version](https://img.shields.io/badge/version-#{BADGE_OLD}-blue)](CHANGELOG.md)"),
      frozen(""),
      frozen("> #{old} 起移动网关默认走互联网中继。"),
      frozen(""),
      site("[![Version](https://img.shields.io/badge/version-#{BADGE_OLD}-blue)](CHANGELOG.md)"),
      frozen("")
    ],

    # ---- plain_files:整文件盲替换,文件里只有「当前版本」语义的引用 ----
    "Xedit.xcodeproj/project.pbxproj" => (
      [frozen("// !$*UTF8*$!"), frozen("{")] +
      Array.new(6) do |index|
        [
          [:build, "\t\t\t\tCURRENT_PROJECT_VERSION = #{SKELETON_BUILD_NUMBER};"],
          site("\t\t\t\tMARKETING_VERSION = #{old};"),
          frozen("\t\t\t\tPRODUCT_NAME = \"Target#{index}\";")
        ]
      end.flatten(1) +
      [frozen("}")]
    ),
    "willdeep-agent/internal/agent/version.go" => [
      frozen("package agent"),
      frozen(""),
      site("const Version = \"#{old}\""),
      frozen("")
    ],
    "Help/WillDeep.help/Contents/Info.plist" => [
      frozen("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"),
      frozen("<plist version=\"1.0\">"),
      frozen("<dict>"),
      frozen("\t<key>CFBundleShortVersionString</key>"),
      site("\t<string>#{old}</string>"),
      frozen("\t<key>CFBundleVersion</key>"),
      frozen("\t<string>442</string>"),
      frozen("</dict>"),
      frozen("</plist>")
    ],
    "ComputerUseHelper/Info.plist" => [
      frozen("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"),
      frozen("<plist version=\"1.0\">"),
      frozen("<dict>"),
      frozen("\t<key>CFBundleShortVersionString</key>"),
      site("\t<string>#{old}</string>"),
      frozen("</dict>"),
      frozen("</plist>")
    ],
    "chrome-extension/willdeep-browser/README.md" => [
      frozen("# WillDeep Browser Extension"),
      frozen(""),
      site("> Version: #{old}"),
      frozen("")
    ],

    # ---- bump 不碰 CHANGELOG(条目手写),但 version_consistency 要读它的顶条 ----
    "CHANGELOG.md" => [
      frozen("# Changelog"),
      frozen(""),
      frozen("## #{NEW_VERSION} - 2026-08-23"),
      frozen(""),
      frozen("- 骨架条目,模拟「人先手写 CHANGELOG,再跑 bump」的真实顺序。"),
      frozen(""),
      frozen("## #{OLD_VERSION} - 2026-08-22"),
      frozen(""),
      frozen("- 上一版条目。"),
      frozen("")
    ]
  }
end

def skeleton_manifest_text
  JSON.pretty_generate(
    "manifest_version" => 3,
    "name" => "__MSG_extensionName__",
    "version" => dotted_version(OLD_VERSION),
    "version_name" => OLD_VERSION,
    "default_locale" => "en"
  ) + "\n"
end

MANIFEST_PATH = "chrome-extension/willdeep-browser/manifest.json"

# mangle: [相对路径, 行号(0-based)] —— 把那一行换成它的「写坏」版本。
def write_skeleton(root, mangle: nil)
  skeleton_documents.each do |relative, tagged|
    lines = tagged.each_with_index.map do |entry, index|
      mangle && mangle.first == relative && mangle.last == index ? entry[3] : entry[1]
    end
    path = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "#{lines.join("\n")}\n")
  end
  manifest_path = File.join(root, MANIFEST_PATH)
  FileUtils.mkdir_p(File.dirname(manifest_path))
  File.write(manifest_path, skeleton_manifest_text)

  FileUtils.mkdir_p(File.join(root, "scripts"))
  COPIED_SCRIPTS.each do |name|
    FileUtils.cp(File.join(REPO_ROOT, "scripts", name), File.join(root, "scripts", name))
  end
end

# 所有带故障注入写法的登记位点:[[相对路径, 行号, 位点名], ...]
def mangleable_sites
  skeleton_documents.flat_map do |relative, tagged|
    tagged.each_with_index.filter_map do |entry, index|
      [relative, index, entry[2]] if entry[0] == :site && entry[2]
    end
  end
end

# ---------------------------------------------------------------- 运行与取样

def run_script(root, name, *arguments)
  command = [RbConfig.ruby, File.join(root, "scripts", name), *arguments]
  output = IO.popen(command, "r", err: %i[child out], chdir: root, &:read)
  [$CHILD_STATUS.exitstatus, output]
end

def run_bump(root)
  run_script(root, "bump_version.rb", OLD_VERSION, NEW_VERSION)
end

def digest_tree(root)
  Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH)
     .select { |path| File.file?(path) }
     .to_h { |path| [path.delete_prefix("#{root}/"), Digest::SHA256.hexdigest(File.binread(path))] }
end

def read_lines(root, relative)
  File.read(File.join(root, relative), encoding: "UTF-8").lines.map { |line| line.chomp("\n") }
end

# 登记位点被改到位之后该长什么样。badge 先换,免得单横线写法误伤双横线 badge。
def expected_site_text(text)
  text.gsub(BADGE_OLD, BADGE_NEW).gsub(OLD_VERSION, NEW_VERSION)
end

def expected_hits(tagged)
  tagged.sum do |entry|
    next 0 unless entry[0] == :site

    entry[1].scan(OLD_VERSION).size + entry[1].scan(BADGE_OLD).size
  end
end

def actual_hits(text)
  text.scan(NEW_VERSION).size + text.scan(BADGE_NEW).size
end

def skeleton_text(tagged)
  "#{tagged.map { |entry| entry[1] }.join("\n")}\n"
end

# 脚本输出可能有十几行,失败详情里塞全文会把报告表格撑爆。
def brief(output)
  compact = output.to_s.split("\n").map(&:strip).reject(&:empty?).join(" ⏎ ")
  compact.length > 220 ? "#{compact[0, 220]}…" : compact
end

# ---------------------------------------------------------------- 检查框架

checks = []

def check(checks, name)
  detail = yield
  checks << { name: name, ok: detail.nil?, detail: detail || "ok" }
rescue StandardError => e
  checks << { name: name, ok: false, detail: "抛异常: #{e.class}: #{e.message}" }
end

repo_digests_before = (PROSE_DOCS + COPIED_SCRIPTS.map { |name| "scripts/#{name}" }).to_h do |relative|
  [relative, Digest::SHA256.hexdigest(File.binread(File.join(REPO_ROOT, relative)))]
end

Dir.mktmpdir("bump_version_contract") do |tmp|
  # ------------------------------------------------------------ 0. fixture 自检
  # 正文里没埋历史版本句子的话,后面那条「正文原样保留」就是句空话。
  check(checks, "fixture 自检:三个散文文档正文里确实埋了描述过去的版本号") do
    barren = PROSE_DOCS.reject do |relative|
      tagged = skeleton_documents.fetch(relative)
      tagged.any? { |entry| entry[0] == :frozen && entry[1].include?(OLD_VERSION) }
    end
    next "以下文档的正文没有一句提到 #{OLD_VERSION},这份守卫对它是空转: #{barren.join(', ')}" unless barren.empty?

    without_sites = PROSE_DOCS.reject do |relative|
      skeleton_documents.fetch(relative).any? { |entry| entry[0] == :site }
    end
    next "以下文档没登记任何位点: #{without_sites.join(', ')}" unless without_sites.empty?
    nil
  end

  # ------------------------------------------------------------ 快乐路径:跑一次
  happy_root = File.join(tmp, "happy")
  write_skeleton(happy_root)
  happy_status, happy_output = run_bump(happy_root)

  check(checks, "bump 在最小仓库骨架上正常跑完") do
    next "脚本非零退出(#{happy_status}):#{brief(happy_output)}" unless happy_status.zero?
    nil
  end

  # ------------------------------------------------------------ 1. 登记位点被改成新版本
  check(checks, "登记位点(标识行/header/health 字段)被改成新版本号") do
    next "bump 没跑成功,这条无从谈起" unless happy_status.zero?

    problems = []
    skeleton_documents.each do |relative, tagged|
      after = read_lines(happy_root, relative)
      if after.length != tagged.length
        problems << "#{relative}: 行数从 #{tagged.length} 变成 #{after.length}"
        next
      end
      tagged.each_with_index do |entry, index|
        next unless entry[0] == :site

        expected = expected_site_text(entry[1])
        next if after[index] == expected

        problems << "#{relative}:#{index + 1} 期望 #{expected.inspect},实际 #{after[index].inspect}"
      end
    end
    next problems.join(" / ") unless problems.empty?
    nil
  end

  # ------------------------------------------------------------ 2. 正文原样保留
  check(checks, "散文正文里描述过去的句子原样保留(散文文档没被塞回整文件盲替换)") do
    next "bump 没跑成功,这条无从谈起" unless happy_status.zero?

    problems = []
    skeleton_documents.each do |relative, tagged|
      after = read_lines(happy_root, relative)
      next if after.length != tagged.length # 行数问题由上一条报

      tagged.each_with_index do |entry, index|
        next unless entry[0] == :frozen
        next if after[index] == entry[1]

        problems << "#{relative}:#{index + 1} 被改写了:#{entry[1].inspect} → #{after[index].inspect}"
      end
    end
    unless problems.empty?
      next "以下本该一字不动的行被改了(把过去的事实改成了假话): #{problems.join(' / ')}"
    end
    nil
  end

  # ------------------------------------------------------------ 3. 逐位点命中处数
  check(checks, "逐位点命中处数与预期一致(文件内容与脚本自报三方对齐)") do
    next "bump 没跑成功,这条无从谈起" unless happy_status.zero?

    problems = []
    skeleton_documents.each do |relative, tagged|
      expected = expected_hits(tagged)
      text = File.read(File.join(happy_root, relative), encoding: "UTF-8")
      # 用增量算,免得把骨架里本来就写着新版本号的地方(CHANGELOG 顶条)算成命中。
      actual = actual_hits(text) - actual_hits(skeleton_text(tagged))
      problems << "#{relative}: 期望改到 #{expected} 处,实际改了 #{actual} 处" if actual != expected

      # 正文该剩下多少个旧版本号,也得对得上。
      left_expected = tagged.sum { |entry| entry[0] == :frozen ? entry[1].scan(OLD_VERSION).size : 0 }
      left_actual = text.scan(OLD_VERSION).size
      if left_actual != left_expected
        problems << "#{relative}: 正文该留 #{left_expected} 处 #{OLD_VERSION},实际剩 #{left_actual} 处"
      end
    end

    # 散文文档还要求脚本把逐位点处数打出来,好让某个位点掉到 0 时一眼可见。
    PROSE_DOCS.each do |relative|
      reported = happy_output[/^#{Regexp.escape(relative)}: (\d+) 处/, 1]
      expected = expected_hits(skeleton_documents.fetch(relative))
      if reported.nil?
        problems << "#{relative}: 脚本没有把命中处数打出来"
      elsif reported.to_i != expected
        problems << "#{relative}: 脚本自报 #{reported} 处,期望 #{expected} 处"
      end
    end

    next problems.join(" / ") unless problems.empty?
    nil
  end

  # ------------------------------------------------------------ 4. 非版本字符串的位点
  check(checks, "构建号 +1、chrome manifest 的两个版本字段同步") do
    next "bump 没跑成功,这条无从谈起" unless happy_status.zero?

    pbxproj = File.read(File.join(happy_root, "Xedit.xcodeproj/project.pbxproj"), encoding: "UTF-8")
    builds = pbxproj.scan(/CURRENT_PROJECT_VERSION = (\d+);/).flatten.map(&:to_i).uniq
    next "构建号不一致: #{builds.inspect}" if builds.length != 1
    if builds.first != SKELETON_BUILD_NUMBER + 1
      next "构建号该从 #{SKELETON_BUILD_NUMBER} 涨到 #{SKELETON_BUILD_NUMBER + 1},实际是 #{builds.first}"
    end

    manifest = JSON.parse(File.read(File.join(happy_root, MANIFEST_PATH), encoding: "UTF-8"))
    if manifest["version_name"] != NEW_VERSION
      next "manifest.version_name 是 #{manifest["version_name"].inspect}"
    end
    next "manifest.version 是 #{manifest["version"].inspect}" if manifest["version"] != dotted_version(NEW_VERSION)
    next "manifest 丢了无关字段: #{manifest.keys.inspect}" unless manifest.key?("default_locale")
    nil
  end

  # ------------------------------------------------------------ 5. 两份登记表对得上
  check(checks, "bump 之后 version_consistency 在同一骨架上报绿(两边登记表对齐)") do
    next "bump 没跑成功,这条无从谈起" unless happy_status.zero?

    status, output = run_script(
      happy_root, "version_consistency.rb",
      "build/ci/version_report.md", "build/ci/version_report.json"
    )
    if output.include?("Errno::ENOENT")
      next "version_consistency 读到了骨架里没有的文件,说明它新增了检查源:" \
           "请同步补进这份测试的 skeleton_documents,并确认 bump_version 也登记了它。#{brief(output)}"
    end
    next "version_consistency 非零退出(#{status}):#{output}" unless status.zero?

    report = JSON.parse(File.read(File.join(happy_root, "build/ci/version_report.json"), encoding: "UTF-8"))
    next "报告不是绿的: #{report["failures"].inspect}" unless report["ok"]
    if report["canonical_version"] != NEW_VERSION
      next "canonical 版本是 #{report["canonical_version"].inspect},期望 #{NEW_VERSION.inspect}"
    end
    nil
  end

  # ------------------------------------------------------------ 6/7. 故障注入
  sites = mangleable_sites
  check(checks, "登记位点的写法被改坏时,脚本非零退出且一个文件都不落盘") do
    next "没有可注入的登记位点,故障注入是空转" if sites.empty?

    problems = []
    sites.each_with_index do |(relative, index, name), ordinal|
      root = File.join(tmp, "mangled-#{ordinal}")
      write_skeleton(root, mangle: [relative, index])
      before = digest_tree(root)
      status, output = run_script(root, "bump_version.rb", OLD_VERSION, NEW_VERSION)

      if status.zero?
        problems << "#{name} 写法改坏后脚本仍然成功退出(该 abort 才对):#{brief(output)}"
        next
      end
      changed = digest_tree(root).reject { |path, digest| before[path] == digest }
      problems << "#{name}: abort 了却动了 #{changed.keys.join(', ')}" unless changed.empty?
      problems << "#{name}: abort 信息里没指名是哪个位点漏配:#{brief(output)}" unless output.include?(relative)
    end
    next problems.join(" / ") unless problems.empty?
    nil
  end

  check(checks, "登记位点上的版本号对不上旧版本时,脚本非零退出且一个文件都不落盘") do
    next "没有可注入的登记位点,故障注入是空转" if sites.empty?

    problems = []
    sites.each_with_index do |(relative, index, name), ordinal|
      root = File.join(tmp, "stale-#{ordinal}")
      write_skeleton(root)
      # 把这一行的版本号换成第三个版本,标识写法不动 —— 位点还在,只是数对不上。
      lines = read_lines(root, relative)
      lines[index] = lines[index].gsub(OLD_VERSION, "9.9.0-rc1")
      File.write(File.join(root, relative), "#{lines.join("\n")}\n")
      before = digest_tree(root)
      status, output = run_script(root, "bump_version.rb", OLD_VERSION, NEW_VERSION)

      if status.zero?
        problems << "#{name} 的版本号对不上却仍然成功退出(该 abort 才对):#{brief(output)}"
        next
      end
      changed = digest_tree(root).reject { |path, digest| before[path] == digest }
      problems << "#{name}: abort 了却动了 #{changed.keys.join(', ')}" unless changed.empty?
    end
    next problems.join(" / ") unless problems.empty?
    nil
  end
end

# ------------------------------------------------------------ 8. 不碰真仓库
check(checks, "整轮测试不碰仓库里的真脚本和真文档") do
  touched = repo_digests_before.reject do |relative, digest|
    Digest::SHA256.hexdigest(File.binread(File.join(REPO_ROOT, relative))) == digest
  end
  next "以下仓库文件被这份测试改了: #{touched.keys.join(', ')}" unless touched.empty?
  nil
end

# ---------------------------------------------------------------- 报告

failures = checks.reject { |entry| entry[:ok] }
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
md = +"# bump_version Contract Report\n\n"
md << "**Status:** #{status}\n\n"
md << "- Checks: #{checks.length}\n"
md << "- Failures: #{failures.length}\n\n"

if failures.empty?
  md << "散文文档只改登记位点、正文原样保留,故障注入全部 fail-closed。\n\n"
else
  md << "## Failures\n\n"
  failures.each { |failure| md << "- #{failure[:name]}: #{failure[:detail]}\n" }
  md << "\n"
end

md << "## Checks\n\n"
md << "| Check | Status | Detail |\n"
md << "| --- | --- | --- |\n"
checks.each do |entry|
  detail = entry[:detail].to_s.gsub("\n", " ").gsub("|", "\\|")
  md << "| #{entry[:name]} | #{entry[:ok] ? "PASS" : "FAIL"} | #{detail} |\n"
end

File.write(File.expand_path(markdown_path, REPO_ROOT), md)

puts "bump_version_contract: #{status.downcase} checks=#{checks.length} failures=#{failures.length}"
failures.each { |failure| puts "  ✗ #{failure[:name]}: #{failure[:detail]}" }
exit(ok ? 0 : 1)
