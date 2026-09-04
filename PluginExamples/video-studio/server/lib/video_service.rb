# frozen_string_literal: true

require "open3"

class VideoService
  ACTIVE_STATES = %w[submitting queued in_progress].freeze
  FILTER_STATES = %w[all draft active completed failed].freeze
  MAX_PROMPT_BYTES = 12_000
  MAX_TITLE_BYTES = 300

  def initialize(store:, adapter_factory:)
    @store = store
    @adapter_factory = adapter_factory
    @store.jobs.each do |job|
      next unless job["state"] == "submitting" && job["remoteID"].to_s.empty?
      @store.update_job(job["id"], "state" => "failed", "ambiguousSubmission" => true,
                        "error" => { "message" => "Submission was interrupted. Verify the provider before retrying." })
    end
  end

  def status
    adapter = @adapter_factory.call
    {
      "ok" => true,
      "provider" => "openai-videos-async",
      "apiBase" => adapter.base_url,
      "apiConfigured" => adapter.configured?,
      "outputDirectory" => adapter.output_directory,
      "storePath" => @store.path,
      "settings" => @store.settings,
      "counts" => counts(@store.jobs)
    }
  rescue VideoProviderError => error
    { "ok" => false, "error" => error.as_json, "settings" => @store.settings }
  end

  def create_draft(arguments)
    prompt = clipped(arguments["text"] || arguments["prompt"], MAX_PROMPT_BYTES)
    return failure("empty_prompt", "A video idea is required.") if prompt.empty?
    title = clipped(arguments["title"], MAX_TITLE_BYTES)
    title = prompt[0, 72] if title.empty?
    job = @store.add_job(
      "title" => title,
      "prompt" => prompt,
      "negativePrompt" => nil,
      "referenceImagePath" => optional_string(arguments["referenceImagePath"]),
      "mode" => optional_string(arguments["referenceImagePath"]) ? "image_to_video" : "text_to_video",
      "source" => optional_string(arguments["source"]) || "manual"
    )
    { "ok" => true, "job" => job }
  end

  def list(arguments)
    filter = arguments["status"].to_s
    filter = "all" unless FILTER_STATES.include?(filter)
    query = clipped(arguments["query"], 300).downcase
    jobs = @store.jobs.select { |job| matches_filter?(job, filter) }
    jobs = jobs.select { |job| searchable_text(job).downcase.include?(query) } unless query.empty?
    {
      "ok" => true,
      "jobs" => jobs,
      "counts" => counts(@store.jobs),
      "settings" => @store.settings,
      "provider" => safe_provider_status
    }
  end

  def settings(arguments)
    changes = {}
    copy_optional_string(arguments, changes, "assistantProviderID", 300)
    copy_optional_string(arguments, changes, "assistantModel", 300)
    copy_optional_string(arguments, changes, "videoModel", 160)
    copy_integer(arguments, changes, "duration")
    copy_integer(arguments, changes, "width")
    copy_integer(arguments, changes, "height")
    copy_integer(arguments, changes, "inferenceSteps")
    changes["autoDownload"] = boolean(arguments["autoDownload"]) if arguments.key?("autoDownload")
    saved = changes.empty? ? @store.settings : @store.update_settings(changes)
    status.merge("settings" => saved)
  end

  def generate(arguments)
    request = normalized_request(arguments)
    validation = validate_request(request)
    return validation if validation

    job = prepare_job(arguments["draftID"], request)
    submit(job)
  rescue VideoProviderError => error
    failure("configuration_error", error.message, error.as_json)
  end

  def refresh(arguments)
    job = @store.find_job(arguments["id"])
    return failure("not_found", "Video job was not found.") unless job
    return failure("missing_remote_id", "This draft has not been submitted.") if job["remoteID"].to_s.empty?
    refresh_job(job)
  end

  def refresh_active
    jobs = @store.jobs.select { |job| ACTIVE_STATES.include?(job["state"]) && !job["remoteID"].to_s.empty? }
    # 每个任务单独兜底：refresh_job 只 rescue 了 VideoProviderError，一个任务
    # 抛别的异常会让这一整批 20 个刷新全废。
    refreshed = jobs.first(20).map do |job|
      begin
        refresh_job(job)["job"] || job
      rescue StandardError => error
        warn "video-studio: refresh skipped for #{job['id']} (#{error.class}: #{error.message})"
        job
      end
    end
    { "ok" => true, "jobs" => refreshed, "counts" => counts(@store.jobs) }
  end

  def retry(arguments)
    original = @store.find_job(arguments["id"])
    return failure("not_found", "Video job was not found.") unless original
    request = original["request"]
    return failure("missing_request", "The original request is unavailable.") unless request.is_a?(Hash)
    return failure("still_active", "An active job cannot be retried.") if ACTIVE_STATES.include?(original["state"])

    job = @store.add_job(job_attributes(request).merge("retryOf" => original["id"], "state" => "submitting"))
    submit(job)
  end

  def remove(arguments)
    job = @store.remove_job(arguments["id"].to_s)
    return failure("not_found", "Video job was not found.") unless job
    { "ok" => true, "removed" => job, "counts" => counts(@store.jobs) }
  end

  def download(arguments)
    job = @store.find_job(arguments["id"])
    return failure("not_found", "Video job was not found.") unless job
    return failure("not_completed", "The video is not completed yet.") unless job["state"] == "completed"
    updated = download_if_ready(job, force: true)
    return { "ok" => false, "job" => updated, "error" => updated["downloadError"] } if updated["downloadError"]
    return failure("missing_output", "The provider has not supplied an output URL.") if updated["outputPath"].to_s.empty?
    { "ok" => true, "job" => updated }
  end

  def pick_reference
    override = ENV["VIDEO_STUDIO_PICK_REFERENCE"].to_s.strip
    return selected_reference(override) unless override.empty?

    script = 'POSIX path of (choose file with prompt "Choose a reference image" of type {"public.png", "public.jpeg", "org.webmproject.webp"})'
    output, error, status = Open3.capture3("/usr/bin/osascript", "-e", script)
    return failure("selection_cancelled", "No reference image was selected.") unless status.success?
    selected_reference(output.strip)
  rescue Errno::ENOENT
    failure("picker_unavailable", "The macOS file picker is unavailable.")
  end

  def reveal_output(arguments)
    job = @store.find_job(arguments["id"])
    return failure("not_found", "Video job was not found.") unless job
    path = job["outputPath"].to_s
    return failure("missing_output", "This job has no downloaded output.") unless File.file?(path)
    pid = Process.spawn("/usr/bin/open", "-R", path, out: File::NULL, err: File::NULL)
    Process.detach(pid)
    { "ok" => true, "path" => path }
  rescue SystemCallError => error
    failure("reveal_failed", "Unable to reveal the output: #{error.class}")
  end

  private

  def safe_provider_status
    adapter = @adapter_factory.call
    {
      "id" => "openai-videos-async",
      "apiBase" => adapter.base_url,
      "apiConfigured" => adapter.configured?,
      "outputDirectory" => adapter.output_directory
    }
  rescue VideoProviderError => error
    { "id" => "openai-videos-async", "apiConfigured" => false, "error" => error.as_json }
  end

  def normalized_request(arguments)
    settings = @store.settings
    reference = optional_string(arguments["referenceImagePath"])
    requested_model = clipped(arguments["model"], 160)
    {
      "title" => clipped(arguments["title"], MAX_TITLE_BYTES),
      "prompt" => clipped(arguments["prompt"], MAX_PROMPT_BYTES),
      "negativePrompt" => clipped(arguments["negativePrompt"], 4_000),
      "referenceImagePath" => reference,
      "mode" => reference ? "image_to_video" : "text_to_video",
      "model" => requested_model.empty? ? settings["videoModel"] : requested_model,
      "duration" => integer_or(arguments["duration"], settings["duration"]),
      "width" => integer_or(arguments["width"], settings["width"]),
      "height" => integer_or(arguments["height"], settings["height"]),
      "inferenceSteps" => integer_or(arguments["inferenceSteps"], settings["inferenceSteps"]),
      "seed" => optional_integer(arguments["seed"]),
      "source" => optional_string(arguments["source"]) || "manual"
    }
  end

  def validate_request(request)
    return failure("empty_prompt", "A video prompt is required.") if request["prompt"].empty?
    return failure("invalid_duration", "Duration must be 2, 4, or 6 seconds.") unless [2, 4, 6].include?(request["duration"])
    return failure("invalid_width", "Width must be a multiple of 32 between 32 and 4096.") unless valid_dimension?(request["width"])
    return failure("invalid_height", "Height must be a multiple of 32 between 32 and 4096.") unless valid_dimension?(request["height"])
    ratio = request["width"].to_f / request["height"]
    return failure("invalid_aspect_ratio", "Aspect ratio must be between 1:4 and 4:1.") unless ratio.between?(0.25, 4.0)
    return failure("invalid_steps", "Inference steps must be between 1 and 100.") unless request["inferenceSteps"].between?(1, 100)
    nil
  end

  def valid_dimension?(value)
    value.between?(32, 4096) && (value % 32).zero?
  end

  def prepare_job(draft_id, request)
    draft = @store.find_job(draft_id)
    attributes = job_attributes(request).merge("state" => "submitting")
    if draft && draft["state"] == "draft"
      @store.update_job(draft["id"], attributes)
    else
      @store.add_job(attributes)
    end
  end

  def job_attributes(request)
    request.merge(
      "title" => request["title"].empty? ? request["prompt"][0, 72] : request["title"],
      "request" => request,
      "progress" => 0,
      "error" => nil,
      "outputURL" => nil,
      "outputPath" => nil,
      "downloadError" => nil,
      "ambiguousSubmission" => false
    )
  end

  def submit(job)
    result = @adapter_factory.call.create(job["request"])
    unless result["remoteID"]
      error = VideoProviderError.new("Video provider accepted the request without returning a task id.")
      return failed_submission(job, error)
    end
    updated = @store.update_job(job["id"], result.merge("ambiguousSubmission" => false))
    updated = download_if_ready(updated)
    { "ok" => true, "job" => updated }
  rescue VideoProviderError => error
    failed_submission(job, error)
  end

  def failed_submission(job, error)
    updated = @store.update_job(
      job["id"],
      "state" => "failed",
      "error" => error.as_json,
      "ambiguousSubmission" => error.ambiguous_submission
    )
    { "ok" => false, "job" => updated, "error" => error.as_json }
  end

  def refresh_job(job)
    next_poll = job["nextPollAt"].to_s
    return { "ok" => true, "job" => job } if !next_poll.empty? && Time.parse(next_poll) > Time.now
    result = @adapter_factory.call.retrieve(job["remoteID"])
    updated = @store.update_job(job["id"], result.merge("lastPollError" => nil, "nextPollAt" => nil))
    updated = download_if_ready(updated)
    { "ok" => true, "job" => updated }
  rescue VideoProviderError => error
    delay = if error.retry_after.to_s.match?(/\A\d+\z/)
              error.retry_after.to_i
            else
              begin
                [Time.httpdate(error.retry_after.to_s) - Time.now, 0].max
              rescue ArgumentError
                5
              end
            end
    updated = @store.update_job(job["id"], "lastPollError" => error.as_json,
                                "nextPollAt" => (Time.now + [delay, 5].max).utc.iso8601)
    { "ok" => false, "job" => updated, "error" => error.as_json }
  end

  def download_if_ready(job, force: false)
    return job unless job["state"] == "completed"
    return job if job["outputURL"].to_s.empty?
    return job unless force || @store.settings["autoDownload"]
    # 手动重下时要认「文件其实已经被用户删了」这种情况，否则只看 outputPath
    # 非空就返回成功，用户拿到的是一条指向不存在文件的路径。
    existing = job["outputPath"].to_s
    return job unless existing.empty? || (force && !File.exist?(existing))

    path = @adapter_factory.call.download(job["outputURL"], job["remoteID"] || job["id"])
    @store.update_job(job["id"], "outputPath" => path, "downloadError" => nil)
  rescue VideoProviderError => error
    @store.update_job(job["id"], "downloadError" => error.as_json)
  end

  def selected_reference(path)
    expanded = File.expand_path(path.to_s)
    return failure("invalid_reference", "The selected reference image is unavailable.") unless File.file?(expanded)
    extension = File.extname(expanded).downcase
    return failure("invalid_reference", "Choose a PNG, JPEG, or WebP image.") unless %w[.png .jpg .jpeg .webp].include?(extension)
    { "ok" => true, "path" => expanded }
  end

  def matches_filter?(job, filter)
    case filter
    when "draft" then job["state"] == "draft"
    when "active" then ACTIVE_STATES.include?(job["state"])
    when "completed" then job["state"] == "completed"
    when "failed" then job["state"] == "failed"
    else true
    end
  end

  def searchable_text(job)
    [job["title"], job["prompt"], job["model"], job["remoteID"], job["state"]].join("\n")
  end

  def counts(jobs)
    {
      "all" => jobs.length,
      "draft" => jobs.count { |job| job["state"] == "draft" },
      "active" => jobs.count { |job| ACTIVE_STATES.include?(job["state"]) },
      "completed" => jobs.count { |job| job["state"] == "completed" },
      "failed" => jobs.count { |job| job["state"] == "failed" }
    }
  end

  def copy_optional_string(source, destination, key, limit)
    return unless source.key?(key)
    destination[key] = optional_string(source[key], limit)
  end

  def copy_integer(source, destination, key)
    destination[key] = Integer(source[key]) if source.key?(key)
  rescue ArgumentError, TypeError
    nil
  end

  def boolean(value)
    value == true || value.to_s == "true"
  end

  def integer_or(value, fallback)
    Integer(value)
  rescue ArgumentError, TypeError
    fallback.to_i
  end

  def optional_integer(value)
    token = value.to_s.strip
    token.empty? ? nil : Integer(token)
  rescue ArgumentError, TypeError
    nil
  end

  def clipped(value, limit)
    token = value.to_s
    return token.strip if token.bytesize <= limit
    token.byteslice(0, limit).scrub("").strip
  end

  def optional_string(value, limit = 1_000)
    token = clipped(value, limit)
    token.empty? ? nil : token
  end

  def failure(code, message, details = nil)
    error = { "code" => code, "message" => message }
    error["details"] = details if details
    { "ok" => false, "error" => error }
  end
end
