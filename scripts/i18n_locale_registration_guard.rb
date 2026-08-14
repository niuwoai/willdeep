#!/usr/bin/env ruby
# frozen_string_literal: true

# i18n_locale_registration_guard.rb — 守住「Picker 里能选的语言 = 真的能被
# 加载的语言」。
#
# 背景:日语在设置里能选、点了也写进了 AppleLanguages,但整个界面纹丝不动。
# 两个原因叠加:
#   1) Xedit.xcodeproj 的 knownRegions 只登记了 en / Base / zh-Hans,ja 没
#      登记,String Catalog 就不会为它生成 .lproj;
#   2) catalog 里 ja 只有个位数条目,剩下的全部回落英文。
# 两者都是「加语言时忘了同步」,所以在这里钉死:
#   * AppLanguagePreference 声明的每个 BCP-47 标签都必须出现在 knownRegions;
#   * 语言切换 UI 自己(settings.language.*)必须每种语言都齐,否则用户切过去
#     之后连「怎么切回来」都读不懂;
#   * 各语言的整体覆盖率只报数不判红——补翻译是长期活,不该卡住 CI。
#
# Usage:
#   ruby scripts/i18n_locale_registration_guard.rb
#   ruby scripts/i18n_locale_registration_guard.rb build/ci/i18n_locale.md build/ci/i18n_locale.json

require "json"
require "fileutils"
require "pathname"

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

ROOT = Pathname.new(__dir__).parent
XCSTRINGS = ROOT.join("Xedit", "Localizable.xcstrings")
APP_LOCALE = ROOT.join("Xedit", "AppLocale.swift")
PBXPROJ = ROOT.join("Xedit.xcodeproj", "project.pbxproj")
UI_KEY_PREFIX = "settings.language."

markdown_path = Pathname.new(ARGV[0] || "build/ci/i18n_locale.md")
json_path = Pathname.new(ARGV[1] || "build/ci/i18n_locale.json")

checks = []
record = lambda do |name, ok, detail|
  checks << { name: name, ok: ok, detail: detail }
end

# ---- 1) AppLanguagePreference 声明了哪些标签 ----
# 只认 languageTag 那个 switch 里的字面量。写法被重构掉时这里会解析不出
# 标签并判红,提示同步本守卫——比悄悄放行安全。
locale_source = APP_LOCALE.read
tag_block = locale_source[/var languageTag: String\? \{.*?\n    \}/m].to_s
declared_tags = tag_block.scan(/return "([A-Za-z-]+)"/).flatten
record.call(
  "declared-tags-parsed",
  !declared_tags.empty?,
  declared_tags.empty? ? "在 AppLocale.swift 的 languageTag 里没解析到任何标签" : declared_tags.join(", ")
)

# ---- 2) knownRegions 是否登记齐全 ----
regions_block = PBXPROJ.read[/knownRegions = \(\n(.*?)\n\t\t\t\);/m].to_s
known_regions = regions_block.scan(/"?([A-Za-z][A-Za-z-]*)"?,/).flatten
missing_regions = declared_tags - known_regions
record.call(
  "known-regions-registered",
  missing_regions.empty?,
  missing_regions.empty? ? "knownRegions=#{known_regions.join(', ')}" : "knownRegions 缺少: #{missing_regions.join(', ')}"
)

# ---- 3) 语言切换 UI 自己必须全语言齐 ----
data = JSON.parse(XCSTRINGS.read)
strings = data["strings"] || {}

ui_keys = strings.keys.select { |k| k.start_with?(UI_KEY_PREFIX) }
incomplete = []
ui_keys.each do |key|
  locs = strings[key]["localizations"] || {}
  gaps = declared_tags.reject { |tag| locs.dig(tag, "stringUnit", "value").to_s != "" }
  incomplete << "#{key} 缺 #{gaps.join('/')}" unless gaps.empty?
end
record.call(
  "language-switcher-fully-translated",
  incomplete.empty?,
  incomplete.empty? ? "#{ui_keys.size} 个 #{UI_KEY_PREFIX}* key 全语言齐" : incomplete.join("; ")
)

# ---- 4) 覆盖率只报数 ----
# 纯符号/格式串在任何语言下显示都一样,不计入分母(与 i18n_coverage_guard.rb
# 同一套口径)。
def translatable?(key, en)
  text = en || key
  stripped = text.gsub(/%(\d+\$)?[@a-zA-Z]+|%(\d+\$)?lld|%(\d+\$)?lf/, "")
  stripped.match?(/[A-Za-z]/)
end

translatable_keys = strings.select do |key, entry|
  translatable?(key, entry.dig("localizations", "en", "stringUnit", "value"))
end

coverage = declared_tags.to_h do |tag|
  covered = translatable_keys.count do |_key, entry|
    entry.dig("localizations", tag, "stringUnit", "value").to_s != ""
  end
  [tag, { covered: covered, total: translatable_keys.size }]
end

status = checks.all? { |c| c[:ok] } ? "pass" : "fail"

FileUtils.mkdir_p(markdown_path.dirname)
FileUtils.mkdir_p(json_path.dirname)
json_path.write(JSON.pretty_generate(
  status: status,
  declared_tags: declared_tags,
  known_regions: known_regions,
  coverage: coverage,
  checks: checks
) + "\n")

lines = [
  "# i18n Locale Registration Guard",
  "",
  "**Status:** #{status.upcase}",
  "",
  "| Check | Result | Detail |",
  "| --- | --- | --- |",
]
checks.each do |check|
  lines << "| #{check[:name]} | #{check[:ok] ? 'PASS' : 'FAIL'} | #{check[:detail].to_s.gsub('|', '\\|')} |"
end
lines += ["", "## 翻译覆盖率(只报数,不判红)", "", "| Locale | Covered | Total | % |", "| --- | --- | --- | --- |"]
coverage.each do |tag, stat|
  pct = stat[:total].zero? ? 0 : (stat[:covered] * 100.0 / stat[:total]).round(1)
  lines << "| #{tag} | #{stat[:covered]} | #{stat[:total]} | #{pct}% |"
end
markdown_path.write(lines.join("\n") + "\n")

summary = coverage.map { |tag, s| "#{tag}=#{s[:covered]}/#{s[:total]}" }.join(" ")
puts "i18n_locale_registration: #{status} #{summary}"
checks.reject { |c| c[:ok] }.each { |c| puts "  FAIL #{c[:name]}: #{c[:detail]}" }
exit(status == "pass" ? 0 : 1)
