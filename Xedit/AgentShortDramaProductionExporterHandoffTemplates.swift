//
//  AgentShortDramaProductionExporterHandoffTemplates.swift
//  WillDeep
//
//  Embedded handoff templates shipped inside the production package:
//  the media API environment example and the Ruby media script.
//

import Foundation

extension AgentShortDramaProductionExporter {
    static func mediaAPIEnvExampleTemplate() -> String {
        """
        # WillDeep short-drama media API environment example.
        # Copy this file to a private location, fill values there, and do not commit secrets.
        #
        # Usage example:
        #   set -a
        #   source /path/to/private-media-api.env
        #   set +a
        #   ruby ruby-media-script-template.rb

        # Required for ruby-media-script-template.rb to call a third-party submit endpoint.
        WILLDEEP_MEDIA_API_URL=

        # Optional bearer token. Keep real tokens out of git, chats, logs, and exported packages.
        WILLDEEP_MEDIA_API_TOKEN=

        # Optional submit method and extra request headers for provider-specific gateways.
        # Keep secrets in your private env file; this exported example intentionally stays blank.
        WILLDEEP_MEDIA_API_METHOD=POST
        WILLDEEP_MEDIA_EXTRA_HEADERS_JSON=

        # Request body format. Use json for API gateways that accept paths/data URLs;
        # use multipart when the provider requires source image / mask file uploads.
        WILLDEEP_MEDIA_REQUEST_FORMAT=json
        WILLDEEP_MEDIA_REQUEST_PRESET=
        WILLDEEP_MEDIA_SOURCE_IMAGE_FIELD=image
        WILLDEEP_MEDIA_MASK_FIELD=mask
        WILLDEEP_REPLICATE_EXTRA_INPUT_JSON=

        # Optional provider label written back into media-import-manifest-template.json.
        # Supported App providers include: replicate, some_im, kling, skill, local, unknown.
        WILLDEEP_MEDIA_PROVIDER=skill

        # Optional model, version, or workflow name sent to the API and written back to the manifest.
        WILLDEEP_MEDIA_MODEL=

        # HTTP timeout for submit, poll, and media download requests.
        WILLDEEP_MEDIA_TIMEOUT_SECONDS=300

        # Optional async polling support. Use {id} when the submit response only returns a job id.
        # Leave empty if the submit response includes poll_url, status_url, urls.get, or direct media.
        WILLDEEP_MEDIA_POLL_URL_TEMPLATE=

        # Optional async cancel support. Use {id} when the submit response only returns a job id.
        # Leave empty if the submit response includes cancel_url, urls.cancel, or links.cancel.
        WILLDEEP_MEDIA_CANCEL_URL_TEMPLATE=

        # Set to 1 when the script should only submit remote async jobs and let WillDeep
        # track pending remote_task_id/status_url entries via import_pending_tasks.
        WILLDEEP_MEDIA_SUBMIT_ONLY=0

        # Set to 1 to retry only manifest items that still carry last_error from a failed run.
        WILLDEEP_MEDIA_ONLY_FAILED=0

        # Optional: set to 1 to include source_image_data_url / mask_data_url in the API JSON body.
        # Keep this off for large files or providers that expect multipart uploads instead.
        WILLDEEP_MEDIA_EMBED_LOCAL_FILES=0

        # Optional WillDeep task metadata for providers that return only an id.
        # Example: custom/images/status. Keep empty unless the provider requires a non-default route.
        WILLDEEP_MEDIA_STATUS_ENDPOINT_SUFFIX=
        WILLDEEP_MEDIA_CANCEL_ENDPOINT_SUFFIX=

        WILLDEEP_MEDIA_POLL_INTERVAL_SECONDS=5
        WILLDEEP_MEDIA_POLL_MAX_ATTEMPTS=120
        WILLDEEP_MEDIA_DONE_STATUSES=succeeded,completed,complete,finished,done,success
        WILLDEEP_MEDIA_FAILED_STATUSES=failed,canceled,cancelled,error,timeout

        # Provider preset: Replicate Predictions (async).
        # Keep the real token in a private env file, never in this exported package.
        # WILLDEEP_MEDIA_PROVIDER=replicate
        # WILLDEEP_MEDIA_API_URL=https://api.replicate.com/v1/predictions
        # WILLDEEP_MEDIA_API_TOKEN=<private token>
        # WILLDEEP_MEDIA_MODEL=<replicate version or workflow id>
        # WILLDEEP_MEDIA_REQUEST_PRESET=replicate_predictions
        # WILLDEEP_MEDIA_SUBMIT_ONLY=1
        # WILLDEEP_MEDIA_EMBED_LOCAL_FILES=1
        # WILLDEEP_REPLICATE_EXTRA_INPUT_JSON={"num_outputs":1}

        # Provider preset: some.im image/video gateway.
        # WILLDEEP_MEDIA_PROVIDER=some_im
        # WILLDEEP_MEDIA_API_URL=https://some.im/<your async media route>
        # WILLDEEP_MEDIA_API_TOKEN=<private token>
        # WILLDEEP_MEDIA_STATUS_ENDPOINT_SUFFIX=<optional status route suffix>
        # WILLDEEP_MEDIA_CANCEL_ENDPOINT_SUFFIX=<optional cancel route suffix>

        # Existing source-image / mask tasks:
        # - image_inpaint / image_erase items forward source_image_path and mask_path.
        # - image_upscale items forward source_image_path.
        # Choose multipart for upload APIs, or EMBED_LOCAL_FILES=1 for JSON data URLs.
        """
    }

    static func rubyMediaScriptTemplate() -> String {
        """
        #!/usr/bin/env ruby
        # frozen_string_literal: true

        # WillDeep short-drama media generation handoff template.
        #
        # Usage:
        #   1. Copy this file or edit it in place.
        #   2. Put provider credentials in environment variables, not in this file.
        #   3. Generate selected items into ./outputs using each item's file_path.
        #   4. Ask WillDeep Agent to call:
        #      import_media_manifest(manifest_path: "<this folder>/media-import-manifest-template.json")
        #
        # This template is intentionally conservative: it does not call a real API
        # until you fill in submit_media_job. That keeps exported production packages
        # free of secrets and provider-specific assumptions.
        #
        # Provider preset: Replicate Predictions
        #   WILLDEEP_MEDIA_PROVIDER=replicate
        #   WILLDEEP_MEDIA_API_URL=https://api.replicate.com/v1/predictions
        #   WILLDEEP_MEDIA_MODEL=<replicate version or workflow id>
        #   WILLDEEP_MEDIA_REQUEST_PRESET=replicate_predictions
        #   WILLDEEP_MEDIA_EMBED_LOCAL_FILES=1
        #   WILLDEEP_MEDIA_SUBMIT_ONLY=1
        #
        # Provider preset: some.im image/video gateway
        #   WILLDEEP_MEDIA_PROVIDER=some_im
        #   WILLDEEP_MEDIA_API_URL=https://some.im/<your async media route>
        #   WILLDEEP_MEDIA_STATUS_ENDPOINT_SUFFIX=<optional status route suffix>
        #   WILLDEEP_MEDIA_CANCEL_ENDPOINT_SUFFIX=<optional cancel route suffix>
        #
        # Existing source-image / mask tasks
        #   image_inpaint / image_erase items forward source_image_path and mask_path.
        #   image_upscale items forward source_image_path.

        require "json"
        require "net/http"
        require "uri"
        require "fileutils"
        require "base64"
        require "cgi"
        require "csv"
        require "securerandom"

        ROOT = File.expand_path(__dir__)
        PACKAGE_PATH = File.join(ROOT, "production-package.json")
        MANIFEST_PATH = File.join(ROOT, "media-import-manifest-template.json")
        REVIEW_QUEUE_PATH = File.join(ROOT, "production-review-queue.csv")
        GAP_REPORT_PATH = File.join(ROOT, "production-gap-report.json")
        OUTPUT_DIR = File.join(ROOT, "outputs")
        WIDGET_PREVIEW_PATH = File.join(ROOT, "widget-preview.html")

        package = JSON.parse(File.read(PACKAGE_PATH))
        manifest = JSON.parse(File.read(MANIFEST_PATH))
        FileUtils.mkdir_p(OUTPUT_DIR)

        provider_label = ENV["WILLDEEP_MEDIA_PROVIDER"]
        manifest["provider"] = provider_label if provider_label && !provider_label.empty?
        manifest["model"] = ENV["WILLDEEP_MEDIA_MODEL"] if ENV["WILLDEEP_MEDIA_MODEL"] && !ENV["WILLDEEP_MEDIA_MODEL"].empty?

        def http_request(uri, request)
          Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
            http.read_timeout = Integer(ENV.fetch("WILLDEEP_MEDIA_TIMEOUT_SECONDS", "300"))
            http.request(request)
          end
        end

        def bearer_token
          token = ENV["WILLDEEP_MEDIA_API_TOKEN"]
          token && !token.empty? ? token : nil
        end

        def authenticated_get(uri)
          request = Net::HTTP::Get.new(uri)
          token = bearer_token
          request["Authorization"] = "Bearer #{token}" if token
          apply_extra_headers!(request)
          request
        end

        def extra_headers
          raw = ENV.fetch("WILLDEEP_MEDIA_EXTRA_HEADERS_JSON", "").strip
          return {} if raw.empty?

          parsed = JSON.parse(raw)
          raise "WILLDEEP_MEDIA_EXTRA_HEADERS_JSON must be a JSON object" unless parsed.is_a?(Hash)

          parsed
            .transform_keys(&:to_s)
            .transform_values(&:to_s)
            .reject { |key, value| key.strip.empty? || value.strip.empty? }
        end

        def apply_extra_headers!(request)
          extra_headers.each do |key, value|
            request[key] = value
          end
          request
        end

        def submit_request_for(uri)
          method = ENV.fetch("WILLDEEP_MEDIA_API_METHOD", "POST").strip.upcase
          klass = case method
                  when "POST" then Net::HTTP::Post
                  when "PUT" then Net::HTTP::Put
                  when "PATCH" then Net::HTTP::Patch
                  else
                    raise "Unsupported WILLDEEP_MEDIA_API_METHOD=#{method}; use POST, PUT, or PATCH"
                  end
          klass.new(uri)
        end

        def env_list(name, fallback)
          ENV.fetch(name, fallback).split(",").map { |value| value.strip.downcase }.reject(&:empty?)
        end

        def download_bytes(url)
          uri = URI(url)
          response = http_request(uri, authenticated_get(uri))
          raise "download failed: #{response.code} #{response.body}" unless response.is_a?(Net::HTTPSuccess)
          response.body
        end

        def parse_json_body(response)
          JSON.parse(response.body)
        rescue JSON::ParserError
          nil
        end

        def nested_value(object, *paths)
          paths.each do |path|
            value = path.reduce(object) do |cursor, key|
              if cursor.is_a?(Hash)
                cursor[key] || cursor[key.to_s]
              elsif cursor.is_a?(Array) && key.is_a?(Integer)
                cursor[key]
              end
            end
            return value if value
          end
          nil
        end

        def media_urls_from(value)
          case value
          when String
            value.start_with?("http://", "https://") ? [value] : []
          when Array
            value.flat_map { |entry| media_urls_from(entry) }
          when Hash
            keys = %w[url media_url result_url output_url image_url video_url download_url artifact_url file_url]
            direct = keys.flat_map { |key| media_urls_from(value[key] || value[key.to_sym]) }
            nested = %w[output outputs result results data artifacts files media images videos].flat_map do |key|
              media_urls_from(value[key] || value[key.to_sym])
            end
            direct + nested
          else
            []
          end
        end

        def extract_media_outputs(response)
          content_type = response["Content-Type"].to_s.downcase
          if content_type.start_with?("image/", "video/", "application/octet-stream")
            return [{ bytes: response.body, source_url: nil }]
          end

          parsed = parse_json_body(response)
          return [] unless parsed

          urls = media_urls_from(parsed).uniq
          outputs = urls.map { |url| { bytes: download_bytes(url), source_url: url } }
          return outputs unless outputs.empty?

          bytes = extract_media_bytes(response)
          bytes && !bytes.empty? ? [{ bytes: bytes, source_url: nil }] : []
        end

        def extract_media_bytes(response)
          content_type = response["Content-Type"].to_s.downcase
          return response.body if content_type.start_with?("image/", "video/", "application/octet-stream")

          parsed = parse_json_body(response)
          return nil unless parsed

          media_url = media_urls_from(parsed).first || nested_value(
            parsed,
            ["url"],
            ["media_url"],
            ["result_url"],
            ["output_url"],
            ["image_url"],
            ["video_url"],
            ["download_url"],
            ["artifact_url"],
            ["file_url"],
            ["image"],
            ["video"],
            ["output"],
            ["output", 0],
            ["output", "url"],
            ["result", "url"],
            ["result", 0, "url"],
            ["data", "url"],
            ["data", 0, "url"],
            ["data", "output"],
            ["data", "output", 0],
            ["outputs", 0, "url"],
            ["artifacts", 0, "url"],
            ["files", 0, "url"]
          )
          return download_bytes(media_url) if media_url.to_s.start_with?("http://", "https://")

          b64 = nested_value(
            parsed,
            ["b64_json"],
            ["image_base64"],
            ["data", "b64_json"],
            ["data", 0, "b64_json"],
            ["output", "b64_json"]
          )
          return Base64.decode64(b64) if b64.to_s.strip.length.positive?

          nil
        end

        def async_status(parsed)
          nested_value(parsed, ["status"], ["state"], ["data", "status"], ["data", "state"], ["prediction", "status"])
        end

        def async_job_id(parsed)
          nested_value(parsed, ["id"], ["prediction_id"], ["task_id"], ["job_id"], ["data", "id"], ["data", "task_id"])
        end

        def async_poll_url(parsed)
          explicit_url = nested_value(
            parsed,
            ["poll_url"],
            ["status_url"],
            ["urls", "get"],
            ["links", "self"],
            ["self"],
            ["data", "poll_url"],
            ["data", "status_url"],
            ["data", "urls", "get"]
          )
          return explicit_url if explicit_url.to_s.start_with?("http://", "https://")

          template = ENV["WILLDEEP_MEDIA_POLL_URL_TEMPLATE"]
          job_id = async_job_id(parsed)
          return nil unless template && !template.empty? && job_id

          template.gsub("{id}", URI.encode_www_form_component(job_id.to_s))
        end

        def async_cancel_url(parsed)
          explicit_url = nested_value(
            parsed,
            ["cancel_url"],
            ["cancelUrl"],
            ["urls", "cancel"],
            ["links", "cancel"],
            ["cancel"],
            ["data", "cancel_url"],
            ["data", "cancelUrl"],
            ["data", "urls", "cancel"],
            ["data", "links", "cancel"]
          )
          return explicit_url if explicit_url.to_s.start_with?("http://", "https://")

          template = ENV["WILLDEEP_MEDIA_CANCEL_URL_TEMPLATE"]
          job_id = async_job_id(parsed)
          return nil unless template && !template.empty? && job_id

          template.gsub("{id}", URI.encode_www_form_component(job_id.to_s))
        end

        def annotate_remote_job!(item, response)
          parsed = parse_json_body(response)
          return unless parsed

          job_id = async_job_id(parsed)
          poll_url = async_poll_url(parsed)
          cancel_url = async_cancel_url(parsed)
          provider = ENV["WILLDEEP_MEDIA_PROVIDER"]
          model = ENV["WILLDEEP_MEDIA_MODEL"]
          status_endpoint_suffix = ENV["WILLDEEP_MEDIA_STATUS_ENDPOINT_SUFFIX"]
          cancel_endpoint_suffix = ENV["WILLDEEP_MEDIA_CANCEL_ENDPOINT_SUFFIX"]
          item["remote_task_id"] ||= job_id if job_id
          item["status_url"] ||= poll_url if poll_url
          item["cancel_url"] ||= cancel_url if cancel_url
          item["provider"] ||= provider if provider && !provider.empty?
          item["model"] ||= model if model && !model.empty?
          item["status_endpoint_suffix"] ||= status_endpoint_suffix if status_endpoint_suffix && !status_endpoint_suffix.empty?
          item["cancel_endpoint_suffix"] ||= cancel_endpoint_suffix if cancel_endpoint_suffix && !cancel_endpoint_suffix.empty?
        end

        def truthy_env?(name)
          %w[1 true yes on].include?(ENV.fetch(name, "").strip.downcase)
        end

        def pending_remote_item?(item)
          item["remote_task_id"].to_s.strip.length.positive? || item["status_url"].to_s.strip.length.positive?
        end

        def should_process_item?(item)
          return true unless truthy_env?("WILLDEEP_MEDIA_ONLY_FAILED")

          item["last_error"].to_s.strip != ""
        end

        def load_review_queue
          return [] unless File.exist?(REVIEW_QUEUE_PATH)

          CSV.read(REVIEW_QUEUE_PATH, headers: true).map(&:to_h)
        end

        def write_review_queue(rows)
          return if rows.empty?

          headers = rows.flat_map(&:keys).uniq
          CSV.open(REVIEW_QUEUE_PATH, "w", write_headers: true, headers: headers) do |csv|
            rows.each { |row| csv << headers.map { |header| row[header] } }
          end
        end

        def review_item_id_for(item)
          item["review_item_id"] || item["reviewItemID"] || item["review_item"] || item["review_id"]
        end

        def mark_review_queue_item!(rows, review_item_id, status:, artifact_path: nil)
          id = review_item_id.to_s.strip
          return false if id.empty?

          row = rows.find { |candidate| candidate["review_item_id"].to_s == id }
          return false unless row

          row["review_status"] = status
          row["status"] = status if row.key?("status")
          if artifact_path && !artifact_path.empty?
            existing = row["artifact_paths"].to_s.split("|").map(&:strip).reject(&:empty?)
            existing << artifact_path unless existing.include?(artifact_path)
            row["artifact_paths"] = existing.join("|")
          end
          true
        end

        def local_path_for(item, key)
          raw = item[key].to_s.strip
          return nil if raw.empty?

          raw.start_with?("/") ? raw : File.expand_path(raw, ROOT)
        end

        def mime_type_for(path)
          case File.extname(path.to_s).downcase
          when ".jpg", ".jpeg" then "image/jpeg"
          when ".png" then "image/png"
          when ".webp" then "image/webp"
          when ".gif" then "image/gif"
          when ".mp4" then "video/mp4"
          when ".mov" then "video/quicktime"
          else "application/octet-stream"
          end
        end

        def data_url_for(path)
          return nil unless path && File.file?(path)

          "data:#{mime_type_for(path)};base64,#{Base64.strict_encode64(File.binread(path))}"
        end

        def request_format
          ENV.fetch("WILLDEEP_MEDIA_REQUEST_FORMAT", "json").strip.downcase
        end

        def request_preset
          ENV.fetch("WILLDEEP_MEDIA_REQUEST_PRESET", "").strip.downcase
        end

        def replicate_predictions_body(body)
          version = body.delete(:model) || ENV["WILLDEEP_MEDIA_MODEL"]
          input = {}
          prompt = body.delete(:prompt)
          input["prompt"] = prompt if prompt && !prompt.to_s.empty?
          source_image = body.delete(:source_image_data_url)
          mask_image = body.delete(:mask_data_url)
          input["image"] = source_image if source_image && !source_image.to_s.empty?
          input["mask"] = mask_image if mask_image && !mask_image.to_s.empty?
          extra_input = ENV.fetch("WILLDEEP_REPLICATE_EXTRA_INPUT_JSON", "").strip
          input.merge!(JSON.parse(extra_input)) unless extra_input.empty?
          {
            version: version,
            input: input.delete_if { |_key, value| value.nil? || value == "" }
          }.delete_if { |_key, value| value.nil? || value == "" || value == {} }
        end

        def multipart_name(value)
          value.to_s.gsub('"', "%22").delete("\r\n")
        end

        def multipart_field_name(env_name, fallback)
          value = ENV.fetch(env_name, "").strip
          value.empty? ? fallback : value
        end

        def append_multipart_field(parts, boundary, name, value)
          return if value.nil? || value == ""

          parts << "--#{boundary}\r\n"
          parts << "Content-Disposition: form-data; name=\"#{multipart_name(name)}\"\r\n\r\n"
          parts << value.to_s
          parts << "\r\n"
        end

        def append_multipart_file(parts, boundary, name, path)
          return unless path && File.file?(path)

          parts << "--#{boundary}\r\n"
          parts << "Content-Disposition: form-data; name=\"#{multipart_name(name)}\"; filename=\"#{multipart_name(File.basename(path))}\"\r\n"
          parts << "Content-Type: #{mime_type_for(path)}\r\n\r\n"
          parts << File.binread(path)
          parts << "\r\n"
        end

        def assign_request_body!(request, body, source_image_path, mask_path)
          case request_format
          when "json"
            if truthy_env?("WILLDEEP_MEDIA_EMBED_LOCAL_FILES")
              body[:source_image_data_url] = data_url_for(source_image_path)
              body[:mask_data_url] = data_url_for(mask_path)
              body.delete_if { |_key, value| value.nil? || value == "" }
            end
            body = replicate_predictions_body(body) if request_preset == "replicate_predictions"
            request["Content-Type"] = "application/json"
            request.body = JSON.dump(body)
          when "multipart", "form-data"
            boundary = "willdeep-#{SecureRandom.hex(12)}"
            parts = []
            body.each do |key, value|
              append_multipart_field(parts, boundary, key, value)
            end
            append_multipart_file(
              parts,
              boundary,
              multipart_field_name("WILLDEEP_MEDIA_SOURCE_IMAGE_FIELD", "image"),
              source_image_path
            )
            append_multipart_file(
              parts,
              boundary,
              multipart_field_name("WILLDEEP_MEDIA_MASK_FIELD", "mask"),
              mask_path
            )
            parts << "--#{boundary}--\r\n"
            request["Content-Type"] = "multipart/form-data; boundary=#{boundary}"
            request.body = parts.join
          else
            raise "Unsupported WILLDEEP_MEDIA_REQUEST_FORMAT=#{request_format}; use json or multipart"
          end
        end

        def poll_for_media(initial_response, item)
          parsed = parse_json_body(initial_response)
          return nil unless parsed

          poll_url = async_poll_url(parsed)
          return nil unless poll_url

          done_statuses = env_list("WILLDEEP_MEDIA_DONE_STATUSES", "succeeded,completed,complete,finished,done,success")
          failed_statuses = env_list("WILLDEEP_MEDIA_FAILED_STATUSES", "failed,canceled,cancelled,error,timeout")
          attempts = Integer(ENV.fetch("WILLDEEP_MEDIA_POLL_MAX_ATTEMPTS", "120"))
          interval = Float(ENV.fetch("WILLDEEP_MEDIA_POLL_INTERVAL_SECONDS", "5"))

          attempts.times do |attempt|
            sleep interval if attempt.positive?
            uri = URI(poll_url)
            response = http_request(uri, authenticated_get(uri))
            raise "media poll failed: #{response.code} #{response.body}" unless response.is_a?(Net::HTTPSuccess)

            annotate_remote_job!(item, response)
            outputs = extract_media_outputs(response)
            return outputs unless outputs.empty?

            poll_json = parse_json_body(response)
            status = async_status(poll_json).to_s.downcase
            raise "media job failed with status #{status}: #{response.body}" if failed_statuses.include?(status)
            next if status.empty? || done_statuses.include?(status)
          end

          nil
        end

        def submit_media_job(item, package)
          api_url = ENV["WILLDEEP_MEDIA_API_URL"]
          unless api_url && !api_url.empty?
            warn "WILLDEEP_MEDIA_API_URL is not set; skipping #{item["file_path"]}."
            return nil
          end

          uri = URI(api_url)
          request = submit_request_for(uri)
          token = bearer_token
          request["Authorization"] = "Bearer #{token}" if token
          source_image_path = local_path_for(item, "source_image_path")
          mask_path = local_path_for(item, "mask_path")
          body = {
            model: ENV["WILLDEEP_MEDIA_MODEL"],
            prompt: item["prompt"],
            kind: item["kind"],
            task_title: item["task_title"],
            review_item_id: review_item_id_for(item),
            suggested_action: item["suggested_action"],
            source_image_path: source_image_path,
            mask_path: mask_path,
            project_title: package.dig("project", "title") || package["title"],
            project_id: item["project_id"],
            episode_id: item["episode_id"],
            shot_id: item["shot_id"],
            asset_kind: item["asset_kind"],
            asset_id: item["asset_id"]
          }.delete_if { |_key, value| value.nil? || value == "" }
          assign_request_body!(request, body, source_image_path, mask_path)
          apply_extra_headers!(request)

          response = http_request(uri, request)
          raise "media api failed: #{response.code} #{response.body}" unless response.is_a?(Net::HTTPSuccess)
          annotate_remote_job!(item, response)
          outputs = extract_media_outputs(response)
          return outputs unless outputs.empty?
          return nil if truthy_env?("WILLDEEP_MEDIA_SUBMIT_ONLY")

          poll_for_media(response, item)
        end

        def output_extension_for(url, fallback_path)
          ext = File.extname(URI(url.to_s).path) if url && !url.to_s.empty?
          ext = File.extname(fallback_path.to_s) if ext.to_s.empty?
          ext.to_s.empty? ? ".bin" : ext
        end

        def sibling_output_path(relative_path, index, source_url)
          base = File.join(File.dirname(relative_path), File.basename(relative_path, File.extname(relative_path)))
          ext = output_extension_for(source_url, relative_path)
          "#{base}-candidate-#{index + 1}#{ext}"
        end

        def duplicate_manifest_item(item, relative_path, index, source_url)
          clone = item.dup
          clone["file_path"] = relative_path
          clone["task_title"] = "#{item["task_title"] || item["kind"] || "media"} candidate #{index + 1}"
          clone["source_url"] = source_url if source_url
          clone
        end

        def pending_job_info(item, relative_path)
          {
            "file_path" => relative_path,
            "task_title" => item["task_title"],
            "provider" => item["provider"],
            "kind" => item["kind"],
            "model" => item["model"],
            "remote_task_id" => item["remote_task_id"],
            "status_url" => item["status_url"],
            "cancel_url" => item["cancel_url"],
            "status_endpoint_suffix" => item["status_endpoint_suffix"],
            "cancel_endpoint_suffix" => item["cancel_endpoint_suffix"],
            "project_id" => item["project_id"],
            "episode_id" => item["episode_id"],
            "shot_id" => item["shot_id"],
            "asset_kind" => item["asset_kind"],
            "asset_id" => item["asset_id"],
            "review_item_id" => item["review_item_id"]
          }.delete_if { |_key, value| value.to_s.strip.empty? }
        end

        def failed_job_info(item, relative_path, error)
          item["last_error"] = "#{error.class}: #{error.message}"
          {
            "file_path" => relative_path,
            "task_title" => item["task_title"],
            "provider" => item["provider"],
            "kind" => item["kind"],
            "model" => item["model"],
            "project_id" => item["project_id"],
            "episode_id" => item["episode_id"],
            "shot_id" => item["shot_id"],
            "asset_kind" => item["asset_kind"],
            "asset_id" => item["asset_id"],
            "review_item_id" => item["review_item_id"],
            "error_class" => error.class.name,
            "error_message" => error.message
          }.delete_if { |_key, value| value.to_s.strip.empty? }
        end

        def write_widget_preview(package, generated, pending, failed, skipped, review_queue_updates)
          project = package.fetch("project", {})
          episodes = project.fetch("episodes", [])
          shot_count = episodes.sum { |episode| episode.fetch("shots", []).length }
          title = project["title"] || package["title"] || "Short Drama"
          import_pending = pending.length.positive?
          handoff_context = [
            "<ruby-media-script-handoff>",
            "action: ruby_media_script_widget_preview",
            "package_directory: #{PACKAGE_DIR}",
            "manifest_path: #{MANIFEST_PATH}",
            "widget_preview_path: #{WIDGET_PREVIEW_PATH}",
            "review_queue_path: #{REVIEW_QUEUE_PATH}",
            "gap_report_path: #{GAP_REPORT_PATH}",
            "generated_count: #{generated.length}",
            "pending_count: #{pending.length}",
            "failed_count: #{failed.length}",
            "review_queue_updates: #{review_queue_updates}",
            "dry_run_import_tool: import_media_manifest",
            "dry_run_import_arguments: package_directory=#{PACKAGE_DIR}, dry_run=true, import_pending_tasks=#{import_pending}",
            "submit_import_tool: import_media_manifest",
            "submit_import_arguments: package_directory=#{PACKAGE_DIR}, dry_run=false, import_pending_tasks=#{import_pending}",
            "review_queue_import_tool: short_drama_import_review_csv",
            "review_queue_import_arguments: file_path=#{REVIEW_QUEUE_PATH}, dry_run=#{review_queue_updates.zero?}",
            "widget_tool: show_widget",
            "widget_arguments: title=短剧制作预览, html_path=#{WIDGET_PREVIEW_PATH}, source_label=ruby-media-script-template, source_path=#{WIDGET_PREVIEW_PATH}, package_directory=#{PACKAGE_DIR}, recommended_tool=import_media_manifest, recommended_arguments=package_directory=#{PACKAGE_DIR}, dry_run=true, import_pending_tasks=#{import_pending}",
            "</ruby-media-script-handoff>"
          ].join("\n")
          generated_items = generated.first(80).map { |path| "<li><code>#{CGI.escapeHTML(path)}</code></li>" }.join("\n")
          pending_items = pending.first(80).map do |job|
            labels = [
              job["provider"],
              job["kind"],
              job["model"],
              job["remote_task_id"] && "remote=#{job["remote_task_id"]}",
              job["status_url"] && "status_url=#{job["status_url"]}",
              job["cancel_url"] && "cancel_url=#{job["cancel_url"]}",
              job["status_endpoint_suffix"] && "status_endpoint_suffix=#{job["status_endpoint_suffix"]}",
              job["cancel_endpoint_suffix"] && "cancel_endpoint_suffix=#{job["cancel_endpoint_suffix"]}"
            ].compact.join(" · ")
            anchor = [
              job["project_id"] && "project=#{job["project_id"]}",
              job["episode_id"] && "episode=#{job["episode_id"]}",
              job["shot_id"] && "shot=#{job["shot_id"]}",
              job["asset_kind"] && "asset=#{job["asset_kind"]}/#{job["asset_id"]}",
              job["review_item_id"] && "review_item=#{job["review_item_id"]}"
            ].compact.join(" · ")
            %(<li><code>#{CGI.escapeHTML(job["file_path"].to_s)}</code><div class="muted">#{CGI.escapeHTML(labels.empty? ? "pending remote task" : labels)}</div><div class="muted">#{CGI.escapeHTML(anchor)}</div></li>)
          end.join("\n")
          failed_items = failed.first(80).map do |job|
            error = [job["error_class"], job["error_message"]].compact.join(": ")
            anchor = [
              job["project_id"] && "project=#{job["project_id"]}",
              job["episode_id"] && "episode=#{job["episode_id"]}",
              job["shot_id"] && "shot=#{job["shot_id"]}",
              job["asset_kind"] && "asset=#{job["asset_kind"]}/#{job["asset_id"]}",
              job["review_item_id"] && "review_item=#{job["review_item_id"]}"
            ].compact.join(" · ")
            %(<li><code>#{CGI.escapeHTML(job["file_path"].to_s)}</code><div class="muted">#{CGI.escapeHTML(error.empty? ? "failed media job" : error)}</div><div class="muted">#{CGI.escapeHTML(anchor)}</div></li>)
          end.join("\n")
          skipped_items = skipped.first(80).map { |path| "<li><code>#{CGI.escapeHTML(path)}</code></li>" }.join("\n")
          review_queue_actions = load_review_queue
            .select { |row| row["review_status"].to_s != "resolved" || row["recommended_tool"].to_s != "" }
            .first(20)
            .map do |row|
              title = [row["episode_order"] && "EP#{row["episode_order"]}", row["shot_order"] && "S#{row["shot_order"]}", row["review_title"]].compact.join(" · ")
              fields = [
                row["kind"] && "kind=#{row["kind"]}",
                row["severity"] && "severity=#{row["severity"]}",
                row["recommended_tool"] && "recommended_tool=#{row["recommended_tool"]}",
                row["recommended_arguments"] && "recommended_arguments=#{row["recommended_arguments"]}",
                row["open_review_tasks_arguments"] && "open_review_tasks_arguments=#{row["open_review_tasks_arguments"]}",
                row["resolve_review_arguments"] && "resolve_review_arguments=#{row["resolve_review_arguments"]}"
              ].compact.reject(&:empty?)
              action_context = [
                "<short-drama-review-queue-action>",
                "action: fix_production_review_queue_item",
                "project_id: #{row["project_id"]}",
                "episode_id: #{row["episode_id"]}",
                "shot_id: #{row["shot_id"]}",
                "review_item_id: #{row["review_item_id"]}",
                "review_kind: #{row["kind"]}",
                "review_severity: #{row["severity"]}",
                "review_title: #{row["review_title"]}",
                "selected_artifact_path: #{row["selected_image_path"]}",
                "recommended_tool: #{row["recommended_tool"]}",
                "recommended_arguments: #{row["recommended_arguments"]}",
                "open_review_tasks_tool: short_drama_open_media_tasks",
                "open_review_tasks_arguments: #{row["open_review_tasks_arguments"]}",
                "resolve_review_tool: short_drama_resolve_review_item",
                "resolve_review_arguments: #{row["resolve_review_arguments"]}",
                "</short-drama-review-queue-action>"
              ].join("\\n")
              action_prompt = "请处理这个制作包修复队列检查项。请优先调用 recommended_tool 与 recommended_arguments；如果需要确认同一检查项的异步任务状态，先调用 open_review_tasks_tool；确认产物已经修复问题后，再调用 resolve_review_tool 关闭检查项。\\n\\n#{action_context}"
              action_button = %(<button onclick="sendPrompt(#{JSON.dump(action_prompt)})">交给聊天处理</button>)
              %(<li><strong>#{CGI.escapeHTML(title.empty? ? row["review_item_id"].to_s : title)}</strong><div class="muted"><code>#{CGI.escapeHTML(fields.join(" · "))}</code></div><div class="actions">#{action_button}</div></li>)
            end.join("\n")
          video_exts = [".mp4", ".mov", ".m4v", ".webm"]
          image_exts = [".png", ".jpg", ".jpeg", ".webp", ".gif", ".tif", ".tiff", ".heic"]
          missing_image_count = episodes.sum { |episode| episode.fetch("shots", []).count { |shot| shot["selectedArtifactPath"].to_s.empty? } }
          missing_video_count = episodes.sum { |episode| episode.fetch("shots", []).count { |shot| shot.fetch("artifactPaths", []).none? { |path| video_exts.include?(File.extname(path.to_s).downcase) } } }
          project_id_for_batch = project["id"]
          scoped_episode_id = episodes.length == 1 ? episodes.first["id"] : nil
          episode_clause = scoped_episode_id ? "、episode_id=#{scoped_episode_id}" : ""
          scope_label = scoped_episode_id ? "这一集" : "这个制作包范围"
          batch_actions = []
          batch_actions << %(<button onclick="sendPrompt(#{JSON.dump("请审查#{scope_label}内所有分镜的连续性和产物一致性。请读取 project_id=#{project_id_for_batch}#{episode_clause} 的短剧上下文，重点检查人物设定、服装道具、场景空间、镜头衔接、画风、主图/视频产物和 prompt 是否一致；发现具体问题时调用 short_drama_upsert_review_item 写回对应分镜，kind 可用 continuity、prompt、redraw、erase、upscale、reshoot 或 note；已经确认无问题的分镜不用写入。")})">批量检查连续性</button>)
          if missing_image_count.positive?
            batch_actions << %(<button onclick="sendPrompt(#{JSON.dump("请为#{scope_label}批量补齐缺主图分镜。请先调用 short_drama_generate_batch_media，并传入 project_id=#{project_id_for_batch}#{episode_clause}、kind=image_generation、target_filter=missing、dry_run=true 预检；确认范围合理后再用 dry_run=false、target_filter=missing 正式提交，提交后打开媒体任务侧栏。")})">批量补主图 #{missing_image_count}</button>)
          end
          if missing_video_count.positive?
            batch_actions << %(<button onclick="sendPrompt(#{JSON.dump("请为#{scope_label}批量补齐缺视频分镜。请先调用 short_drama_generate_batch_media，并传入 project_id=#{project_id_for_batch}#{episode_clause}、kind=video_generation、target_filter=missing、dry_run=true 预检；确认范围合理后再用 dry_run=false、target_filter=missing 正式提交，视频生成应优先复用分镜主图作为首帧参考，提交后打开媒体任务侧栏。")})">批量补视频 #{missing_video_count}</button>)
          end
          review_item_action = lambda do |shot, project_id, episode_id, shot_id, selected|
            item = shot.fetch("reviewItems", []).find { |candidate| candidate["status"] != "resolved" }
            return nil unless item

            review_item_id = review_item_id_for(item)
            kind = item["kind"].to_s
            suggested_action = item["suggested_action"].to_s.empty? ? item["detail"].to_s : item["suggested_action"].to_s
            base_arguments = "project_id=#{project_id}, episode_id=#{episode_id}, shot_id=#{shot_id}, review_item_id=#{review_item_id}"
            regenerate_arguments = "#{base_arguments}, kind=image_generation"
            recommendation = case kind
                             when "redraw"
                               if selected.to_s.empty?
                                 {
                                   hint: "当前分镜没有可编辑主图，请先调用 short_drama_generate_shot_media，并传入 review_item_id。",
                                   tool: "short_drama_generate_shot_media",
                                   arguments: regenerate_arguments
                                 }
                               else
                                 {
                                   hint: "请调用 short_drama_open_image_editor，传入 operation=inpaint、artifact_path 和 review_item_id。",
                                   tool: "short_drama_open_image_editor",
                                   arguments: "#{base_arguments}, operation=inpaint, artifact_path=#{selected}"
                                 }
                               end
                             when "erase"
                               if selected.to_s.empty?
                                 {
                                   hint: "当前分镜没有可擦除主图，请先调用 short_drama_generate_shot_media，并传入 review_item_id。",
                                   tool: "short_drama_generate_shot_media",
                                   arguments: regenerate_arguments
                                 }
                               else
                                 {
                                   hint: "请调用 short_drama_open_image_editor，传入 operation=erase、artifact_path 和 review_item_id。",
                                   tool: "short_drama_open_image_editor",
                                   arguments: "#{base_arguments}, operation=erase, artifact_path=#{selected}"
                                 }
                               end
                             when "upscale"
                               if selected.to_s.empty?
                                 {
                                   hint: "当前分镜没有可放大主图，请先调用 short_drama_generate_shot_media，并传入 review_item_id。",
                                   tool: "short_drama_generate_shot_media",
                                   arguments: regenerate_arguments
                                 }
                               else
                                 {
                                   hint: "请调用 short_drama_upscale_shot_artifact，传入 artifact_path 和 review_item_id。",
                                   tool: "short_drama_upscale_shot_artifact",
                                   arguments: "#{base_arguments}, artifact_path=#{selected}"
                                 }
                               end
                             when "reshoot"
                               {
                                 hint: "请调用 short_drama_generate_shot_media，传入 kind=image_generation 和 review_item_id。",
                                 tool: "short_drama_generate_shot_media",
                                 arguments: regenerate_arguments
                               }
                             when "prompt"
                               {
                                 hint: "请先修正分镜 prompt；如果需要重新生成，请调用 short_drama_generate_shot_media 并传入 review_item_id。",
                                 tool: "short_drama_generate_shot_media",
                                 arguments: regenerate_arguments,
                                 secondary_tool: "short_drama_upsert_review_item",
                                 secondary_arguments: "#{base_arguments}, kind=prompt, status=doing"
                               }
                             else
                               {
                                 hint: "请先分析这条检查项；如果需要生成、编辑、放大或关闭检查项，必须沿用 review_item_id。",
                                 tool: "short_drama_open_media_tasks",
                                 arguments: "#{base_arguments}, scope=review_item"
                               }
                             end
            context = [
              "<short-drama-review-item-action>",
              "action: fix_production_review_item",
              "project_id: #{project_id}",
              "episode_id: #{episode_id}",
              "shot_id: #{shot_id}",
              "shot_title: #{shot.fetch("title", "Untitled")}",
              "selected_artifact_path: #{selected}",
              "review_item_id: #{review_item_id}",
              "review_kind: #{kind}",
              "review_severity: #{item["severity"]}",
              "review_title: #{item["title"]}",
              "review_detail: #{item["detail"]}",
              "suggested_action: #{suggested_action}",
              "recommended_tool: #{recommendation[:tool]}",
              "recommended_arguments: #{recommendation[:arguments]}",
              "review_tasks_tool: short_drama_open_media_tasks",
              "review_tasks_arguments: project_id=#{project_id}, episode_id=#{episode_id}, shot_id=#{shot_id}, scope=review_item, review_item_id=#{review_item_id}",
              "refresh_review_tasks_tool: short_drama_refresh_media_tasks",
              "refresh_review_tasks_arguments: project_id=#{project_id}, episode_id=#{episode_id}, shot_id=#{shot_id}, scope=review_item, review_item_id=#{review_item_id}",
              "resolve_review_tool: short_drama_resolve_review_item",
              "resolve_review_arguments: project_id=#{project_id}, episode_id=#{episode_id}, shot_id=#{shot_id}, item_id=#{review_item_id}"
            ]
            if recommendation[:secondary_arguments]
              context << "secondary_tool: #{recommendation[:secondary_tool] || recommendation[:tool]}"
              context << "secondary_arguments: #{recommendation[:secondary_arguments]}"
            end
            context << "</short-drama-review-item-action>"
            prompt = "请处理这个制作包分镜的具体检查项，并把后续媒体任务锚定到同一个 review_item_id。\n#{recommendation[:hint]}\n任务完成并确认修复后，请调用 short_drama_resolve_review_item，并传入 item_id 或 review_item_id。\n如需查看这条检查项的任务流水，请先调用 short_drama_open_media_tasks(scope=review_item, review_item_id=...)，需要同步最新异步状态时再调用 short_drama_refresh_media_tasks，参数相同。\n\n#{context.join("\n")}"
            %(<button onclick="sendPrompt(#{JSON.dump(prompt)})">处理检查项</button>)
          end
          timeline_items = episodes.sort_by { |episode| episode.fetch("order", 0) }.flat_map do |episode|
            episode.fetch("shots", []).sort_by { |shot| shot.fetch("order", 0) }.map do |shot|
              artifacts = shot.fetch("artifactPaths", [])
              selected = shot["selectedArtifactPath"]
              image_count = artifacts.count { |path| image_exts.include?(File.extname(path.to_s).downcase) }
              video_count = artifacts.count { |path| video_exts.include?(File.extname(path.to_s).downcase) }
              video_path = artifacts.find { |path| video_exts.include?(File.extname(path.to_s).downcase) }
              open_reviews = shot.fetch("reviewItems", []).count { |item| item["status"] != "resolved" }
              image_badge = selected.to_s.empty? ? '<span class="badge warn">缺主图</span>' : '<span class="badge ok">主图就绪</span>'
              video_badge = video_count.zero? ? '<span class="badge warn">缺视频</span>' : %(<span class="badge ok">视频 #{video_count}</span>)
              review_badge = open_reviews.zero? ? '<span class="badge ok">检查项清零</span>' : %(<span class="badge warn">未解决 #{open_reviews}</span>)
              project_id = project["id"]
              episode_id = episode["id"]
              shot_id = shot["id"]
              actions = []
              actions << %(<button onclick="sendPrompt(#{JSON.dump("请打开这个短剧分镜的媒体任务侧栏，并优先刷新同一范围的异步任务状态。请调用 short_drama_open_media_tasks，并传入 project_id=#{project_id}、episode_id=#{episode_id}、shot_id=#{shot_id}、scope=shot；如果需要拉取最新 some.im / Replicate / 第三方异步状态，请随后调用 short_drama_refresh_media_tasks，参数相同。")})">查看任务</button>)
              actions << %(<button onclick="sendPrompt(#{JSON.dump("请审查这个短剧分镜现有产物是否符合连续性和分镜意图。请读取 project_id=#{project_id}、episode_id=#{episode_id}、shot_id=#{shot_id} 的分镜上下文，重点检查人物设定、服装道具、场景空间、画风、主图/视频产物和 prompt 是否一致；发现具体问题时调用 short_drama_upsert_review_item 写回这个分镜，kind 可用 continuity、prompt、redraw、erase、upscale、reshoot 或 note。")})">检查连续性</button>)
              if image_count > 1
                base_arguments = "project_id=#{project_id}, episode_id=#{episode_id}, shot_id=#{shot_id}"
                image_choice_context = [
                  "<short-drama-production-image-choice>",
                  "action: show_image_choice_widget",
                  "project_id: #{project_id}",
                  "episode_id: #{episode_id}",
                  "shot_id: #{shot_id}",
                  "artifact_count: #{artifacts.count}",
                  "recommended_tool: short_drama_show_image_choice_widget",
                  "recommended_arguments: #{base_arguments}",
                  "post_select_video_tool: generate_video_from_image",
                  "post_select_video_arguments: #{base_arguments}, image_path=...",
                  "post_select_edit_tool: short_drama_open_image_editor",
                  "post_select_edit_arguments: #{base_arguments}, artifact_path=..., operation=inpaint",
                  "post_select_erase_tool: short_drama_open_image_editor",
                  "post_select_erase_arguments: #{base_arguments}, artifact_path=..., operation=erase",
                  "post_select_upscale_tool: short_drama_upscale_shot_artifact",
                  "post_select_upscale_arguments: #{base_arguments}, artifact_path=...",
                  "post_select_resolve_review_tool: short_drama_resolve_review_item",
                  "post_select_resolve_review_arguments: #{base_arguments}, item_id=...",
                  "</short-drama-production-image-choice>"
                ]
                prompt = "请打开这个短剧分镜的候选图选择器。请调用 short_drama_show_image_choice_widget，并传入 project_id=#{project_id}、episode_id=#{episode_id}、shot_id=#{shot_id}。打开后我会在网页组件里选择主图；选择完成后请读取候选图组件输出的 post_select_* 字段继续衔接视频、蒙版重绘、擦除、放大或检查项关闭。\n\n#{image_choice_context.join("\n")}"
                actions << %(<button onclick="sendPrompt(#{JSON.dump(prompt)})">选主图</button>)
              end
              unless selected.to_s.empty?
                actions << %(<button onclick="sendPrompt(#{JSON.dump("请打开这个短剧分镜主图做蒙版重绘。请调用 short_drama_open_image_editor，并传入 project_id=#{project_id}、episode_id=#{episode_id}、shot_id=#{shot_id}、operation=inpaint、artifact_path=#{selected}。打开后我会在右侧图片蒙版面板框选区域并提交 Replicate 或 some.im 编辑任务。")})">蒙版编辑</button>)
                actions << %(<button onclick="sendPrompt(#{JSON.dump("请打开这个短剧分镜主图做蒙版擦除。请调用 short_drama_open_image_editor，并传入 project_id=#{project_id}、episode_id=#{episode_id}、shot_id=#{shot_id}、operation=erase、artifact_path=#{selected}。打开后我会在右侧图片蒙版面板框选需要擦除的区域并提交 Replicate 或 some.im 编辑任务。")})">擦除区域</button>)
                actions << %(<button onclick="sendPrompt(#{JSON.dump("请放大这个短剧分镜主图。请调用 short_drama_upscale_shot_artifact，并传入 project_id=#{project_id}、episode_id=#{episode_id}、shot_id=#{shot_id}、artifact_path=#{selected}。提交后请打开或提示我查看媒体任务侧栏。")})">放大主图</button>)
              end
              unless video_path.to_s.empty?
                video_context = [
                  "<short-drama-production-video-action>",
                  "action: review_shot_video_artifact",
                  "project_id: #{project_id}",
                  "episode_id: #{episode_id}",
                  "shot_id: #{shot_id}",
                  "video_path: #{video_path}",
                  "open_shot_tasks_tool: short_drama_open_media_tasks",
                  "open_shot_tasks_arguments: project_id=#{project_id}, episode_id=#{episode_id}, shot_id=#{shot_id}, scope=shot",
                  "refresh_shot_tasks_tool: short_drama_refresh_media_tasks",
                  "refresh_shot_tasks_arguments: project_id=#{project_id}, episode_id=#{episode_id}, shot_id=#{shot_id}, scope=shot",
                  "storyboard_widget_tool: short_drama_show_storyboard_widget",
                  "storyboard_widget_arguments: project_id=#{project_id}, episode_id=#{episode_id}",
                  "</short-drama-production-video-action>"
                ]
                prompt = "请基于这个制作包分镜视频产物继续审片。请检查视频是否符合分镜提示词、人物/服装/场景连续性、运动节奏、镜头衔接和画面稳定性；若发现问题，请调用 short_drama_upsert_review_item 写回这个分镜。需要查看任务流水时，请优先使用下面的 open/refresh 结构化参数。\n\n#{video_context.join("\n")}"
                actions << %(<button onclick="sendPrompt(#{JSON.dump(prompt)})">审片视频</button>)
              end
              if selected.to_s.empty?
                actions << %(<button onclick="sendPrompt(#{JSON.dump("请为这个短剧分镜补主图。请先调用 short_drama_generate_shot_media，并传入 project_id=#{project_id}、episode_id=#{episode_id}、shot_id=#{shot_id}、kind=image_generation、dry_run=true 预检；确认 prompt/model/endpoint 合理后，再用 dry_run=false 正式提交。提交后打开媒体任务侧栏。")})">补主图</button>)
              end
              if video_count.zero?
                actions << %(<button onclick="sendPrompt(#{JSON.dump("请为这个短剧分镜补视频。请先调用 short_drama_generate_shot_media，并传入 project_id=#{project_id}、episode_id=#{episode_id}、shot_id=#{shot_id}、kind=video_generation、dry_run=true 预检；如果缺少主图，请先补主图。确认参考图、prompt/model/endpoint 合理后，再用 dry_run=false 正式提交。提交后打开媒体任务侧栏。")})">补视频</button>)
              end
              if open_reviews.positive?
                actions << review_item_action.call(shot, project_id, episode_id, shot_id, selected)
              end
              action_html = actions.empty? ? "" : %(<div class="actions">#{actions.join}</div>)
              %(<div class="shot-row"><div class="shot-title">EP#{episode.fetch("order", 0)} · S#{shot.fetch("order", 0)} #{CGI.escapeHTML(shot.fetch("title", "Untitled"))}</div><div class="muted">#{CGI.escapeHTML(shot.fetch("status", "planned"))} · #{CGI.escapeHTML(shot["summary"].to_s.empty? ? "无摘要" : shot["summary"])}</div><div class="badges">#{image_badge}#{video_badge}#{review_badge}</div>#{action_html}</div>)
            end
          end.first(80).join("\n")
          project_id_for_batch = project["id"]
          episode_items = episodes.sort_by { |episode| episode.fetch("order", 0) }.map do |episode|
            shots = episode.fetch("shots", []).sort_by { |shot| shot.fetch("order", 0) }
            episode_id = episode["id"]
            missing_images = shots.count { |shot| shot["selectedArtifactPath"].to_s.empty? }
            missing_videos = shots.count { |shot| shot.fetch("artifactPaths", []).none? { |path| video_exts.include?(File.extname(path.to_s).downcase) } }
            open_reviews = shots.sum { |shot| shot.fetch("reviewItems", []).count { |item| item["status"] != "resolved" } }
            image_badge = missing_images.zero? ? '<span class="badge ok">主图齐备</span>' : %(<span class="badge warn">缺主图 #{missing_images}</span>)
            video_badge = missing_videos.zero? ? '<span class="badge ok">视频齐备</span>' : %(<span class="badge warn">缺视频 #{missing_videos}</span>)
            review_badge = open_reviews.zero? ? '<span class="badge ok">检查项清零</span>' : %(<span class="badge warn">未解决 #{open_reviews}</span>)
            actions = []
            actions << %(<button onclick="sendPrompt(#{JSON.dump("请打开这一集的短剧媒体任务侧栏，并优先刷新同一范围的异步任务状态。请调用 short_drama_open_media_tasks，并传入 project_id=#{project_id_for_batch}、episode_id=#{episode_id}、scope=episode；如果需要拉取最新 some.im / Replicate / 第三方异步状态，请随后调用 short_drama_refresh_media_tasks，参数相同。")})">查看任务</button>)
            actions << %(<button onclick="sendPrompt(#{JSON.dump("请打开这一集的短剧网页分镜板。请调用 short_drama_show_storyboard_widget，并传入 project_id=#{project_id_for_batch}、episode_id=#{episode_id}。")})">本集分镜板</button>)
            actions << %(<button onclick="sendPrompt(#{JSON.dump("请审查这一集所有分镜的连续性和产物一致性。请读取 project_id=#{project_id_for_batch}、episode_id=#{episode_id} 的短剧上下文，重点检查人物设定、服装道具、场景空间、镜头衔接、画风、主图/视频产物和 prompt 是否一致；发现具体问题时调用 short_drama_upsert_review_item 写回对应分镜。")})">检查连续性</button>)
            if missing_images.positive?
                actions << %(<button onclick="sendPrompt(#{JSON.dump("请为这一集批量补齐缺主图分镜。请先调用 short_drama_generate_batch_media，并传入 project_id=#{project_id_for_batch}、episode_id=#{episode_id}、kind=image_generation、target_filter=missing、dry_run=true 预检；确认范围合理后再用 dry_run=false、target_filter=missing 正式提交，提交后打开媒体任务侧栏。")})">补主图 #{missing_images}</button>)
            end
            if missing_videos.positive?
                actions << %(<button onclick="sendPrompt(#{JSON.dump("请为这一集批量补齐缺视频分镜。请先调用 short_drama_generate_batch_media，并传入 project_id=#{project_id_for_batch}、episode_id=#{episode_id}、kind=video_generation、target_filter=missing、dry_run=true 预检；确认范围合理后再用 dry_run=false、target_filter=missing 正式提交，视频生成应优先复用分镜主图作为首帧参考，提交后打开媒体任务侧栏。")})">补视频 #{missing_videos}</button>)
            end
            summary = episode["summary"].to_s.empty? ? "无摘要" : episode["summary"].to_s
            %(<div class="shot-row"><div class="shot-title">EP#{episode.fetch("order", 0)} · #{CGI.escapeHTML(episode.fetch("title", "Untitled"))}</div><div class="muted">#{shots.length} 个分镜 · #{CGI.escapeHTML(summary)}</div><div class="badges"><span class="badge">分镜 #{shots.length}</span>#{image_badge}#{video_badge}#{review_badge}</div><div class="actions">#{actions.join}</div></div>)
          end.first(80).join("\n")
          asset_items = []
          [
            ["人物", "character", project.fetch("characters", [])],
            ["场景", "scene", project.fetch("scenes", [])],
          ].each do |kind_label, asset_kind, assets|
            assets.each do |asset|
              asset_id = asset["id"]
              next if asset_id.to_s.empty?
              name = CGI.escapeHTML(asset.fetch("name", "未命名资产"))
              summary = asset["description"].to_s.empty? ? asset["visualPrompt"].to_s : asset["description"].to_s
              reference_paths = asset.fetch("referenceImagePaths", [])
              reference_count = reference_paths.length
              reference_badge = reference_count.zero? ? '<span class="badge warn">缺参考图</span>' : %(<span class="badge ok">参考图 #{reference_count}</span>)
              actions = []
              asset_tasks_context = [
                "<short-drama-asset-widget-action>",
                "action: inspect_asset_media_tasks",
                "project_id: #{project_id_for_batch}",
                "asset_kind: #{asset_kind}",
                "asset_kind_label: #{kind_label}",
                "asset_id: #{asset_id}",
                "asset_name: #{asset.fetch("name", "未命名资产")}",
                "open_tasks_tool: short_drama_open_media_tasks",
                "open_tasks_arguments: project_id=#{project_id_for_batch}, scope=asset, asset_kind=#{asset_kind}, asset_id=#{asset_id}",
                "refresh_tasks_tool: short_drama_refresh_media_tasks",
                "refresh_tasks_arguments: project_id=#{project_id_for_batch}, scope=asset, asset_kind=#{asset_kind}, asset_id=#{asset_id}",
                "generate_asset_reference_tool: short_drama_generate_asset_media",
                "generate_asset_reference_dry_run_arguments: project_id=#{project_id_for_batch}, asset_kind=#{asset_kind}, asset_id=#{asset_id}, dry_run=true",
                "generate_asset_reference_arguments: project_id=#{project_id_for_batch}, asset_kind=#{asset_kind}, asset_id=#{asset_id}, dry_run=false",
                "</short-drama-asset-widget-action>"
              ]
              actions << %(<button onclick="sendPrompt(#{JSON.dump("请打开这个短剧#{kind_label}资产的媒体任务侧栏，并刷新同一资产的异步任务状态。请先调用 short_drama_open_media_tasks，再按需调用 short_drama_refresh_media_tasks，两个工具都使用 project_id=#{project_id_for_batch}、scope=asset、asset_kind=#{asset_kind}、asset_id=#{asset_id}。如果参考图不足，也可以继续调用 short_drama_generate_asset_media 为该资产生成更多参考图。\n\n#{asset_tasks_context.join("\n")}")})">查看任务</button>)
              if reference_count.zero?
                actions << %(<button onclick="sendPrompt(#{JSON.dump("请为这个短剧#{kind_label}资产生成参考图。请先调用 short_drama_generate_asset_media，并传入 project_id=#{project_id_for_batch}、asset_kind=#{asset_kind}、asset_id=#{asset_id}、dry_run=true 预检；确认 prompt/model/endpoint 合理后，再用 dry_run=false 正式提交。提交后打开媒体任务侧栏，完成后参考图应回填到该资产。")})">生成参考图</button>)
              else
                reference_path = reference_paths.first
                context = "<short-drama-asset-widget-action>\\naction: %{action}\\nproject_id: #{project_id_for_batch}\\nasset_kind: #{asset_kind}\\nasset_kind_label: #{kind_label}\\nasset_id: #{asset_id}\\nasset_name: #{asset.fetch("name", "未命名资产")}\\nimage_path: #{reference_path}\\nopen_tasks_tool: short_drama_open_media_tasks\\nopen_tasks_arguments: project_id=#{project_id_for_batch}, scope=asset, asset_kind=#{asset_kind}, asset_id=#{asset_id}\\nrefresh_tasks_tool: short_drama_refresh_media_tasks\\nrefresh_tasks_arguments: project_id=#{project_id_for_batch}, scope=asset, asset_kind=#{asset_kind}, asset_id=#{asset_id}\\ngenerate_asset_reference_tool: short_drama_generate_asset_media\\ngenerate_asset_reference_dry_run_arguments: project_id=#{project_id_for_batch}, asset_kind=#{asset_kind}, asset_id=#{asset_id}, dry_run=true\\ngenerate_asset_reference_arguments: project_id=#{project_id_for_batch}, asset_kind=#{asset_kind}, asset_id=#{asset_id}, dry_run=false\\n</short-drama-asset-widget-action>"
                actions << %(<button onclick="sendPrompt(#{JSON.dump("请打开这个短剧#{kind_label}资产的参考图做蒙版重绘。请调用 open_image_editor，并传入 image_path=#{reference_path}、operation=inpaint、project_id=#{project_id_for_batch}、asset_kind=#{asset_kind}、asset_id=#{asset_id}。打开后我会在右侧图片蒙版面板框选区域并提交 Replicate 或 some.im 编辑任务，完成产物应继续绑定到该资产参考图。\\n\\n#{context % { action: "open_asset_reference_editor" }}")})">编辑参考图</button>)
                actions << %(<button onclick="sendPrompt(#{JSON.dump("请打开这个短剧#{kind_label}资产的参考图做蒙版擦除。请调用 open_image_editor，并传入 image_path=#{reference_path}、operation=erase、project_id=#{project_id_for_batch}、asset_kind=#{asset_kind}、asset_id=#{asset_id}。打开后我会在右侧图片蒙版面板框选需要移除的区域并提交 Replicate 或 some.im 擦除任务，完成产物应继续绑定到该资产参考图。\\n\\n#{context % { action: "erase_asset_reference" }}")})">擦除区域</button>)
                actions << %(<button onclick="sendPrompt(#{JSON.dump("请放大这个短剧#{kind_label}资产的参考图。请调用 upscale_image，并传入 image_path=#{reference_path}、project_id=#{project_id_for_batch}、asset_kind=#{asset_kind}、asset_id=#{asset_id}。提交后打开或提示我查看该资产媒体任务侧栏，完成产物应继续绑定到该资产参考图。\\n\\n#{context % { action: "upscale_asset_reference" }}")})">放大参考图</button>)
              end
              asset_items << %(<div class="shot-row"><div class="shot-title">#{CGI.escapeHTML(kind_label)} · #{name}</div><div class="muted">#{CGI.escapeHTML(summary.empty? ? "无描述" : summary)}</div><div class="badges">#{reference_badge}</div><div class="actions">#{actions.join}</div></div>)
            end
          end
          asset_items = asset_items.first(80).join("\n")
          failed_analysis_prompt = "请分析这个制作包 Ruby 媒体脚本的 failed jobs：读取脚本 JSON 输出中的 failed/failed_paths，以及 media-import-manifest-template.json 里带 last_error 的 item；请优先使用下面 <ruby-media-script-handoff> 中的 dry_run_import_arguments 让失败项登记为媒体任务，再按 status_message、review_item_id、project/episode/shot/asset 锚点判断是重跑 ruby-media-script-template.rb、修正 API 参数，还是读取 production-gap-report.json 重新排产。\n\n#{handoff_context}"
          retry_failed_prompt = "请只重跑这个制作包里的失败媒体项：设置 WILLDEEP_MEDIA_ONLY_FAILED=1，并复用 media-api.env.example 中的第三方 API 环境变量运行 ruby-media-script-template.rb。运行后请优先使用下面 <ruby-media-script-handoff> 中的 dry_run_import_arguments 预检，确认 last_error 已被成功项清理、pending 远端任务可登记、outputs 可导入；确认无误后再使用 submit_import_arguments 正式导入并打开媒体任务侧栏。\n\n#{handoff_context}"
          html = <<~HTML
            <!doctype html>
            <html>
            <head>
              <meta charset="utf-8">
              <meta name="viewport" content="width=device-width, initial-scale=1">
              <title>#{CGI.escapeHTML(title)} · 制作预览</title>
              <style>
                :root { color-scheme: light dark; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
                body { margin: 0; padding: 18px; background: var(--bg, #111); color: var(--fg, #f8f8f8); }
                .wrap { max-width: 980px; margin: 0 auto; }
                h1 { margin: 0 0 6px; font-size: 24px; line-height: 1.2; }
                .muted { color: var(--secondary, #8f8f8f); font-size: 13px; }
                .grid { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 10px; margin: 16px 0; }
                .card { border: 1px solid rgba(140, 140, 140, 0.28); border-radius: 8px; padding: 12px; background: rgba(140, 140, 140, 0.10); }
                .num { font-size: 24px; font-weight: 700; }
                .label { color: var(--secondary, #aaa); font-size: 12px; margin-top: 4px; }
                .cols { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; }
                .timeline { display: grid; gap: 8px; margin-top: 10px; }
                .shot-row { border: 1px solid rgba(140, 140, 140, 0.18); border-radius: 6px; padding: 8px; background: rgba(140, 140, 140, 0.07); }
                .shot-title { font-weight: 600; font-size: 13px; }
                .badges { display: flex; flex-wrap: wrap; gap: 6px; margin-top: 6px; }
                .actions { display: flex; flex-wrap: wrap; gap: 6px; margin-top: 8px; }
                .badge { border-radius: 999px; padding: 2px 7px; font-size: 11px; background: rgba(140, 140, 140, 0.16); }
                .badge.warn { background: rgba(245, 166, 35, 0.22); }
                .badge.ok { background: rgba(52, 199, 89, 0.20); }
                ul { margin: 8px 0 0; padding-left: 18px; }
                code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12px; overflow-wrap: anywhere; }
                button { border: 0; border-radius: 6px; padding: 8px 10px; background: var(--accent, #3478f6); color: white; cursor: pointer; }
                @media (max-width: 720px) { .grid, .cols { grid-template-columns: 1fr; } }
              </style>
            </head>
            <body>
              <div class="wrap">
                <h1>#{CGI.escapeHTML(title)}</h1>
                <div class="muted">WillDeep 短剧制作包脚本预览</div>
                <div class="grid">
                  <div class="card"><div class="num">#{episodes.length}</div><div class="label">Episodes</div></div>
                  <div class="card"><div class="num">#{shot_count}</div><div class="label">Shots</div></div>
                  <div class="card"><div class="num">#{generated.length}</div><div class="label">Generated outputs</div></div>
                  <div class="card"><div class="num">#{pending.length}</div><div class="label">Pending remote jobs</div></div>
                  <div class="card"><div class="num">#{failed.length}</div><div class="label">Failed jobs</div></div>
                  <div class="card"><div class="num">#{review_queue_updates}</div><div class="label">Review queue updates</div></div>
                </div>
                <div class="card">
                  <strong>下一步</strong>
                  <p class="muted">在 WillDeep Agent 里先 dry-run，再正式调用 <code>import_media_manifest</code> 导回媒体任务和短剧分镜。若存在 pending remote jobs，请带上 <code>import_pending_tasks: true</code>。</p>
                  <button onclick="sendPrompt(#{JSON.dump("请读取这个制作包，优先使用下面 <ruby-media-script-handoff> 中的 dry_run_import_arguments 先 dry-run；确认无误后使用 submit_import_arguments 导入 outputs 和 pending 远端任务，并打开短剧媒体任务侧栏。\n\n#{handoff_context}")})">交给 Agent 导回</button>
                  <button onclick="sendPrompt(#{JSON.dump("请读取这个制作包的 media-import-manifest-template.json，重点检查 pending remote jobs 的 remote_task_id、status_url、cancel_url、status_endpoint_suffix、cancel_endpoint_suffix；请使用下面 <ruby-media-script-handoff> 中的 dry_run_import_arguments 先预检，确认 pending 任务能进入媒体任务侧栏并可刷新/取消，再用 submit_import_arguments 正式导入。\n\n#{handoff_context}")})">导回异步任务</button>
                  <button onclick="sendPrompt(#{JSON.dump(failed_analysis_prompt)})">分析失败</button>
                  <button onclick="sendPrompt(#{JSON.dump(retry_failed_prompt)})">重跑失败</button>
                  <p class="muted">如果脚本更新了 <code>production-review-queue.csv</code>，请用 <code>short_drama_import_review_csv(file_path)</code> 把 doing/resolved 状态写回短剧检查项。</p>
                  <button onclick="sendPrompt(#{JSON.dump("请导入这个制作包里的 production-review-queue.csv，优先使用下面 <ruby-media-script-handoff> 中的 review_queue_import_arguments；如果 dry_run=true，先检查 review_item_id 和 review_status，再用 short_drama_import_review_csv(file_path=#{REVIEW_QUEUE_PATH}, dry_run=false) 正式写回短剧分镜检查项。\n\n#{handoff_context}")})">回写修复队列</button>
                </div>
                <div class="card">
                  <strong>修复队列推荐动作</strong>
                  <p class="muted"><code>production-review-queue.csv</code> 里的每条未解决检查项都带 <code>recommended_tool</code>、<code>recommended_arguments</code>、任务流水参数和关闭检查项参数；脚本或聊天窗口可按行直接执行。</p>
                  <ul>#{review_queue_actions.empty? ? '<li class="muted">暂无待处理推荐动作</li>' : review_queue_actions}</ul>
                </div>
                <div class="card">
                  <strong>剪辑时间线</strong>
                  <p class="muted"><code>production-timeline.json</code> 已按集和分镜顺序整理主图、视频、图片、prompt 和未解决检查项，可交给短剧 Skill、Ruby 脚本或剪辑脚本继续装配成片。</p>
                  <button onclick="sendPrompt(#{JSON.dump("请读取这个制作包的 production-timeline.json，按集和分镜顺序检查主图、视频产物、缺失镜头和未解决检查项，并给出下一步剪辑/补图/补视频计划；请优先使用下面 <ruby-media-script-handoff> 中的 widget_preview_path、gap_report_path、dry_run_import_arguments 和 submit_import_arguments。\n\n#{handoff_context}")})">按时间线继续</button>
                  <p class="muted"><code>production-gap-report.json</code> 按项目、资产、分集和分镜列出缺参考图、缺主图、缺视频、未解决检查项，并给出补缺工具参数。</p>
                  <button onclick="sendPrompt(#{JSON.dump("请读取这个制作包的 production-gap-report.json，按 missing_asset_reference_count、missing_image_count、missing_video_count 和 open_review_item_count 排出资产参考图、补图、补视频和检查项处理顺序；资产条目里的 linked_shot_ids、linked_shot_image_dry_run_arguments、linked_shot_image_submit_arguments、linked_shot_video_dry_run_arguments、linked_shot_video_submit_arguments 可用于补完人物/场景参考图后优先推进相关分镜；如需提交资产参考图任务，请先使用 assets[].generate_reference_dry_run_arguments 预检，再确认是否使用 assets[].generate_reference_arguments 正式提交；如需提交关联分镜媒体任务，请优先使用对应 linked_shot_*_dry_run_arguments 预检，再确认 submit 参数；如需全局补齐，请使用 batch_actions 里的 dry-run 参数，再确认是否正式调用 short_drama_generate_batch_media；请保留下面 <ruby-media-script-handoff> 作为导入和网页组件回流上下文。\n\n#{handoff_context}")})">按缺口报告排产</button>
                  <p class="muted"><code>production-shot-list.csv</code> 是一镜一行的平面清单；<code>production-review-template.csv</code> 预留审片回写列；<code>production-review-queue.csv</code> 将未解决检查项展开成一条 reviewItem 一行的修复队列。</p>
                  <button onclick="sendPrompt(#{JSON.dump("请读取这个制作包的 production-shot-list.csv、production-review-template.csv 和 production-review-queue.csv，按一镜一行检查主图、视频路径、未解决检查项、summary 和 prompt，输出可执行的审片/剪辑准备清单；如果 production-review-template.csv 已填写，请调用 short_drama_import_review_csv(package_directory=#{PACKAGE_DIR}, dry_run=true) 预检并写回对应分镜 reviewItems；如果 production-review-queue.csv 里有未解决项，请按 kind/severity/suggested_action 排出修复顺序，并优先使用下面 <ruby-media-script-handoff> 中的 review_queue_import_arguments 调用 short_drama_import_review_csv。\n\n#{handoff_context}")})">按 CSV 审片</button>
                  <div class="actions">#{batch_actions.join}</div>
                  <div class="timeline">#{timeline_items.empty? ? '<div class="muted">暂无分镜时间线</div>' : timeline_items}</div>
                </div>
                <div class="card">
                  <strong>分集管理</strong>
                  <p class="muted">按集查看分镜数量、主图/视频缺口和未解决检查项；需要集中处理某一集时，可直接把本集 scope 交回聊天窗口。</p>
                  <div class="timeline">#{episode_items.empty? ? '<div class="muted">暂无分集</div>' : episode_items}</div>
                </div>
                <div class="card">
                  <strong>参考资产</strong>
                  <p class="muted">人物和场景参考图用于保持多分镜角色、服装、道具与空间连续性；缺参考图时可先生成，再继续分镜图或视频。</p>
                  <div class="timeline">#{asset_items.empty? ? '<div class="muted">暂无人物或场景资产</div>' : asset_items}</div>
                </div>
                <div class="cols">
                  <div class="card"><strong>Generated</strong><ul>#{generated_items.empty? ? '<li class="muted">暂无生成产物</li>' : generated_items}</ul></div>
                  <div class="card"><strong>Pending remote jobs</strong><ul>#{pending_items.empty? ? '<li class="muted">暂无远端异步任务</li>' : pending_items}</ul></div>
                  <div class="card"><strong>Failed jobs</strong><ul>#{failed_items.empty? ? '<li class="muted">暂无失败任务</li>' : failed_items}</ul></div>
                  <div class="card"><strong>Skipped</strong><ul>#{skipped_items.empty? ? '<li class="muted">暂无跳过项</li>' : skipped_items}</ul></div>
                </div>
              </div>
            </body>
            </html>
          HTML
          File.write(WIDGET_PREVIEW_PATH, html)
        end

        generated = []
        pending = []
        failed = []
        skipped = []
        review_queue_rows = load_review_queue
        review_queue_updates = 0

        manifest.fetch("items", []).each do |item|
          relative_path = item.fetch("file_path")
          unless should_process_item?(item)
            skipped << relative_path
            next
          end

          output_path = File.join(OUTPUT_DIR, relative_path)
          if File.exist?(output_path)
            item.delete("last_error")
            generated << output_path
            review_queue_updates += 1 if mark_review_queue_item!(
              review_queue_rows,
              review_item_id_for(item),
              status: "resolved",
              artifact_path: output_path
            )
            next
          end

          begin
            outputs = submit_media_job(item, package)
          rescue StandardError => e
            warn "media job failed for #{relative_path}: #{e.class}: #{e.message}"
            failed << failed_job_info(item, relative_path, e)
            next
          end
          if outputs.nil? || outputs.empty?
            if pending_remote_item?(item)
              item.delete("last_error")
              pending << pending_job_info(item, relative_path)
              review_queue_updates += 1 if mark_review_queue_item!(
                review_queue_rows,
                review_item_id_for(item),
                status: "doing"
              )
            else
              skipped << relative_path
            end
            next
          end

          outputs.each_with_index do |output, index|
            candidate_relative_path = index.zero? ? relative_path : sibling_output_path(relative_path, index, output[:source_url])
            candidate_output_path = File.join(OUTPUT_DIR, candidate_relative_path)
            FileUtils.mkdir_p(File.dirname(candidate_output_path))
            File.binwrite(candidate_output_path, output[:bytes])
            item.delete("last_error")
            generated << candidate_output_path
            if index.positive?
              manifest["items"] << duplicate_manifest_item(item, candidate_relative_path, index, output[:source_url])
            end
            review_queue_updates += 1 if mark_review_queue_item!(
              review_queue_rows,
              review_item_id_for(item),
              status: "resolved",
              artifact_path: candidate_output_path
            )
          end
        end

        File.write(MANIFEST_PATH, JSON.pretty_generate(manifest))
        write_review_queue(review_queue_rows) if review_queue_updates.positive?
        write_widget_preview(package, generated, pending, failed, skipped, review_queue_updates)

        puts JSON.pretty_generate(
          manifest_path: MANIFEST_PATH,
          review_queue_path: REVIEW_QUEUE_PATH,
          gap_report_path: GAP_REPORT_PATH,
          output_dir: OUTPUT_DIR,
          widget_preview_path: WIDGET_PREVIEW_PATH,
          generated_count: generated.length,
          pending_count: pending.length,
          failed_count: failed.length,
          skipped_count: skipped.length,
          review_queue_updates: review_queue_updates,
          generated: generated,
          pending: pending,
          pending_paths: pending.map { |job| job["file_path"] },
          failed: failed,
          failed_paths: failed.map { |job| job["file_path"] },
          skipped: skipped,
          dry_run_import_tool: "import_media_manifest",
          dry_run_import_arguments: "package_directory=#{PACKAGE_DIR}, dry_run=true, import_pending_tasks=#{pending.length.positive?}",
          submit_import_tool: "import_media_manifest",
          submit_import_arguments: "package_directory=#{PACKAGE_DIR}, dry_run=false, import_pending_tasks=#{pending.length.positive?}",
          review_queue_import_tool: "short_drama_import_review_csv",
          review_queue_import_arguments: "file_path=#{REVIEW_QUEUE_PATH}, dry_run=#{review_queue_updates.zero?}",
          widget_tool: "show_widget",
          widget_arguments: "title=短剧制作预览, html_path=#{WIDGET_PREVIEW_PATH}, source_label=ruby-media-script-template, source_path=#{WIDGET_PREVIEW_PATH}, package_directory=#{PACKAGE_DIR}, recommended_tool=import_media_manifest, recommended_arguments=package_directory=#{PACKAGE_DIR}, dry_run=true, import_pending_tasks=#{pending.length.positive?}",
          follow_up_note: "After import, read <media-import-follow-up>: completed_image_choice_actions and completed_image_follow_up_actions include selectable images, primary image selection, image-to-video, mask edit, erase, upscale, asset reference binding, and review item resolution.",
          next_step: "In WillDeep Agent, inspect failed before retrying third-party API calls, then read gap_report_path before batch filling missing shots; first call import_media_manifest with dry_run=true and import_pending_tasks=#{pending.length.positive?}; if the preview is correct, call import_media_manifest again with dry_run=false. If review_queue_updates is positive, call short_drama_import_review_csv with review_queue_path. Use show_widget with widget_preview_path to inspect the generated production preview."
        )
        """
    }
}
