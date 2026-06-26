# frozen_string_literal: true
# 统一替换全仓库所有版本号位点(见 version_consistency.rb 的检查清单)。
# 用法: ruby scripts/bump_version.rb <old> <new>
#   ruby scripts/bump_version.rb 1.108.0-rc25 1.108.0-rc26
require "fileutils"

old = ARGV[0] or abort "need <old>"
new = ARGV[1] or abort "need <new>"
root = File.expand_path("..", __dir__)

# 普通位点:直接把 old → new
plain_files = [
  "Xedit.xcodeproj/project.pbxproj",
  "willdeep-agent/internal/agent/version.go",
  "Help/WillDeep.help/Contents/Info.plist",
  "product-overview.md",
  "docs/MOBILE_GATEWAY_REQUIREMENTS.md",
  "docs/AGENT_HARNESS_IMPROVEMENT_PRIORITIES.md",
]

# README 的 shields.io badge 用双横线写法: 1.108.0--rc25
badge_old = old.sub("-rc", "--rc")
badge_new = new.sub("-rc", "--rc")

total = 0
plain_files.each do |rel|
  path = File.join(root, rel)
  text = File.read(path, encoding: "UTF-8")
  count = text.scan(old).size
  next if count.zero?
  File.write(path, text.gsub(old, new))
  total += count
  puts "#{rel}: #{count} 处"
end

readme = File.join(root, "README.md")
rtext = File.read(readme, encoding: "UTF-8")
rcount = rtext.scan(badge_old).size
if rcount.positive?
  File.write(readme, rtext.gsub(badge_old, badge_new))
  total += rcount
  puts "README.md: #{rcount} 处 (badge #{badge_old} → #{badge_new})"
end

puts "总计替换 #{total} 处: #{old} → #{new}"
puts "注意:CHANGELOG.md 顶部新条目请手动用编辑器添加(脚本不自动生成变更说明)。"
