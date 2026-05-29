#!/usr/bin/env bash
# Remove this assistant's runtime footprint while preserving source files and .env.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

YES=false
PRUNE_SYSTEM=false
for arg in "$@"; do
  case "$arg" in
    -y|--yes) YES=true ;;
    --prune-system) PRUNE_SYSTEM=true ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

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

if [[ "$YES" != true ]]; then
  echo "About to remove assistant runtime for slug '$SLUG':"
  echo "  - container: $SLUG"
  echo "  - image: ${SLUG}:local"
  echo "  - volumes: ${SLUG}_data, ${SLUG}_workbench, ${SLUG}_docker"
  echo "  - Docker builder cache"
  if [[ "$PRUNE_SYSTEM" == true ]]; then
    echo "  - unused Docker containers/images/networks across the whole machine"
  fi
  echo "Preserved:"
  echo "  - .env"
  echo "  - source files"
  read -rp "Continue? [y/N] " ans
  case "$ans" in
    y|Y|yes|YES|Yes) ;;
    *) echo "Aborted."; exit 1 ;;
  esac
fi

echo
echo "[1/5] Compose down ..."
docker compose down --remove-orphans -v 2>&1 | sed 's/^/    /' || true

echo
echo "[2/5] Removing assistant container ..."
docker rm -f "$SLUG" 2>&1 | sed 's/^/    /' || true

echo
echo "[3/5] Removing assistant image ..."
docker image rm "${SLUG}:local" 2>&1 | sed 's/^/    /' || true

echo
echo "[4/5] Removing assistant volumes ..."
docker volume rm \
  "${SLUG}_data" "${SLUG}_workbench" "${SLUG}_docker" 2>&1 | sed 's/^/    /' || true

echo
echo "[5/5] Pruning Docker builder cache ..."
docker builder prune -af 2>&1 | tail -20 | sed 's/^/    /'

if [[ "$PRUNE_SYSTEM" == true ]]; then
  echo
  echo "[extra] Pruning unused Docker objects across the whole machine ..."
  docker system prune -af 2>&1 | tail -40 | sed 's/^/    /'
fi

echo
echo "Done. Boot fresh with:"
echo "    scripts/setup.sh"
