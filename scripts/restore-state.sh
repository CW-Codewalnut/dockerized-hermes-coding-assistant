#!/usr/bin/env bash
# Restore assistant state volumes from a backup produced by backup-state.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ $# -ne 1 ]]; then
  echo "Usage: scripts/restore-state.sh <backup.tar.gz>" >&2
  exit 2
fi

BACKUP_INPUT="$1"
BACKUP_DIR="$(cd "$(dirname "$BACKUP_INPUT")" && pwd)"
BACKUP_FILE="$(basename "$BACKUP_INPUT")"
BACKUP_PATH="$BACKUP_DIR/$BACKUP_FILE"

test -f "$BACKUP_PATH"

if [[ ! -f .env ]]; then
  tar -xzf "$BACKUP_PATH" .env
  chmod 600 .env
fi

get_env() {
  local key="$1"
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

docker volume create "${SLUG}_data" >/dev/null
docker volume create "${SLUG}_workbench" >/dev/null
docker volume create "${SLUG}_docker" >/dev/null

docker run --rm \
  -e BACKUP_FILE="$BACKUP_FILE" \
  -v "${SLUG}_data:/data" \
  -v "${SLUG}_workbench:/workbench" \
  -v "${SLUG}_docker:/docker" \
  -v "$BACKUP_DIR:/backup:ro" \
  alpine:latest \
  sh -lc '
    set -eu
    test -d /data
    test -d /workbench
    test -d /docker
    rm -rf /restore
    mkdir -p /restore
    tar -xzf "/backup/$BACKUP_FILE" -C /restore
    test -d /restore/data
    test -d /restore/workbench
    test -d /restore/docker
    find /data -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    find /workbench -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    find /docker -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    cp -a /restore/data/. /data/
    cp -a /restore/workbench/. /workbench/
    cp -a /restore/docker/. /docker/
  '

echo "Restored ${SLUG}_data, ${SLUG}_workbench, and ${SLUG}_docker from $BACKUP_PATH"
