#!/usr/bin/env bash
# miohh _serve 入口（systemd / dev 模式共用）
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${MIOHH_ROOT:-$(cd "$HERE/.." && pwd)}"
export MIOHH_ROOT="$ROOT"
exec python3 "$ROOT/runtime/serve.py"
