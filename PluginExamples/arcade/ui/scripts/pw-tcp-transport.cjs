'use strict';

/**
 * 受限沙箱适配（开发/回归工具，不参与业务逻辑）。
 *
 * 背景：在部分受限 macOS 沙箱中，Chromium 的 `--remote-debugging-pipe`
 * 传输会在启动时触发 SEGV（与 Playwright 的 spawn 参数组合相关），而
 * TCP 传输（`--remote-debugging-port=0` + WebSocket）完全正常。
 *
 * Playwright 的 in-process 模式下，`require('playwright-core').chromium`
 * 只是客户端代理，真正的浏览器启动参数由服务端 Chromium 实例构造
 * （通过 `client._connection.toImpl(client)` 可达）。因此这里同时给
 * 客户端代理与服务端实现打补丁：
 *  - defaultArgs：`--remote-debugging-pipe` → `--remote-debugging-port=0`
 *  - supportsPipeTransport → false（走 WebSocketTransport 连接）
 *  - waitForReadyState：从浏览器 stderr 的 "DevTools listening on ..." 解析
 *    wsEndpoint（与 playwright-core 内部实现同构）
 *
 * 仅当浏览器实例未打过补丁时生效（幂等），并限定在支持 CDP 的 Chromium 上。
 */
const core = require('playwright-core');

const client = core && core.chromium;
const targets = [];
if (client) targets.push(client);
if (client && client._connection && typeof client._connection.toImpl === 'function') {
  const impl = client._connection.toImpl(client);
  if (impl && typeof impl.defaultArgs === 'function') targets.push(impl);
}

for (const browserType of targets) {
  if (browserType.__tcpTransportPatched) continue;
  const originalDefaultArgs = browserType.defaultArgs;

  browserType.defaultArgs = async function defaultArgs(options, isPersistent, userDataDir) {
    const args = await originalDefaultArgs.call(this, options, isPersistent, userDataDir);
    // 已显式指定 --remote-debugging-port 时移除 pipe 参数；否则把 pipe 换成
    // --remote-debugging-port=0（headless shell 不支持 pipe 调试会 SEGV）。
    const hasPort = args.some((arg) => arg.startsWith('--remote-debugging-port='));
    return args
      .filter((arg) => !(hasPort && arg === '--remote-debugging-pipe'))
      .map((arg) => (arg === '--remote-debugging-pipe' && !hasPort ? '--remote-debugging-port=0' : arg));
  };

  browserType.supportsPipeTransport = function supportsPipeTransport() {
    return false;
  };

  browserType.waitForReadyState = function waitForReadyState(options, browserLogsCollector) {
    return new Promise((resolve, reject) => {
      browserLogsCollector.onMessage((message) => {
        if (
          message.includes('Failed to create a ProcessSingleton') ||
          message.includes('Opening in existing browser session.')
        ) {
          reject(new Error(`profile in use: ${message}`));
          return;
        }
        const match = message.match(/DevTools listening on (.*)/);
        if (match) resolve({ wsEndpoint: match[1] });
      });
    });
  };

  Object.defineProperty(browserType, '__tcpTransportPatched', { value: true, configurable: false });
  // eslint-disable-next-line no-console
  console.error(`[pw-tcp-transport] patched ${browserType.constructor?.name ?? 'browserType'} pid=${process.pid}`);
}
