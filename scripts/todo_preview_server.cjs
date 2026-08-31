// Isolated real-MCP preview. Never reads or writes the user's plugin-data directory.
const http = require('node:http');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const readline = require('node:readline');
const { spawn } = require('node:child_process');

const root = path.resolve(__dirname, '../PluginExamples/todo');
const store = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'todo-ui-preview-')), 'todos.json');
const port = Number(process.env.TODO_PREVIEW_PORT || 38765);
const child = spawn('/usr/bin/ruby', [path.join(root, 'server/todo.rb')], { env: { ...process.env, WD_TODO_FILE: store }, stdio: ['pipe', 'pipe', 'inherit'] });
let sequence = 0;
const pending = new Map();
readline.createInterface({ input: child.stdout }).on('line', line => {
  const message = JSON.parse(line);
  const resolve = pending.get(message.id);
  if (resolve) { pending.delete(message.id); resolve(message.result); }
});
function tool(name, arguments_ = {}) {
  return new Promise(resolve => {
    const id = ++sequence;
    pending.set(id, resolve);
    child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method: 'tools/call', params: { name, arguments: arguments_ } }) + '\n');
  });
}
const rows = [
  ['修复待办项目切换', 'Xedit', '2026-08-31T18:00:00+08:00', 'high', ['界面', '修复']],
  ['优化收藏夹卡片间距', 'Xedit', '2026-08-31T20:00:00+08:00', 'normal', ['界面']],
  ['检查移动端标签换行', 'WillDeep Android', '2026-09-01T11:00:00+08:00', 'normal', ['界面', '测试']],
  ['复核插件深色主题', 'Xedit', '2026-09-01T15:00:00+08:00', 'low', ['界面', '测试']],
  ['整理标签使用说明', 'WillDeep Docs', '', 'low', ['界面', '文档']],
  ['调整空状态提示', 'Xedit', '', '', ['界面']],
  ['整理发布记录', 'Xedit', '', '', ['文档']],
  ['补充契约测试', 'Xedit', '', '', ['测试']],
  ['检查更新源', 'Xedit', '', '', ['发布']],
  ['检查登录接口', 'Muchtoken', '', '', ['修复']],
  ['未归项目的任务', '', '', '', []],
  ['检查无标签筛选', 'Xedit', '', '', []]
];
const bridge = `window.willdeep={getContext:()=>({locale:new URLSearchParams(location.search).get('lang')||'zh-CN',workspaceReference:'/demo/Xedit'}),executeCommand:(name,args)=>fetch('/command',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({name,args})}).then(r=>r.json()),ai:{providers:()=>Promise.resolve([]),complete:()=>Promise.reject(new Error('Preview uses the local parser'))}};`;
const types = { '.html': 'text/html', '.css': 'text/css', '.js': 'text/javascript', '.svg': 'image/svg+xml' };
let failNextSave = false;
const server = http.createServer(async (request, response) => {
  const url = new URL(request.url, `http://127.0.0.1:${port}`);
  response.setHeader('Cache-Control', 'no-store');
  if (request.method === 'POST') {
    if (request.headers.origin && request.headers.origin !== `http://127.0.0.1:${port}`) { response.writeHead(403).end(); return; }
    if (url.pathname === '/test/fail-next-save') { failNextSave = true; response.end('ok'); return; }
    if (url.pathname !== '/command') { response.writeHead(404).end(); return; }
    let body = '';
    for await (const chunk of request) { body += chunk; if (body.length > 32768) { response.writeHead(413).end(); return; } }
    try {
      const { name, args } = JSON.parse(body);
      if (!/^todo\.(add|quick_add|list|update|toggle|remove|restore|settings|stats)$/.test(name)) throw new Error('Unknown command');
      response.setHeader('Content-Type', 'application/json');
      if (failNextSave && name === 'todo.update') { failNextSave = false; response.end(JSON.stringify({ ok: false, error: '测试：保存失败，请重试' })); return; }
      response.end(JSON.stringify(await tool(name, args)));
    } catch (error) { response.writeHead(400).end(JSON.stringify({ ok: false, error: error.message })); }
    return;
  }
  if (url.pathname === '/preview-bridge.js') { response.setHeader('Content-Type', 'text/javascript'); response.end(bridge); return; }
  const relative = url.pathname === '/' ? 'index.html' : decodeURIComponent(url.pathname.slice(1));
  const file = path.resolve(root, 'ui', relative);
  if (!file.startsWith(path.join(root, 'ui') + path.sep)) { response.writeHead(403).end(); return; }
  try {
    let content = fs.readFileSync(file);
    if (relative === 'index.html') {
      const dark = url.searchParams.get('theme') === 'dark';
      const theme = `<style>:root { --willdeep-bg: ${dark ? '#1c1c1e' : '#ffffff'}; --willdeep-fg: ${dark ? '#f2f2f4' : '#1a1a1c'}; --willdeep-secondary: ${dark ? '#a1a1a6' : '#6c6c70'}; --willdeep-accent: ${dark ? '#f2f2f4' : '#111111'}; color-scheme: ${dark ? 'dark' : 'light'}; }</style>`;
      content = content.toString().replace('</head>', theme + '</head>').replace('<script src="details-i18n.js">', '<script src="/preview-bridge.js"></script><script src="details-i18n.js">');
    }
    response.setHeader('Content-Type', (types[path.extname(file)] || 'text/plain') + '; charset=utf-8'); response.end(content);
  } catch { response.writeHead(404).end(); }
});
(async () => {
  for (const [text, project, due, priority, tags] of rows) await tool('todo.add', { text, projectPath: project ? '/demo/' + project : '', due, priority, tags });
  await tool('todo.settings', { parser: 'local' });
  server.listen(port, '127.0.0.1', () => console.log(`Todo preview: http://127.0.0.1:${port}; isolated store: ${store}`));
})();
function stop() { server.close(); child.kill(); process.exit(0); }
process.on('SIGINT', stop); process.on('SIGTERM', stop);
