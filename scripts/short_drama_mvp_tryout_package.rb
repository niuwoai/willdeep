# frozen_string_literal: true

require "base64"
require "csv"
require "fileutils"
require "json"
require "time"

PACKAGE_DIR = File.expand_path(ARGV[0] || "build/ci/short_drama_mvp_tryout_package")
REPORT_MD = File.expand_path(ARGV[1] || File.join(PACKAGE_DIR, "tryout-package-report.md"))
REPORT_JSON = File.expand_path(ARGV[2] || File.join(PACKAGE_DIR, "tryout-package-report.json"))

PROJECT_ID = "11111111-1111-4111-8111-111111111111"
EPISODE_ID = "22222222-2222-4222-8222-222222222222"
SHOT_ID = "33333333-3333-4333-8333-333333333333"
SHOT_2_ID = "44444444-4444-4444-8444-444444444444"
CHARACTER_ID = "55555555-5555-4555-8555-555555555555"
SCENE_ID = "66666666-6666-4666-8666-666666666666"
REVIEW_ITEM_ID = "77777777-7777-4777-8777-777777777777"

SAMPLE_PNG = Base64.decode64(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="
)

def write_json(path, value)
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, "#{JSON.pretty_generate(value)}\n")
end

def write_text(path, value)
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, value)
end

def write_png(path)
  FileUtils.mkdir_p(File.dirname(path))
  File.binwrite(path, SAMPLE_PNG)
end

def csv_string(rows)
  CSV.generate do |csv|
    rows.each { |row| csv << row }
  end
end

def require_file(path, checks)
  checks << {
    name: "file exists: #{File.basename(path)}",
    ok: File.file?(path),
    path: path
  }
end

def manifest_item_count(path)
  JSON.parse(File.read(path)).fetch("items").length
end

FileUtils.rm_rf(PACKAGE_DIR)
FileUtils.mkdir_p(File.join(PACKAGE_DIR, "outputs"))
FileUtils.mkdir_p(File.join(PACKAGE_DIR, "masks"))

write_png(File.join(PACKAGE_DIR, "outputs", "shot-001-main.png"))
write_png(File.join(PACKAGE_DIR, "outputs", "shot-001-candidate-2.png"))
write_png(File.join(PACKAGE_DIR, "outputs", "hero-reference.png"))
write_png(File.join(PACKAGE_DIR, "masks", "shot-001-redraw-mask.png"))

exported_at = Time.now.utc.iso8601

package = {
  "schema" => "willdeep.short_drama.production_package.tryout.v1",
  "scope" => "project",
  "exported_at" => exported_at,
  "project" => {
    "id" => PROJECT_ID,
    "title" => "MVP Tryout Short Drama",
    "logline" => "A tiny local package for dry-run, manifest import, Widget preview, and review queue smoke tests.",
    "episodes" => [
      {
        "id" => EPISODE_ID,
        "title" => "Episode 1",
        "shots" => [
          {
            "id" => SHOT_ID,
            "title" => "S1 - neon alley reveal",
            "summary" => "Hero enters the alley and sees the clue.",
            "prompt" => "cinematic neon alley, steady wide shot, dramatic rain reflection",
            "selected_image_path" => "outputs/shot-001-main.png",
            "artifact_paths" => [
              "outputs/shot-001-main.png",
              "outputs/shot-001-candidate-2.png"
            ],
            "open_review_item_count" => 1
          },
          {
            "id" => SHOT_2_ID,
            "title" => "S2 - clue close-up",
            "summary" => "A close-up shot that still needs video generation.",
            "prompt" => "macro close-up of a glowing clue, subtle camera push",
            "selected_image_path" => nil,
            "artifact_paths" => [],
            "open_review_item_count" => 0
          }
        ]
      }
    ],
    "characters" => [
      {
        "id" => CHARACTER_ID,
        "name" => "Hero",
        "description" => "Curious lead character with a dark coat.",
        "reference_image_paths" => ["outputs/hero-reference.png"]
      }
    ],
    "scenes" => [
      {
        "id" => SCENE_ID,
        "name" => "Neon Alley",
        "description" => "Wet alley, cyan-magenta neon signs, reflective ground.",
        "reference_image_paths" => []
      }
    ]
  }
}

timeline = {
  "project_id" => PROJECT_ID,
  "episode_count" => 1,
  "shots" => [
    {
      "episode_id" => EPISODE_ID,
      "shot_id" => SHOT_ID,
      "order" => 1,
      "title" => "S1 - neon alley reveal",
      "selected_image_path" => "outputs/shot-001-main.png",
      "video_path" => nil,
      "prompt" => "cinematic neon alley, steady wide shot, dramatic rain reflection",
      "open_review_item_count" => 1
    },
    {
      "episode_id" => EPISODE_ID,
      "shot_id" => SHOT_2_ID,
      "order" => 2,
      "title" => "S2 - clue close-up",
      "selected_image_path" => nil,
      "video_path" => nil,
      "prompt" => "macro close-up of a glowing clue, subtle camera push",
      "open_review_item_count" => 0
    }
  ]
}

gap_report = {
  "project_id" => PROJECT_ID,
  "scope" => "project",
  "missing_asset_reference_count" => 1,
  "missing_image_count" => 1,
  "missing_video_count" => 2,
  "open_review_item_count" => 1,
  "assets" => [
    {
      "asset_kind" => "scene",
      "asset_id" => SCENE_ID,
      "name" => "Neon Alley",
      "linked_shot_ids" => [SHOT_ID, SHOT_2_ID],
      "generate_reference_dry_run_arguments" => "project_id=#{PROJECT_ID}, asset_kind=scene, asset_id=#{SCENE_ID}, dry_run=true",
      "generate_reference_arguments" => "project_id=#{PROJECT_ID}, asset_kind=scene, asset_id=#{SCENE_ID}, dry_run=false"
    }
  ],
  "batch_actions" => {
    "missing_image_dry_run_arguments" => "project_id=#{PROJECT_ID}, kind=image_generation, target_filter=missing, dry_run=true",
    "missing_image_submit_arguments" => "project_id=#{PROJECT_ID}, kind=image_generation, target_filter=missing, dry_run=false",
    "missing_video_dry_run_arguments" => "project_id=#{PROJECT_ID}, kind=video_generation, target_filter=missing, dry_run=true",
    "missing_video_submit_arguments" => "project_id=#{PROJECT_ID}, kind=video_generation, target_filter=missing, dry_run=false"
  }
}

manifest = {
  "title" => "MVP Tryout Manifest",
  "base_directory" => ".",
  "provider" => "skill",
  "project_id" => PROJECT_ID,
  "episode_id" => EPISODE_ID,
  "items" => [
    {
      "file_path" => "outputs/shot-001-main.png",
      "task_title" => "S1 main image import",
      "kind" => "image_generation",
      "prompt" => "cinematic neon alley, steady wide shot",
      "shot_id" => SHOT_ID
    },
    {
      "file_path" => "outputs/shot-001-candidate-2.png",
      "task_title" => "S1 alternate candidate import",
      "kind" => "image_generation",
      "prompt" => "alternate candidate for image choice widget",
      "shot_id" => SHOT_ID
    },
    {
      "file_path" => "outputs/hero-reference.png",
      "task_title" => "Hero character reference import",
      "kind" => "image_generation",
      "asset_kind" => "character",
      "asset_id" => CHARACTER_ID
    },
    {
      "file_path" => "outputs/shot-002-video.mp4",
      "task_title" => "S2 pending video generation",
      "kind" => "video_generation",
      "provider" => "some_im",
      "prompt" => "macro close-up of a glowing clue, subtle camera push",
      "shot_id" => SHOT_2_ID,
      "remote_task_id" => "tryout-someim-video-0001",
      "status_url" => "https://api.some.im/v1/tasks/tryout-someim-video-0001",
      "cancel_url" => "https://api.some.im/v1/tasks/tryout-someim-video-0001/cancel",
      "status_endpoint_suffix" => "tasks/tryout-someim-video-0001",
      "cancel_endpoint_suffix" => "tasks/tryout-someim-video-0001/cancel"
    },
    {
      "file_path" => "outputs/shot-001-redraw.png",
      "task_title" => "S1 redraw review fix",
      "kind" => "image_inpaint",
      "provider" => "replicate",
      "prompt" => "remove the logo artifact while preserving alley lighting",
      "shot_id" => SHOT_ID,
      "source_image_path" => "outputs/shot-001-main.png",
      "mask_path" => "masks/shot-001-redraw-mask.png",
      "review_item_id" => REVIEW_ITEM_ID,
      "last_error" => "tryout: provider not called; use this failed row for recovery smoke"
    }
  ]
}

review_header = %w[
  project_id episode_id shot_id review_item_id review_title review_detail
  kind severity review_status suggested_action artifact_paths
]
review_row = [
  PROJECT_ID,
  EPISODE_ID,
  SHOT_ID,
  REVIEW_ITEM_ID,
  "Logo artifact on wall",
  "The wall sign has a visible logo-like artifact; inpaint it before video generation.",
  "redraw",
  "medium",
  "open",
  "Use edit_image_with_mask with masks/shot-001-redraw-mask.png.",
  "outputs/shot-001-main.png"
]

manifest_preview_path = File.join(PACKAGE_DIR, "media-import-manifest-template.json")
timeline_preview_path = File.join(PACKAGE_DIR, "production-timeline.json")
gap_report_preview_path = File.join(PACKAGE_DIR, "production-gap-report.json")
review_queue_preview_path = File.join(PACKAGE_DIR, "production-review-queue.csv")

widget_html = [
  "<!doctype html>",
  "<meta charset=\"utf-8\">",
  "<title>WillDeep Short Drama MVP Tryout</title>",
  "<style>",
  "body { font: 14px -apple-system, BlinkMacSystemFont, sans-serif; margin: 24px; color: #1f2937; }",
  "code { background: #eef2ff; padding: 2px 5px; border-radius: 4px; }",
  "button { margin: 4px 8px 4px 0; padding: 6px 10px; }",
  ".muted { color: #6b7280; }",
  "</style>",
  "<h1>Short Drama MVP Tryout Package</h1>",
  "<p class=\"muted\">Local-only package generated by <code>scripts/short_drama_mvp_tryout_package.rb</code>.</p>",
  "<p>Use this package to smoke dry-run import, pending remote task registration, Widget handoff, and review queue import.</p>",
  "<button onclick=\"sendPrompt('请 dry-run 导入这个短剧 MVP 试用包：import_media_manifest(package_directory=#{PACKAGE_DIR}, dry_run=true, import_pending_tasks=true)')\">Dry-run import</button>",
  "<button onclick=\"sendPrompt('请正式导入这个短剧 MVP 试用包：import_media_manifest(package_directory=#{PACKAGE_DIR}, dry_run=false, import_pending_tasks=true)')\">Import manifest</button>",
  "<button onclick=\"sendPrompt('请读取 production-gap-report.json，按缺口报告给出补图、补视频和检查项修复顺序。package_directory=#{PACKAGE_DIR}')\">Plan gaps</button>",
  "<button onclick=\"sendPrompt('请 dry-run 回写制作包修复队列：short_drama_import_review_csv(file_path=#{review_queue_preview_path}, dry_run=true)')\">Review queue</button>",
  "<h2>Paths</h2>",
  "<ul>",
  "<li>Package: <code>#{PACKAGE_DIR}</code></li>",
  "<li>Manifest: <code>#{manifest_preview_path}</code></li>",
  "<li>Timeline: <code>#{timeline_preview_path}</code></li>",
  "<li>Gap report: <code>#{gap_report_preview_path}</code></li>",
  "</ul>"
].join("\n")

write_json(File.join(PACKAGE_DIR, "production-package.json"), package)
write_json(File.join(PACKAGE_DIR, "production-timeline.json"), timeline)
write_json(File.join(PACKAGE_DIR, "production-gap-report.json"), gap_report)
write_json(File.join(PACKAGE_DIR, "media-import-manifest-template.json"), manifest)
write_text(
  File.join(PACKAGE_DIR, "production-package.md"),
  "# MVP Tryout Short Drama\n\nLocal-only package for WillDeep short-drama MVP smoke testing.\n"
)
write_text(
  File.join(PACKAGE_DIR, "production-shot-list.csv"),
  csv_string([
    %w[project_id episode_id shot_id order title selected_image_path video_path open_review_item_count prompt],
    [PROJECT_ID, EPISODE_ID, SHOT_ID, 1, "S1 - neon alley reveal", "outputs/shot-001-main.png", "", 1, "cinematic neon alley, steady wide shot"],
    [PROJECT_ID, EPISODE_ID, SHOT_2_ID, 2, "S2 - clue close-up", "", "", 0, "macro close-up of a glowing clue"]
  ])
)
write_text(File.join(PACKAGE_DIR, "production-review-template.csv"), csv_string([review_header, review_row]))
write_text(File.join(PACKAGE_DIR, "production-review-queue.csv"), csv_string([review_header, review_row]))
write_text(File.join(PACKAGE_DIR, "widget-preview.html"), widget_html)
write_text(
  File.join(PACKAGE_DIR, "media-api.env.example"),
  "# Local tryout package: do not put real tokens in this file.\nWILLDEEP_MEDIA_PROVIDER=skill\n"
)

checks = []
%w[
  production-package.json
  production-package.md
  production-timeline.json
  production-gap-report.json
  production-shot-list.csv
  production-review-template.csv
  production-review-queue.csv
  media-import-manifest-template.json
  widget-preview.html
  media-api.env.example
].each do |name|
  require_file(File.join(PACKAGE_DIR, name), checks)
end
%w[
  outputs/shot-001-main.png
  outputs/shot-001-candidate-2.png
  outputs/hero-reference.png
  masks/shot-001-redraw-mask.png
].each do |name|
  require_file(File.join(PACKAGE_DIR, name), checks)
end

manifest_path = File.join(PACKAGE_DIR, "media-import-manifest-template.json")
manifest_data = JSON.parse(File.read(manifest_path))
checks << {
  name: "manifest has completed artifacts",
  ok: manifest_data.fetch("items").count { |item| File.file?(File.join(PACKAGE_DIR, item.fetch("file_path"))) } >= 3
}
checks << {
  name: "manifest has pending remote task",
  ok: manifest_data.fetch("items").any? { |item| item["remote_task_id"] && item["status_url"] }
}
checks << {
  name: "manifest has failed review repair task",
  ok: manifest_data.fetch("items").any? { |item| item["last_error"] && item["review_item_id"] == REVIEW_ITEM_ID }
}
checks << {
  name: "widget exposes import handoff",
  ok: File.read(File.join(PACKAGE_DIR, "widget-preview.html")).include?("import_media_manifest")
}

ok = checks.all? { |check| check.fetch(:ok) }
report = {
  status: ok ? "pass" : "fail",
  package_directory: PACKAGE_DIR,
  manifest_path: manifest_path,
  widget_preview_path: File.join(PACKAGE_DIR, "widget-preview.html"),
  manifest_item_count: manifest_item_count(manifest_path),
  checks: checks
}

write_json(REPORT_JSON, report)
write_text(
  REPORT_MD,
  [
    "# Short Drama MVP Tryout Package",
    "",
    "**Status:** #{ok ? "pass" : "fail"}",
    "",
    "- Package: `#{PACKAGE_DIR}`",
    "- Manifest: `#{manifest_path}`",
    "- Widget preview: `#{File.join(PACKAGE_DIR, "widget-preview.html")}`",
    "- Manifest items: #{report[:manifest_item_count]}",
    "",
    "## Checks",
    "",
    *checks.map { |check| "- #{check.fetch(:ok) ? "[x]" : "[ ]"} #{check.fetch(:name)}" },
    ""
  ].join("\n")
)

puts "short_drama_mvp_tryout_package: #{ok ? "pass" : "fail"} package=#{PACKAGE_DIR} items=#{report[:manifest_item_count]}"
exit(ok ? 0 : 1)
