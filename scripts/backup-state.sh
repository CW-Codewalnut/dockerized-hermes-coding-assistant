#!/usr/bin/env bash
# Export assistant state volumes plus .env into a portable tarball.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

get_env() {
  local key="$1"
  [[ -f .env ]] || return 0
  awk -v key="$key" '
    $0 ~ "^[[:space:]]*" key "=" {
      val = substr($0, index($0, "=") + 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
      if (val ~ /^".*"$/ || val ~ /^'\''.*'\''$/) val = substr(val, 2, length(val) - 2)
      print val
      exit
    }
  ' .env
}

SLUG="$(get_env ASSISTANT_SLUG)"
SLUG="${SLUG:-hermes-assistant}"
OUT="${1:-${SLUG}-state-$(date +%Y%m%d-%H%M%S).tar.gz}"

docker volume inspect "${SLUG}_data" >/dev/null
docker volume inspect "${SLUG}_workbench" >/dev/null
docker volume inspect "${SLUG}_docker" >/dev/null
test -f .env

docker run --rm \
  -e OUT="$OUT" \
  -v "${SLUG}_data:/data:ro" \
  -v "${SLUG}_workbench:/workbench:ro" \
  -v "${SLUG}_docker:/docker:ro" \
  -v "$ROOT:/repo:ro" \
  -v "$ROOT:/backup" \
  alpine:latest \
  sh -lc '
    set -eu
    test -d /data
    test -d /workbench
    test -d /docker
    test -f /repo/.env
    rm -rf /backup-staging
    mkdir -p /backup-staging/data /backup-staging/workbench /backup-staging/docker
    cp -a /data/. /backup-staging/data/
    cp -a /workbench/. /backup-staging/workbench/
    cp -a /docker/. /backup-staging/docker/
    cp /repo/.env /backup-staging/.env
    tar -czf "/backup/$OUT" -C /backup-staging .
  '

echo "Wrote $OUT"
