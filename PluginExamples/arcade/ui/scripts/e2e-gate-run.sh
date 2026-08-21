#!/bin/sh
# 验收专用：受限共享宿主机上 Chromium 启动存在周期性失败窗口，
# 本脚本在窗口开启时立即执行完整 e2e 套件；失败则等待下一窗口重试。
#
# 探测与真实套件采用完全相同的启动路径：node + playwright-core launch
# chrome-headless-shell（--no-zygote，沙箱内 crashpad 注册被拒的规避）。
# 直接 CLI 启动 HSS 带 remote-debugging-port 会误报崩溃，故不采用。
set -u
cd "$(dirname "$0")/.."

export TMPDIR="$PWD/.cache/tmp"
export PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-/Users/rocky/Library/Caches/ms-playwright}"
export NODE_OPTIONS="--require $PWD/scripts/pw-tcp-transport.cjs"

gate() {
  node "$PWD/scripts/e2e-probe.cjs" > "$PWD/.cache/e2e-probe.log" 2>&1
  [ "$?" -eq 0 ]
}

attempt=1
max_attempts="${MAX_ATTEMPTS:-14}"
while [ "$attempt" -le "$max_attempts" ]; do
  if gate; then
    echo "[e2e-gate] attempt $attempt: window OPEN, running suite"
    ./scripts/run-yarn.sh test:e2e --workers=2 --reporter=line > .cache/e2e-retry.log 2>&1
    code=$?
    if [ "$code" -eq 0 ]; then
      echo "[e2e-gate] SUCCESS on attempt $attempt"
      exit 0
    fi
    echo "[e2e-gate] attempt $attempt: suite failed (exit $code), waiting for next window"
  else
    echo "[e2e-gate] attempt $attempt: window CLOSED, waiting"
  fi
  attempt=$((attempt + 1))
  sleep 15
done
echo "[e2e-gate] all $max_attempts attempts exhausted"
exit 1
