#!/usr/bin/env ruby
# frozen_string_literal: true

# i18n_coverage_guard.rb — 守住简体中文(zh-Hans)翻译覆盖率,缺译即报红。
#
# 背景:用户要求所有面向用户的文案中文用户都能看到中文、不回落英文。把
# Localizable.xcstrings 里**可翻译**的 key 全部补齐 zh-Hans 后,这个守卫保证
# 以后**新增**的 key 一旦漏翻就在 CI 卡住,不再让中文用户看到英文。
#
# 纯符号/格式串(如 ""、":"、"%lld"、"·"、"/bin/zsh")在任何语言下显示都一样,
# 无需翻译,自动豁免(与 scripts/i18n_extract_missing.rb 同一套过滤口径)。
#
# Usage:
#   ruby scripts/i18n_coverage_guard.rb
#   ruby scripts/i18n_coverage_guard.rb build/ci/i18n_report.md build/ci/i18n_report.json

require "json"
require "fileutils"
require "time"

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

repo_root = File.expand_path("..", __dir__)
xcstrings_path = File.join(repo_root, "Xedit", "Localizable.xcstrings")
markdown_path = ARGV[0] || "build/ci/i18n_report.md"
json_path = ARGV[1] || "build/ci/i18n_report.json"
target_locale = "zh-Hans"

data = JSON.parse(File.read(xcstrings_path, encoding: "UTF-8"))
strings = data["strings"] || {}

# 纯符号/格式串豁免:剥掉 %@ / %lld / %lf 等占位后若不含任何字母,
# 则它在任何语言下都一样显示,无需翻译。
def translatable?(key, en)
  text = en || key
  stripped = text.gsub(/%(\d+\$)?[@a-zA-Z]+|%(\d+\$)?lld|%(\d+\$)?lf/, "")
  stripped =~ /[A-Za-z]/ ? true : false
end

translatable = 0
covered = 0
missing = []

strings.each do |key, entry|
  loc = entry["localizations"] || {}
  en = loc.dig("en", "stringUnit", "value") || key
  next unless translatable?(key, en)
  translatable += 1
  if loc.key?(target_locale)
    covered += 1
  else
    missing << { key: key, en: en }
  end
end

ok = missing.empty?
status = ok ? "PASS" : "FAIL"
coverage_pct = translatable.zero? ? 100.0 : (covered.to_f / translatable * 100).round(2)

report = {
  ok: ok,
  generated_at: Time.now.utc.iso8601,
  target_locale: target_locale,
  total_keys: strings.size,
  translatable: translatable,
  covered: covered,
  missing_count: missing.size,
  coverage_pct: coverage_pct,
  missing: missing.first(200),
}

FileUtils.mkdir_p(File.dirname(File.expand_path(json_path, repo_root)))
File.write(File.expand_path(json_path, repo_root), JSON.pretty_generate(report))

md = +"# i18n Coverage Guard\n\n"
md << "- Status: **#{status}**\n"
md << "- Target locale: `#{target_locale}`\n"
md << "- Translatable keys: #{translatable}\n"
md << "- Covered: #{covered} (#{coverage_pct}%)\n"
md << "- Missing: #{missing.size}\n\n"
unless missing.empty?
  md << "## Missing #{target_locale} (first 200)\n\n"
  md << "| Key | en |\n| --- | --- |\n"
  missing.first(200).each do |m|
    safe_en = m[:en].to_s.gsub("|", "\\|").gsub("\n", " ")
    md << "| `#{m[:key]}` | #{safe_en} |\n"
  end
  md << "\n"
end
FileUtils.mkdir_p(File.dirname(File.expand_path(markdown_path, repo_root)))
File.write(File.expand_path(markdown_path, repo_root), md)

puts "i18n_coverage_guard: #{status.downcase} translatable=#{translatable} covered=#{covered} missing=#{missing.size} coverage=#{coverage_pct}%"
unless ok
  puts "缺 #{target_locale} 翻译的 key(最多列 20):"
  missing.first(20).each { |m| puts "  - #{m[:key].inspect}  en=#{m[:en].inspect}" }
  puts "补法:ruby scripts/i18n_extract_missing.rb <dir> 4  → 翻译 → ruby scripts/i18n_apply_translations.rb <dir> <new_keys.json>"
end
exit(ok ? 0 : 1)
