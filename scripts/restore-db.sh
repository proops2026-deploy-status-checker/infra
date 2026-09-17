#!/usr/bin/env bash
# Restores a backup produced by backup-db.sh into a fresh, throwaway
# Postgres container — never the live one. This is the rehearsal/
# verification tool for DOP-001 §10's "restore testing" requirement;
# for an actual disaster-recovery restore into a real replacement
# primary, an operator runs the same pg_restore commands by hand against
# that instance.
#
# Usage:
#   ./restore-db.sh <backup-timestamp> [--compose-dir <path>] [--name <container-name>]
#
#   <backup-timestamp>   The directory name backup-db.sh created, e.g.
#                        20260917T021500Z (ls infra/backups/ to see options).
#
# Leaves the throwaway container running on success so its data can be
# inspected (row counts, pointing a real service at it, etc.) — remove it
# yourself when done:
#   docker rm -f <container-name>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONTAINER_NAME="tie29-restore-verify"
DATABASES=(deploy_db log_db)

TIMESTAMP="${1:-}"
if [[ -z "$TIMESTAMP" ]]; then
  echo "Usage: $0 <backup-timestamp> [--compose-dir <path>] [--name <container-name>]" >&2
  exit 1
fi
shift

while [[ $# -gt 0 ]]; do
  case "$1" in
    --compose-dir) COMPOSE_DIR="$2"; shift 2 ;;
    --name) CONTAINER_NAME="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

BACKUP_DIR="$COMPOSE_DIR/backups/$TIMESTAMP"
if [[ ! -d "$BACKUP_DIR" ]]; then
  echo "$BACKUP_DIR not found." >&2
  exit 1
fi

ENV_FILE="$COMPOSE_DIR/.env.postgres"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "$ENV_FILE not found." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  echo "==> Removing pre-existing $CONTAINER_NAME"
  docker rm -f "$CONTAINER_NAME" >/dev/null
fi

echo "==> Starting fresh throwaway Postgres ($CONTAINER_NAME)"
docker run -d --name "$CONTAINER_NAME" \
  -e POSTGRES_USER="$POSTGRES_USER" \
  -e POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
  -e DEPLOY_DB_PASSWORD="$DEPLOY_DB_PASSWORD" \
  -e LOG_DB_PASSWORD="$LOG_DB_PASSWORD" \
  -v "$COMPOSE_DIR/init:/docker-entrypoint-initdb.d:ro" \
  -v "$BACKUP_DIR:/restore:ro" \
  postgres:16-alpine >/dev/null

echo "==> Waiting for it to become ready"
# The official postgres image restarts once after running init scripts on a
# fresh volume (temp server for initdb, then the real one) — pg_isready can
# briefly succeed against the temp server and then fail. Wait for the
# "ready to accept connections" log line to appear twice instead.
for _ in $(seq 1 60); do
  ready_count="$(docker logs "$CONTAINER_NAME" 2>&1 | grep -c "database system is ready to accept connections" || true)"
  if [[ "$ready_count" -ge 2 ]]; then
    break
  fi
  sleep 1
done
docker exec "$CONTAINER_NAME" pg_isready -U "$POSTGRES_USER" >/dev/null

for db in "${DATABASES[@]}"; do
  echo "==> Restoring $db"
  docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" "$CONTAINER_NAME" \
    pg_restore -U "$POSTGRES_USER" -d "$db" --no-owner --role="$POSTGRES_USER" "/restore/${db}.dump"
done

echo "==> Restored into container: $CONTAINER_NAME"
echo "==> Row counts:"
for db in "${DATABASES[@]}"; do
  case "$db" in
    deploy_db) table="deploys" ;;
    log_db) table="log_entries" ;;
  esac
  count="$(docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" "$CONTAINER_NAME" \
    psql -U "$POSTGRES_USER" -d "$db" -tAc "SELECT count(*) FROM ${table};")"
  echo "  ${db}.${table}: ${count}"
done
