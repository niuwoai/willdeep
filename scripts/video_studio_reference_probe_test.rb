# frozen_string_literal: true
require "json"
require "fileutils"
require_relative "lib/video_studio_reference_probe"

root = File.expand_path("..", __dir__)
plugin = File.join(root, "PluginExamples/video-studio")
require File.join(plugin, "server/lib/image_generation")
checks = []
check = ->(name, value) { checks << { name: name, ok: value == true } }
original_compile = ReferencePackage.method(:compile)
positive = VideoStudioReferenceProbe.call(plugin_root: plugin)
check.call("pinned planning and backend preserve ordered filePath", positive[:ok])
check.call("only one local backend call and zero provider calls", positive[:mock_requests] == 1 && positive[:real_provider_requests] == 0)
check.call("reference compiler restored after probe", ReferencePackage.method(:compile) == original_compile)

wrong_entry = Class.new(ImageGeneration) do
  def frame_reference(slot, compiled)
    super.merge("filePath" => slot.fetch("mediaURL"))
  end
end
check.call("mediaURL substitution before ReferenceLegend is rejected",
  !VideoStudioReferenceProbe.call(plugin_root: plugin, generation_class: wrong_entry)[:ok])

wrong_plan = Class.new(ImageGeneration) do
  def frame_plan(*arguments)
    super.merge("references" => ["willdeep-plugin://bundle/__media__/wrong.png"])
  end
end
check.call("mediaURL substitution after ReferenceLegend is rejected",
  !VideoStudioReferenceProbe.call(plugin_root: plugin, generation_class: wrong_plan)[:ok])

wrong_dispatch = Class.new(ImageGeneration) do
  def run(plan, *arguments)
    super(plan.merge("references" => []), *arguments)
  end
end
check.call("backend dropping reference_paths is rejected",
  !VideoStudioReferenceProbe.call(plugin_root: plugin, generation_class: wrong_dispatch)[:ok])
report = { ok: checks.all? { |item| item[:ok] }, checks: checks, real_provider_requests: 0 }
md = ARGV[0] || File.join(root, "build/video-studio-reference-probe/report.md")
json = ARGV[1] || File.join(root, "build/video-studio-reference-probe/report.json")
[md, json].each { |path| FileUtils.mkdir_p(File.dirname(path)) }
File.write(json, JSON.pretty_generate(report) + "\n")
File.write(md, "# 参考图路径行为回归\n\n" + checks.map { |item| "- #{item[:ok] ? '通过' : '失败'}：#{item[:name]}" }.join("\n") + "\n\n真实 Provider 请求：0。\n")
puts "video_studio_reference_probe: #{report[:ok] ? 'pass' : 'fail'} checks=#{checks.length}"
exit(report[:ok] ? 0 : 1)
