#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require "pathname"
require "yaml"

ROOT = Pathname.new(__dir__).join("..").expand_path
SKILLS_ROOT = ROOT.join("BundledSkills")
TOOL_REGISTRY = ROOT.join("Xedit", "AgentToolRegistry.swift")
LOCALIZATION = ROOT.join("Xedit", "AgentSkillLocalization.swift")

FORBIDDEN_PATTERNS = {
  "legacy product name" => /\balma\b/i,
  "copied product name" => /\bwork\s*buddy\b|\bworkbuddy\b/i,
  "legacy workspace path" => /(?:^|[\/.`])\.alma(?:[\/.`]|$)/i,
  "legacy configuration path" => %r{config/alma}i,
  "legacy local API" => /localhost:23001/i,
  "legacy chat environment" => /ALMA_(?:CHAT|THREAD)_ID/,
}.freeze

DEPRECATED_TOOL_WORDS = %w[
  ChromeRelayClick
  ChromeRelayEval
  ChromeRelayListTabs
  ChromeRelayNavigate
  ChromeRelayRead
  ChromeRelayReadDom
  ChromeRelayScreenshot
  ChromeRelayScroll
  WebFetch
].freeze

REQUIRED_RUNTIME_TOOLS = {
  "browser" => %w[
    list_mcp_servers list_mcp_tools call_mcp_tool web_search web_fetch
    visual_qa_screenshot search_mcp_servers suggest_mcp_server
  ],
  "daily-report" => %w[run_command list_workspace_sessions],
  "discord" => %w[
    list_mcp_servers list_mcp_tools call_mcp_tool search_mcp_servers
    suggest_mcp_server
  ],
  "file-manager" => %w[
    search_files grep_files list_directory read_file create_file edit_file
    apply_patch run_command
  ],
  "image-gen" => %w[
    generate_image edit_generated_image open_image_editor
    edit_image_with_mask upscale_image show_image_choice_widget
  ],
  "memory-management" => %w[add_memory],
  "music-gen" => %w[
    list_mcp_servers list_mcp_tools call_mcp_tool search_mcp_servers
    suggest_mcp_server
  ],
  "music-listener" => %w[
    run_command list_mcp_servers list_mcp_tools call_mcp_tool
    search_mcp_servers suggest_mcp_server
  ],
  "notebook" => %w[read_file edit_file apply_patch run_command],
  "reactions" => %w[
    lark_cli list_mcp_servers list_mcp_tools call_mcp_tool
    search_mcp_servers suggest_mcp_server
  ],
  "scheduler" => %w[schedule_task complete_scheduled_task],
  "screenshot" => %w[
    capture_screenshot computer_use_get_app_state chrome_capture_tab
    embedded_browser_capture_screenshot visual_qa_screenshot
  ],
  "self-management" => %w[
    computer_use_permissions suggest_session_title rename_session
    list_mcp_servers search_mcp_servers suggest_mcp_server configure_mcp_server
  ],
  "self-reflection" => %w[add_memory],
  "selfie" => %w[generate_image edit_generated_image],
  "send-file" => %w[list_mcp_servers list_mcp_tools lark_cli],
  "skill-hub" => %w[
    list_skills read_skill create_user_skill update_user_skill
    delete_user_skill search_mcp_servers suggest_mcp_server
  ],
  "skill-search" => %w[
    list_skills read_skill create_user_skill search_mcp_servers
    suggest_mcp_server configure_mcp_server
  ],
  "tasks" => %w[
    read_skill schedule_task list_queued_tasks list_workspace_sessions
  ],
  "telegram" => %w[
    list_mcp_servers list_mcp_tools call_mcp_tool search_mcp_servers
    suggest_mcp_server
  ],
  "thread-management" => %w[
    list_workspace_sessions suggest_session_title rename_session
  ],
  "todo" => %w[read_file create_file edit_file],
  "travel" => %w[web_search web_fetch],
  "twitter-media" => %w[
    web_fetch web_search chrome_status chrome_read_page run_command
  ],
  "video-reader" => %w[
    run_command visual_qa_screenshot list_mcp_servers list_mcp_tools
    call_mcp_tool search_mcp_servers suggest_mcp_server
  ],
  "voice" => %w[
    run_command create_file list_mcp_servers list_mcp_tools
  ],
  "web-fetch" => %w[web_fetch web_search chrome_status],
  "web-search" => %w[web_search web_fetch],
}.freeze

def parse_frontmatter(path)
  text = path.read
  parts = text.split(/^---\s*$\n/, 3)
  raise "missing or unterminated YAML frontmatter" unless parts.length == 3

  metadata = YAML.safe_load(parts[1], permitted_classes: [], aliases: false)
  raise "frontmatter must be a mapping" unless metadata.is_a?(Hash)

  [metadata, text]
end

def relative(path)
  path.relative_path_from(ROOT).to_s
end

options = { format: "markdown" }
OptionParser.new do |parser|
  parser.banner = "Usage: validate_bundled_skills.rb [--format markdown|json]"
  parser.on("--format FORMAT", %w[markdown json]) { |value| options[:format] = value }
end.parse!

errors = []
warnings = []
skill_paths = SKILLS_ROOT.glob("*/SKILL.md").sort
runtime_tools = TOOL_REGISTRY.read.scan(
  /AgentToolDescriptor\(\s*name:\s*"([a-z][a-z0-9_]+)"/m
).flatten.to_h { |name| [name, true] }

skill_paths.each do |path|
  slug = path.dirname.basename.to_s
  begin
    metadata, text = parse_frontmatter(path)
  rescue StandardError => e
    errors << { file: relative(path), message: e.message }
    next
  end

  unknown_keys = metadata.keys.map(&:to_s) - %w[name description]
  errors << {
    file: relative(path),
    message: "frontmatter has unsupported keys: #{unknown_keys.join(', ')}",
  } unless unknown_keys.empty?

  errors << {
    file: relative(path),
    message: "frontmatter name #{metadata['name'].inspect} must match directory #{slug.inspect}",
  } unless metadata["name"] == slug

  description = metadata["description"].to_s.strip
  errors << {
    file: relative(path),
    message: "description must be a non-empty single-line string",
  } if description.empty? || description.include?("\n")

  FORBIDDEN_PATTERNS.each do |label, pattern|
    next unless text.match?(pattern)

    errors << { file: relative(path), message: "contains #{label}" }
  end

  DEPRECATED_TOOL_WORDS.each do |word|
    next unless text.include?(word)

    errors << { file: relative(path), message: "contains deprecated tool name #{word}" }
  end

  REQUIRED_RUNTIME_TOOLS.fetch(slug, []).each do |tool|
    unless runtime_tools.key?(tool)
      errors << {
        file: relative(path),
        message: "references unavailable WillDeep tool #{tool}",
      }
    end
    unless text.include?("`#{tool}`")
      errors << {
        file: relative(path),
        message: "must document required WillDeep tool #{tool}",
      }
    end
  end
end

localized_text = LOCALIZATION.read
FORBIDDEN_PATTERNS.each do |label, pattern|
  next unless localized_text.match?(pattern)

  errors << { file: relative(LOCALIZATION), message: "contains #{label}" }
end

result = {
  ok: errors.empty?,
  skill_count: skill_paths.length,
  runtime_tool_count: runtime_tools.length,
  errors: errors,
  warnings: warnings,
}

if options[:format] == "json"
  puts JSON.pretty_generate(result)
else
  puts "# Bundled Skill Validation"
  puts
  puts "- Result: #{result[:ok] ? 'PASS' : 'FAIL'}"
  puts "- Skills checked: #{result[:skill_count]}"
  puts "- WillDeep runtime tools discovered: #{result[:runtime_tool_count]}"
  puts "- Errors: #{errors.length}"
  puts "- Warnings: #{warnings.length}"
  unless errors.empty?
    puts
    puts "## Errors"
    puts
    errors.each { |error| puts "- `#{error[:file]}`: #{error[:message]}" }
  end
end

exit(errors.empty? ? 0 : 1)
