#!/bin/sh
# 受限沙箱环境下的依赖安装辅助脚本（开发工具，不参与运行时）。
# 沙箱网络间歇可用且 node 进程 DNS 被拦截：
#   1) 轮询等待网络窗口（curl 可解析外网）
#   2) 通过 scripts/dns-shim.cjs 让 node/yarn 复用 curl 的解析结果
#   3) yarn 自带重试，脚本本身也会整轮重试
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
YARN_JS="${YARN_JS:-/Users/rocky/.cache/node/corepack/v1/yarn/1.22.22/bin/yarn.js}"
MAX_WAIT="${MAX_WAIT:-900}"
ATTEMPTS="${ATTEMPTS:-6}"

wait_for_network() {
  waited=0
  while [ "$waited" -lt "$MAX_WAIT" ]; do
    if curl -s -m 6 -o /dev/null https://registry.npmjs.org/react; then
      echo "[retry-install] network window open after ${waited}s"
      return 0
    fi
    sleep 5
    waited=$((waited + 5))
  done
  echo "[retry-install] network unavailable after ${MAX_WAIT}s" >&2
  return 1
}

if [ ! -f "$YARN_JS" ]; then
  echo "[retry-install] yarn.js not found at $YARN_JS (set YARN_JS)" >&2
  exit 2
fi

attempt=1
while [ "$attempt" -le "$ATTEMPTS" ]; do
  echo "[retry-install] attempt $attempt/$ATTEMPTS"
  wait_for_network || exit 1
  if YARN_CACHE_FOLDER="$ROOT/.cache/yarn" \
     NODE_OPTIONS="--require $ROOT/scripts/dns-shim.cjs" \
     node "$YARN_JS" install --non-interactive >"$ROOT/.cache/yarn-install.log" 2>&1; then
    echo "[retry-install] install OK (attempt $attempt)"
    exit 0
  fi
  echo "[retry-install] attempt $attempt failed, tail:"
  tail -6 "$ROOT/.cache/yarn-install.log"
  attempt=$((attempt + 1))
  sleep 10
done

echo "[retry-install] all attempts failed" >&2
exit 1
