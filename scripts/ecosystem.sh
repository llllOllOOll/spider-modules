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
# Every build below uses this checkout instead of the Spider pinned in
# build.zig.zon. Relative to this repository: Zig 0.17 refuses an absolute
# --fork path for a package that has path dependencies of its own (Spider's
# modules/), and every build here runs from the repository's root.
SPIDER_DIR=$(cd "$SPIDER_DIR" && pwd)
export SPIDER_FORK="--fork=$(realpath --relative-to="$ROOT" "$SPIDER_DIR")"

spider_version=$(sed -n 's/^    \.version = "\(.*\)",/\1/p' "$SPIDER_DIR/build.zig.zon" | head -1)
echo "== Spider $spider_version ($SPIDER_DIR) =="

failed=()
cd "$ROOT"
echo "== unit tests =="
zig build test "$SPIDER_FORK" --summary all || failed+=("unit")

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
