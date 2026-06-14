#!/usr/bin/env ruby
# frozen_string_literal: true

require "base64"
require "digest/sha1"
require "fileutils"
require "json"
require "net/http"
require "open3"
require "securerandom"
require "socket"
require "tempfile"
require "time"
require "uri"

ROOT_DIR = File.expand_path("..", __dir__)
AGENT_DIR = File.join(ROOT_DIR, "willdeep-agent")
OUT_DIR = File.join(ROOT_DIR, "build", "mobile_gateway_integration")
REPORT_JSON = File.join(OUT_DIR, "report.json")
REPORT_MD = File.join(OUT_DIR, "report.md")

class StepRecorder
  attr_reader :steps

  def initialize
    @steps = []
  end

  def record(name)
    started = Time.now
    result = yield
    @steps << {
      name: name,
      status: "passed",
      duration_ms: ((Time.now - started) * 1000).round,
    }
    result
  rescue StandardError => e
    @steps << {
      name: name,
      status: "failed",
      duration_ms: ((Time.now - started) * 1000).round,
      error: "#{e.class}: #{e.message}",
    }
    raise
  end
end

class MinimalWebSocket
  GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  def initialize(url, headers = {})
    @uri = URI(url)
    @socket = TCPSocket.new(@uri.host, @uri.port)
    key = Base64.strict_encode64(SecureRandom.random_bytes(16))
    path = @uri.query ? "#{@uri.path}?#{@uri.query}" : @uri.path
    path = "/" if path.empty?
    request_headers = {
      "Host" => "#{@uri.host}:#{@uri.port}",
      "Upgrade" => "websocket",
      "Connection" => "Upgrade",
      "Sec-WebSocket-Key" => key,
      "Sec-WebSocket-Version" => "13",
    }.merge(headers)
    request = +"GET #{path} HTTP/1.1\r\n"
    request_headers.each { |name, value| request << "#{name}: #{value}\r\n" }
    request << "\r\n"
    @socket.write(request)
    response = read_http_response
    unless response.start_with?("HTTP/1.1 101")
      raise "websocket upgrade failed: #{response.lines.first&.strip}"
    end
    accept = response[/^Sec-WebSocket-Accept:\s*(.+)$/i, 1]&.strip
    expected = Base64.strict_encode64(Digest::SHA1.digest(key + GUID))
    raise "websocket accept mismatch" if accept != expected
  end

  def write_json(value)
    payload = JSON.generate(value)
    mask = SecureRandom.random_bytes(4).bytes
    bytes = payload.bytes
    header = [0x81]
    if bytes.length < 126
      header << (0x80 | bytes.length)
    elsif bytes.length <= 65_535
      header << (0x80 | 126)
      header.concat([bytes.length].pack("n").bytes)
    else
      header << (0x80 | 127)
      header.concat([bytes.length].pack("Q>").bytes)
    end
    masked = bytes.each_with_index.map { |byte, index| byte ^ mask[index % 4] }
    @socket.write((header + mask + masked).pack("C*"))
  end

  def read_json(timeout: 5)
    deadline = Time.now + timeout
    loop do
      remaining = deadline - Time.now
      raise "timed out waiting for websocket frame" if remaining <= 0
      ready = IO.select([@socket], nil, nil, remaining)
      raise "timed out waiting for websocket frame" unless ready
      opcode, payload = read_frame
      case opcode
      when 1
        return JSON.parse(payload)
      when 8
        raise "websocket closed"
      when 9
        write_control_frame(10, payload)
      end
    end
  end

  def close
    write_control_frame(8, "") rescue nil
    @socket.close unless @socket.closed?
  end

  private

  def read_http_response
    response = +""
    response << @socket.readpartial(1) until response.include?("\r\n\r\n")
    response
  end

  def read_frame
    first = read_exact(2).bytes
    opcode = first[0] & 0x0f
    masked = (first[1] & 0x80) != 0
    length = first[1] & 0x7f
    length = read_exact(2).unpack1("n") if length == 126
    length = read_exact(8).unpack1("Q>") if length == 127
    mask = masked ? read_exact(4).bytes : nil
    payload = read_exact(length).bytes
    payload = payload.each_with_index.map { |byte, index| byte ^ mask[index % 4] } if masked
    [opcode, payload.pack("C*")]
  end

  def read_exact(length)
    data = +""
    data << @socket.readpartial(length - data.bytesize) while data.bytesize < length
    data
  end

  def write_control_frame(opcode, payload)
    bytes = payload.bytes
    mask = SecureRandom.random_bytes(4).bytes
    masked = bytes.each_with_index.map { |byte, index| byte ^ mask[index % 4] }
    @socket.write(([0x80 | opcode, 0x80 | bytes.length] + mask + masked).pack("C*"))
  end
end

def free_port
  server = TCPServer.new("127.0.0.1", 0)
  server.addr[1]
ensure
  server&.close
end

def http_json(method, url, headers: {}, body: nil)
  uri = URI(url)
  request = case method
            when :get then Net::HTTP::Get.new(uri)
            when :post then Net::HTTP::Post.new(uri)
            else raise "unsupported method: #{method}"
            end
  headers.each { |name, value| request[name] = value }
  if body
    request["Content-Type"] = "application/json"
    request.body = JSON.generate(body)
  end
  response = Net::HTTP.start(uri.host, uri.port, read_timeout: 5, open_timeout: 5) do |http|
    http.request(request)
  end
  parsed = response.body.to_s.empty? ? {} : JSON.parse(response.body)
  [response, parsed]
end

def wait_for_gateway(base_url)
  deadline = Time.now + 20
  loop do
    response, body = http_json(:get, "#{base_url}/mobile/health")
    return body if response.code.to_i == 200 && body["ok"]
  rescue Errno::ECONNREFUSED, Errno::ECONNRESET, Net::OpenTimeout
    raise if Time.now >= deadline
    sleep 0.2
  end
end

def write_reports(result)
  FileUtils.mkdir_p(OUT_DIR)
  File.write(REPORT_JSON, JSON.pretty_generate(result))
  lines = [
    "# Mobile Gateway Integration Report",
    "",
    "- Status: #{result[:status]}",
    "- Version: #{result[:version]}",
    "- Protocol: #{result[:protocol_version]}",
    "- Base URL: `#{result[:base_url]}`",
    "- Generated at: #{result[:generated_at]}",
    "",
    "| Step | Status | Duration |",
    "| --- | --- | --- |",
  ]
  result[:steps].each do |step|
    status = step[:status] == "passed" ? "passed" : "failed"
    lines << "| #{step[:name]} | #{status} | #{step[:duration_ms]} ms |"
  end
  failures = result[:steps].select { |step| step[:status] != "passed" }
  unless failures.empty?
    lines << ""
    lines << "## Failures"
    failures.each { |step| lines << "- #{step[:name]}: #{step[:error]}" }
  end
  File.write(REPORT_MD, lines.join("\n") + "\n")
end

def main
  FileUtils.mkdir_p(OUT_DIR)
  recorder = StepRecorder.new
  port = free_port
  base_url = "http://127.0.0.1:#{port}"
  ws_url = "ws://127.0.0.1:#{port}/mobile/ws"
  desktop_token = "desktop-#{SecureRandom.hex(12)}"
  token_file = Tempfile.new("willdeep-mobile-desktop-token")
  token_file.write(desktop_token)
  token_file.close

  stdout_log = File.join(OUT_DIR, "gateway.stdout.log")
  stderr_log = File.join(OUT_DIR, "gateway.stderr.log")
  stdout = File.open(stdout_log, "w")
  stderr = File.open(stderr_log, "w")
  pid = Process.spawn(
    "go", "run", "./cmd/willdeep-agent", "serve-mobile",
    "--host", "127.0.0.1",
    "--port", port.to_s,
    "--desktop-name", "Integration Mac",
    "--desktop-token-file", token_file.path,
    "--pairing-base-url", base_url,
    chdir: AGENT_DIR,
    out: stdout,
    err: stderr,
  )

  desktop_ws = nil
  mobile_ws = nil
  result = {
    status: "failed",
    generated_at: Time.now.utc.iso8601,
    base_url: base_url,
    version: nil,
    protocol_version: nil,
    steps: recorder.steps,
  }

  begin
    health = recorder.record("health endpoint") { wait_for_gateway(base_url) }
    result[:version] = health.dig("data", "version", "version")
    result[:protocol_version] = health.dig("data", "protocol_version")

    pairing = recorder.record("desktop pairing payload") do
      response, body = http_json(
        :get,
        "#{base_url}/mobile/pairing",
        headers: { "Authorization" => "Bearer #{desktop_token}" },
      )
      raise "pairing status #{response.code}" unless response.code.to_i == 200
      body.dig("data", "pairing_payload") || raise("missing pairing_payload")
    end

    claim = recorder.record("mobile pairing claim") do
      response, body = http_json(
        :post,
        "#{base_url}/mobile/pair/claim",
        body: {
          pairing_token: pairing.fetch("pairing_token"),
          device_name: "Integration Android",
        },
      )
      raise "claim status #{response.code}: #{response.body}" unless response.code.to_i == 200
      body.fetch("data")
    end
    device_token = claim.fetch("device_token")

    recorder.record("desktop rotates pairing payload after claim") do
      response, body = http_json(
        :post,
        "#{base_url}/mobile/pairing/rotate",
        headers: { "Authorization" => "Bearer #{desktop_token}" },
        body: {},
      )
      raise "rotate status #{response.code}: #{response.body}" unless response.code.to_i == 200
      rotated = body.dig("data", "pairing_payload") || raise("missing rotated pairing_payload")
      if rotated.fetch("pairing_token") == pairing.fetch("pairing_token")
        raise "rotated pairing token did not change"
      end
      second_claim_response, second_claim_body = http_json(
        :post,
        "#{base_url}/mobile/pair/claim",
        body: {
          pairing_token: rotated.fetch("pairing_token"),
          device_name: "Second Integration Android",
        },
      )
      unless second_claim_response.code.to_i == 200
        raise "second claim status #{second_claim_response.code}: #{second_claim_response.body}"
      end
      second_claim_body.fetch("data").fetch("device_token")
    end

    desktop_ws = recorder.record("desktop websocket connects") do
      MinimalWebSocket.new(ws_url, "Authorization" => "Bearer #{desktop_token}")
    end
    mobile_ws = recorder.record("mobile websocket connects") do
      MinimalWebSocket.new(ws_url, "Authorization" => "Bearer #{device_token}")
    end

    recorder.record("mobile command forwards to desktop and acks") do
      command = {
        id: "cmd-1",
        type: "message.send",
        session_id: "session-1",
        payload: { text: "Build the Android gateway control surface" },
      }
      mobile_ws.write_json(command)
      forwarded = desktop_ws.read_json
      raise "forwarded type #{forwarded["type"]}" unless forwarded["type"] == "message.send"
      raise "missing _device_id" unless forwarded.dig("payload", "_device_id").to_s.start_with?("dev_")
      ack = mobile_ws.read_json
      raise "ack type #{ack["type"]}" unless ack["type"] == "ack"
      raise "ack command #{ack.dig("payload", "type")}" unless ack.dig("payload", "type") == "message.send"
    end

    recorder.record("desktop events broadcast to mobile") do
      desktop_ws.write_json(
        id: "evt-1",
        type: "message.delta",
        session_id: "session-1",
        payload: { message_id: "m1", delta: "Editing files on the Mac..." },
      )
      event = mobile_ws.read_json
      raise "event type #{event["type"]}" unless event["type"] == "message.delta"
      raise "event delta missing" unless event.dig("payload", "delta").include?("Mac")
    end

    recorder.record("worktree update broadcasts to mobile") do
      desktop_ws.write_json(
        id: "evt-2",
        type: "worktree.updated",
        session_id: "session-1",
        payload: {
          session_id: "session-1",
          repository_root: "/tmp/willdeep",
          file_count: 1,
          total_added_lines: 12,
          total_deleted_lines: 2,
          files: [
            {
              path: "app/src/main/java/com/willdeep/android/MainActivity.kt",
              kind: "M",
              added_lines: 12,
              deleted_lines: 2,
            },
          ],
        },
      )
      event = mobile_ws.read_json
      raise "event type #{event["type"]}" unless event["type"] == "worktree.updated"
      raise "file_count mismatch" unless event.dig("payload", "file_count") == 1
    end

    result[:status] = "passed"
  ensure
    desktop_ws&.close
    mobile_ws&.close
    Process.kill("TERM", pid) rescue nil
    Process.wait(pid) rescue nil
    stdout.close
    stderr.close
    token_file.unlink
    write_reports(result)
  end

  puts "report: #{REPORT_MD}"
  puts "json: #{REPORT_JSON}"
  exit(result[:status] == "passed" ? 0 : 1)
end

main
