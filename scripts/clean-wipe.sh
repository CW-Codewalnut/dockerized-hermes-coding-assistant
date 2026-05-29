#!/usr/bin/env bash
# Remove this assistant's runtime footprint while preserving source files and local setup profile.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# shellcheck source=scripts/lib/setup-store.sh
source "$ROOT/scripts/lib/setup-store.sh"
assistant_store_init "$ROOT"

YES=false
PRUNE_SYSTEM=false
PRUNE_BUILDER=false
for arg in "$@"; do
  case "$arg" in
    -y | --yes) YES=true ;;
    --prune-builder-cache) PRUNE_BUILDER=true ;;
    --prune-system) PRUNE_SYSTEM=true ;;
    *)
      echo "Unknown option: $arg" >&2
      exit 2
      ;;
  esac
done

SLUG="$(read_store_value config assistant_slug 2>/dev/null || true)"
SLUG="${SLUG:-hermes-assistant}"
if ! validate_assistant_slug "$SLUG"; then
  echo "Invalid assistant slug in setup profile: $SLUG" >&2
  echo "Run scripts/setup.sh to repair the local setup profile before wiping." >&2
  exit 2
fi

if [[ "$YES" != true ]]; then
  echo "About to remove assistant runtime for slug '$SLUG':"
  echo "  - container: $SLUG"
  echo "  - image: ${SLUG}:local"
  echo "  - volumes: ${SLUG}_data, ${SLUG}_workbench, ${SLUG}_docker"
  if [[ "$PRUNE_BUILDER" == true ]]; then
    echo "  - Docker builder cache across the whole machine"
  fi
  if [[ "$PRUNE_SYSTEM" == true ]]; then
    echo "  - unused Docker containers/images/networks across the whole machine"
  fi
  echo "Preserved:"
  echo "  - .assistant/"
  echo "  - source files"
  read -rp "Continue? [y/N] " ans
  case "$ans" in
    y | Y | yes | YES | Yes) ;;
    *)
      echo "Aborted."
      exit 1
      ;;
  esac
fi

echo
echo "[1/5] Compose down ..."
compose down --remove-orphans -v 2>&1 | sed 's/^/    /' || true

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

if [[ "$PRUNE_BUILDER" == true ]]; then
  echo
  echo "[5/5] Pruning Docker builder cache ..."
  docker builder prune -af 2>&1 | tail -20 | sed 's/^/    /'
fi

if [[ "$PRUNE_SYSTEM" == true ]]; then
  echo
  echo "[extra] Pruning unused Docker objects across the whole machine ..."
  docker system prune -af 2>&1 | tail -40 | sed 's/^/    /'
fi

echo
echo "Done. Boot fresh with:"
echo "    scripts/setup.sh"
