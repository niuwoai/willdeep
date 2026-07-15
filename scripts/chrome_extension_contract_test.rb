#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "pathname"
require "set"

ROOT = Pathname.new(__dir__).parent
EXTENSION = ROOT.join("chrome-extension", "willdeep-browser")
DEFAULT_MARKDOWN_REPORT = "/tmp/xedit-chrome-extension-contract.md"
DEFAULT_JSON_REPORT = "/tmp/xedit-chrome-extension-contract.json"

markdown_path = Pathname.new(ARGV[0] || DEFAULT_MARKDOWN_REPORT)
json_path = Pathname.new(ARGV[1] || DEFAULT_JSON_REPORT)
checks = []

record = lambda do |name, ok, detail|
  checks << { name: name, ok: ok, detail: detail }
end

manifest = JSON.parse(EXTENSION.join("manifest.json").read)
record.call("manifest-v3", manifest["manifest_version"] == 3, "manifest_version=#{manifest["manifest_version"]}")
record.call("semantic-version-name", manifest["version_name"].to_s.match?(/^\d+\.\d+\.\d+(?:-[a-z]+\d+)?$/), manifest["version_name"].to_s)
record.call("options-page", manifest["options_page"] == "options.html", manifest["options_page"].to_s)

required_permissions = Set.new(%w[alarms notifications storage])
permissions = Set.new(Array(manifest["permissions"]))
missing_permissions = required_permissions - permissions
record.call("update-permissions", missing_permissions.empty?, "missing=#{missing_permissions.to_a.join(",")}")

required_files = %w[options.html options.css options.js update_checker.js service_worker.js]
missing_files = required_files.reject { |path| EXTENSION.join(path).file? }
record.call("update-files", missing_files.empty?, "missing=#{missing_files.join(",")}")

icon_sizes = [16, 32, 48, 128]
missing_icons = icon_sizes.reject { |size| EXTENSION.join("icons", "icon#{size}.png").file? }
record.call("png-icons", missing_icons.empty?, "missing=#{missing_icons.join(",")}")

locale_paths = {
  "en" => EXTENSION.join("_locales", "en", "messages.json"),
  "zh_CN" => EXTENSION.join("_locales", "zh_CN", "messages.json")
}
locale_keys = locale_paths.transform_values { |path| Set.new(JSON.parse(path.read).keys) }
record.call(
  "locale-key-parity",
  locale_keys.values.uniq.length == 1,
  locale_keys.transform_values(&:length).map { |locale, count| "#{locale}=#{count}" }.join(" ")
)

html_keys = EXTENSION.glob("*.html").flat_map do |path|
  path.read.scan(/data-i18n="([^"]+)"/).flatten
end.to_set
missing_translations = locale_keys.flat_map do |locale, keys|
  (html_keys - keys).map { |key| "#{locale}:#{key}" }
end
record.call("html-i18n", missing_translations.empty?, "missing=#{missing_translations.join(",")}")

checker_source = EXTENSION.join("update_checker.js").read
record.call("managed-endpoint", checker_source.include?("https://some.im/api/v1/public/app-updates/latest"), "some.im public app-update endpoint")
record.call("managed-app-id", checker_source.include?("willdeep-browser-extension"), "app_id=willdeep-browser-extension")

status = checks.all? { |check| check[:ok] } ? "pass" : "fail"
payload = {
  status: status,
  version: manifest["version_name"],
  checks: checks
}

json_path.write(JSON.pretty_generate(payload) + "\n")
markdown_lines = [
  "# Chrome Extension Contract Report",
  "",
  "**Status:** #{status.upcase}",
  "",
  "- Version: `#{manifest["version_name"]}`",
  "- Extension: `#{EXTENSION.relative_path_from(ROOT)}`",
  "",
  "| Check | Result | Detail |",
  "| --- | --- | --- |",
]
checks.each do |check|
  markdown_lines << "| #{check[:name]} | #{check[:ok] ? "PASS" : "FAIL"} | #{check[:detail].to_s.gsub("|", "\\|")} |"
end
markdown_path.write(markdown_lines.join("\n") + "\n")

puts "chrome_extension_contract: #{status} checks=#{checks.length} version=#{manifest["version_name"]}"
exit(status == "pass" ? 0 : 1)
