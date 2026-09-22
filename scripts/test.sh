#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$project_dir/.cache"
export CLANG_MODULE_CACHE_PATH="$project_dir/.cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$project_dir/.cache"
swift build --package-path "$project_dir" --disable-sandbox --cache-path "$project_dir/.cache"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/batchprint-check.XXXXXX")"
"$project_dir/.build/debug/BatchPrint" --self-test "$check_dir"
printf '验证报告：%s/report.json\n' "$check_dir"
