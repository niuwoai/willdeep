'use strict';

/**
 * 受限沙箱适配（开发/回归工具，不参与业务逻辑）。
 *
 * 背景：沙箱限制 node 进程树的深度——node 的“孙进程”（如 playwright
 * worker fork 后 spawn 的进程）无法注册 crashpad 的 mach bootstrap 名
 * （Permission denied 1100），多进程 Chrome 启动即退出；而顶层 node
 * 直接 spawn Chrome（配合 --single-process 让 crashpad 进程内初始化）
 * 稳定可用。playwright 的 launchServer 内部走未打补丁的 pipe 传输，
 * 在本沙箱同样不可用。
 *
 * 因此本脚本以顶层 node 常驻：用 chromium.launch()（TCP 传输补丁 +
 * --single-process）启动浏览器并固定 CDP 调试端口，随后把端点写入
 * PW_CDP_ENDPOINT_FILE；playwright 测试经 connectOverCDP fixture
 * 连接该浏览器，worker 自身不再 spawn 浏览器。
 */
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const os = require('node:os');
const { chromium } = require('playwright-core');

const root = path.resolve(__dirname, '..');
const cacheBase = process.env.PLAYWRIGHT_BROWSERS_PATH || path.join(os.homedir(), 'Library/Caches/ms-playwright');
// 沙箱内 Chrome for Testing 的 crashpad 无法注册 mach bootstrap（SEGV）；
// chrome-headless-shell（无 crashpad）+ --no-zygote 实测可用，优先选用。
const chromeCandidates = [
  process.env.CHROME_EXECUTABLE,
  path.join(cacheBase, 'chromium_headless_shell-1234/chrome-headless-shell-mac-arm64/chrome-headless-shell'),
  path.join(cacheBase, 'chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing'),
].filter((c): c is string => Boolean(c));
const chrome = chromeCandidates.find((c) => fs.existsSync(c)) || chromeCandidates[0];
const port = Number(process.env.PW_CDP_PORT || 9333);
const readyFile = process.env.PW_CDP_ENDPOINT_FILE || path.join(root, '.cache/e2e-cdp-endpoint.txt');

function pollCdp(cb, attempt = 1) {
  http
    .get(`http://127.0.0.1:${port}/json/version`, (res) => {
      let body = '';
      res.on('data', (c) => (body += c));
      res.on('end', () => {
        try {
          const info = JSON.parse(body);
          cb(null, info.webSocketDebuggerUrl);
        } catch (e) {
          cb(e);
        }
      });
    })
    .on('error', (e) => cb(e));
}

async function main() {
  if (!fs.existsSync(chrome)) {
    console.error(`[e2e-cdp-server] Chrome not found at ${chrome}`);
    process.exit(2);
  }
  fs.mkdirSync(path.dirname(readyFile), { recursive: true });
  fs.rmSync(readyFile, { force: true });

  const browser = await chromium.launch({
    headless: true,
    executablePath: chrome,
    // --no-zygote：沙箱内 zygote 进程 mach bootstrap 注册被拒（Permission denied 1100）
    // 导致 SEGV；绕过 zygote 后 Chrome 稳定可用（验收工具，不参与业务逻辑）。
    args: ['--no-sandbox', '--no-zygote', '--disable-crash-reporter', `--remote-debugging-port=${port}`],
  });
  console.log(`[e2e-cdp-server] browser launched, waiting for CDP on :${port}`);

  await new Promise((resolve, reject) => {
    const tryPoll = (attempt) => {
      pollCdp((err, ws) => {
        if (!err && ws) {
          fs.writeFileSync(readyFile, ws);
          console.log(`[e2e-cdp-server] ready ${ws}`);
          resolve();
          return;
        }
        if (attempt > 60) {
          reject(new Error('CDP endpoint not reachable'));
          return;
        }
        setTimeout(() => tryPoll(attempt + 1), 1000);
      });
    };
    tryPoll(1);
  });

  const shutdown = (signal) => {
    console.log(`[e2e-cdp-server] ${signal}, closing`);
    browser.close().then(() => process.exit(0));
  };
  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT', () => shutdown('SIGINT'));
}

main().catch((err) => {
  console.error('[e2e-cdp-server] failed:', err && err.message ? err.message : err);
  process.exit(1);
});
