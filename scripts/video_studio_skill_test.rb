#!/usr/bin/env ruby
# frozen_string_literal: true

# 必须跑在 macOS 自带的 /usr/bin/ruby（2.6）下：mcp.json 把插件解释器钉死成它。
require "json"
require "tmpdir"
require "fileutils"
require_relative "../PluginExamples/video-studio/server/lib/creative_skill_store"

results = []
check = lambda do |name, &block|
  block.call
  results << { name: name, status: "passed" }
rescue StandardError => error
  results << { name: name, status: "failed", error: "#{error.class}: #{error.message}" }
end

TEMPLATE_ROOT = File.expand_path("../PluginExamples/video-studio/skills/creative", __dir__)

Dir.mktmpdir("willdeep-skill-test-") do |directory|
  user_root = File.join(directory, "creative-skills")
  store = CreativeSkillStore.new(template_root: TEMPLATE_ROOT, user_root: user_root)

  check.call("every stage maps to a template that exists") do
    CreativeSkillStore::STAGE_SKILLS.each do |stage, id|
      path = File.join(TEMPLATE_ROOT, "#{id}.md")
      raise "stage #{stage} maps to missing #{id}.md" unless File.exist?(path)
    end
  end

  check.call("the listing covers stage and common skills with metadata") do
    entries = store.list["skills"]
    stages = entries.select { |entry| entry["kind"] == "stage" }
    commons = entries.select { |entry| entry["kind"] == "common" }
    raise "expected stage skills, got #{stages.length}" if stages.length < 6
    raise "expected common skills, got #{commons.length}" if commons.length < 3
    # 名称与描述来自 frontmatter：列不出来的话界面上只有一串文件名。
    raise "missing names" if entries.any? { |entry| entry["name"].to_s.empty? }
    raise "missing descriptions" if entries.any? { |entry| entry["description"].to_s.empty? }
    raise "nothing should be customized yet" if entries.any? { |entry| entry["customized"] }
  end

  check.call("first read materialises a user copy without touching the template") do
    before = File.read(File.join(TEMPLATE_ROOT, "planning.md"), encoding: "UTF-8")
    entry = store.get("planning")
    raise "body missing" unless entry["body"].include?("短剧策划")
    raise "user copy not created" unless File.exist?(File.join(user_root, "planning.md"))
    after = File.read(File.join(TEMPLATE_ROOT, "planning.md"), encoding: "UTF-8")
    # 模板必须原样保留，否则 reset 就没有可回退的东西了。
    raise "template was modified" unless before == after
  end

  check.call("a saved edit survives and is marked customized") do
    store.save("planning", "# 我自己的策划规则\n只写三集。")
    entry = store.get("planning")
    raise "edit lost" unless entry["body"].include?("我自己的策划规则")
    raise "not marked customized" unless entry["customized"]
    listed = store.list["skills"].find { |item| item["id"] == "planning" }
    raise "listing did not reflect the edit" unless listed["customized"]
  end

  check.call("reset falls back to the bundled template") do
    store.reset("planning")
    entry = store.get("planning")
    raise "template not restored" unless entry["body"].include?("短剧策划")
    raise "still marked customized" if entry["customized"]
  end

  check.call("compose puts the stage skill first and appends selected common skills in order") do
    composed = store.compose(stage: "planning", common: ["common/de-ai-flavor", "common/romance"])
    system = composed["system"]
    planning_at = system.index("短剧策划")
    deai_at = system.index("去 AI 味")
    romance_at = system.index("# 言情")
    raise "stage skill missing" unless planning_at
    raise "common skills missing" unless deai_at && romance_at
    raise "stage skill must come first" unless planning_at < deai_at
    raise "common skills must keep the given order" unless deai_at < romance_at
  end

  check.call("compose without common skills returns just the stage skill") do
    composed = store.compose(stage: "storyboard", common: [])
    raise "stage skill missing" unless composed["system"].include?("# 分镜")
    raise "unexpected common skill" if composed["system"].include?("去 AI 味")
  end

  check.call("an unknown common skill is skipped, not fatal") do
    composed = store.compose(stage: "planning", common: ["common/does-not-exist"])
    raise "stage skill missing" unless composed["system"].include?("短剧策划")
  end

  check.call("a stage skill cannot be attached as a common skill") do
    # 阶段技能与通用技能不是一个用途。把 episode 当通用技能挂到策划上，
    # 会让模型同时收到两套互相冲突的输出格式要求。
    composed = store.compose(stage: "planning", common: ["episode"])
    raise "stage skill leaked into the common slot" if composed["system"].include?("# 单集剧本")
  end

  check.call("path traversal in an id is refused") do
    %w[../../etc/passwd common/../../secret ../planning].each do |evil|
      raise "#{evil} should not resolve" unless store.get(evil).nil?
      begin
        store.save(evil, "x")
        raise "#{evil} should not be writable"
      rescue ArgumentError
        # 预期
      end
    end
    raise "escaped the user root" if Dir.glob(File.join(directory, "*")).any? { |p| p.include?("passwd") }
  end

  check.call("an oversized body is refused instead of silently truncated") do
    begin
      store.save("planning", "x" * 40_001)
      raise "oversized body accepted"
    rescue ArgumentError
      # 预期：截断会让用户以为存住了。
    end
  end

  check.call("skill files are owner-only") do
    store.save("character", "# 自己的角色规则")
    mode = File.stat(File.join(user_root, "character.md")).mode & 0o777
    raise "unsafe mode #{mode.to_s(8)}" unless mode == 0o600
  end
end

failed = results.count { |result| result[:status] == "failed" }
puts JSON.pretty_generate(summary: { total: results.length, passed: results.length - failed, failed: failed }, tests: results)
exit(failed.zero? ? 0 : 1)
