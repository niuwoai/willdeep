#!/usr/bin/env ruby
# frozen_string_literal: true

# session_vitality_server_test.rb -- regression guard for the session-vitality
# plugin server. Verifies the dashboard is served through the read-only MCP
# `resources/read` method (which needs no confirmation dialog) and returns
# parseable JSON -- the fix for the `res.content is undefined` page crash that
# occurred when the page used `tools/call` and the host asked to confirm.
#
# Usage: ruby scripts/session_vitality_server_test.rb [report.md] [report.json]

require "json"
require "open3"
require "tmpdir"

ROOT = File.expand_path("..", __dir__)
SERVER = File.join(ROOT, "PluginExamples", "session-vitality", "server", "session_vitality.rb")
STATS_URI = "willdeep-plugin://vitality/stats"
SIDEBAR_URI = "willdeep-plugin://vitality/sidebar"
MAIN_URI = "ui://vitality/main"

results = []

def check(condition, message, results)
  results << { "ok" => condition, "message" => message }
end

Dir.mktmpdir do |dir|
  # Reproduce the host's launch: system Ruby with no UTF-8 locale, and a
  # missing session store so the server returns the clearly-labeled demo data.
  env = { "WD_VITALITY_SESSIONS_DIR" => File.join(dir, "missing") }
  env.delete("LANG")
  env.delete("LC_ALL")

  Open3.popen3(env, "/usr/bin/ruby", SERVER) do |stdin, stdout, _stderr, _wait|
    stdin.sync = true
    next_id = 0

    call = lambda do |method, params = {}|
      id = (next_id += 1)
      stdin.puts JSON.generate(jsonrpc: "2.0", id: id, method: method, params: params)
      loop do
        line = stdout.gets
        return nil if line.nil?
        begin
          message = JSON.parse(line)
        rescue JSON::ParserError
          next
        end
        return message if message["id"] == id
      end
    end

    init = call.call("initialize", {})
    check(init && init.dig("result", "serverInfo", "name") == "session-vitality",
          "server responds to initialize with session-vitality serverInfo.", results)

    stats = call.call("resources/read", { "uri" => STATS_URI })
    contents = stats && stats.dig("result", "contents")
    check(contents.is_a?(Array) && contents.length == 1,
          "resources/read for the stats URI returns exactly one content item.", results)

    text = contents && contents[0] && contents[0]["text"]
    check(text.is_a?(String) && !text.empty?, "stats content has non-empty text.", results)

    data = begin
      JSON.parse(text)
    rescue StandardError
      nil
    end
    check(data.is_a?(Hash), "stats text parses as a JSON object.", results)
    check(data && data["demo"] == true, "missing store yields the demo dataset.", results)
    check(data && data["projects"].is_a?(Array), "stats JSON exposes a projects array.", results)

    sidebar = call.call("resources/read", { "uri" => SIDEBAR_URI })
    check(!sidebar.dig("result", "contents", 0, "text").to_s.empty?,
          "sidebar resource returns a document.", results)

    main = call.call("resources/read", { "uri" => MAIN_URI })
    check(main.dig("result", "contents", 0, "text").to_s.include?("<html"),
          "main page resource returns HTML.", results)

    stdin.close
  end
end

failed = results.reject { |result| result["ok"] }
json_path = ARGV[1]
markdown_path = ARGV[0]
if json_path
  File.write(json_path, JSON.pretty_generate("ok" => failed.empty?, "checks" => results))
end
if markdown_path
  lines = ["# Session Vitality Server Contract", "", "- Status: #{failed.empty? ? "pass" : "fail"}", "", "## Checks", ""]
  results.each { |result| lines << "- #{result["ok"] ? "PASS" : "FAIL"}: #{result["message"]}" }
  File.write(markdown_path, "#{lines.join("\n")}\n")
end

abort failed.map { |result| result["message"] }.join("\n") unless failed.empty?
puts "session_vitality_server_test: pass checks=#{results.length}"
