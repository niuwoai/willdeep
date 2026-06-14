#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "net/http"
require "time"
require "uri"

ROOT_DIR = File.expand_path("..", __dir__)
OUT_DIR = File.join(ROOT_DIR, "build", "mobile_gateway_live_readiness")
REPORT_JSON = File.join(OUT_DIR, "report.json")
REPORT_MD = File.join(OUT_DIR, "report.md")
EXPECTED_PROTOCOL = "mobile-gateway.v1"
MAC_BUNDLE_ID = ENV.fetch("MOBILE_GATEWAY_MAC_BUNDLE_ID", "com.willdeep.app")
BASE_URL = ENV.fetch("MOBILE_GATEWAY_DESKTOP_BASE_URL", "http://127.0.0.1:8876").delete_suffix("/")
TOKEN_FILE = ENV.fetch(
  "MOBILE_GATEWAY_DESKTOP_TOKEN_FILE",
  File.join(Dir.home, "Library", "Application Support", MAC_BUNDLE_ID, "MobileGateway", "desktop-token"),
)
TIMEOUT_SECONDS = ENV.fetch("MOBILE_GATEWAY_READINESS_TIMEOUT_SECONDS", "2").to_f

def request_json(method, path, token: nil)
  uri = URI("#{BASE_URL}#{path}")
  http = Net::HTTP.new(uri.host, uri.port, nil)
  http.use_ssl = uri.scheme == "https"
  http.open_timeout = TIMEOUT_SECONDS
  http.read_timeout = TIMEOUT_SECONDS
  request = case method
            when :get then Net::HTTP::Get.new(uri)
            when :post then Net::HTTP::Post.new(uri)
            else raise "unsupported HTTP method: #{method}"
            end
  request["Authorization"] = "Bearer #{token}" if token && !token.empty?
  request["Content-Type"] = "application/json" if method == :post
  request.body = "{}" if method == :post
  response = http.start { |client| client.request(request) }
  body = JSON.parse(response.body)
  [response, body]
end

def health_probe
  response, body = request_json(:get, "/mobile/health")
  data = body.fetch("data", {})
  {
    status: response.is_a?(Net::HTTPSuccess) ? "passed" : "failed",
    status_code: response.code.to_i,
    server_version: data["server_version"] || data["app_version"] || data.dig("version", "version"),
    protocol_version: data["protocol_version"],
    desktop_name: data["desktop_name"],
    pairing_allowed: data["pairing_allowed"],
    error: body["error"],
  }
rescue StandardError => e
  {
    status: "failed",
    status_code: nil,
    server_version: nil,
    protocol_version: nil,
    desktop_name: nil,
    pairing_allowed: nil,
    error: "#{e.class}: #{e.message}",
  }
end

def token_probe
  if File.file?(TOKEN_FILE)
    {
      status: "passed",
      path: TOKEN_FILE,
      present: true,
      byte_count: File.size(TOKEN_FILE),
    }
  else
    {
      status: "failed",
      path: TOKEN_FILE,
      present: false,
      byte_count: 0,
    }
  end
end

def pairing_rotate_probe(token_present)
  return { status: "skipped", error: "desktop token file is missing" } unless token_present

  token = File.read(TOKEN_FILE).strip
  return { status: "failed", error: "desktop token file is empty" } if token.empty?

  response, body = request_json(:post, "/mobile/pairing/rotate", token: token)
  payload = body.dig("data", "pairing_payload") || {}
  status = response.is_a?(Net::HTTPSuccess) && payload["pairing_token"].to_s != "" ? "passed" : "failed"
  {
    status: status,
    status_code: response.code.to_i,
    base_url: payload["base_url"],
    protocol_version: payload["protocol_version"],
    desktop_name: payload["desktop_name"],
    expires_at: payload["expires_at"],
    pairing_token_present: payload["pairing_token"].to_s != "",
    error: body["error"],
  }
rescue StandardError => e
  { status: "failed", error: "#{e.class}: #{e.message}" }
end

def acceptance_evidence(health, token, rotate)
  [
    {
      key: "mac_gateway_health",
      status: health[:status],
      evidence: health[:status] == "passed" ? "Public /mobile/health is reachable." : health[:error].to_s,
    },
    {
      key: "desktop_token_file",
      status: token[:status],
      evidence: token[:present] ? "Default desktop token file exists." : "Default desktop token file is missing.",
    },
    {
      key: "desktop_pairing_rotate",
      status: rotate[:status],
      evidence: rotate[:status] == "passed" ? "Desktop-authenticated pairing rotate produced a fresh payload." : rotate[:error].to_s,
    },
    {
      key: "protocol_version",
      status: health[:protocol_version] == EXPECTED_PROTOCOL ? "passed" : "failed",
      evidence: "Expected #{EXPECTED_PROTOCOL}, observed #{health[:protocol_version] || "missing"}.",
    },
    {
      key: "pairing_allowed",
      status: health[:pairing_allowed] == true ? "passed" : "failed",
      evidence: "pairing_allowed=#{health[:pairing_allowed].nil? ? "missing" : health[:pairing_allowed]}.",
    },
  ]
end

def next_actions(health, token, rotate)
  actions = []
  actions << "Open WillDeep on the Mac, enable Settings > Mobile Gateway, and start the gateway." unless health[:status] == "passed"
  actions << "Keep WillDeep running so it writes the desktop token file for Android live acceptance." unless token[:present]
  actions << "Allow new device pairing in Settings > Mobile Gateway." unless health[:pairing_allowed] == true
  actions << "Use the Refresh Pairing button if pairing rotate is failing after the gateway is running." unless rotate[:status] == "passed"
  actions << "Run `ruby scripts/mobile_gateway_live_readiness.rb` again, then run Android `ruby scripts/mobile_gateway_live_acceptance.rb`." if actions.any?
  actions
end

def write_reports(report)
  FileUtils.mkdir_p(OUT_DIR)
  File.write(REPORT_JSON, JSON.pretty_generate(report) + "\n")
  lines = [
    "# Mobile Gateway Live Readiness",
    "",
    "- Generated at: `#{report[:generated_at]}`",
    "- Status: `#{report[:status]}`",
    "- Base URL: `#{report[:base_url]}`",
    "- Desktop token file: `#{report.dig(:desktop_token_file, :present) ? "present" : "missing"}`",
    "- Health reachable: `#{report.dig(:health, :status) == "passed" ? "yes" : "no"}`",
    "- Server version: `#{report.dig(:health, :server_version) || "unknown"}`",
    "- Protocol version: `#{report.dig(:health, :protocol_version) || "unknown"}`",
    "- Pairing allowed: `#{report.dig(:health, :pairing_allowed).nil? ? "unknown" : report.dig(:health, :pairing_allowed)}`",
    "- Pairing rotate: `#{report.dig(:pairing_rotate, :status)}`",
    "",
    "## Acceptance Evidence",
    "",
    "| Requirement | Status | Evidence |",
    "| --- | --- | --- |",
  ]
  report[:acceptance_evidence].each do |item|
    lines << "| `#{item[:key]}` | `#{item[:status]}` | #{item[:evidence].to_s.gsub("|", "\\|")} |"
  end
  unless report[:next_actions].empty?
    lines << ""
    lines << "## Next Actions"
    lines << ""
    report[:next_actions].each { |action| lines << "- #{action}" }
  end
  lines << ""
  File.write(REPORT_MD, lines.join("\n"))
end

health = health_probe
token = token_probe
rotate = pairing_rotate_probe(token[:present])
evidence = acceptance_evidence(health, token, rotate)
status = evidence.all? { |item| item[:status] == "passed" } ? "passed" : "failed"
report = {
  generated_at: Time.now.utc.iso8601,
  status: status,
  base_url: BASE_URL,
  expected_protocol: EXPECTED_PROTOCOL,
  health: health,
  desktop_token_file: token,
  pairing_rotate: rotate,
  acceptance_evidence: evidence,
  next_actions: next_actions(health, token, rotate),
}

write_reports(report)
puts "Wrote #{REPORT_JSON}"
puts "Wrote #{REPORT_MD}"
exit(status == "passed" ? 0 : 1)
