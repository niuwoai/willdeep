# frozen_string_literal: true
# 统一替换全仓库所有版本号位点(见 version_consistency.rb 的检查清单)。
# 用法: ruby scripts/bump_version.rb <old> <new>
#   ruby scripts/bump_version.rb 1.108.0-rc25 1.108.0-rc26
require "fileutils"
require "json"

old = ARGV[0] or abort "need <old>"
new = ARGV[1] or abort "need <new>"
root = File.expand_path("..", __dir__)

# 普通位点:直接把 old → new(整文件盲替换,文件里只有"当前版本"语义的引用)
plain_files = [
  "Xedit.xcodeproj/project.pbxproj",
  "willdeep-agent/internal/agent/version.go",
  "Help/WillDeep.help/Contents/Info.plist",
  "ComputerUseHelper/Info.plist",
  "docs/MOBILE_GATEWAY_REQUIREMENTS.md",
  "docs/AGENT_HARNESS_IMPROVEMENT_PRIORITIES.md",
]

# product-overview.md 正文有「历史版本」条目(如「…（1.108.0-rc26）」),整文件盲替换
# 会把历史也改掉。只动开头的「Current version:」标识行。
def bump_current_version_line(path, old, new)
  text = File.read(path, encoding: "UTF-8")
  count = 0
  out = text.lines.map do |line|
    if line =~ /Current version:/ && line.include?(old)
      count += line.scan(old).size
      line.gsub(old, new)
    else
      line
    end
  end.join
  File.write(path, out)
  count
end

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

po_count = bump_current_version_line(File.join(root, "product-overview.md"), old, new)
if po_count.positive?
  total += po_count
  puts "product-overview.md: #{po_count} 处 (仅 Current version 行)"
end

chrome_manifest_path = File.join(root, "chrome-extension/willdeep-browser/manifest.json")
chrome_manifest = JSON.parse(File.read(chrome_manifest_path, encoding: "UTF-8"))
unless chrome_manifest["version_name"] == old
  abort "Chrome extension version_name is #{chrome_manifest["version_name"].inspect}, expected #{old.inspect}"
end
new_match = new.match(/\A(\d+)\.(\d+)\.(\d+)(?:-rc(\d+))?\z/)
abort "invalid semantic version for Chrome manifest: #{new}" unless new_match

chrome_manifest["version"] = [
  new_match[1],
  new_match[2],
  new_match[3],
  new_match[4] || "0"
].join(".")
chrome_manifest["version_name"] = new
File.write(chrome_manifest_path, JSON.pretty_generate(chrome_manifest) + "\n")
total += 2
puts "chrome-extension/willdeep-browser/manifest.json: 2 处"

chrome_readme_path = File.join(root, "chrome-extension/willdeep-browser/README.md")
chrome_readme = File.read(chrome_readme_path, encoding: "UTF-8")
chrome_readme_count = chrome_readme.scan(old).size
abort "Chrome extension README does not contain #{old}" if chrome_readme_count.zero?
File.write(chrome_readme_path, chrome_readme.gsub(old, new))
total += chrome_readme_count
puts "chrome-extension/willdeep-browser/README.md: #{chrome_readme_count} 处"

# CFBundleVersion。Sparkle 用它排序,发布引擎要求"版本号变了构建号必须
# 严格增长",而它不含版本字符串,所以上面的字面量替换永远碰不到它。漏掉
# 的代价是发布跑完编译、签名、公证十几分钟后才在 appcast 那步被拒
# (1.257.0-rc1 到 1.261.0-rc2 之间它一直卡在 384)。
pbxproj_path = File.join(root, "Xedit.xcodeproj/project.pbxproj")
pbxproj = File.read(pbxproj_path, encoding: "UTF-8")
build_numbers = pbxproj.scan(/CURRENT_PROJECT_VERSION = (\d+);/).flatten.map(&:to_i).uniq
abort "no CURRENT_PROJECT_VERSION found in project.pbxproj" if build_numbers.empty?
abort "CURRENT_PROJECT_VERSION is inconsistent: #{build_numbers.inspect}" if build_numbers.size > 1
next_build = build_numbers.first + 1
build_count = pbxproj.scan(/CURRENT_PROJECT_VERSION = \d+;/).size
File.write(
  pbxproj_path,
  pbxproj.gsub(/CURRENT_PROJECT_VERSION = \d+;/, "CURRENT_PROJECT_VERSION = #{next_build};")
)
total += build_count
puts "Xedit.xcodeproj/project.pbxproj: #{build_count} 处 (build #{build_numbers.first} → #{next_build})"

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
