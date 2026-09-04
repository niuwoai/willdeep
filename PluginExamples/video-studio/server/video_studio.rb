#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8
$stdout.sync = true
$stdout.set_encoding(Encoding::UTF_8)
$stderr.set_encoding(Encoding::UTF_8)

require_relative "adapters/openai_videos_async"
require_relative "lib/video_store"
require_relative "lib/video_service"

def video_store_path
  ENV["VIDEO_STUDIO_STORE"] ||
    File.expand_path("~/Library/Application Support/WillDeep/plugin-data/video-studio/jobs.json")
end

def video_output_directory
  value = ENV["VIDEO_STUDIO_OUTPUT_DIRECTORY"].to_s.strip
  value = "~/Movies/WillDeep Video Studio" if value.empty?
  File.expand_path(value)
end

STORE = VideoStore.new(video_store_path)
ADAPTER_FACTORY = lambda do
  OpenAIVideosAsyncAdapter.new(
    base_url: ENV["VIDEO_STUDIO_API_BASE"] || "https://hub.tsingfly.com",
    api_key: ENV["VIDEO_STUDIO_API_KEY"],
    output_directory: video_output_directory,
    open_timeout: (ENV["VIDEO_STUDIO_OPEN_TIMEOUT"] || 20).to_i,
    read_timeout: (ENV["VIDEO_STUDIO_READ_TIMEOUT"] || 90).to_i
  )
end
SERVICE = VideoService.new(store: STORE, adapter_factory: ADAPTER_FACTORY)

TOOLS = [
  {
    name: "video.status",
    description: "Return the safe Video Studio provider configuration and local job counts. Never returns credentials.",
    inputSchema: { type: "object", properties: {} }
  },
  {
    name: "video.create_draft",
    description: "Save a video idea as a draft. Use this for chat-selection capture before generation.",
    inputSchema: {
      type: "object",
      properties: {
        text: { type: "string", description: "Video idea or prompt." },
        title: { type: "string" },
        referenceImagePath: { type: "string" },
        source: { type: "string" }
      },
      required: ["text"]
    }
  },
  {
    name: "video.list",
    description: "List locally persisted video drafts and asynchronous jobs.",
    inputSchema: {
      type: "object",
      properties: {
        status: { type: "string", enum: %w[all draft active completed failed] },
        query: { type: "string" }
      }
    }
  },
  {
    name: "video.generate",
    description: "Submit an asynchronous text-to-video or first-frame image-to-video job. Omitting referenceImagePath uses t2va; providing it uses fl2va.",
    inputSchema: {
      type: "object",
      properties: {
        draftID: { type: "string" },
        title: { type: "string" },
        prompt: { type: "string" },
        negativePrompt: { type: "string" },
        referenceImagePath: { type: "string", description: "Readable local PNG, JPEG, or WebP path." },
        model: { type: "string", description: "Defaults to MiniMax-H3." },
        duration: { type: "integer", enum: [2, 4, 6] },
        width: { type: "integer", description: "Multiple of 32." },
        height: { type: "integer", description: "Multiple of 32." },
        inferenceSteps: { type: "integer", minimum: 1, maximum: 100 },
        seed: { type: "integer" },
        source: { type: "string" }
      },
      required: ["prompt"]
    }
  },
  {
    name: "video.refresh",
    description: "Poll one remote video task and download the MP4 when completed and auto-download is enabled.",
    inputSchema: { type: "object", properties: { id: { type: "string" } }, required: ["id"] }
  },
  {
    name: "video.refresh_active",
    description: "Poll up to twenty active video jobs once. It does not create background or scheduled work.",
    inputSchema: { type: "object", properties: {} }
  },
  {
    name: "video.retry",
    description: "Explicitly submit a new attempt using a finished job's stored request. The original job is preserved.",
    inputSchema: { type: "object", properties: { id: { type: "string" } }, required: ["id"] }
  },
  {
    name: "video.download",
    description: "Download a completed video or retry a failed download without creating a new paid generation task.",
    inputSchema: { type: "object", properties: { id: { type: "string" } }, required: ["id"] }
  },
  {
    name: "video.remove",
    description: "Remove a local job record without deleting its downloaded video file.",
    inputSchema: { type: "object", properties: { id: { type: "string" } }, required: ["id"] }
  },
  {
    name: "video.settings",
    description: "Read or update creative-assistant routing and default video parameters. API credentials remain in plugin settings and are never returned.",
    inputSchema: {
      type: "object",
      properties: {
        assistantProviderID: { type: ["string", "null"] },
        assistantModel: { type: ["string", "null"] },
        videoModel: { type: "string" },
        duration: { type: "integer", enum: [2, 4, 6] },
        width: { type: "integer" },
        height: { type: "integer" },
        inferenceSteps: { type: "integer" },
        autoDownload: { type: "boolean" }
      }
    }
  },
  {
    name: "video.pick_reference",
    description: "Open the macOS file picker and return a local PNG, JPEG, or WebP path.",
    inputSchema: { type: "object", properties: {} }
  },
  {
    name: "video.reveal_output",
    description: "Reveal a completed job's downloaded MP4 in Finder.",
    inputSchema: { type: "object", properties: { id: { type: "string" } }, required: ["id"] }
  }
].freeze

def call_tool(name, arguments)
  case name
  when "video.status" then SERVICE.status
  when "video.create_draft" then SERVICE.create_draft(arguments)
  when "video.list" then SERVICE.list(arguments)
  when "video.generate" then SERVICE.generate(arguments)
  when "video.refresh" then SERVICE.refresh(arguments)
  when "video.refresh_active" then SERVICE.refresh_active
  when "video.retry" then SERVICE.retry(arguments)
  when "video.download" then SERVICE.download(arguments)
  when "video.remove" then SERVICE.remove(arguments)
  when "video.settings" then SERVICE.settings(arguments)
  when "video.pick_reference" then SERVICE.pick_reference
  when "video.reveal_output" then SERVICE.reveal_output(arguments)
  else { "ok" => false, "error" => { "code" => "unknown_tool", "message" => "Unknown tool #{name}" } }
  end
end

ARGF.each_line do |line|
  request = JSON.parse(line)
  next unless request["id"]

  result = case request["method"]
           when "initialize"
             {
               protocolVersion: "2025-06-18",
               capabilities: { tools: {} },
               serverInfo: { name: "video-studio", version: "0.1.0" }
             }
           when "tools/list"
             { tools: TOOLS }
           when "tools/call"
             arguments = request.dig("params", "arguments") || {}
             payload = call_tool(request.dig("params", "name"), arguments)
             { content: [{ type: "text", text: JSON.generate(payload) }] }
           else
             {}
           end

  puts JSON.generate(jsonrpc: "2.0", id: request["id"], result: result)
rescue JSON::ParserError
  warn "video-studio: invalid JSON-RPC request"
rescue StandardError => error
  warn "video-studio: #{error.class}"
  if defined?(request) && request.is_a?(Hash) && request["id"]
    puts JSON.generate(
      jsonrpc: "2.0",
      id: request["id"],
      error: { code: -32_000, message: "Video Studio internal error" }
    )
  end
end
