#!/usr/bin/env node
"use strict";

// history-recall 插件页面的隔离预览服务器。
//
// 跑法：node scripts/history_recall_preview_server.cjs [--port 4173] [--sessions <dir>] [--ai]
//
// 起一个真实的 Ruby MCP 子进程，并给页面注入一个假的 window.willdeep bridge，
// 于是在普通浏览器里就能验收页面——不必每次都 bump 版本号重装插件。
//
// 默认 ai.complete 直接 reject，用来验证「模型不可用时定位功能照常可用」这条降级路径；
// 传 --ai 则让它返回一个固定的检索词 JSON，用来验证模型在场时的分支。

const http = require("http");
const fs = require("fs");
const path = require("path");
const { spawn } = require("child_process");

const ROOT = path.resolve(__dirname, "..");
const PAGE = path.join(ROOT, "PluginExamples/history-recall/ui/index.html");
const SERVER = path.join(ROOT, "PluginExamples/history-recall/server/history_recall.rb");

function parseArgs(argv) {
  const options = { port: 4173, sessions: null, ai: false, dataDir: null };
  for (let i = 2; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--port") options.port = Number(argv[++i]);
    else if (arg === "--sessions") options.sessions = argv[++i];
    else if (arg === "--data-dir") options.dataDir = argv[++i];
    else if (arg === "--ai") options.ai = true;
  }
  return options;
}

const options = parseArgs(process.argv);

const env = Object.assign({}, process.env);
if (options.sessions) env.WD_HISTORY_SESSIONS_DIR = options.sessions;
if (options.dataDir) env.WD_HISTORY_DATA_DIR = options.dataDir;
// 复现宿主的启动环境：不带 locale。
delete env.LANG;
delete env.LC_ALL;

const child = spawn("/usr/bin/ruby", [SERVER], { env, stdio: ["pipe", "pipe", "pipe"] });
child.stderr.on("data", (chunk) => process.stderr.write(`[ruby] ${chunk}`));
child.on("exit", (code) => {
  console.error(`ruby server exited: ${code}`);
  process.exit(code === 0 ? 0 : 1);
});

// NDJSON 行分帧，与宿主一致。
let buffer = "";
let nextID = 0;
const pending = new Map();

child.stdout.setEncoding("utf8");
child.stdout.on("data", (chunk) => {
  buffer += chunk;
  let index = buffer.indexOf("\n");
  while (index >= 0) {
    const line = buffer.slice(0, index).trim();
    buffer = buffer.slice(index + 1);
    if (line) {
      try {
        const message = JSON.parse(line);
        const resolver = pending.get(message.id);
        if (resolver) {
          pending.delete(message.id);
          resolver(message);
        }
      } catch (error) {
        console.error("bad line from server:", line);
      }
    }
    index = buffer.indexOf("\n");
  }
});

function rpc(method, params) {
  nextID += 1;
  const id = nextID;
  const payload = { jsonrpc: "2.0", id, method };
  if (params) payload.params = params;
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      pending.delete(id);
      reject(new Error(`timeout on ${method}`));
    }, 30000);
    pending.set(id, (message) => {
      clearTimeout(timer);
      resolve(message);
    });
    child.stdin.write(`${JSON.stringify(payload)}\n`);
  });
}

// 页面用命令 ID 调用，这里映射到工具名，与 manifest 的 commands 保持一致。
const COMMAND_TO_TOOL = {
  "historyRecall.search": "history.search",
  "historyRecall.excerpt": "history.excerpt",
  "historyRecall.projects": "history.projects",
  "historyRecall.settings": "history.settings"
};

const BRIDGE = `
<script>
window.willdeep = {
  getContext: function () {
    return { destinationID: "history-recall", locale: navigator.language,
             colorScheme: "light", workspaceReference: "", sessionReference: "" };
  },
  executeCommand: function (commandID, args) {
    if (commandID === "historyRecall.openSession") {
      // 宿主的 session.open 在预览里没有对应物，只做可见反馈。
      console.log("[preview] session.open ->", args && args.sessionID);
      alert("预览环境：这里会跳转到会话 " + (args && args.sessionID));
      return Promise.resolve(undefined);
    }
    return fetch("/command", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ commandID: commandID, args: args || {} })
    }).then(function (response) { return response.text(); });
  },
  ai: {
    providers: function () {
      return Promise.resolve({ providers: [{ providerID: "preview", displayName: "Preview",
                                             isActive: true, isLocal: true, models: [] }] });
    },
    complete: function (request) {
      return fetch("/ai", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(request)
      }).then(function (response) {
        if (!response.ok) return response.text().then(function (text) { throw new Error(text); });
        return response.json();
      });
    }
  }
};
</script>
`;

const server = http.createServer(async (request, response) => {
  const url = new URL(request.url, "http://localhost");

  if (url.pathname === "/command" && request.method === "POST") {
    let body = "";
    request.on("data", (chunk) => { body += chunk; });
    request.on("end", async () => {
      try {
        const parsed = JSON.parse(body);
        const tool = COMMAND_TO_TOOL[parsed.commandID];
        if (!tool) {
          response.writeHead(400, { "content-type": "text/plain; charset=utf-8" });
          response.end(`unknown command ${parsed.commandID}`);
          return;
        }
        const result = await rpc("tools/call", { name: tool, arguments: parsed.args });
        // 页面的 unwrap() 期望拿到完整的 MCP result，原样转发。
        response.writeHead(200, { "content-type": "application/json; charset=utf-8" });
        response.end(JSON.stringify(result.result));
      } catch (error) {
        response.writeHead(500, { "content-type": "text/plain; charset=utf-8" });
        response.end(String(error && error.message));
      }
    });
    return;
  }

  if (url.pathname === "/ai" && request.method === "POST") {
    if (!options.ai) {
      // 默认让模型不可用，验证降级路径。
      response.writeHead(503, { "content-type": "text/plain; charset=utf-8" });
      response.end("model unavailable in preview (pass --ai to enable)");
      return;
    }
    let body = "";
    request.on("data", (chunk) => { body += chunk; });
    request.on("end", () => {
      const parsed = JSON.parse(body || "{}");
      const sentence = ((parsed.messages || [])[0] || {}).content || "";
      // 极简的假模型：去掉几个常见的填充词，剩下的当检索词。
      const terms = String(sentence)
        .replace(/上次|那次|哪次|我们|之前|聊过|聊的|是在|哪个会话|记得/g, " ")
        .split(/\s+/)
        .filter((term) => term.length > 0)
        .slice(0, 3);
      response.writeHead(200, { "content-type": "application/json; charset=utf-8" });
      response.end(JSON.stringify({
        text: JSON.stringify({ terms: terms }),
        model: "preview-fake",
        providerID: "preview"
      }));
    });
    return;
  }

  if (url.pathname === "/" || url.pathname === "/index.html") {
    let html;
    try {
      html = fs.readFileSync(PAGE, "utf8");
    } catch (error) {
      response.writeHead(500, { "content-type": "text/plain; charset=utf-8" });
      response.end(String(error && error.message));
      return;
    }
    // bridge 必须先于页面脚本执行。
    response.writeHead(200, { "content-type": "text/html; charset=utf-8" });
    response.end(BRIDGE + html);
    return;
  }

  response.writeHead(404, { "content-type": "text/plain; charset=utf-8" });
  response.end("not found");
});

(async () => {
  await rpc("initialize", {});
  server.listen(options.port, () => {
    console.log(`history-recall preview: http://localhost:${options.port}`);
    console.log(`  sessions: ${options.sessions || "(default ~/Library/.../agent-sessions)"}`);
    console.log(`  ai.complete: ${options.ai ? "fake model enabled" : "always rejects (fallback path)"}`);
  });
})();
