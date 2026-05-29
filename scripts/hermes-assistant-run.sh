#!/usr/bin/env bash
# Launch Hermes after loading the setup-owned mounted profile files.
set -euo pipefail

CONFIG_DIR="${ASSISTANT_CONFIG_DIR:-/run/hermes-assistant/config}"
SECRETS_DIR="${ASSISTANT_SECRETS_DIR:-/run/hermes-assistant/secrets}"

read_profile_file() {
  local dir="$1"
  local key="$2"
  local path="$dir/$key"
  local value=""
  [[ -f "$path" ]] || return 1
  IFS= read -r value < "$path" || value=""
  printf '%s\n' "$value"
}

print_profile_debug() {
  echo "Setup profile debug:" >&2
  echo "  config dir: $CONFIG_DIR" >&2
  if [[ -d "$CONFIG_DIR" ]]; then
    find "$CONFIG_DIR" -maxdepth 1 -type f -printf '  config/%f\n' 2>/dev/null | sort >&2 || true
  else
    echo "  config dir missing" >&2
  fi
  echo "  secrets dir: $SECRETS_DIR" >&2
  if [[ -d "$SECRETS_DIR" ]]; then
    find "$SECRETS_DIR" -maxdepth 1 -type f -printf '  secrets/%f\n' 2>/dev/null | sort >&2 || true
  else
    echo "  secrets dir missing" >&2
  fi
  echo "Run scripts/setup.sh on the host to create a complete setup profile." >&2
}

export_config() {
  local env_name="$1"
  local key="$2"
  local fallback="${3:-}"
  local required="${4:-false}"
  local value
  value="$(read_profile_file "$CONFIG_DIR" "$key" 2>/dev/null || true)"
  value="${value:-$fallback}"
  if [[ -z "$value" && "$required" == "true" ]]; then
    echo "Missing required setup value: $key" >&2
    print_profile_debug
    exit 1
  fi
  export "$env_name=$value"
}

export_secret() {
  local env_name="$1"
  local key="$2"
  local required="${3:-false}"
  local value
  value="$(read_profile_file "$SECRETS_DIR" "$key" 2>/dev/null || true)"
  if [[ -z "$value" && "$required" == "true" ]]; then
    echo "Missing required setup secret: $key" >&2
    print_profile_debug
    exit 1
  fi
  if [[ -n "$value" ]]; then
    export "$env_name=$value"
  fi
}

export_config ASSISTANT_NAME assistant_name "" true
export_config ASSISTANT_SLUG assistant_slug "hermes-assistant"
export_config USER_NAME user_name "" true
export_config GIT_USER_NAME git_user_name ""
export_config GIT_USER_EMAIL git_user_email ""
export_config BRANCH_PREFIX branch_prefix "$ASSISTANT_SLUG"
export_config API_SERVER_ENABLED api_server_enabled "false"
export_config DOCKERD_STORAGE_DRIVER dockerd_storage_driver "overlay2"

export_secret TELEGRAM_BOT_TOKEN telegram_bot_token true
export_secret TELEGRAM_ALLOWED_USERS telegram_allowed_users true
export_secret API_SERVER_KEY api_server_key false

export HERMES_DASHBOARD="${HERMES_DASHBOARD:-1}"
export DOCKER_HOST="${DOCKER_HOST:-unix:///var/run/docker.sock}"
export DOCKER_BUILDKIT="${DOCKER_BUILDKIT:-1}"
export COMPOSE_DOCKER_CLI_BUILD="${COMPOSE_DOCKER_CLI_BUILD:-1}"

if [[ -n "${HERMES_GATEWAY_BIN:-}" ]]; then
  exec "$HERMES_GATEWAY_BIN" run
elif command -v gateway >/dev/null 2>&1; then
  exec "$(command -v gateway)" run
elif [[ -x /opt/hermes/.venv/bin/gateway ]]; then
  exec /opt/hermes/.venv/bin/gateway run
elif [[ -x /opt/hermes/.venv/bin/hermes ]] && /opt/hermes/.venv/bin/hermes gateway --help >/dev/null 2>&1; then
  exec /opt/hermes/.venv/bin/hermes gateway run
fi

cat >&2 <<'EOF'
Hermes gateway executable not found.
Expected one of:
  - gateway on PATH
  - /opt/hermes/.venv/bin/gateway
  - /opt/hermes/.venv/bin/hermes gateway run

Keeping the container alive so setup, auth, and debug commands can continue.
EOF

exec sleep infinity
