# frozen_string_literal: true
# 重建 Help Book 的搜索索引。
#
# Help Viewer 需要 book 里带索引才肯把本地帮助当成一本可显示的书；缺索引时它会
# 转头去 Apple 的在线帮助库找，找不到就报「所选内容当前不可用」。改过
# Help/WillDeep.help 下的 HTML 之后必须重跑这个脚本，并把生成的索引一起提交。
#
# 用法: ruby scripts/build_help_index.rb [--check]
#   --check  只校验索引存在且不比 HTML 旧，不重建（给 CI 用）

require "fileutils"

ROOT = File.expand_path("..", __dir__)
BOOK = File.join(ROOT, "Help/WillDeep.help/Contents/Resources")
INDEX_BASENAME = "WillDeep"
check_only = ARGV.include?("--check")

lprojs = Dir.glob(File.join(BOOK, "*.lproj")).sort
abort "找不到任何 lproj: #{BOOK}" if lprojs.empty?

failures = []

lprojs.each do |lproj|
  locale = File.basename(lproj, ".lproj")
  html = Dir.glob(File.join(lproj, "*.html"))
  if html.empty?
    failures << "#{locale}: 没有 HTML 页面"
    next
  end
  newest_html = html.map { |f| File.mtime(f) }.max

  # lsm 与 corespotlight 两种索引都生成：不同 macOS 版本的 Help Viewer 认的不是同一种。
  targets = {
    "lsm" => File.join(lproj, "#{INDEX_BASENAME}.helpindex"),
    "corespotlight" => File.join(lproj, "#{INDEX_BASENAME}.cshelpindex")
  }

  targets.each do |kind, path|
    if check_only
      if !File.exist?(path)
        failures << "#{locale}: 缺索引 #{File.basename(path)}"
      elsif File.mtime(path) < newest_html
        failures << "#{locale}: #{File.basename(path)} 比 HTML 旧，请重跑 build_help_index.rb"
      end
      next
    end

    ok = system("hiutil", "-I", kind, "-Caf", path, "-l", locale, lproj, out: File::NULL)
    if ok && File.exist?(path)
      puts "#{locale}/#{File.basename(path)}: #{File.size(path)} 字节"
    else
      failures << "#{locale}: hiutil 生成 #{kind} 索引失败"
    end
  end
end

if failures.empty?
  puts check_only ? "help_index: pass" : "help_index: 已重建 #{lprojs.size} 个语言"
  exit 0
end

warn "help_index: fail"
failures.each { |f| warn "  - #{f}" }
exit 1
