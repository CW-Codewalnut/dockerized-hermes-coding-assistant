#!/usr/bin/env bash
# Shared helpers for the setup-owned local profile store.

ASSISTANT_STORE_ROOT=""
ASSISTANT_CONFIG_DIR=""
ASSISTANT_SECRETS_DIR=""

assistant_store_init() {
  ASSISTANT_STORE_ROOT="$1"
  ASSISTANT_CONFIG_DIR="$ASSISTANT_STORE_ROOT/.assistant/config"
  ASSISTANT_SECRETS_DIR="$ASSISTANT_STORE_ROOT/.assistant/secrets"
}

ensure_store_dirs() {
  mkdir -p "$ASSISTANT_CONFIG_DIR" "$ASSISTANT_SECRETS_DIR"
  chmod 700 "$ASSISTANT_STORE_ROOT/.assistant" "$ASSISTANT_CONFIG_DIR" "$ASSISTANT_SECRETS_DIR"
}

store_path() {
  local kind="$1"
  local key="$2"
  case "$kind" in
    config) printf '%s/%s\n' "$ASSISTANT_CONFIG_DIR" "$key" ;;
    secret) printf '%s/%s\n' "$ASSISTANT_SECRETS_DIR" "$key" ;;
    *) echo "Unknown store kind: $kind" >&2; return 2 ;;
  esac
}

read_store_value() {
  local kind="$1"
  local key="$2"
  local path value
  path="$(store_path "$kind" "$key")"
  [[ -f "$path" ]] || return 1
  IFS= read -r value < "$path" || value=""
  printf '%s\n' "$value"
}

write_store_value() {
  local kind="$1"
  local key="$2"
  local value="$3"
  local path mode
  ensure_store_dirs
  path="$(store_path "$kind" "$key")"
  mode=600
  [[ "$kind" == "config" ]] && mode=644
  umask 077
  printf '%s\n' "$value" > "$path"
  chmod "$mode" "$path"
}

has_store_value() {
  local kind="$1"
  local key="$2"
  local value
  value="$(read_store_value "$kind" "$key" 2>/dev/null || true)"
  [[ -n "$value" ]]
}

slugify() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g'
}

confirm() {
  local prompt="$1"
  local ans
  read -r -p "$prompt [Y/n]: " ans
  case "$ans" in
    n|N|no|NO|No) return 1 ;;
    *) return 0 ;;
  esac
}

prompt_stored_value() {
  local kind="$1"
  local key="$2"
  local label="$3"
  local default="${4:-}"
  local secret="${5:-false}"
  local required="${6:-false}"
  local current input prompt

  current="$(read_store_value "$kind" "$key" 2>/dev/null || true)"
  [[ -n "$current" ]] && return 0

  while true; do
    prompt="$label"
    if [[ -n "$default" ]]; then
      if [[ "$secret" == "true" ]]; then
        prompt="$prompt [press enter to use generated default]"
      else
        prompt="$prompt [$default]"
      fi
    fi
    prompt="$prompt: "

    if [[ "$secret" == "true" ]]; then
      read -r -s -p "$prompt" input
      echo
    else
      read -r -p "$prompt" input
    fi

    input="${input:-$default}"
    if [[ -n "$input" ]]; then
      write_store_value "$kind" "$key" "$input"
      return 0
    fi

    if [[ "$required" != "true" ]]; then
      return 0
    fi

    echo "$label is required."
  done
}

random_hex_32() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
  else
    od -An -N32 -tx1 /dev/urandom | tr -d ' \n'
    printf '\n'
  fi
}

load_compose_env() {
  local assistant_slug dashboard_port api_port
  assistant_slug="$(read_store_value config assistant_slug 2>/dev/null || true)"
  dashboard_port="$(read_store_value config dashboard_port 2>/dev/null || true)"
  api_port="$(read_store_value config api_port 2>/dev/null || true)"

  export ROCKY_ASSISTANT_SLUG="${assistant_slug:-hermes-assistant}"
  export ROCKY_DASHBOARD_PORT="${dashboard_port:-9119}"
  export ROCKY_API_PORT="${api_port:-8642}"
}

compose() {
  load_compose_env
  docker compose "$@"
}
