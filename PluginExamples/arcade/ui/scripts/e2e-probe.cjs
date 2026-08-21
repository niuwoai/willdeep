'use strict';

/**
 * 受限沙箱 e2e 门禁探测（验收工具，不参与业务逻辑）。
 *
 * 与真实套件一致的启动条件：playwright-core launch chrome-headless-shell
 * （--no-zygote）并完成一次导航。共享宿主机存在周期性 Chromium 失败窗口，
 * 探测失败即视为窗口关闭，由 e2e-gate-run.sh 稍后重试。
 */
const path = require('node:path');
const os = require('node:os');
const { chromium } = require('playwright-core');

const root = path.resolve(__dirname, '..');
const cacheBase = process.env.PLAYWRIGHT_BROWSERS_PATH || path.join(os.homedir(), 'Library/Caches/ms-playwright');
const hss = path.join(
  cacheBase,
  'chromium_headless_shell-1234/chrome-headless-shell-mac-arm64/chrome-headless-shell',
);

(async () => {
  const browser = await chromium.launch({
    headless: true,
    executablePath: hss,
    args: ['--no-sandbox', '--no-zygote', '--disable-crash-reporter'],
  });
  const page = await browser.newPage();
  await page.goto('data:text/html,<html><body>probe</body></html>');
  await page.evaluate(() => document.body.textContent);
  await browser.close();
  console.log('[e2e-probe] OK');
})().catch((err) => {
  console.error('[e2e-probe] FAIL:', err && err.message ? err.message.split('\n')[0] : err);
  process.exit(1);
});
