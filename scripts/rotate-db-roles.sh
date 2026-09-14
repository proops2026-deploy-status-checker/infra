#!/usr/bin/env bash
# Applies the passwords currently in .env.postgres to the running Postgres
# roles. Use this after generate-secrets.sh has written new secrets for an
# environment where Postgres was already initialized (so the roles created
# by infra/init/01-databases.sh still hold the *old* passwords).
#
# Usage:
#   ./rotate-db-roles.sh [--dir <path>] [--container <name>]
#
#   --dir <path>        Directory containing .env.postgres (default: infra/).
#   --container <name>  Postgres container name (default: autodetected from
#                        `docker compose ps`, run from --dir).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONTAINER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)
      TARGET_DIR="$2"
      shift 2
      ;;
    --container)
      CONTAINER="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

ENV_FILE="$TARGET_DIR/.env.postgres"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "$ENV_FILE not found. Run generate-secrets.sh first." >&2
  exit 1
fi

if [[ -z "$CONTAINER" ]]; then
  CONTAINER="$(docker compose -f "$TARGET_DIR/docker-compose.yml" ps -q postgres)"
fi
if [[ -z "$CONTAINER" ]]; then
  echo "Could not find a running postgres container. Pass --container <name>." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

docker exec -i "$CONTAINER" psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d postgres <<SQL
ALTER USER "$POSTGRES_USER" WITH PASSWORD '$POSTGRES_PASSWORD';
ALTER USER deploy_user WITH PASSWORD '$DEPLOY_DB_PASSWORD';
ALTER USER log_user WITH PASSWORD '$LOG_DB_PASSWORD';
SQL

echo "Rotated postgres/deploy_user/log_user passwords on $CONTAINER to match $ENV_FILE."
echo "Now recreate the app containers so they pick up the new .env files:"
echo "  docker compose -f $TARGET_DIR/docker-compose.yml up -d --force-recreate api-gateway deploy-service log-service"
