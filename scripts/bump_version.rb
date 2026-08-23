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
]

# 散文类文档:正文里「当前版本」和「历史版本」两种语义的版本号混在一起,整文件盲
# 替换会把描述过去的句子改写成假话。1.287.0-rc3 → rc4 这次就正好踩中:
# AGENT_HARNESS_IMPROVEMENT_PRIORITIES.md 里「…于 1.287.0-rc3 再拆七个模型域」和
# 「1.287.0-rc3 拆完后请对着…」两句会被一并改成 rc4,把 rc3 干的事记成 rc4 干的;而
# version_consistency.rb 对这两个文档只校验下面枚举的这些位点,正文被改脏它照样
# 报绿。所以这里只重写显式登记的「当前版本」位点,正文一律不碰。
# 新增位点时:先在这里登记,再到 version_consistency.rb 把对应 expected_count 调齐。
targeted_docs = {
  "product-overview.md" => [
    ["Current version 行", /Current version:/]
  ],
  "docs/AGENT_HARNESS_IMPROVEMENT_PRIORITIES.md" => [
    ["Current version 行", /Current version:/]
  ],
  "docs/MOBILE_GATEWAY_REQUIREMENTS.md" => [
    ["Target version 行", /Target version:/],
    ["X-App-Version", /X-App-Version:/],
    ["X-Server-Version", /X-Server-Version:/],
    ["health 响应 version 字段", /^\s*"version":\s*"/]
  ]
}

# 逐位点数命中处数。同一行被多条规则命中时只算第一条,和下面的重写保持一致。
def count_targeted_sites(text, old, rules)
  counts = Hash.new(0)
  text.each_line do |line|
    rule = rules.find { |(_, pattern)| line.match?(pattern) }
    counts[rule.first] += line.scan(old).size if rule
  end
  counts
end

# 只重写命中 rules 的行,其余行(正文)原样保留。
def bump_targeted_sites(path, old, new, rules)
  text = File.read(path, encoding: "UTF-8")
  out = text.lines.map do |line|
    rules.any? { |(_, pattern)| line.match?(pattern) } ? line.gsub(old, new) : line
  end.join
  File.write(path, out)
end

# README 的 shields.io badge 用双横线写法: 1.108.0--rc25
badge_old = old.sub("-rc", "--rc")
badge_new = new.sub("-rc", "--rc")

# 先只扫描不落盘:任何一个登记位点匹配不到 old,都说明文档改了写法而这里没跟上,
# 在动第一个文件之前就停下,免得留一个改到一半的仓库。
targeted_counts = targeted_docs.to_h do |rel, rules|
  [rel, count_targeted_sites(File.read(File.join(root, rel), encoding: "UTF-8"), old, rules)]
end
missing_sites = targeted_docs.flat_map do |rel, rules|
  rules.filter_map { |(name, _)| "#{rel} 的「#{name}」" if targeted_counts[rel][name].zero? }
end
unless missing_sites.empty?
  abort <<~MESSAGE
    以下「当前版本」位点没有匹配到 #{old},文档写法可能变了,先确认再 bump(未改动任何文件):
    #{missing_sites.map { |site| "  - #{site}" }.join("\n")}
  MESSAGE
end

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

targeted_docs.each do |rel, rules|
  counts = targeted_counts[rel]
  bump_targeted_sites(File.join(root, rel), old, new, rules)
  matched = rules.sum { |(name, _)| counts[name] }
  total += matched
  breakdown = rules.map { |(name, _)| "#{name} #{counts[name]} 处" }.join(", ")
  puts "#{rel}: #{matched} 处 (只改登记位点: #{breakdown})"
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
