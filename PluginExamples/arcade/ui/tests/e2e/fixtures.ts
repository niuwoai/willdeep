import { test as base, chromium } from '@playwright/test';

/**
 * 受限沙箱适配（开发/回归工具，不参与业务逻辑）：
 * 沙箱禁止 node 孙进程（playwright worker）spawn Chrome，因此 e2e 在
 * 沙箱中通过 scripts/e2e-cdp-server.cjs 以顶层 node 常驻浏览器（CDP
 * 端点见 PW_CDP_ENDPOINT），本 fixture 让每个测试连接该浏览器并创建
 * 独立 context；非沙箱环境（未设置 PW_CDP_ENDPOINT）走默认 launch。
 */
const endpoint = process.env.PW_CDP_ENDPOINT;

const test = endpoint
  ? base.extend({
      context: async ({ viewport, hasTouch }, use, testInfo) => {
        const browser = await chromium.connectOverCDP(endpoint);
        const ctx = await browser.newContext({
          baseURL: testInfo.project.use.baseURL as string | undefined,
          viewport,
          hasTouch,
        });
        await use(ctx);
        await ctx.close();
      },
    })
  : base;

export { expect } from '@playwright/test';
export { test };
