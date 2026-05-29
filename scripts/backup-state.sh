#!/usr/bin/env bash
# Export assistant state volumes into a portable tarball.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# shellcheck source=scripts/lib/setup-store.sh
source "$ROOT/scripts/lib/setup-store.sh"
assistant_store_init "$ROOT"

INCLUDE_SECRETS=false
OUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --include-secrets)
      INCLUDE_SECRETS=true
      shift
      ;;
    -h|--help)
      echo "Usage: scripts/backup-state.sh [--include-secrets] [output.tar.gz]" >&2
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

ensure_store_dirs

SLUG="$(read_store_value config assistant_slug 2>/dev/null || true)"
SLUG="${SLUG:-hermes-assistant}"
OUT="${OUT:-${SLUG}-state-$(date +%Y%m%d-%H%M%S).tar.gz}"
if [[ "$OUT" != /* ]]; then
  OUT="$ROOT/$OUT"
fi
OUT_DIR="$(cd "$(dirname "$OUT")" && pwd)"
OUT_FILE="$(basename "$OUT")"
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"

docker volume inspect "${SLUG}_data" >/dev/null
docker volume inspect "${SLUG}_workbench" >/dev/null
docker volume inspect "${SLUG}_docker" >/dev/null

docker run --rm \
  -e OUT_FILE="$OUT_FILE" \
  -e SLUG="$SLUG" \
  -e INCLUDE_SECRETS="$INCLUDE_SECRETS" \
  -e HOST_UID="$HOST_UID" \
  -e HOST_GID="$HOST_GID" \
  -v "${SLUG}_data:/data:ro" \
  -v "${SLUG}_workbench:/workbench:ro" \
  -v "${SLUG}_docker:/docker:ro" \
  -v "$ASSISTANT_CONFIG_DIR:/profile-config:ro" \
  -v "$ASSISTANT_SECRETS_DIR:/profile-secrets:ro" \
  -v "$OUT_DIR:/backup" \
  alpine:latest \
  sh -lc '
    set -eu
    umask 077
    test -d /data
    test -d /workbench
    test -d /docker
    test -d /profile-config
    rm -rf /backup-staging
    mkdir -p /backup-staging/data /backup-staging/workbench /backup-staging/docker /backup-staging/metadata /backup-staging/.assistant
    cp -a /data/. /backup-staging/data/
    cp -a /workbench/. /backup-staging/workbench/
    cp -a /docker/. /backup-staging/docker/
    cp -a /profile-config /backup-staging/.assistant/config
    printf "%s\n" "$SLUG" > /backup-staging/metadata/assistant_slug
    date -u +"%Y-%m-%dT%H:%M:%SZ" > /backup-staging/metadata/created_at
    printf "%s\n" "$INCLUDE_SECRETS" > /backup-staging/metadata/includes_secrets

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
  echo "Known auth stores and setup secrets were excluded. Use --include-secrets only for a full sensitive backup."
fi
