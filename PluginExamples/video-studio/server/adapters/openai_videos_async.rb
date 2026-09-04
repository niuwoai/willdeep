# frozen_string_literal: true

require "fileutils"
require "json"
require "net/http"
require "securerandom"
require "uri"

class VideoProviderError < StandardError
  attr_reader :http_status, :code, :retry_after, :ambiguous_submission

  def initialize(message, http_status: nil, code: nil, retry_after: nil, ambiguous_submission: false)
    super(message)
    @http_status = http_status
    @code = code
    @retry_after = retry_after
    @ambiguous_submission = ambiguous_submission
  end

  def as_json
    {
      "message" => message,
      "httpStatus" => http_status,
      "code" => code,
      "retryAfter" => retry_after,
      "ambiguousSubmission" => ambiguous_submission
    }.reject { |_key, value| value.nil? }
  end
end

class OpenAIVideosAsyncAdapter
  MAX_REFERENCE_BYTES = 32 * 1024 * 1024
  MAX_DOWNLOAD_BYTES = 1024 * 1024 * 1024

  def initialize(base_url:, api_key:, output_directory:, open_timeout: 20, read_timeout: 90)
    @base_url = normalize_base_url(base_url)
    @api_key = api_key.to_s.strip
    @output_directory = File.expand_path(output_directory)
    @open_timeout = open_timeout
    @read_timeout = read_timeout
  end

  attr_reader :base_url, :output_directory

  def configured?
    !@api_key.empty?
  end

  def create(request)
    raise VideoProviderError, "Video API key is not configured." unless configured?

    fields, files = multipart_fields(request)
    response = post_multipart(endpoint("/v1/videos"), fields, files)
    begin
      task = parse_task(response)
      raise VideoProviderError, "Video provider accepted the request without returning a task id." unless task["remoteID"]
      task
    rescue VideoProviderError => error
      raise VideoProviderError.new(error.message, ambiguous_submission: true)
    end
  rescue VideoProviderError
    raise
  rescue StandardError => error
    raise VideoProviderError.new(
      "The create request ended without a confirmed response: #{error.class}",
      ambiguous_submission: true
    )
  end

  def retrieve(remote_id)
    id = validate_remote_id(remote_id)
    request = Net::HTTP::Get.new(endpoint("/v1/videos/#{id}"))
    parse_task(request_json(request))
  end

  def download(url, remote_id)
    uri = validate_download_url(url)
    FileUtils.mkdir_p(output_directory)
    filename = "#{safe_filename(remote_id)}.mp4"
    destination = unique_path(File.join(output_directory, filename))
    temporary = "#{destination}.part"
    stream_download(uri, temporary, 0)
    File.rename(temporary, destination)
    destination
  rescue VideoProviderError
    raise
  rescue StandardError => error
    raise VideoProviderError, "Output download failed: #{error.class}"
  ensure
    File.delete(temporary) if defined?(temporary) && File.exist?(temporary)
  end

  private

  def normalize_base_url(value)
    token = value.to_s.strip.sub(%r{/+\z}, "")
    raise VideoProviderError, "Video API base URL is empty." if token.empty?
    uri = URI.parse(token)
    raise VideoProviderError, "Video API base URL must not contain credentials, a query, or a fragment." if uri.userinfo || uri.query || uri.fragment
    local_http = uri.scheme == "http" && %w[localhost 127.0.0.1 ::1].include?(uri.host)
    unless uri.host && (uri.scheme == "https" || local_http)
      raise VideoProviderError, "Video API base URL must use HTTPS (HTTP is allowed only for localhost)."
    end
    token.sub(%r{/v1\z}i, "")
  rescue URI::InvalidURIError
    raise VideoProviderError, "Video API base URL is invalid."
  end

  def endpoint(path)
    URI.parse("#{base_url}#{path}")
  end

  def multipart_fields(request)
    prompt = request["prompt"].to_s.strip
    model = request["model"].to_s.strip
    raise VideoProviderError, "prompt is required" if prompt.empty?
    raise VideoProviderError, "model is required" if model.empty?

    reference = request["referenceImagePath"].to_s.strip
    task = reference.empty? ? "t2va" : "fl2va"
    fields = {
      "model" => model,
      "prompt" => prompt,
      "width" => request["width"].to_i.to_s,
      "height" => request["height"].to_i.to_s,
      "fps" => "24",
      "num_inference_steps" => request["inferenceSteps"].to_i.to_s,
      "extra_params" => JSON.generate(
        "task" => task,
        "duration" => request["duration"].to_i,
        "audio_flow_shift" => 3
      )
    }
    optional_field(fields, "negative_prompt", request["negativePrompt"])
    optional_field(fields, "seed", request["seed"])
    files = reference.empty? ? {} : { "input_reference" => validate_reference(reference) }
    [fields, files]
  end

  def optional_field(fields, key, value)
    token = value.to_s.strip
    fields[key] = token unless token.empty?
  end

  def validate_reference(path)
    expanded = File.expand_path(path)
    raise VideoProviderError, "Reference image does not exist." unless File.file?(expanded)
    raise VideoProviderError, "Reference image is too large." if File.size(expanded) > MAX_REFERENCE_BYTES
    extension = File.extname(expanded).downcase
    raise VideoProviderError, "Reference image must be PNG, JPEG, or WebP." unless %w[.png .jpg .jpeg .webp].include?(extension)
    expanded
  end

  def post_multipart(uri, fields, files)
    boundary = "WillDeepVideoStudio#{SecureRandom.hex(16)}"
    request = Net::HTTP::Post.new(uri)
    request["Authorization"] = "Bearer #{@api_key}"
    request["Accept"] = "application/json"
    request["Content-Type"] = "multipart/form-data; boundary=#{boundary}"
    request.body = multipart_body(boundary, fields, files)
    request_json(request, accepted_statuses: [200, 202], ambiguous_submission: true)
  end

  def multipart_body(boundary, fields, files)
    body = String.new(encoding: Encoding::BINARY)
    fields.each do |name, value|
      body << "--#{boundary}\r\n"
      body << "Content-Disposition: form-data; name=\"#{name}\"\r\n\r\n"
      body << value.to_s.encode(Encoding::UTF_8).b << "\r\n"
    end
    files.each do |name, path|
      body << "--#{boundary}\r\n"
      body << "Content-Disposition: form-data; name=\"#{name}\"; filename=\"#{File.basename(path)}\"\r\n"
      body << "Content-Type: #{mime_type(path)}\r\n\r\n"
      body << File.binread(path) << "\r\n"
    end
    body << "--#{boundary}--\r\n"
    body
  end

  def mime_type(path)
    case File.extname(path).downcase
    when ".png" then "image/png"
    when ".webp" then "image/webp"
    else "image/jpeg"
    end
  end

  def request_json(request, accepted_statuses: nil, ambiguous_submission: false)
    request["Authorization"] ||= "Bearer #{@api_key}"
    request["Accept"] ||= "application/json"
    response = perform(request)
    allowed = accepted_statuses || (200..299)
    handle_http_error(response) unless allowed.include?(response.code.to_i)
    JSON.parse(response.body)
  rescue JSON::ParserError
    raise VideoProviderError.new("Video provider returned invalid JSON.", ambiguous_submission: ambiguous_submission)
  rescue Timeout::Error, EOFError, IOError, SocketError, SystemCallError => error
    raise VideoProviderError.new(
      "Video provider request failed: #{error.class}",
      ambiguous_submission: ambiguous_submission
    )
  end

  def perform(request)
    uri = request.uri
    Net::HTTP.start(
      uri.host,
      uri.port,
      use_ssl: uri.scheme == "https",
      open_timeout: @open_timeout,
      read_timeout: @read_timeout
    ) { |http| http.request(request) }
  end

  def handle_http_error(response)
    parsed = JSON.parse(response.body) rescue {}
    raw_error = parsed.is_a?(Hash) ? parsed["error"] : nil
    message = raw_error.is_a?(Hash) ? (raw_error["message"] || raw_error["code"]) : raw_error
    message = "Video provider HTTP #{response.code}" if message.to_s.strip.empty?
    code = raw_error.is_a?(Hash) ? raw_error["code"] : nil
    retry_after = response["Retry-After"].to_s.strip
    raise VideoProviderError.new(
      redact(message.to_s)[0, 1000],
      http_status: response.code.to_i,
      code: code,
      retry_after: retry_after.empty? ? nil : retry_after
    )
  end

  def parse_task(raw)
    raise VideoProviderError, "Video provider returned a non-object task." unless raw.is_a?(Hash)
    {
      "remoteID" => raw["id"].to_s.empty? ? nil : raw["id"].to_s,
      "state" => normalize_status(raw["status"]),
      "progress" => normalize_progress(raw["progress"]),
      "outputURL" => raw["url"].to_s.empty? ? nil : raw["url"].to_s,
      "error" => raw["error"].nil? ? nil : JSON.parse(redact(JSON.generate(raw["error"]))),
      "providerResponse" => safe_provider_summary(raw)
    }
  end

  def normalize_status(value)
    case value.to_s.downcase
    when "queued", "created", "pending", "submitted" then "queued"
    when "in_progress", "running", "processing", "generating" then "in_progress"
    when "completed", "complete", "succeeded", "success", "done" then "completed"
    when "failed", "failure", "error" then "failed"
    else "queued"
    end
  end

  def redact(value)
    @api_key.empty? ? value : value.gsub(@api_key, "[redacted]")
  end

  def normalize_progress(value)
    [[value.to_i, 0].max, 100].min
  end

  def safe_provider_summary(raw)
    keys = %w[id object status model progress created_at started_at completed_at expires_at seconds size_bytes inference_time_s]
    keys.each_with_object({}) { |key, result| result[key] = raw[key] if raw.key?(key) }
  end

  def validate_remote_id(value)
    token = value.to_s.strip
    raise VideoProviderError, "Remote task id is missing." unless token.match?(/\A[A-Za-z0-9_.:-]{1,200}\z/)
    token
  end

  def validate_download_url(value)
    uri = URI.parse(value.to_s)
    local_http = uri.scheme == "http" && %w[localhost 127.0.0.1 ::1].include?(uri.host)
    unless uri.host && (uri.scheme == "https" || local_http)
      raise VideoProviderError, "Output URL must use HTTPS."
    end
    uri
  rescue URI::InvalidURIError
    raise VideoProviderError, "Output URL is invalid."
  end

  def stream_download(uri, destination, redirects)
    raise VideoProviderError, "Too many output download redirects." if redirects > 4
    redirect = nil
    request = Net::HTTP::Get.new(uri)
    Net::HTTP.start(
      uri.host,
      uri.port,
      use_ssl: uri.scheme == "https",
      open_timeout: @open_timeout,
      read_timeout: @read_timeout
    ) do |http|
      http.request(request) do |response|
        if response.is_a?(Net::HTTPRedirection)
          location = response["Location"]
          raise VideoProviderError, "Output download redirect has no location." if location.to_s.empty?
          redirect = URI.join(uri.to_s, location)
          next
        end
        handle_http_error(response) unless response.is_a?(Net::HTTPSuccess)
        expected = response["Content-Length"].to_i
        raise VideoProviderError, "Output video is larger than 1 GiB." if expected > MAX_DOWNLOAD_BYTES
        written = 0
        File.open(destination, "wb") do |file|
          response.read_body do |chunk|
            written += chunk.bytesize
            raise VideoProviderError, "Output video exceeded the 1 GiB limit." if written > MAX_DOWNLOAD_BYTES
            file.write(chunk)
          end
        end
      end
    end
    stream_download(validate_download_url(redirect.to_s), destination, redirects + 1) if redirect
  end

  def safe_filename(value)
    token = value.to_s.gsub(/[^A-Za-z0-9_.-]+/, "-").sub(/\A-+/, "")[0, 120]
    token.empty? ? "video-#{Time.now.to_i}" : token
  end

  def unique_path(candidate)
    return candidate unless File.exist?(candidate)
    stem = File.basename(candidate, File.extname(candidate))
    extension = File.extname(candidate)
    directory = File.dirname(candidate)
    index = 2
    loop do
      path = File.join(directory, "#{stem}-#{index}#{extension}")
      return path unless File.exist?(path)
      index += 1
    end
  end
end
