#!/usr/bin/env bash
# Restore assistant Docker volumes from a backup produced by backup-state.sh.
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

docker run --rm \
  -e BACKUP_FILE="$BACKUP_FILE" \
  -v "${SLUG}_data:/state/data" \
  -v "${SLUG}_workbench:/state/workbench" \
  -v "$BACKUP_DIR:/backup:ro" \
  alpine:latest \
  sh -lc '
    set -eu
    rm -rf /restore
    mkdir -p /restore
    tar -xzf "/backup/$BACKUP_FILE" -C /restore
    find /state/data -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    find /state/workbench -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    cp -a /restore/data/. /state/data/
    cp -a /restore/workbench/. /state/workbench/
  '

echo "Restored ${SLUG}_data and ${SLUG}_workbench from $BACKUP_PATH"
