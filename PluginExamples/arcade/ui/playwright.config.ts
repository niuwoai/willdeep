import { existsSync } from 'node:fs';
import { join } from 'node:path';
import os from 'node:os';
import { defineConfig } from '@playwright/test';

// 受限沙箱适配：Chromium pipe 传输 SEGV → 改用 TCP 传输（见 scripts/pw-tcp-transport.cjs）
import './scripts/pw-tcp-transport.cjs';

// 沙箱适配：受限沙箱内 node 的孙进程（playwright worker）无法 spawn 多进程
// Chrome（crashpad mach bootstrap 被拒）。经实测，chrome-headless-shell
// （无 crashpad）+ --no-zygote 在沙箱内稳定可用，故优先选用；Chrome for
// Testing 作为非沙箱环境的回退（--disable-crash-reporter 规避 crashpad）。
const browsersPath =
  process.env.PLAYWRIGHT_BROWSERS_PATH ?? join(os.homedir(), 'Library/Caches/ms-playwright');
const candidates = [
  process.env.CHROME_EXECUTABLE,
  join(browsersPath, 'chromium_headless_shell-1234/chrome-headless-shell-mac-arm64/chrome-headless-shell'),
  join(
    browsersPath,
    'chromium-1234/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing',
  ),
].filter((c): c is string => Boolean(c));
const chrome = candidates.find((c) => existsSync(c));
const launchOptions = chrome
  ? { executablePath: chrome, args: ['--no-sandbox', '--no-zygote', '--disable-crash-reporter'] }
  : {};

export default defineConfig({
  testDir: './tests/e2e',
  fullyParallel: true,
  // Pong 获胜用例的物理推进循环最长需要 ~240s（真实时钟），默认 30s 超时会误杀
  timeout: 300_000,
  // 受限沙箱/共享宿主机上存在偶发失败窗口，重试可吸收单次失败
  retries: 2,
  reporter: [['list']],
  use: {
    baseURL: 'http://127.0.0.1:5173',
    trace: 'on-first-retry',
    launchOptions,
  },
  projects: [{ name: 'chromium', use: { browserName: 'chromium' } }],
  webServer: {
    command: 'node node_modules/vite/bin/vite.js --host 127.0.0.1 --port 5173 --strictPort',
    url: 'http://127.0.0.1:5173',
    reuseExistingServer: !process.env.CI,
    timeout: 120_000,
  },
});
