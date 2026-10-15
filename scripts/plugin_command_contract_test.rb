#!/usr/bin/env ruby
# frozen_string_literal: true

# plugin_command_contract_test.rb -- guard the plugin page/host command
# contract for every bundled example plugin.
#
# A plugin page reaches the host through `window.willdeep.executeCommand(id, …)`.
# The host resolves that id strictly against the loaded manifest's
# `contributes.commands` (AgentPluginRegistry.command(pluginID:commandID:)) and
# throws `missingContribution` when it is absent, which surfaces in the page as
# "Plugin contribution not found: <id>.".
#
# That mismatch is invisible to every other test we have: the Ruby server tests
# call the MCP tool directly, so a tool can be fully implemented server-side and
# still be unreachable from the UI. `todo.attach` shipped that way -- server
# tool, server test, UI button, no manifest contribution -- and only a user
# clicking the paperclip found it.
#
# This guard closes the loop: every command id the UI actually invokes must be
# declared in that plugin's manifest, and every manifest command must route to
# something real (an mcpTool the plugin's own server dispatches, a known host
# action, or a declared navigate destination).
#
# Usage:
#   ruby scripts/plugin_command_contract_test.rb
#   ruby scripts/plugin_command_contract_test.rb build/ci/plugin_command_report.md build/ci/plugin_command_report.json

require "json"
require "fileutils"
require "set"
require "time"
require_relative "lib/video_studio_reference_probe"

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

repo_root = File.expand_path("..", __dir__)
markdown_path = ARGV[0] || "build/plugin_command_contract/report.md"
json_path = ARGV[1] || "build/plugin_command_contract/report.json"

# Command ids the page may call without a manifest contribution: these are
# resolved by the bridge itself, not by the contribution registry.
HOST_BUILTIN_COMMAND_IDS = [].freeze

# Source extensions that can contain an executeCommand call.
UI_GLOBS = ["**/*.js", "**/*.jsx", "**/*.ts", "**/*.tsx", "**/*.html"].freeze

# Built ui/dist bundles are generated from ui/src; scanning both would double
# count and, worse, let a stale dist mask a fresh src. Skip generated output.
SKIP_UI_DIRECTORIES = %w[dist node_modules].freeze

# Matches runCommand('todo.attach', …) / window.willdeep.executeCommand("x.y", …)
# and the `executeCommand(\n  'x.y'` form the React sources use. Only string
# literals are checked: a computed id cannot be verified statically, and the
# guard deliberately stays silent rather than guessing.
CALL_PATTERN = /(?:executeCommand|runCommand)\s*\(\s*['"]([A-Za-z0-9_.\-]+)['"]/.freeze

def ui_sources(plugin_dir)
  ui_root = File.join(plugin_dir, "ui")
  return [] unless Dir.exist?(ui_root)

  UI_GLOBS.flat_map { |glob| Dir.glob(File.join(ui_root, glob)) }.reject do |path|
    relative = path.delete_prefix(ui_root + File::SEPARATOR)
    SKIP_UI_DIRECTORIES.any? { |directory| relative.split(File::SEPARATOR).include?(directory) }
  end
end

def invoked_command_ids(plugin_dir)
  ui_sources(plugin_dir).each_with_object({}) do |path, found|
    File.read(path, encoding: "UTF-8").scan(CALL_PATTERN).each do |(identifier)|
      (found[identifier] ||= []) << path
    end
  rescue ArgumentError, Errno::EISDIR
    next
  end
end

# Every dotted identifier the server mentions as a string literal. Servers
# dispatch in more than one style -- a `when "todo.attach"` branch, a ternary on
# `tool_name`, a lookup table -- so matching on `when` alone reports false
# failures for the ternary form (session-vitality). The looser scan still
# catches what this check is for: a manifest handler naming a tool the server
# has never heard of.
def server_mentioned_tools(plugin_dir)
  server_root = File.join(plugin_dir, "server")
  return nil unless Dir.exist?(server_root)

  sources = Dir.glob(File.join(server_root, "**/*.rb"))
  return nil if sources.empty?

  sources.flat_map do |path|
    File.read(path, encoding: "UTF-8").scan(/["']([A-Za-z0-9_\-]+(?:\.[A-Za-z0-9_\-]+)+)["']/).flatten
  end.to_set
end

plugin_dirs = Dir.glob(File.join(repo_root, "PluginExamples/*/.willdeep-plugin"))
                 .map { |path| File.dirname(path) }
                 .sort

checks = []
add_check = lambda do |name, ok, detail|
  checks << { name: name, ok: ok == true, detail: detail }
end

add_check.call(
  "plugin manifests discovered",
  !plugin_dirs.empty?,
  "Found #{plugin_dirs.length} plugin(s) with a .willdeep-plugin manifest."
)

plugin_dirs.each do |plugin_dir|
  slug = File.basename(plugin_dir)
  manifest_path = File.join(plugin_dir, ".willdeep-plugin/plugin.json")

  begin
    manifest = JSON.parse(File.read(manifest_path, encoding: "UTF-8"))
  rescue JSON::ParserError => error
    add_check.call("#{slug}: manifest parses", false, "#{manifest_path}: #{error.message}")
    next
  end

  contributes = manifest["contributes"] || {}
  commands = contributes["commands"] || []
  declared = commands.filter_map { |command| command["id"] }.to_set

  invoked = invoked_command_ids(plugin_dir)
  undeclared = invoked.keys.to_set - declared - HOST_BUILTIN_COMMAND_IDS.to_set

  add_check.call(
    "#{slug}: every UI-invoked command is declared",
    undeclared.empty?,
    if undeclared.empty?
      "#{invoked.length} invoked id(s) all declared in contributes.commands."
    else
      undeclared.sort.map do |identifier|
        callers = invoked[identifier].map { |path| path.delete_prefix(repo_root + File::SEPARATOR) }
        "#{identifier} (called from #{callers.uniq.join(", ")})"
      end.join("; ")
    end
  )

  # Every declared mcpTool command must name a tool the plugin's own server
  # actually dispatches. Catches the mirror-image typo: a manifest entry
  # pointing at a tool that does not exist.
  dispatched = server_mentioned_tools(plugin_dir)
  next if dispatched.nil?

  unrouted = commands.filter_map do |command|
    handler = command["handler"] || {}
    next unless handler["type"] == "mcpTool"

    tool = handler["tool"]
    next if tool.nil? || dispatched.include?(tool)

    "#{command["id"]} -> #{tool}"
  end

  add_check.call(
    "#{slug}: declared mcpTool commands reach a server handler",
    unrouted.empty?,
    unrouted.empty? ? "All mcpTool handlers name a tool the server mentions." : unrouted.join("; ")
  )

  # Localisation: a declared command with a titleKey the locale files do not
  # carry renders as a raw key in menus and the command palette.
  locale_paths = Dir.glob(File.join(plugin_dir, ".willdeep-plugin/locales/*.json"))
  next if locale_paths.empty?

  missing_keys = locale_paths.flat_map do |locale_path|
    begin
      table = JSON.parse(File.read(locale_path, encoding: "UTF-8"))
    rescue JSON::ParserError => error
      next ["#{File.basename(locale_path)}: #{error.message}"]
    end
    commands.filter_map do |command|
      key = command["titleKey"]
      next if key.nil? || table.key?(key)

      "#{File.basename(locale_path)} missing #{key}"
    end
  end

  add_check.call(
    "#{slug}: command titleKeys are localised",
    missing_keys.empty?,
    missing_keys.empty? ? "#{locale_paths.length} locale file(s) cover every command titleKey." : missing_keys.join("; ")
  )
end

# Host-side invariant: one structural slot in AgentModeView renders every
# plugin page, so without per-destination view identity a plugin switch reuses
# the previous plugin's WKWebView -- and with it that plugin's websiteDataStore
# and the scheme handler's pluginID, which is what resolves `/__media__/` to a
# plugin-data directory. That failure is silent on the page (an empty image
# box) and only shows up as one unified-log line.
page_host_source = File.read(File.join(repo_root, "Xedit/AgentPluginPageHost.swift"), encoding: "UTF-8")

add_check.call(
  "plugin web page carries per-destination view identity",
  page_host_source.include?(".id(destination.qualifiedID)"),
  "AgentPluginWebView must be .id()-tagged by destination so makeNSView re-runs on a plugin switch."
)

# Reference images travel as local paths, so the clamp in the bridge is the only
# boundary: without it a plugin page could make the host read an arbitrary file
# and UPLOAD it to a public URL. None of this produces a compile error if it
# regresses, and a missing face only makes the generated image subtly wrong.
bridge_source = File.read(File.join(repo_root, "Xedit/AgentPluginAIBridge.swift"), encoding: "UTF-8")
# 1.378.0-rc1 起出图（含参考图路径钳制）搬到 AgentPluginImageGeneration，页面与 MCP 反向请求共用。
image_generation_source = File.read(
  File.join(repo_root, "Xedit/AgentPluginImageGeneration.swift"), encoding: "UTF-8"
)

add_check.call(
  "reference image paths are clamped to the plugin's own media root",
  image_generation_source.include?("referenceImageOutsidePluginData") &&
    image_generation_source.include?("resolvingSymlinksInPath") &&
    image_generation_source.include?("deletingLastPathComponent() == root"),
  "uploadedReferenceImages must reject symlinks and anything outside the plugin's generated-media folder."
)

add_check.call(
  "reference image count is capped at the gateway limit in both layers",
  bridge_source.include?("maximumReferenceImages") &&
    File.read(File.join(repo_root, "Xedit/SomeIMIntegration.swift"), encoding: "UTF-8")
      .include?("maximumReferenceImages"),
  "The 9-image cap must be enforced in the plugin validator and in the some.im client."
)

# 0.26 起出图的参考图由插件服务端按 target 解析（页面只传 target，不再自己拼
# referenceImagePaths），所以这两条约束改盯服务端的 image_generation.rb。
video_studio_image_generation = File.read(
  File.join(repo_root, "PluginExamples/video-studio/server/lib/image_generation.rb"), encoding: "UTF-8"
)
video_studio_character_plan = video_studio_image_generation[/def character_plan\b.*?\n  end\n/m].to_s

reference_probe = VideoStudioReferenceProbe.call(plugin_root: File.join(repo_root, "PluginExamples/video-studio"))
add_check.call(
  "video-studio sends reference images by filePath, not mediaURL",
  reference_probe[:ok],
  "Pinned frame planning and backend dispatch preserve two ordered filePath values through ReferenceLegend; one local stub request, no provider."
)

add_check.call(
  "character portrait generation stays text-only",
  !video_studio_character_plan.empty? &&
    video_studio_character_plan.include?("plan(prompt, [], [], [], [])"),
  "Generating a character's own portrait must not attach that character as its own reference."
)

add_check.call(
  "scheme handler pluginID follows the mounted destination",
  page_host_source.include?("coordinator.schemeHandler?.pluginID = destination.pluginID"),
  "updateNSView must refresh pluginID alongside packageURL; a stale id serves media from the wrong plugin."
)

run_tests_source = File.read(File.join(repo_root, "scripts/run_tests.sh"), encoding: "UTF-8")
# CI runs guards through run_ci_guard_group.rb, not by naming each script in the
# workflow, so that registry is where the CI wiring has to be asserted.
ci_group_source = File.read(File.join(repo_root, "scripts/run_ci_guard_group.rb"), encoding: "UTF-8")

add_check.call(
  "local runner executes the plugin command contract",
  [
    "scripts/plugin_command_contract_test.rb",
    "plugin_command_report.md",
    "plugin_command_report.json"
  ].all? { |token| run_tests_source.include?(token) },
  "run_tests.sh should run and publish this contract."
)

add_check.call(
  "CI guard group executes the plugin command contract",
  ci_group_source.include?("plugin_command_contract_test.rb") &&
    ci_group_source.include?("plugin_command"),
  "run_ci_guard_group.rb should register this contract in a guard group."
)

failures = checks.reject { |check| check[:ok] }
ok = failures.empty?
report = {
  ok: ok,
  generated_at: Time.now.utc.iso8601,
  plugins: plugin_dirs.map { |dir| File.basename(dir) },
  checks: checks,
  failures: failures
}

[markdown_path, json_path].each do |path|
  directory = File.dirname(File.expand_path(path, repo_root))
  FileUtils.mkdir_p(directory) unless Dir.exist?(directory)
end

File.write(File.expand_path(json_path, repo_root), JSON.pretty_generate(report))

status = ok ? "PASS" : "FAIL"
md = +"# Plugin Command Contract Report\n\n"
md << "**Status:** #{status}\n\n"
md << "- Plugins: #{plugin_dirs.length}\n"
md << "- Checks: #{checks.length}\n"
md << "- Failures: #{failures.length}\n\n"

if failures.empty?
  md << "Every UI-invoked plugin command is declared, routed, and localised.\n\n"
else
  md << "## Failures\n\n"
  failures.each { |failure| md << "- #{failure[:name]}: #{failure[:detail]}\n" }
  md << "\n"
end

md << "## Checks\n\n"
md << "| Check | Status | Detail |\n"
md << "| --- | --- | --- |\n"
checks.each do |check|
  md << "| #{check[:name]} | #{check[:ok] ? "PASS" : "FAIL"} | #{check[:detail]} |\n"
end

File.write(File.expand_path(markdown_path, repo_root), md)

puts "plugin_command_contract: #{status.downcase} plugins=#{plugin_dirs.length} checks=#{checks.length} failures=#{failures.length}"
exit(ok ? 0 : 1)
