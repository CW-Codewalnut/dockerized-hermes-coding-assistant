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

exec gateway run
