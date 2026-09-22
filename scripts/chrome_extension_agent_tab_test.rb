#!/usr/bin/env ruby
# frozen_string_literal: true

# Behavioral test for the Chrome extension's Agent-tab pinning. It loads the
# real service_worker.js in Node with a fake `chrome` API and replays the
# failure the pinning fixes: the user switches tabs between two Agent
# commands, and the second command must still land on the Agent's tab.
#
# Usage: ruby scripts/chrome_extension_agent_tab_test.rb [report.md] [report.json]

require "json"
require "open3"
require "pathname"
require "tmpdir"
require "fileutils"

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

ROOT = Pathname.new(__dir__).parent
# CHROME_EXTENSION_DIR lets a reviewer point the same checks at another
# build of the extension (e.g. the pre-fix one) to prove they can fail.
EXTENSION = Pathname.new(ENV.fetch("CHROME_EXTENSION_DIR", ROOT.join("chrome-extension", "willdeep-browser").to_s))
DEFAULT_MARKDOWN_REPORT = "/tmp/xedit-chrome-extension-agent-tab.md"
DEFAULT_JSON_REPORT = "/tmp/xedit-chrome-extension-agent-tab.json"

markdown_path = Pathname.new(ARGV[0] || DEFAULT_MARKDOWN_REPORT)
json_path = Pathname.new(ARGV[1] || DEFAULT_JSON_REPORT)

HARNESS = <<~'JS'
  // Minimal in-memory Chrome: tabs, windows, storage.session, messaging.
  const tabs = new Map();
  let activeId = null;
  const sessionStore = {};
  const contentCalls = [];
  const captured = [];
  const listeners = { message: null, updated: new Set() };
  const event = () => ({ addListener() {}, removeListener() {} });
  const addTab = (id, url, title) => tabs.set(id, { id, windowId: 1, url, title, status: "complete", active: false });
  const activate = (id) => { for (const t of tabs.values()) t.active = t.id === id; activeId = id; };

  globalThis.chrome = {
    runtime: {
      onInstalled: event(), onStartup: event(),
      onMessage: { addListener(fn) { listeners.message = fn; } },
      connectNative() { throw new Error("no native host in tests"); },
      getManifest: () => ({ version: "0.0.0", version_name: "0.0.0" }),
      lastError: null
    },
    alarms: { onAlarm: event(), create: async () => {}, clear: async () => {}, get: async () => null },
    notifications: { onClicked: event(), create: async () => {}, clear: async () => {} },
    action: { setBadgeText: async () => {}, setBadgeBackgroundColor: async () => {} },
    storage: {
      session: {
        async get(key) { return key in sessionStore ? { [key]: sessionStore[key] } : {}; },
        async set(values) { Object.assign(sessionStore, values); }
      },
      local: { async get() { return {}; }, async set() {} }
    },
    windows: { update: async () => ({}) },
    scripting: { executeScript: async () => [] },
    debugger: { attach: async () => {}, detach: async () => {}, sendCommand: async () => ({}) },
    tabs: {
      onUpdated: {
        addListener(fn) { listeners.updated.add(fn); },
        removeListener(fn) { listeners.updated.delete(fn); }
      },
      async query(filter) {
        const all = [...tabs.values()];
        return filter && filter.active ? all.filter((t) => t.active) : all;
      },
      async get(id) {
        const tab = tabs.get(id);
        if (!tab) throw new Error(`No tab with id: ${id}`);
        return { ...tab };
      },
      async update(id, props) {
        const tab = tabs.get(id);
        if (!tab) throw new Error(`No tab with id: ${id}`);
        if (props.active) activate(id);
        if (props.url) {
          tab.url = props.url; tab.title = `Title of ${props.url}`; tab.status = "loading";
          setTimeout(() => {
            tab.status = "complete";
            for (const fn of [...listeners.updated]) fn(id, { status: "complete" }, { ...tab });
          }, 5);
        }
        return { ...tab };
      },
      async goBack() {}, async goForward() {}, async reload() {},
      async sendMessage(tabId, message) {
        if (message.type === "probe") return { ok: true };
        contentCalls.push({ tabId, type: message.type });
        return { ok: true, command: message.type };
      },
      async captureVisibleTab(windowId) { captured.push(windowId); return "data:image/png;base64,AAAA"; },
      async create() { return {}; }
    }
  };

  await import(`${process.argv[2]}/service_worker.js`);

  const send = (type, payload = {}) => new Promise((resolve) => listeners.message({ type, payload }, {}, resolve));
  const results = [];
  const check = (name, ok, detail) => results.push({ name, ok: Boolean(ok), detail });

  addTab(1, "https://agent.example/", "Agent page");
  addTab(2, "https://user.example/", "User page");
  activate(1);

  let r = await send("page.read");
  check("first command claims the active tab", r.tab_id === 1 && contentCalls.at(-1).tabId === 1 && sessionStore.willdeepAgentTabId === 1,
        `tab_id=${r.tab_id} content_tab=${contentCalls.at(-1)?.tabId} pinned=${sessionStore.willdeepAgentTabId}`);

  activate(2); // the user switches tabs mid-task
  r = await send("page.type", { selector: "#q", text: "hello" });
  check("user switching tabs does not redirect Agent input", contentCalls.at(-1).tabId === 1 && r.tab_id === 1,
        `content_tab=${contentCalls.at(-1)?.tabId} tab_id=${r.tab_id}`);

  r = await send("page.read", { useActiveTab: true });
  check("popup reads the user's active tab without moving the pin",
        contentCalls.at(-1).tabId === 2 && sessionStore.willdeepAgentTabId === 1,
        `content_tab=${contentCalls.at(-1)?.tabId} pinned=${sessionStore.willdeepAgentTabId}`);

  r = await send("tab.capture");
  check("capture refuses a background Agent tab instead of switching tabs",
        r.ok === false && /chrome_activate_tab/.test(r.error || "") && captured.length === 0 && activeId === 2,
        `ok=${r.ok} active=${activeId} error=${(r.error || "").slice(0, 60)}`);

  r = await send("tab.navigate", { url: "https://agent.example/next" });
  check("navigate stays on the Agent tab and waits for load",
        r.ok && r.settled === true && r.tab_id === 1 && tabs.get(1).url === "https://agent.example/next" && tabs.get(2).url === "https://user.example/",
        `settled=${r.settled} tab_id=${r.tab_id} agent_url=${tabs.get(1).url}`);

  r = await send("page.click", { selector: "#go", tabId: 2 });
  check("explicit tabId targets and re-pins that tab",
        contentCalls.at(-1).tabId === 2 && sessionStore.willdeepAgentTabId === 2,
        `content_tab=${contentCalls.at(-1)?.tabId} pinned=${sessionStore.willdeepAgentTabId}`);

  r = await send("page.click", { selector: "#go", tabId: 99 });
  check("unknown tabId is an error, not a silent fallback", r.ok === false && /no longer exists/.test(r.error || ""), `error=${r.error}`);

  r = await send("tab.list");
  const flagged = (r.tabs || []).filter((t) => t.agent_target).map((t) => t.id);
  check("tab.list marks the Agent tab", r.agent_tab_id === 2 && flagged.length === 1 && flagged[0] === 2,
        `agent_tab_id=${r.agent_tab_id} flagged=${flagged}`);

  tabs.delete(2); // the user closes the Agent's tab
  activate(1);
  r = await send("page.read");
  check("closed Agent tab falls back to the active tab and says so",
        r.tab_id === 1 && typeof r.retargeted === "string" && sessionStore.willdeepAgentTabId === 1,
        `tab_id=${r.tab_id} retargeted=${Boolean(r.retargeted)} pinned=${sessionStore.willdeepAgentTabId}`);

  r = await send("tab.activate", { tabId: 1 });
  check("activate pins the tab", r.ok && sessionStore.willdeepAgentTabId === 1, `pinned=${sessionStore.willdeepAgentTabId}`);

  r = await send("tab.capture");
  check("capture works when the Agent tab is the visible one", r.ok === true && captured.length === 1, `ok=${r.ok} captures=${captured.length}`);

  console.log(JSON.stringify(results));
  process.exit(0);
JS

checks = []
node = ENV.fetch("NODE", "node")
Dir.mktmpdir("willdeep-chrome-ext-test") do |dir|
  %w[service_worker.js update_checker.js].each do |file|
    FileUtils.cp(EXTENSION.join(file), File.join(dir, file))
  end
  File.write(File.join(dir, "package.json"), JSON.generate({ type: "module" }))
  harness = File.join(dir, "harness.mjs")
  File.write(harness, HARNESS)
  stdout, stderr, status = Open3.capture3(node, harness, "file://#{dir}")
  if status.success?
    begin
      checks = JSON.parse(stdout.lines.last.to_s, symbolize_names: true)
    rescue JSON::ParserError => error
      checks = [{ name: "harness output", ok: false, detail: "unparseable output: #{error.message}: #{stdout[-300, 300]}" }]
    end
  else
    checks = [{ name: "harness run", ok: false, detail: "node exited #{status.exitstatus}: #{stderr[-500, 500] || stderr}" }]
  end
end

checks = [{ name: "harness ran checks", ok: false, detail: "no checks reported" }] if checks.empty?
status = checks.all? { |check| check[:ok] } ? "pass" : "fail"
json_path.write(JSON.pretty_generate({ status: status, checks: checks }) + "\n")
markdown = [
  "# Chrome Extension Agent-Tab Report",
  "",
  "**Status:** #{status.upcase}",
  "",
  "| Check | Result | Detail |",
  "| --- | --- | --- |",
]
checks.each do |check|
  markdown << "| #{check[:name]} | #{check[:ok] ? "PASS" : "FAIL"} | #{check[:detail].to_s.gsub("|", "\\|")} |"
end
markdown_path.write(markdown.join("\n") + "\n")

puts "chrome_extension_agent_tab: #{status} checks=#{checks.length}"
checks.reject { |check| check[:ok] }.each { |check| puts "  FAIL #{check[:name]}: #{check[:detail]}" }
exit(status == "pass" ? 0 : 1)
