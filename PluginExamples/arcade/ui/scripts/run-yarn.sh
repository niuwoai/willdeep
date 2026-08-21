#!/bin/sh
# 受限沙箱环境下运行 yarn 命令的封装（开发工具，不参与运行时）。
# 沙箱会把 HOME/TMPDIR 指向只读目录导致 yarn 1 无法创建缓存/全局/临时目录，
# 这里统一重定向到工作区内 .cache/（已 gitignore）。
# 用法：./scripts/run-yarn.sh <yarn 命令...>，如 ./scripts/run-yarn.sh build
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/.cache/tmp" "$ROOT/.cache/yarn" "$ROOT/.cache/yarn-global"

export TMPDIR="$ROOT/.cache/tmp"
export YARN_CACHE_FOLDER="$ROOT/.cache/yarn"

YARN_JS="${YARN_JS:-/Users/rocky/.cache/node/corepack/v1/yarn/1.22.22/bin/yarn.js}"
if [ ! -f "$YARN_JS" ]; then
  echo "[run-yarn] yarn.js not found at $YARN_JS (set YARN_JS)" >&2
  exit 2
fi

exec node "$YARN_JS" "$@"
