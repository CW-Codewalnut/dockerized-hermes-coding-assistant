#!/usr/bin/env bash
# Run docker compose with the setup profile loaded.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/setup-store.sh
source "$ROOT/scripts/lib/setup-store.sh"
assistant_store_init "$ROOT"

DOCKER_BIN="${DOCKER_BIN:-docker}"

compose_subcommand() {
  local -a args=("$@")
  local arg_index arg
  for ((arg_index = 0; arg_index < ${#args[@]}; arg_index++)); do
    arg="${args[$arg_index]}"
    case "$arg" in
      -f | --file | -p | --project-name | --profile | --project-directory | --env-file | --ansi | --parallel | --progress)
        arg_index=$((arg_index + 1))
        ;;
      -f?* | -p?*)
        ;;
      --file=* | --project-name=* | --profile=* | --project-directory=* | --env-file=* | --ansi=* | --parallel=* | --progress=*)
        ;;
      --all-resources | --compatibility | --dry-run)
        ;;
      --)
        if ((arg_index + 1 < ${#args[@]})); then
          printf '%s\n' "${args[$((arg_index + 1))]}"
        fi
        return 0
        ;;
      -*)
        ;;
      *)
        printf '%s\n' "$arg"
        return 0
        ;;
    esac
  done
}

subcommand="$(compose_subcommand "$@")"

profile_required=false
case "$subcommand" in
  build | create | run | scale | up | watch)
    profile_required=true
    ;;
esac

if [[ ! -d "$ASSISTANT_CONFIG_DIR" && "$profile_required" == "true" ]]; then
  echo "No setup profile found. Run scripts/setup.sh first." >&2
  exit 1
fi

missing=()
warnings=()
require_config() {
  local key="$1"
  if ! has_store_value config "$key"; then
    missing+=("config/$key")
  fi
}

warn_config() {
  local key="$1"
  if ! has_store_value config "$key"; then
    warnings+=("config/$key")
  fi
}

require_secret() {
  local key="$1"
  if ! has_store_value secret "$key"; then
    missing+=("secrets/$key")
  fi
}

if [[ -d "$ASSISTANT_CONFIG_DIR" ]]; then
  require_config assistant_name
  require_config assistant_slug
  require_config user_name
  require_config branch_prefix
  require_config dashboard_port
  require_config api_port
  require_config api_server_enabled
  require_config dockerd_storage_driver
  require_secret telegram_bot_token
  require_secret telegram_allowed_users
  warn_config git_user_name
  warn_config git_user_email

  api_enabled="$(read_store_value config api_server_enabled 2>/dev/null || true)"
  if [[ "$api_enabled" == "true" ]]; then
    require_secret api_server_key
  fi
fi

if [[ "$profile_required" == "true" && "${#missing[@]}" -gt 0 ]]; then
  echo "Setup profile is incomplete. Run scripts/setup.sh first." >&2
  printf 'Missing: %s\n' "${missing[@]}" >&2
  exit 1
fi

if [[ "$profile_required" == "true" && "${#warnings[@]}" -gt 0 ]]; then
  echo "Setup profile is missing post-start values. Run scripts/setup.sh to finish setup." >&2
  printf 'Missing: %s\n' "${warnings[@]}" >&2
fi

cd "$ROOT"
if [[ "$profile_required" == "true" ]]; then
  grant_runtime_store_access
fi
load_compose_env
exec "$DOCKER_BIN" compose "$@"
