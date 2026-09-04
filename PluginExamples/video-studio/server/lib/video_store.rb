# frozen_string_literal: true

require "fileutils"
require "json"
require "securerandom"
require "time"

class VideoStore
  VERSION = 1
  MAX_JOBS = 500

  DEFAULT_SETTINGS = {
    "assistantProviderID" => nil,
    "assistantModel" => nil,
    "videoModel" => "MiniMax-H3",
    "duration" => 4,
    "width" => 832,
    "height" => 480,
    "inferenceSteps" => 20,
    "autoDownload" => true
  }.freeze

  def initialize(path)
    @path = File.expand_path(path)
  end

  attr_reader :path

  def data
    parsed = JSON.parse(File.read(path))
    return empty_data unless parsed.is_a?(Hash)

    {
      "version" => VERSION,
      "settings" => normalize_settings(parsed["settings"]),
      "jobs" => normalize_jobs(parsed["jobs"])
    }
  rescue Errno::ENOENT
    empty_data
  rescue JSON::ParserError, SystemCallError => error
    warn "video-studio: unreadable store (#{error.class}); starting with an empty view"
    empty_data
  end

  def settings
    data["settings"]
  end

  def update_settings(changes)
    current = data
    current["settings"] = normalize_settings(current["settings"].merge(changes))
    write(current)
    current["settings"]
  end

  def jobs
    data["jobs"]
  end

  def find_job(id)
    token = id.to_s.strip
    jobs.find { |job| job["id"] == token || job["remoteID"] == token }
  end

  def add_job(attributes)
    current = data
    now = Time.now.utc.iso8601
    job = {
      "id" => SecureRandom.uuid,
      "remoteID" => nil,
      "provider" => "openai-videos-async",
      "state" => "draft",
      "progress" => 0,
      "createdAt" => now,
      "updatedAt" => now,
      "error" => nil,
      "outputURL" => nil,
      "outputPath" => nil,
      "downloadError" => nil,
      "ambiguousSubmission" => false
    }.merge(attributes)
    current["jobs"].unshift(job)
    current["jobs"] = current["jobs"].first(MAX_JOBS)
    write(current)
    job
  end

  def update_job(id, changes)
    current = data
    index = current["jobs"].index { |job| job["id"] == id || job["remoteID"] == id }
    return nil if index.nil?

    current["jobs"][index] = current["jobs"][index].merge(changes).merge("updatedAt" => Time.now.utc.iso8601)
    write(current)
    current["jobs"][index]
  end

  def remove_job(id)
    current = data
    removed = current["jobs"].find { |job| job["id"] == id || job["remoteID"] == id }
    return nil unless removed

    current["jobs"].reject! { |job| job["id"] == removed["id"] }
    write(current)
    removed
  end

  private

  def empty_data
    { "version" => VERSION, "settings" => DEFAULT_SETTINGS.dup, "jobs" => [] }
  end

  def normalize_settings(raw)
    value = raw.is_a?(Hash) ? DEFAULT_SETTINGS.merge(raw) : DEFAULT_SETTINGS.dup
    value["assistantProviderID"] = optional_string(value["assistantProviderID"])
    value["assistantModel"] = optional_string(value["assistantModel"])
    value["videoModel"] = clean_string(value["videoModel"], "MiniMax-H3", 160)
    value["duration"] = allowed_integer(value["duration"], [2, 4, 6], 4)
    value["width"] = dimension(value["width"], 832)
    value["height"] = dimension(value["height"], 480)
    value["inferenceSteps"] = bounded_integer(value["inferenceSteps"], 1, 100, 20)
    value["autoDownload"] = value["autoDownload"] != false
    value
  end

  def normalize_jobs(raw)
    return [] unless raw.is_a?(Array)

    raw.select { |job| job.is_a?(Hash) && !job["id"].to_s.empty? }.first(MAX_JOBS)
  end

  def optional_string(value)
    token = value.to_s.strip[0, 300]
    token.empty? ? nil : token
  end

  def clean_string(value, fallback, limit)
    token = value.to_s.strip[0, limit]
    token.empty? ? fallback : token
  end

  def allowed_integer(value, allowed, fallback)
    number = Integer(value)
    allowed.include?(number) ? number : fallback
  rescue ArgumentError, TypeError
    fallback
  end

  def bounded_integer(value, minimum, maximum, fallback)
    number = Integer(value)
    number.between?(minimum, maximum) ? number : fallback
  rescue ArgumentError, TypeError
    fallback
  end

  def dimension(value, fallback)
    number = bounded_integer(value, 32, 4096, fallback)
    normalized = number - (number % 32)
    normalized < 32 ? fallback : normalized
  end

  def write(payload)
    FileUtils.mkdir_p(File.dirname(path))
    temporary = "#{path}.#{Process.pid}.tmp"
    File.write(temporary, JSON.pretty_generate(payload), perm: 0o600)
    File.rename(temporary, path)
    payload
  ensure
    File.delete(temporary) if defined?(temporary) && File.exist?(temporary)
  end
end
