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
YES=false
RESTORE_HELPER_IMAGE="${RESTORE_HELPER_IMAGE:-alpine:3.20}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y | --yes)
      YES=true
      shift
      ;;
    --slug)
      SLUG_OVERRIDE="${2:-}"
      if [[ -z "$SLUG_OVERRIDE" ]]; then
        echo "--slug requires a value" >&2
        exit 2
      fi
      shift 2
      ;;
    -h | --help)
      echo "Usage: scripts/restore-state.sh [--yes] [--slug assistant-slug] <backup.tar.gz>" >&2
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
  echo "Usage: scripts/restore-state.sh [--yes] [--slug assistant-slug] <backup.tar.gz>" >&2
  exit 2
fi

BACKUP_DIR="$(cd "$(dirname "$BACKUP_INPUT")" && pwd)"
BACKUP_FILE="$(basename "$BACKUP_INPUT")"
BACKUP_PATH="$BACKUP_DIR/$BACKUP_FILE"

test -f "$BACKUP_PATH"

validate_slug() {
  local slug="$1"
  if validate_assistant_slug "$slug"; then
    return 0
  fi
  echo "Invalid assistant slug: $slug" >&2
  echo "Use lowercase letters, numbers, and hyphens only." >&2
  exit 2
}

validate_backup_member_types() {
  local listing type_char
  while IFS= read -r listing; do
    type_char="${listing:0:1}"
    case "$type_char" in
      - | d) ;;
      *)
        echo "Unsupported backup member type: $listing" >&2
        echo "Only regular files and directories are accepted." >&2
        exit 2
        ;;
    esac
  done < <(tar -tvzf "$BACKUP_PATH")
}

validate_backup_members() {
  local member normalized
  while IFS= read -r member; do
    normalized="$member"
    while [[ "$normalized" == ./* ]]; do
      normalized="${normalized#./}"
    done
    case "$normalized" in
      "" | "." | /* | ".." | ../* | */.. | */../*)
        echo "Unsafe backup member path: $member" >&2
        exit 2
        ;;
    esac
  done < <(tar -tzf "$BACKUP_PATH")
}

has_volume_payload() {
  [[ -d "$BACKUP_TEMP_DIR/data" || -d "$BACKUP_TEMP_DIR/workbench" || -d "$BACKUP_TEMP_DIR/docker" ]]
}

refuse_running_container() {
  local state running restarting
  state="$(docker inspect -f '{{.State.Running}} {{.State.Restarting}}' "$SLUG" 2>/dev/null || true)"
  [[ -n "$state" ]] || return 0
  read -r running restarting <<<"$state"
  if [[ "$running" == "true" || "$restarting" == "true" ]]; then
    echo "Refusing to restore volumes while container '$SLUG' is running or restarting." >&2
    echo "Stop it first with: scripts/compose.sh down" >&2
    exit 1
  fi
}

confirm_restore() {
  if [[ "$YES" == true ]]; then
    return 0
  fi
  if [[ ! -t 0 ]]; then
    echo "Refusing destructive restore without --yes in a non-interactive shell." >&2
    exit 2
  fi

  echo "About to replace assistant state for slug '$SLUG':"
  [[ -d "$BACKUP_TEMP_DIR/data" ]] && echo "  - volume: ${SLUG}_data"
  [[ -d "$BACKUP_TEMP_DIR/workbench" ]] && echo "  - volume: ${SLUG}_workbench"
  [[ -d "$BACKUP_TEMP_DIR/docker" ]] && echo "  - volume: ${SLUG}_docker"
  [[ -d "$BACKUP_TEMP_DIR/.assistant/config" ]] && echo "  - local profile config: .assistant/config"
  [[ -d "$BACKUP_TEMP_DIR/.assistant/secrets" ]] && echo "  - local profile secrets: .assistant/secrets"
  read -rp "Continue? [y/N] " ans
  case "$ans" in
    y | Y | yes | YES | Yes) ;;
    *)
      echo "Aborted."
      exit 1
      ;;
  esac
}

restore_profile_from_stage() {
  local temp_dir="$1"
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
  if [[ -d "$ASSISTANT_STORE_ROOT/.assistant" ]]; then
    ensure_store_dirs
    find "$ASSISTANT_CONFIG_DIR" -type f -exec chmod 644 {} + 2>/dev/null || true
    find "$ASSISTANT_SECRETS_DIR" -type f -exec chmod 600 {} + 2>/dev/null || true
  fi
}

validate_backup_member_types
validate_backup_members
BACKUP_TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$BACKUP_TEMP_DIR"' EXIT
tar -xzf "$BACKUP_PATH" -C "$BACKUP_TEMP_DIR"

if [[ ! -d "$BACKUP_TEMP_DIR/data" &&
  ! -d "$BACKUP_TEMP_DIR/workbench" &&
  ! -d "$BACKUP_TEMP_DIR/docker" &&
  ! -d "$BACKUP_TEMP_DIR/.assistant/config" &&
  ! -d "$BACKUP_TEMP_DIR/.assistant/secrets" ]]; then
  echo "Backup does not contain any restorable assistant payload." >&2
  exit 2
fi

if [[ -n "$SLUG_OVERRIDE" ]]; then
  validate_slug "$SLUG_OVERRIDE"
fi

SLUG="$SLUG_OVERRIDE"
if [[ -z "$SLUG" ]]; then
  if [[ -f "$BACKUP_TEMP_DIR/metadata/assistant_slug" ]]; then
    IFS= read -r SLUG <"$BACKUP_TEMP_DIR/metadata/assistant_slug" || SLUG=""
  fi
fi
SLUG="${SLUG:-hermes-assistant}"
validate_slug "$SLUG"

if has_volume_payload; then
  refuse_running_container
fi

confirm_restore
if has_volume_payload; then
  docker volume create "${SLUG}_data" >/dev/null
  docker volume create "${SLUG}_workbench" >/dev/null
  docker volume create "${SLUG}_docker" >/dev/null

  docker run --rm \
    -v "${SLUG}_data:/data" \
    -v "${SLUG}_workbench:/workbench" \
    -v "${SLUG}_docker:/docker" \
    -v "$BACKUP_TEMP_DIR:/restore:ro" \
    "$RESTORE_HELPER_IMAGE" \
    sh -lc '
      set -eu
      test -d /data
      test -d /workbench
      test -d /docker
      if [ -d /restore/data ]; then
        find /data -mindepth 1 -maxdepth 1 -exec rm -rf {} +
        cp -a /restore/data/. /data/
      fi
      if [ -d /restore/workbench ]; then
        find /workbench -mindepth 1 -maxdepth 1 -exec rm -rf {} +
        cp -a /restore/workbench/. /workbench/
      fi
      if [ -d /restore/docker ]; then
        find /docker -mindepth 1 -maxdepth 1 -exec rm -rf {} +
        cp -a /restore/docker/. /docker/
      fi
    '
fi

restore_profile_from_stage "$BACKUP_TEMP_DIR"
if [[ -n "$SLUG_OVERRIDE" ]]; then
  write_store_value config assistant_slug "$SLUG_OVERRIDE"
fi

echo "Restored backup for slug '$SLUG' from $BACKUP_PATH"
if [[ ! -d "$ASSISTANT_CONFIG_DIR" || ! -f "$ASSISTANT_SECRETS_DIR/telegram_bot_token" ]]; then
  echo "Run scripts/setup.sh to create or refresh the local setup profile before starting the assistant."
fi
