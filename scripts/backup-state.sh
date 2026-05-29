#!/usr/bin/env bash
# Export assistant state volumes into a portable tarball.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# shellcheck source=scripts/lib/setup-store.sh
source "$ROOT/scripts/lib/setup-store.sh"
assistant_store_init "$ROOT"

INCLUDE_SECRETS=false
INCLUDE_DATA=false
INCLUDE_WORKBENCH=false
INCLUDE_DOCKER=false
BACKUP_HELPER_IMAGE="${BACKUP_HELPER_IMAGE:-alpine:3.20}"
OUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --include-secrets)
      INCLUDE_SECRETS=true
      shift
      ;;
    --include-data)
      INCLUDE_DATA=true
      shift
      ;;
    --include-workbench)
      INCLUDE_WORKBENCH=true
      shift
      ;;
    --include-docker)
      INCLUDE_DOCKER=true
      shift
      ;;
    -h | --help)
      echo "Usage: scripts/backup-state.sh [--include-secrets] [--include-data] [--include-workbench] [--include-docker] [output.tar.gz]" >&2
      exit 0
      ;;
    *)
      if [[ -n "$OUT" ]]; then
        echo "Unexpected argument: $1" >&2
        exit 2
      fi
      OUT="$1"
      shift
      ;;
  esac
done

if [[ ! -d "$ASSISTANT_CONFIG_DIR" ]]; then
  echo "No setup profile found. Run scripts/setup.sh before backing up." >&2
  exit 1
fi

if [[ "$INCLUDE_SECRETS" != "true" &&
  ("$INCLUDE_DATA" == "true" || "$INCLUDE_WORKBENCH" == "true" || "$INCLUDE_DOCKER" == "true") ]]; then
  echo "Runtime data, workbench checkouts, and inner Docker state can contain arbitrary secrets." >&2
  echo "Pass --include-secrets to create an explicitly sensitive backup." >&2
  exit 2
fi

ensure_store_dirs

SLUG="$(read_store_value config assistant_slug 2>/dev/null || true)"
SLUG="${SLUG:-hermes-assistant}"
if ! validate_assistant_slug "$SLUG"; then
  echo "Invalid assistant slug in setup profile: $SLUG" >&2
  echo "Run scripts/setup.sh to repair the local setup profile before backing up." >&2
  exit 2
fi
OUT="${OUT:-${SLUG}-state-$(date +%Y%m%d-%H%M%S).tar.gz}"
if [[ "$OUT" != /* ]]; then
  OUT="$ROOT/$OUT"
fi
OUT_DIR="$(cd "$(dirname "$OUT")" && pwd)"
OUT_FILE="$(basename "$OUT")"
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"
docker_args=(
  --rm
  -e "OUT_FILE=$OUT_FILE"
  -e "SLUG=$SLUG"
  -e "INCLUDE_SECRETS=$INCLUDE_SECRETS"
  -e "INCLUDE_DATA=$INCLUDE_DATA"
  -e "INCLUDE_WORKBENCH=$INCLUDE_WORKBENCH"
  -e "INCLUDE_DOCKER=$INCLUDE_DOCKER"
  -e "HOST_UID=$HOST_UID"
  -e "HOST_GID=$HOST_GID"
  -v "$ASSISTANT_CONFIG_DIR:/profile-config:ro"
  -v "$ASSISTANT_SECRETS_DIR:/profile-secrets:ro"
  -v "$OUT_DIR:/backup"
)

if [[ "$INCLUDE_DATA" == "true" ]]; then
  docker volume inspect "${SLUG}_data" >/dev/null
  docker_args+=(-v "${SLUG}_data:/data:ro")
fi

if [[ "$INCLUDE_WORKBENCH" == "true" ]]; then
  docker volume inspect "${SLUG}_workbench" >/dev/null
  docker_args+=(-v "${SLUG}_workbench:/workbench:ro")
fi

if [[ "$INCLUDE_DOCKER" == "true" ]]; then
  docker volume inspect "${SLUG}_docker" >/dev/null
  docker_args+=(-v "${SLUG}_docker:/docker:ro")
fi

docker run "${docker_args[@]}" \
  "$BACKUP_HELPER_IMAGE" \
  sh -lc '
    set -eu
    umask 077
    test -d /profile-config
    rm -rf /backup-staging
    mkdir -p /backup-staging/metadata /backup-staging/.assistant
    cp -a /profile-config /backup-staging/.assistant/config
    printf "%s\n" "$SLUG" > /backup-staging/metadata/assistant_slug
    date -u +"%Y-%m-%dT%H:%M:%SZ" > /backup-staging/metadata/created_at
    printf "%s\n" "$INCLUDE_SECRETS" > /backup-staging/metadata/includes_secrets
    printf "%s\n" "$INCLUDE_DATA" > /backup-staging/metadata/includes_data
    printf "%s\n" "$INCLUDE_WORKBENCH" > /backup-staging/metadata/includes_workbench
    printf "%s\n" "$INCLUDE_DOCKER" > /backup-staging/metadata/includes_docker

    if [ "$INCLUDE_DATA" = "true" ]; then
      test -d /data
      mkdir -p /backup-staging/data
      cp -a /data/. /backup-staging/data/
    fi

    if [ "$INCLUDE_WORKBENCH" = "true" ]; then
      test -d /workbench
      mkdir -p /backup-staging/workbench
      cp -a /workbench/. /backup-staging/workbench/
    fi

    if [ "$INCLUDE_DOCKER" = "true" ]; then
      test -d /docker
      mkdir -p /backup-staging/docker
      cp -a /docker/. /backup-staging/docker/
    fi

    if [ "$INCLUDE_SECRETS" = "true" ]; then
      cp -a /profile-secrets /backup-staging/.assistant/secrets
    else
      rm -f /backup-staging/data/config.yaml
      rm -f /backup-staging/data/google_client_secret.json
      rm -f /backup-staging/data/google_token.json
      rm -f /backup-staging/data/.hermes-google-client-secret.json.tmp
      rm -f /backup-staging/data/.codex/auth.json
      rm -rf /backup-staging/data/.config/gh
      rm -f /backup-staging/data/.config/opencode/auth.json
      rm -f /backup-staging/data/.local/share/opencode/auth.json
      rm -rf /backup-staging/data/.cursor
      rm -rf /backup-staging/data/.local/share/cursor-agent
    fi

    tar -czf "/backup/$OUT_FILE" -C /backup-staging .
    chmod 600 "/backup/$OUT_FILE"
    chown "$HOST_UID:$HOST_GID" "/backup/$OUT_FILE" 2>/dev/null || true
  '
chmod 600 "$OUT"

echo "Wrote $OUT"
if [[ "$INCLUDE_SECRETS" != "true" ]]; then
  echo "Known auth stores and setup secrets were excluded. Use --include-secrets only for a sensitive auth backup."
fi
if [[ "$INCLUDE_DATA" != "true" || "$INCLUDE_WORKBENCH" != "true" || "$INCLUDE_DOCKER" != "true" ]]; then
  echo "Runtime data, workbench, and inner Docker volumes are excluded unless their include flags are passed."
else
  echo "Review the archive before sharing; runtime state, repos, and Docker layers can contain sensitive content."
fi
