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

print_google_workspace_skip_instructions() {
  cat <<'EOF'
Skipped Google Workspace setup.

To finish later, rerun `scripts/setup.sh` and answer yes at the Google Workspace
prompt, or follow the README "Google Workspace" section manually.

You will need:
  - a Google Cloud project;
  - Gmail, Calendar, Drive, Sheets, Docs, and People APIs enabled as needed;
  - an OAuth 2.0 Desktop client JSON downloaded from Google Cloud Console.
EOF
}

setup_google_workspace() {
  local gsetup container_secret client_secret_path auth_url oauth_callback
  gsetup='python "$HERMES_HOME/skills/productivity/google-workspace/scripts/setup.py"'
  container_secret="/tmp/hermes-google-client-secret.json"

  echo
  echo "== Google Workspace =="

  docker compose exec -T -u hermes "$SERVICE" sh -lc 'command -v gws >/dev/null'

  if docker compose exec -T -u hermes "$SERVICE" sh -lc "$gsetup --check" >/dev/null 2>&1; then
    echo "Google Workspace auth: already configured"
    return 0
  fi

  cat <<'EOF'
Google Workspace setup is optional but recommended if this assistant should use
Gmail, Calendar, Drive, Docs, Sheets, or Contacts.

Before continuing, create a Google OAuth Desktop client:
  1. Open https://console.cloud.google.com/projectselector2/home/dashboard
  2. Create or select a project.
  3. Enable the APIs you need from https://console.cloud.google.com/apis/library
     Recommended: Gmail API, Google Calendar API, Google Drive API,
     Google Sheets API, Google Docs API, People API.
  4. Open https://console.cloud.google.com/apis/credentials
  5. Create Credentials -> OAuth client ID -> Desktop app.
  6. If the app is in testing mode, add your account at:
     https://console.cloud.google.com/auth/audience
  7. Download the OAuth client JSON.
EOF

  if ! confirm "Set up Google Workspace now"; then
    print_google_workspace_skip_instructions
    return 0
  fi

  if docker compose exec -T -u hermes "$SERVICE" test -s /opt/data/google_client_secret.json; then
    echo "Google OAuth client secret: already stored"
  else
    while true; do
      read -r -p "Path to downloaded OAuth Desktop client JSON (blank to skip): " client_secret_path
      if [[ -z "$client_secret_path" ]]; then
        print_google_workspace_skip_instructions
        return 0
      fi
      if [[ -f "$client_secret_path" ]]; then
        break
      fi
      echo "File not found: $client_secret_path"
    done

    docker compose cp "$client_secret_path" "$SERVICE:$container_secret"
    docker compose exec -T "$SERVICE" sh -lc "chown 10000:10000 '$container_secret' && chmod 600 '$container_secret'"
    docker compose exec -T -u hermes "$SERVICE" sh -lc "$gsetup --client-secret '$container_secret'"
    docker compose exec -T "$SERVICE" rm -f "$container_secret"
  fi

  auth_url="$(docker compose exec -T -u hermes "$SERVICE" sh -lc "$gsetup --auth-url")"

  echo
  echo "Open this URL in your browser and approve access:"
  echo "$auth_url"
  echo
  echo "The browser will probably fail to load http://localhost:1 after approval."
  echo "That is expected. Copy the full redirected URL from the browser address bar."
  echo
  read -r -p "Paste the full redirected URL or auth code (blank to finish later): " oauth_callback
  if [[ -z "$oauth_callback" ]]; then
    cat <<'EOF'
Google Workspace authorization is pending.

To finish later, rerun `scripts/setup.sh` and answer yes at the Google Workspace
prompt, or run this inside the container:
  GSETUP="python $HERMES_HOME/skills/productivity/google-workspace/scripts/setup.py"
  $GSETUP --auth-url
  $GSETUP --auth-code 'PASTE_FULL_REDIRECT_URL_HERE'
EOF
    return 0
  fi

  docker compose exec -T -u hermes "$SERVICE" sh -lc "$gsetup --auth-code \"\$1\"" sh "$oauth_callback"

  if docker compose exec -T -u hermes "$SERVICE" sh -lc "$gsetup --check-live"; then
    echo "Google Workspace auth: configured"
  else
    echo "Google Workspace token was stored, but live verification failed. Check enabled APIs and OAuth scopes." >&2
  fi
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
prompt_env GH_TOKEN "GitHub classic PAT with repo/gist scopes" "" true
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

setup_google_workspace

echo
echo "== Verification =="
docker compose exec -T "$SERVICE" sh -lc '
  set -eu
  test -n "${TELEGRAM_BOT_TOKEN:-}" && echo "Telegram token: present" || { echo "Telegram token: missing"; exit 1; }
  test -n "${TELEGRAM_ALLOWED_USERS:-}" && echo "Telegram allowed users: present" || { echo "Telegram allowed users: missing"; exit 1; }
  test -n "${GH_TOKEN:-}" && echo "GitHub token: present" || { echo "GitHub token: missing"; exit 1; }
  ! grep -R "<ASSISTANT_NAME>\|<USER_NAME>\|<GIT_USER_NAME>\|<GIT_USER_EMAIL>\|<BRANCH_PREFIX>" /opt/data/SOUL.md /opt/data/AGENTS.md /opt/data/coding-agents/AGENTS.md >/dev/null
  ! grep -R "Replace these placeholders before running the assistant:" /opt/data/SOUL.md /opt/data/AGENTS.md /opt/data/coding-agents/AGENTS.md >/dev/null
  echo "Runtime instruction placeholders: replaced"
'

docker compose exec -T "$SERVICE" sh -lc '
  if command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    ok="$(curl -fsS "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getMe" | jq -r .ok)"
    test "$ok" = "true" && echo "Telegram token: valid"
  fi
'

docker compose exec -T "$SERVICE" gh auth status
docker compose exec -T "$SERVICE" sh -lc '
  set -eu
  scopes="$(gh api -i /user 2>/dev/null | tr -d "\r" | awk -F": " "tolower(\$1)==\"x-oauth-scopes\" {print \$2; exit}")"
  case ",$scopes," in
    *", gist,"*|*",gist,"*|*", gist"*)
      echo "GitHub gist scope: present"
      ;;
    *)
      echo "GitHub gist scope: missing; regenerate GH_TOKEN with the gist scope" >&2
      exit 1
      ;;
  esac
  gh gist list --limit 1 >/dev/null
  echo "GitHub gist read: ok"
'
docker compose exec -T -u hermes "$SERVICE" sh -lc 'test -s "$HOME/.codex/auth.json" && echo "Codex auth: present" || echo "Codex auth: not found"'
docker compose exec -T -u hermes "$SERVICE" sh -lc 'find "$HOME/.local/share/opencode" "$HOME/.config/opencode" -type f 2>/dev/null | grep -q . && echo "OpenCode auth/config: present" || echo "OpenCode auth/config: not found"'
docker compose exec -T -u hermes "$SERVICE" sh -lc '
  set -eu
  command -v gws >/dev/null
  echo "Google Workspace CLI: $(gws --version | head -n1)"
  if python "$HERMES_HOME/skills/productivity/google-workspace/scripts/setup.py" --check >/dev/null 2>&1; then
    echo "Google Workspace auth: present"
  else
    echo "Google Workspace auth: not configured"
  fi
'
docker compose exec -T -u hermes "$SERVICE" hermes status || true

echo
echo "Setup complete."
echo "Dashboard: http://localhost:$(get_env DASHBOARD_PORT)"
