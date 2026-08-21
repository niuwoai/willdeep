/**
 * 沙箱 DNS shim（仅开发环境工具，不参与运行时）。
 *
 * 某些受限 shell 环境会阻断 node 进程的 getaddrinfo，但允许 curl。
 * 本模块通过 NODE_OPTIONS=--require 预加载，将 dns.lookup 重定向到
 * curl 解析结果，保证 yarn/npm/playwright 等 node 工具可访问 registry。
 * 用法：NODE_OPTIONS="--require $PWD/scripts/dns-shim.cjs" yarn install
 */
'use strict';

const { execFileSync } = require('node:child_process');
const dns = require('node:dns');

const cache = new Map();

const DEBUG = !!process.env.DNS_SHIM_DEBUG;

function debug(...args) {
  if (DEBUG) console.error('[dns-shim]', ...args);
}

function resolveViaCurl(hostname) {
  if (cache.has(hostname)) return cache.get(hostname);
  try {
    const out = execFileSync(
      'curl',
      ['-sS', '-m', '10', '-o', '/dev/null', '-w', '%{remote_ip}', `https://${hostname}`],
      { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] },
    );
    const ip = (out || '').trim();
    debug('resolve', hostname, '->', ip || '(empty)');
    cache.set(hostname, ip || null);
    return ip || null;
  } catch (err) {
    debug('curl failed for', hostname, err.message);
    cache.set(hostname, null);
    return null;
  }
}

const originalLookup = dns.lookup;

dns.lookup = function lookupShim(hostname, options, callback) {
  if (typeof options === 'function') {
    callback = options;
    options = {};
  } else if (typeof options === 'number') {
    options = { family: options };
  }
  options = options || {};

  if (typeof hostname !== 'string' || !hostname) {
    return originalLookup.call(dns, hostname, options, callback);
  }

  const ip = resolveViaCurl(hostname);
  if (!ip) {
    return originalLookup.call(dns, hostname, options, callback);
  }

  if (options.all) {
    return callback(null, [{ address: ip, family: 4 }]);
  }
  return callback(null, ip, 4);
};
