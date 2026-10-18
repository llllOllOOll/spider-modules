#!/usr/bin/env bash
# Runs notify's module and database tests against a DISPOSABLE Postgres:
# starts an empty one in memory (tmpfs), runs `zig build test-notify-db` from
# the repository root and removes the container. No SQL is loaded here: the
# module test has Spider apply notify's migrations (server.migrateModules),
# which is what the database tests then use.
#
#   notify/scripts/test-db.sh
#
# NOTIFY_TEST_CONTAINER / NOTIFY_PG_PORT override the container name and port.
set -euo pipefail

NAME=${NOTIFY_TEST_CONTAINER:-spider_notify_test}
PORT=${NOTIFY_PG_PORT:-5437}
ROOT=$(cd "$(dirname "$0")/../.." && pwd)

docker rm -f "$NAME" >/dev/null 2>&1 || true
trap 'docker rm -f "$NAME" >/dev/null 2>&1 || true' EXIT

docker run -d --rm --name "$NAME" \
  -e POSTGRES_USER=notify -e POSTGRES_PASSWORD=notify -e POSTGRES_DB=notify_test \
  -p "127.0.0.1:${PORT}:5432" --tmpfs /var/lib/postgresql/data postgres:17-alpine >/dev/null

# The image starts, initializes, stops and starts again: wait for two answers.
for _ in $(seq 1 60); do
  if docker exec "$NAME" psql -U notify -d notify_test -qAtc 'select 1' >/dev/null 2>&1; then
    sleep 1
    docker exec "$NAME" psql -U notify -d notify_test -qAtc 'select 1' >/dev/null 2>&1 && break
  fi
  sleep 0.5
done

cd "$ROOT"
NOTIFY_PG_PORT="$PORT" zig build test-notify-db --summary all
