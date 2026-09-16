#!/usr/bin/env bash
# One-command release: pull -> restart -> health-gate -> automatic rollback.
#
# Usage:
#   ./deploy.sh <service> <tag>
#
#   <service>  One of: api-gateway, deploy-service, log-service
#   <tag>      Image tag to deploy (e.g. a commit SHA from CI)
#
# Rewrites infra/docker-compose.prod.yml's image tag for <service>, pulls
# and restarts it, then polls its Docker health status. If it doesn't
# become healthy within the timeout, the previous tag is automatically
# restored and the service is restarted again. Exits 0 on a successful
# deploy, non-zero if it had to roll back.

set -euo pipefail

# CI builds images on ubuntu-latest (amd64) only; force that platform so
# this also works correctly from an arm64 host (e.g. Apple Silicon).
export DOCKER_DEFAULT_PLATFORM=linux/amd64

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_FILES=(-f "$INFRA_DIR/docker-compose.yml" -f "$INFRA_DIR/docker-compose.prod.yml")
PROD_FILE="$INFRA_DIR/docker-compose.prod.yml"

HEALTH_TIMEOUT_SECONDS=60
POLL_INTERVAL_SECONDS=2

SERVICE="${1:-}"
NEW_TAG="${2:-}"

case "$SERVICE" in
  api-gateway|deploy-service|log-service) ;;
  *)
    echo "Usage: $0 <api-gateway|deploy-service|log-service> <tag>" >&2
    exit 1
    ;;
esac

if [[ -z "$NEW_TAG" ]]; then
  echo "Usage: $0 <api-gateway|deploy-service|log-service> <tag>" >&2
  exit 1
fi

image_line_pattern="^([[:space:]]*image: tert62/dsc-${SERVICE}:)([^[:space:]]+)\$"

current_tag() {
  grep -E "$image_line_pattern" "$PROD_FILE" | sed -E "s#$image_line_pattern#\2#"
}

set_tag() {
  local tag="$1"
  sed -i.bak -E "s#$image_line_pattern#\1${tag}#" "$PROD_FILE"
  rm -f "$PROD_FILE.bak"
}

wait_healthy() {
  local container_id
  container_id="$(docker compose "${COMPOSE_FILES[@]}" ps -q "$SERVICE")"
  if [[ -z "$container_id" ]]; then
    return 1
  fi

  local elapsed=0
  while (( elapsed < HEALTH_TIMEOUT_SECONDS )); do
    local status
    status="$(docker inspect -f '{{.State.Health.Status}}' "$container_id" 2>/dev/null || echo "unknown")"
    if [[ "$status" == "healthy" ]]; then
      return 0
    fi
    sleep "$POLL_INTERVAL_SECONDS"
    elapsed=$((elapsed + POLL_INTERVAL_SECONDS))
  done
  return 1
}

smoke_test_api_gateway() {
  local host_port
  host_port="$(grep -E '^GATEWAY_HOST_PORT=' "$INFRA_DIR/.env" 2>/dev/null | cut -d= -f2)"
  host_port="${host_port:-3000}"
  curl -sf --max-time 5 "http://localhost:${host_port}/health" >/dev/null
}

deploy() {
  local tag="$1"
  set_tag "$tag"
  echo "==> Deploying ${SERVICE}:${tag}"

  # NOTE: this function is invoked as an `if` condition, which disables
  # `set -e` for everything inside it — every step must be checked explicitly.
  if ! docker compose "${COMPOSE_FILES[@]}" pull "$SERVICE"; then
    echo "==> Failed to pull ${SERVICE}:${tag}"
    return 1
  fi
  if ! docker compose "${COMPOSE_FILES[@]}" up -d --no-deps "$SERVICE"; then
    echo "==> Failed to start ${SERVICE}:${tag}"
    return 1
  fi

  if ! wait_healthy; then
    echo "==> ${SERVICE}:${tag} did not become healthy within ${HEALTH_TIMEOUT_SECONDS}s"
    return 1
  fi

  if [[ "$SERVICE" == "api-gateway" ]] && ! smoke_test_api_gateway; then
    echo "==> ${SERVICE}:${tag} is Docker-healthy but failed the external /health smoke test"
    return 1
  fi

  echo "==> ${SERVICE}:${tag} is healthy"
  return 0
}

PREVIOUS_TAG="$(current_tag)"
if [[ -z "$PREVIOUS_TAG" ]]; then
  echo "Could not determine the current tag for ${SERVICE} in $PROD_FILE" >&2
  exit 1
fi

if deploy "$NEW_TAG"; then
  if ! git -C "$INFRA_DIR" diff --quiet -- docker-compose.prod.yml; then
    git -C "$INFRA_DIR" add docker-compose.prod.yml
    git -C "$INFRA_DIR" commit -m "Deploy ${SERVICE}:${NEW_TAG}" >/dev/null
  fi
  echo "==> Deploy succeeded: ${SERVICE} is now running ${NEW_TAG}"
  exit 0
fi

echo "==> Rolling back ${SERVICE} to ${PREVIOUS_TAG}"
if deploy "$PREVIOUS_TAG"; then
  echo "==> Rollback succeeded: ${SERVICE} restored to ${PREVIOUS_TAG}"
else
  echo "==> Rollback FAILED: ${SERVICE} is not healthy on ${PREVIOUS_TAG} either. Manual intervention required." >&2
fi
exit 1
