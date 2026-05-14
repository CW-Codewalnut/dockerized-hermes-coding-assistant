#!/usr/bin/env bash
# Interactive one-command setup for a Dockerized Hermes assistant.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ENV_FILE="$ROOT/.env"
SERVICE="assistant"

get_env() {
  local key="$1"
  [[ -f "$ENV_FILE" ]] || return 0
  awk -v key="$key" '
    $0 ~ "^[[:space:]]*" key "=" {
      val = substr($0, index($0, "=") + 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
      if (val ~ /^".*"$/ || val ~ /^'\''.*'\''$/) val = substr(val, 2, length(val) - 2)
      print val
      exit
    }
  ' "$ENV_FILE"
}

quote_env() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

set_env() {
  local key="$1"
  local value="$2"
  local quoted
  quoted="\"$(quote_env "$value")\""
  awk -v key="$key" -v line="$key=$quoted" '
    BEGIN { done = 0 }
    $0 ~ "^[[:space:]]*" key "=" { print line; done = 1; next }
    { print }
    END { if (!done) print line }
  ' "$ENV_FILE" > "$ENV_FILE.tmp"
  mv "$ENV_FILE.tmp" "$ENV_FILE"
}

slugify() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g'
}

prompt_env() {
  local key="$1"
  local label="$2"
  local default="${3:-}"
  local secret="${4:-false}"
  local current input prompt
  current="$(get_env "$key")"
  [[ -n "$current" ]] && return 0

  prompt="$label"
  [[ -n "$default" ]] && prompt="$prompt [$default]"
  prompt="$prompt: "

  if [[ "$secret" == "true" ]]; then
    read -r -s -p "$prompt" input
    echo
  else
    read -r -p "$prompt" input
  fi

  input="${input:-$default}"
  [[ -n "$input" ]] && set_env "$key" "$input"
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

if [[ ! -f "$ENV_FILE" ]]; then
  cp .env.example "$ENV_FILE"
  chmod 600 "$ENV_FILE"
fi

echo "== Local identity =="
prompt_env ASSISTANT_NAME "Assistant name" "Hermes Assistant"
assistant_name="$(get_env ASSISTANT_NAME)"
prompt_env ASSISTANT_SLUG "Docker-safe assistant slug" "$(slugify "$assistant_name")"
prompt_env USER_NAME "Primary user/team name" ""
prompt_env GIT_USER_NAME "Git author name" "$(get_env USER_NAME)"
prompt_env GIT_USER_EMAIL "Git author email" ""
prompt_env BRANCH_PREFIX "Task branch prefix" "$(get_env ASSISTANT_SLUG)"
prompt_env DASHBOARD_PORT "Dashboard localhost port" "9119"
prompt_env API_PORT "API localhost port" "8642"
prompt_env DOCKER_MEMORY "Docker memory limit" "4G"
prompt_env DOCKER_CPUS "Docker CPU limit" "12.0"

echo
echo "== Credentials =="
prompt_env TELEGRAM_BOT_TOKEN "Telegram bot token" "" true
prompt_env TELEGRAM_ALLOWED_USERS "Telegram allowed user IDs, comma-separated" ""
prompt_env GH_TOKEN "GitHub classic PAT" "" true
prompt_env API_SERVER_ENABLED "Enable external API server" "false"

if ! docker info >/dev/null 2>&1; then
  echo "Docker is not running. Start Docker Desktop, then rerun scripts/setup.sh." >&2
  exit 1
fi

echo
echo "== Build and start =="
docker compose up -d --build

echo
echo "Waiting for container ..."
for _ in {1..90}; do
  if docker compose exec -T "$SERVICE" true >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
docker compose exec -T "$SERVICE" true >/dev/null

echo
echo "== Interactive logins =="
if confirm "Run Hermes model setup now"; then
  docker compose exec -u hermes -it "$SERVICE" hermes setup model
fi

if confirm "Run Codex device login now"; then
  docker compose exec -u hermes -it "$SERVICE" codex login --device-auth
fi

if confirm "Run OpenCode auth login now"; then
  docker compose exec -u hermes -it "$SERVICE" opencode auth login
fi

echo
echo "== Verification =="
docker compose exec -T "$SERVICE" sh -lc '
  set -eu
  test -n "${TELEGRAM_BOT_TOKEN:-}" && echo "Telegram token: present" || { echo "Telegram token: missing"; exit 1; }
  test -n "${TELEGRAM_ALLOWED_USERS:-}" && echo "Telegram allowed users: present" || { echo "Telegram allowed users: missing"; exit 1; }
  test -n "${GH_TOKEN:-}" && echo "GitHub token: present" || { echo "GitHub token: missing"; exit 1; }
  ! grep -R "<ASSISTANT_NAME>\|<USER_NAME>\|<GIT_USER_NAME>\|<GIT_USER_EMAIL>\|<BRANCH_PREFIX>" /opt/data/SOUL.md /opt/data/AGENTS.md /opt/data/coding-agents/AGENTS.md >/dev/null
  echo "Runtime instruction placeholders: replaced"
'

docker compose exec -T "$SERVICE" sh -lc '
  if command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    ok="$(curl -fsS "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getMe" | jq -r .ok)"
    test "$ok" = "true" && echo "Telegram token: valid"
  fi
'

docker compose exec -T "$SERVICE" gh auth status
docker compose exec -T -u hermes "$SERVICE" sh -lc 'test -s "$HOME/.codex/auth.json" && echo "Codex auth: present" || echo "Codex auth: not found"'
docker compose exec -T -u hermes "$SERVICE" sh -lc 'find "$HOME/.local/share/opencode" "$HOME/.config/opencode" -type f 2>/dev/null | grep -q . && echo "OpenCode auth/config: present" || echo "OpenCode auth/config: not found"'
docker compose exec -T -u hermes "$SERVICE" hermes status || true

echo
echo "Setup complete."
echo "Dashboard: http://localhost:$(get_env DASHBOARD_PORT)"
