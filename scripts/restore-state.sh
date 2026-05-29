#!/usr/bin/env bash
# Restore assistant state volumes from a backup produced by backup-state.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# shellcheck source=scripts/lib/setup-store.sh
source "$ROOT/scripts/lib/setup-store.sh"
assistant_store_init "$ROOT"

SLUG_OVERRIDE=""
BACKUP_INPUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --slug)
      SLUG_OVERRIDE="${2:-}"
      if [[ -z "$SLUG_OVERRIDE" ]]; then
        echo "--slug requires a value" >&2
        exit 2
      fi
      shift 2
      ;;
    -h|--help)
      echo "Usage: scripts/restore-state.sh [--slug assistant-slug] <backup.tar.gz>" >&2
      exit 0
      ;;
    *)
      if [[ -n "$BACKUP_INPUT" ]]; then
        echo "Unexpected argument: $1" >&2
        exit 2
      fi
      BACKUP_INPUT="$1"
      shift
      ;;
  esac
done

if [[ -z "$BACKUP_INPUT" ]]; then
  echo "Usage: scripts/restore-state.sh [--slug assistant-slug] <backup.tar.gz>" >&2
  exit 2
fi

BACKUP_DIR="$(cd "$(dirname "$BACKUP_INPUT")" && pwd)"
BACKUP_FILE="$(basename "$BACKUP_INPUT")"
BACKUP_PATH="$BACKUP_DIR/$BACKUP_FILE"

test -f "$BACKUP_PATH"

restore_profile_from_backup() {
  local temp_dir="$1"
  if tar -xzf "$BACKUP_PATH" -C "$temp_dir" ./.assistant 2>/dev/null ||
    tar -xzf "$BACKUP_PATH" -C "$temp_dir" .assistant 2>/dev/null; then
    if [[ -d "$temp_dir/.assistant/config" ]]; then
      rm -rf "$ASSISTANT_CONFIG_DIR"
      mkdir -p "$ASSISTANT_STORE_ROOT/.assistant"
      cp -a "$temp_dir/.assistant/config" "$ASSISTANT_CONFIG_DIR"
    fi
    if [[ -d "$temp_dir/.assistant/secrets" ]]; then
      rm -rf "$ASSISTANT_SECRETS_DIR"
      mkdir -p "$ASSISTANT_STORE_ROOT/.assistant"
      cp -a "$temp_dir/.assistant/secrets" "$ASSISTANT_SECRETS_DIR"
    fi
    ensure_store_dirs
    find "$ASSISTANT_CONFIG_DIR" -type f -exec chmod 644 {} + 2>/dev/null || true
    find "$ASSISTANT_SECRETS_DIR" -type f -exec chmod 600 {} + 2>/dev/null || true
  fi
}

PROFILE_TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$PROFILE_TEMP_DIR"' EXIT
restore_profile_from_backup "$PROFILE_TEMP_DIR"

if [[ -n "$SLUG_OVERRIDE" ]]; then
  write_store_value config assistant_slug "$SLUG_OVERRIDE"
fi

SLUG="$SLUG_OVERRIDE"
if [[ -z "$SLUG" ]]; then
  SLUG="$(read_store_value config assistant_slug 2>/dev/null || true)"
fi
if [[ -z "$SLUG" ]]; then
  SLUG="$(tar -xOzf "$BACKUP_PATH" ./metadata/assistant_slug 2>/dev/null || tar -xOzf "$BACKUP_PATH" metadata/assistant_slug 2>/dev/null || true)"
fi
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
if [[ ! -d "$ASSISTANT_CONFIG_DIR" || ! -f "$ASSISTANT_SECRETS_DIR/telegram_bot_token" ]]; then
  echo "Run scripts/setup.sh to create or refresh the local setup profile before starting the assistant."
fi
