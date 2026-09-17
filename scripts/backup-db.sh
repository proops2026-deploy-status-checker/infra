#!/usr/bin/env bash
# Backs up deploy_db and log_db with pg_dump (custom format), and prunes
# backups older than RETENTION_DAYS.
#
# Per DOP-001 §10 ("regular backups... required") and §14 (restore time
# target). No IRD currently specifies the mechanism — see TIE-29/TIE-35
# for the standing gap.
#
# Usage:
#   ./backup-db.sh [--dir <path>] [--container <name>]
#
#   --dir <path>        Directory backups are written to, from inside the
#                        postgres container (default: /backups, which
#                        infra/docker-compose.yml bind-mounts to ./backups
#                        on the host).
#   --container <name>  Postgres container name (default: autodetected via
#                        `docker compose ps`, run from --compose-dir).
#   --compose-dir <path> Directory containing docker-compose.yml + .env.postgres
#                        (default: this script's parent directory, i.e. infra/).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BACKUP_DIR="/backups"
CONTAINER=""
RETENTION_DAYS=7
DATABASES=(deploy_db log_db)

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) BACKUP_DIR="$2"; shift 2 ;;
    --container) CONTAINER="$2"; shift 2 ;;
    --compose-dir) COMPOSE_DIR="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

ENV_FILE="$COMPOSE_DIR/.env.postgres"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "$ENV_FILE not found. Run generate-secrets.sh first." >&2
  exit 1
fi

if [[ -z "$CONTAINER" ]]; then
  CONTAINER="$(docker compose -f "$COMPOSE_DIR/docker-compose.yml" ps -q postgres)"
fi
if [[ -z "$CONTAINER" ]]; then
  echo "Could not find a running postgres container. Pass --container <name>." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
run_dir="${BACKUP_DIR}/${timestamp}"
docker exec "$CONTAINER" mkdir -p "$run_dir"

for db in "${DATABASES[@]}"; do
  echo "==> Backing up $db"
  docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" "$CONTAINER" \
    pg_dump -U "$POSTGRES_USER" -Fc -f "${run_dir}/${db}.dump" "$db"
done

echo "==> Backup written to ${run_dir} (inside the postgres container; host path: $(basename "$COMPOSE_DIR")/backups/${timestamp})"

echo "==> Pruning backups older than ${RETENTION_DAYS} days"
docker exec "$CONTAINER" find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -mtime "+${RETENTION_DAYS}" -exec rm -rf {} +

echo "==> Done: ${timestamp}"
