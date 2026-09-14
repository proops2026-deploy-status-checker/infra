#!/usr/bin/env bash
# Generates fresh, host-local secrets for one environment's .env.* files.
#
# Run this independently on each host (local dev machine, staging VM, ...).
# Every invocation produces its own random secrets — nothing is shared
# between environments, and nothing here is ever committed to git
# (.env / .env.* are gitignored; only .env.*.example templates are tracked).
#
# Usage:
#   ./generate-secrets.sh [--dir <path>] [--force]
#
#   --dir <path>   Directory to write .env.* into (default: this script's
#                  parent directory, i.e. infra/).
#   --force        Overwrite existing .env.* files. Without this flag the
#                  script refuses to touch files that already exist, so a
#                  live environment's secrets are never silently rotated.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FORCE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)
      TARGET_DIR="$2"
      shift 2
      ;;
    --force)
      FORCE=1
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if ! command -v openssl >/dev/null 2>&1; then
  echo "openssl is required to generate secrets and was not found on this host." >&2
  exit 1
fi

mkdir -p "$TARGET_DIR"

ENV_FILES=(.env.postgres .env.deploy .env.gateway .env.log)
if [[ "$FORCE" -ne 1 ]]; then
  existing=()
  for f in "${ENV_FILES[@]}"; do
    [[ -f "$TARGET_DIR/$f" ]] && existing+=("$f")
  done
  if [[ ${#existing[@]} -gt 0 ]]; then
    echo "Refusing to overwrite existing secrets without --force: ${existing[*]}" >&2
    echo "(in $TARGET_DIR)" >&2
    exit 1
  fi
fi

hex() { openssl rand -hex "$1"; }

postgres_password="$(hex 20)"
deploy_db_password="$(hex 20)"
log_db_password="$(hex 20)"
jwt_secret="$(hex 32)"
ci_api_key="$(hex 24)"

write() {
  local path="$1"
  local content="$2"
  local tmp
  tmp="$(mktemp "$TARGET_DIR/.env.XXXXXX")"
  printf '%s\n' "$content" > "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$path"
}

write "$TARGET_DIR/.env.postgres" "POSTGRES_USER=postgres
POSTGRES_PASSWORD=$postgres_password
DEPLOY_DB_PASSWORD=$deploy_db_password
LOG_DB_PASSWORD=$log_db_password"

write "$TARGET_DIR/.env.deploy" "PORT=3001
DATABASE_URL=postgresql://deploy_user:$deploy_db_password@postgres:5432/deploy_db
REDIS_URL=redis://redis:6379"

write "$TARGET_DIR/.env.gateway" "PORT=3000
JWT_SECRET=$jwt_secret
CI_API_KEY=$ci_api_key
DEPLOY_SERVICE_URL=http://deploy-service:3001
LOG_SERVICE_URL=http://log-service:3002"

write "$TARGET_DIR/.env.log" "PORT=3002
DATABASE_URL=postgresql://log_user:$log_db_password@postgres:5432/log_db"

echo "Generated fresh secrets in $TARGET_DIR: ${ENV_FILES[*]}"
echo "Values are not printed. If postgres has already been initialized with"
echo "the previous passwords, rotate the live DB roles before restarting the"
echo "app services (see README note in this directory)."
