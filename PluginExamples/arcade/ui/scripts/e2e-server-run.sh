#!/bin/sh
# 受限沙箱下的 e2e 回归入口（开发/回归工具，不参与业务逻辑）。
#
# 沙箱限制 node 孙进程启动 Chrome，因此：
#   1) 以顶层 node 启动 scripts/e2e-cdp-server.cjs 常驻浏览器
#      （chromium.launch + TCP 传输补丁 + --single-process + 固定 CDP 端口）
#   2) playwright test 的 worker 经 PW_CDP_ENDPOINT + connectOverCDP
#      fixture 连接该浏览器，自身不 spawn 浏览器（见 tests/e2e/fixtures.ts）
#   3) 套件结束后关闭浏览器
#
# 沙箱/共享宿主机存在周期性失败窗口，浏览器启动带重试。
# 用法：./scripts/e2e-server-run.sh [playwright 参数...]
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p "$ROOT/.cache/tmp"

export TMPDIR="$ROOT/.cache/tmp"
export PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-/Users/rocky/Library/Caches/ms-playwright}"
export NODE_OPTIONS="--require $ROOT/scripts/pw-tcp-transport.cjs"
export PW_CDP_PORT="${PW_CDP_PORT:-9333}"
export PW_CDP_ENDPOINT_FILE="$ROOT/.cache/e2e-cdp-endpoint.txt"

start_server() {
  rm -f "$PW_CDP_ENDPOINT_FILE"
  find "$ROOT/.cache/tmp" -maxdepth 1 -name 'playwright_chromiumdev_profile-*' -exec rm -rf {} + 2>/dev/null
  node "$ROOT/scripts/e2e-cdp-server.cjs" > "$ROOT/.cache/e2e-cdp-server.log" 2>&1 &
  SERVER_PID=$!
  waited=0
  while [ ! -f "$PW_CDP_ENDPOINT_FILE" ]; do
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
      echo "[e2e-server-run] cdp server died on startup" >&2
      tail -3 "$ROOT/.cache/e2e-cdp-server.log" >&2
      return 1
    fi
    sleep 1
    waited=$((waited + 1))
    if [ "$waited" -ge 30 ]; then
      echo "[e2e-server-run] cdp endpoint timeout" >&2
      kill "$SERVER_PID" 2>/dev/null
      return 1
    fi
  done
  export PW_CDP_ENDPOINT="$(cat "$PW_CDP_ENDPOINT_FILE")"
  echo "[e2e-server-run] cdp browser ready ($PW_CDP_ENDPOINT)"
  return 0
}

SERVER_PID=""
server_attempt=1
while [ "$server_attempt" -le 12 ]; do
  if start_server; then
    break
  fi
  echo "[e2e-server-run] server attempt $server_attempt failed, retrying"
  server_attempt=$((server_attempt + 1))
  sleep 5
done
if [ -z "$SERVER_PID" ] || ! kill -0 "$SERVER_PID" 2>/dev/null; then
  echo "[e2e-server-run] could not start cdp browser after 12 attempts" >&2
  exit 2
fi

CODE=1
suite_attempt=1
while [ "$suite_attempt" -le 3 ] && [ "$CODE" -ne 0 ]; do
  echo "[e2e-server-run] suite attempt $suite_attempt"
  "$ROOT/scripts/run-yarn.sh" test:e2e "$@"
  CODE=$?
  suite_attempt=$((suite_attempt + 1))
done

kill "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
echo "[e2e-server-run] e2e exit=$CODE, cdp browser closed"
exit "$CODE"
