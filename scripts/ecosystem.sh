#!/usr/bin/env bash
# The ecosystem check: every official module built and tested against one
# Spider. Spider's release gate and nightly run this; so can anyone.
#
#   scripts/ecosystem.sh                 # against ../spider
#   SPIDER_DIR=/path/to/spider scripts/ecosystem.sh
#
# Steps: unit tests of every module (zig build test), then each module's
# database tests on a disposable Postgres (<module>/scripts/test-db.sh).
# Exit status: 0 when every module passed.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SPIDER_DIR=${SPIDER_DIR:-$ROOT/../spider}

if [ ! -f "$SPIDER_DIR/build.zig.zon" ]; then
  echo "error: no Spider checkout at $SPIDER_DIR (set SPIDER_DIR)" >&2
  exit 2
fi
# build.zig.zon points at ../spider; another checkout is linked there.
if [ "$(cd "$SPIDER_DIR" && pwd)" != "$(cd "$ROOT/.." && pwd)/spider" ]; then
  echo "error: build.zig.zon expects Spider at ../spider; check it out there (CI does)" >&2
  exit 2
fi

spider_version=$(sed -n 's/^    \.version = "\(.*\)",/\1/p' "$SPIDER_DIR/build.zig.zon" | head -1)
echo "== Spider $spider_version ($SPIDER_DIR) =="

failed=()
cd "$ROOT"
echo "== unit tests =="
zig build test --summary all || failed+=("unit")

for script in "$ROOT"/*/scripts/test-db.sh; do
  module=$(basename "$(dirname "$(dirname "$script")")")
  echo "== $module: database tests =="
  bash "$script" || failed+=("$module")
done

if [ ${#failed[@]} -gt 0 ]; then
  echo "FAILED: ${failed[*]}"
  exit 1
fi
echo "ok: every module passed against Spider $spider_version"
