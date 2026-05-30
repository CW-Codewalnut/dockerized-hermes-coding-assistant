#!/usr/bin/env bash
# Interactive one-command setup for a Dockerized Hermes assistant.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVICE="assistant"
cd "$ROOT"

# shellcheck source=scripts/lib/setup-store.sh
source "$ROOT/scripts/lib/setup-store.sh"
assistant_store_init "$ROOT"

_SETUP_STTY_STATE=""
SETUP_TEMP_FILES=()
SETUP_CONTAINER_TEMP_SECRET=""
OPTIONAL_STEP_ACTIVE=false
OPTIONAL_STEP_INTERRUPTED=false
OPTIONAL_STEP_NAME=""

cleanup_setup_temps() {
  if [[ "${#SETUP_TEMP_FILES[@]}" -gt 0 ]]; then
    rm -f "${SETUP_TEMP_FILES[@]}" 2>/dev/null || true
  fi
  if [[ -n "$SETUP_CONTAINER_TEMP_SECRET" ]]; then
    compose exec -T "$SERVICE" rm -f "$SETUP_CONTAINER_TEMP_SECRET" >/dev/null 2>&1 || true
  fi
}

setup_interrupt() {
  setup_enable_echo
  if [[ "$OPTIONAL_STEP_ACTIVE" == "true" ]]; then
    OPTIONAL_STEP_INTERRUPTED=true
    echo
    echo "Skipping ${OPTIONAL_STEP_NAME:-optional setup step}."
    return 130
  fi
  cleanup_setup_temps
  echo
  exit 130
}

trap setup_interrupt INT TERM
trap cleanup_setup_temps EXIT

setup_disable_echo() {
  if [[ -t 0 && -z "$_SETUP_STTY_STATE" ]]; then
    _SETUP_STTY_STATE="$(stty -g)"
    stty -echo
  fi
}

setup_enable_echo() {
  if [[ -n "$_SETUP_STTY_STATE" ]]; then
    stty "$_SETUP_STTY_STATE"
    _SETUP_STTY_STATE=""
  fi
}

run_with_optional_interrupt() {
  local label="$1"
  local status
  shift

  OPTIONAL_STEP_ACTIVE=true
  OPTIONAL_STEP_INTERRUPTED=false
  OPTIONAL_STEP_NAME="$label"

  # Capture the optional step status in the parent while preserving errexit
  # inside the step itself. Calling shell functions from an `if`/`||` condition
  # disables errexit throughout that function body, which hid real setup errors.
  set +e
  (
    set -Eeuo pipefail
    trap setup_interrupt INT TERM
    trap cleanup_setup_temps EXIT
    "$@"
  )
  status=$?
  set -e

  OPTIONAL_STEP_ACTIVE=false
  OPTIONAL_STEP_NAME=""

  if [[ "$OPTIONAL_STEP_INTERRUPTED" == "true" || "$status" -eq 130 ]]; then
    setup_enable_echo
    OPTIONAL_STEP_INTERRUPTED=false
    return 130
  fi

  return "$status"
}

retry_optional_auth() {
  local label="$1"
  local status retry_status
  shift

  while true; do
    if run_with_optional_interrupt "$label" "$@"; then
      status=0
    else
      status=$?
    fi
    case "$status" in
      0)
        return 0
        ;;
      130)
        echo "$label skipped."
        return 130
        ;;
    esac

    echo "$label failed." >&2
    if run_with_optional_interrupt "$label" confirm "Try $label again"; then
      retry_status=0
    else
      retry_status=$?
    fi
    case "$retry_status" in
      0) ;;
      130)
        echo "$label skipped."
        return 130
        ;;
      *)
        return "$status"
        ;;
    esac
  done
}

run_optional_login_prompt() {
  local prompt="$1"
  local label="$2"
  local status
  shift 2

  if run_with_optional_interrupt "$label" confirm "$prompt"; then
    status=0
  else
    status=$?
  fi
  case "$status" in
    0) ;;
    130)
      echo "$label skipped."
      return 0
      ;;
    *)
      echo "$label skipped."
      return 0
      ;;
  esac

  if retry_optional_auth "$label" "$@"; then
    status=0
  else
    status=$?
  fi
  if [[ "$status" -ne 0 && "$status" -ne 130 ]]; then
    echo "$label failed; continuing setup." >&2
  fi
  return 0
}

json_file_is_valid() {
  local path="$1"
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json, sys; json.load(open(sys.argv[1]))' "$path" >/dev/null 2>&1
  elif command -v python >/dev/null 2>&1; then
    python -c 'import json, sys; json.load(open(sys.argv[1]))' "$path" >/dev/null 2>&1
  else
    return 1
  fi
}

read_google_client_secret_json() {
  local output_path="$1"
  local first_line="${2:-}"
  local line

  : >"$output_path"
  setup_disable_echo
  if [[ -n "$first_line" ]]; then
    printf '%s\n' "$first_line" >>"$output_path"
  fi

  while ! json_file_is_valid "$output_path"; do
    if ! IFS= read -r line; then
      break
    fi
    [[ "$line" == "END_GOOGLE_JSON" ]] && break
    printf '%s\n' "$line" >>"$output_path"
  done
  setup_enable_echo
  echo
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

validate_container_profile() {
  local missing=()

  for key in assistant_name assistant_slug user_name branch_prefix dashboard_port api_port api_server_enabled dockerd_storage_driver; do
    if ! has_store_value config "$key"; then
      missing+=("config/$key")
    fi
  done

  for key in telegram_bot_token telegram_allowed_users; do
    if ! has_store_value secret "$key"; then
      missing+=("secrets/$key")
    fi
  done

  if [[ "${#missing[@]}" -gt 0 ]]; then
    echo "Setup profile is incomplete; refusing to start the container." >&2
    printf 'Missing: %s\n' "${missing[@]}" >&2
    echo "Run scripts/setup.sh in an interactive terminal to fill these values." >&2
    exit 1
  fi
}

assistant_container_name() {
  local name
  name="$(read_store_value config assistant_slug 2>/dev/null || true)"
  printf '%s\n' "${name:-hermes-assistant}"
}

container_id() {
  local name
  name="$(assistant_container_name)"
  docker ps -aq --filter "name=^/${name}$" | head -n1
}

container_state() {
  local id="$1"
  docker inspect -f '{{.State.Running}} {{.State.Restarting}} {{.State.Status}} {{.State.ExitCode}} {{.State.Error}}' "$id" 2>/dev/null || true
}

container_running() {
  local id state running restarting
  id="$(container_id)"
  [[ -n "$id" ]] || return 1
  state="$(container_state "$id")"
  read -r running restarting _ <<<"$state"
  [[ "$running" == "true" && "$restarting" != "true" ]]
}

print_container_debug() {
  local name
  name="$(assistant_container_name)"
  echo
  echo "Container did not become stable. Container status:"
  docker ps -a --filter "name=^/${name}$" 2>&1 | sed 's/^/    /' || true
  echo
  echo "Recent container logs:"
  docker logs --tail=180 "$name" 2>&1 | sed 's/^/    /' || true
}

wait_for_container() {
  local attempt id state
  echo
  echo "Waiting for container ..."
  for attempt in {1..60}; do
    if container_running; then
      return 0
    fi
    if ((attempt == 1 || attempt % 10 == 0)); then
      id="$(container_id)"
      if [[ -n "$id" ]]; then
        state="$(container_state "$id")"
        echo "  container state: ${state:-unknown}"
      else
        echo "  container state: not created yet"
      fi
    fi
    sleep 2
  done
  print_container_debug
  return 1
}

compose_exec() {
  local timeout_seconds="$1"
  local docker_args=()
  local service container
  shift

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -T)
        shift
        ;;
      -u | --user | -e | --env | -w | --workdir)
        docker_args+=("$1" "$2")
        shift 2
        ;;
      --user=* | --env=* | --workdir=*)
        docker_args+=("$1")
        shift
        ;;
      -*)
        docker_args+=("$1")
        shift
        ;;
      *)
        break
        ;;
    esac
  done

  service="$1"
  shift
  if [[ "$service" == "$SERVICE" ]]; then
    container="$(assistant_container_name)"
  else
    container="$service"
  fi

  if command -v timeout >/dev/null 2>&1; then
    timeout "${timeout_seconds}s" docker exec "${docker_args[@]}" "$container" "$@"
  else
    docker exec "${docker_args[@]}" "$container" "$@"
  fi
}

inner_docker_ready() {
  compose_exec 4 -u hermes "$SERVICE" docker info >/dev/null 2>&1
}

wait_for_inner_docker_once() {
  local attempt
  echo "Waiting for inner Docker daemon ..."
  for attempt in {1..20}; do
    if inner_docker_ready; then
      return 0
    fi
    if ((attempt == 1 || attempt % 5 == 0)); then
      echo "  inner Docker not ready yet (${attempt}/20)"
    fi
    sleep 2
  done
  inner_docker_ready
}

print_inner_docker_debug() {
  echo
  echo "Inner Docker did not become ready. Recent container logs:"
  compose logs --tail=160 "$SERVICE" 2>&1 | sed 's/^/    /' || true
  echo
  echo "Inner Docker process/socket state:"
  compose_exec 5 "$SERVICE" sh -lc '
    set +e
    echo "dockerd service:"
    s6-svstat /run/service/dockerd 2>/dev/null || true
    ls -la /etc/services.d/dockerd /run/service/dockerd 2>/dev/null || true
    echo
    echo "dockerd process:"
    ps -ef | grep "[d]ockerd"
    echo
    echo "dockerd socket/state:"
    ls -l /var/run/docker.sock /var/lib/docker 2>/dev/null
    echo
    echo "dockerd log:"
    tail -80 /var/log/docker.log 2>/dev/null
  ' 2>&1 | sed 's/^/    /' || true
}

retry_inner_docker_driver() {
  local driver="$1"
  echo
  echo "Inner Docker did not become ready; retrying ${driver} ..."
  write_store_value config dockerd_storage_driver "$driver"
  compose up -d --force-recreate
  wait_for_container
  wait_for_inner_docker_once
}

wait_for_inner_docker() {
  local driver
  if wait_for_inner_docker_once; then
    return 0
  fi

  driver="$(read_store_value config dockerd_storage_driver 2>/dev/null || true)"
  case "${driver:-overlay2}" in
    overlay2)
      retry_inner_docker_driver "fuse-overlayfs" && return 0
      retry_inner_docker_driver "vfs" && return 0
      ;;
    fuse-overlayfs)
      retry_inner_docker_driver "vfs" && return 0
      ;;
  esac

  print_inner_docker_debug
  return 1
}

warn_inner_docker_degraded() {
  cat <<'EOF'

WARNING: Inner Docker did not become ready.
Continuing setup without Docker-in-Docker. Coding-agent tasks that need docker
inside the assistant will fail until inner Docker is fixed.

After setup, inspect with:
  scripts/compose.sh logs --tail=200 assistant
  scripts/compose.sh exec assistant sh -lc 'tail -120 /var/log/docker.log'
EOF
}

wait_for_inner_docker_or_warn() {
  if wait_for_inner_docker; then
    return 0
  fi
  warn_inner_docker_degraded
  return 0
}

normalize_bool_config() {
  local key="$1"
  local label="$2"
  local default="$3"
  local value

  value="$(read_store_value config "$key" 2>/dev/null || true)"
  if [[ -z "$value" ]]; then
    prompt_stored_value config "$key" "$label" "$default" false false
    value="$(read_store_value config "$key" 2>/dev/null || true)"
  fi

  case "$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')" in
    true | yes | y | 1) write_store_value config "$key" "true" ;;
    false | no | n | 0 | "") write_store_value config "$key" "false" ;;
    *)
      echo "$label must be true or false."
      rm -f "$(store_path config "$key")"
      prompt_stored_value config "$key" "$label" "$default" false false
      normalize_bool_config "$key" "$label" "$default"
      ;;
  esac
}

validate_slug_config() {
  local key="$1"
  local label="$2"
  local default="$3"
  local value

  while true; do
    value="$(read_store_value config "$key" 2>/dev/null || true)"
    if [[ "$value" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
      return 0
    fi
    [[ -n "$value" ]] && echo "$label must use lowercase letters, numbers, and hyphens only."
    rm -f "$(store_path config "$key")"
    prompt_stored_value config "$key" "$label" "$default" false true
  done
}

validate_branch_prefix_config() {
  local key="$1"
  local label="$2"
  local default="$3"
  local value

  while true; do
    value="$(read_store_value config "$key" 2>/dev/null || true)"
    if [[ "$value" =~ ^[A-Za-z0-9._/-]+$ && "$value" != */ && "$value" != /* ]]; then
      return 0
    fi
    [[ -n "$value" ]] && echo "$label must be a simple git branch prefix without spaces."
    rm -f "$(store_path config "$key")"
    prompt_stored_value config "$key" "$label" "$default" false true
  done
}

validate_port_config() {
  local key="$1"
  local label="$2"
  local default="$3"
  local value

  while true; do
    value="$(read_store_value config "$key" 2>/dev/null || true)"
    if [[ "$value" =~ ^[0-9]+$ && "$value" -ge 1 && "$value" -le 65535 ]]; then
      return 0
    fi
    [[ -n "$value" ]] && echo "$label must be a TCP port from 1 to 65535."
    rm -f "$(store_path config "$key")"
    prompt_stored_value config "$key" "$label" "$default" false true
  done
}

configure_local_profile() {
  local assistant_name assistant_slug user_name api_enabled

  ensure_store_dirs

  echo "== Local identity =="
  prompt_stored_value config assistant_name "Assistant name" "" false true
  assistant_name="$(read_store_value config assistant_name)"
  assistant_slug="$(slugify "$assistant_name")"
  assistant_slug="${assistant_slug:-hermes-assistant}"
  prompt_stored_value config assistant_slug "Docker-safe assistant slug" "$assistant_slug" false false
  validate_slug_config assistant_slug "Docker-safe assistant slug" "$assistant_slug"
  assistant_slug="$(read_store_value config assistant_slug)"
  prompt_stored_value config user_name "User nickname the assistant should use" "" false true
  user_name="$(read_store_value config user_name)"
  prompt_stored_value config branch_prefix "Task branch prefix" "$assistant_slug" false false
  validate_branch_prefix_config branch_prefix "Task branch prefix" "$assistant_slug"
  prompt_stored_value config dashboard_port "Dashboard localhost port" "9119" false false
  validate_port_config dashboard_port "Dashboard localhost port" "9119"
  prompt_stored_value config api_port "API localhost port" "8642" false false
  validate_port_config api_port "API localhost port" "8642"

  if ! has_store_value config dockerd_storage_driver; then
    write_store_value config dockerd_storage_driver "overlay2"
  fi

  normalize_bool_config api_server_enabled "Enable external API server" "false"
  api_enabled="$(read_store_value config api_server_enabled)"
  if [[ "$api_enabled" == "true" && ! -f "$(store_path secret api_server_key)" ]]; then
    prompt_stored_value secret api_server_key "External API server key" "$(random_hex_32)" true true
  fi

  echo
  echo "== Telegram =="
  prompt_stored_value secret telegram_bot_token "Telegram bot token" "" true true
  prompt_stored_value secret telegram_allowed_users "Telegram allowed user IDs, comma-separated" "" false true

  # Avoid shellcheck warning for values intentionally read as validation above.
  : "$user_name"
}

github_configured() {
  compose exec -T -u hermes "$SERVICE" gh auth status -h github.com >/dev/null 2>&1
}

derive_git_identity_from_github() {
  local login name id email changed_var="$1"
  login="$(compose exec -T -u hermes "$SERVICE" gh api user --jq '.login' 2>/dev/null | tr -d '\r' || true)"
  [[ -n "$login" ]] || return 1

  name="$(compose exec -T -u hermes "$SERVICE" gh api user --jq '.name // .login' 2>/dev/null | tr -d '\r' || true)"
  id="$(compose exec -T -u hermes "$SERVICE" gh api user --jq '.id | tostring' 2>/dev/null | tr -d '\r' || true)"
  email="$(compose exec -T -u hermes "$SERVICE" gh api user --jq '.email // ""' 2>/dev/null | tr -d '\r' || true)"

  name="${name:-$login}"
  if [[ -z "$email" && -n "$id" ]]; then
    email="${id}+${login}@users.noreply.github.com"
  fi

  if ! has_store_value config git_user_name; then
    write_store_value config git_user_name "$name"
    printf -v "$changed_var" '%s' "true"
  fi

  if ! has_store_value config git_user_email && [[ -n "$email" ]]; then
    write_store_value config git_user_email "$email"
    printf -v "$changed_var" '%s' "true"
  fi

  echo "GitHub account: $login"
}

prompt_missing_git_identity() {
  local changed_var="$1"
  local user_name
  user_name="$(read_store_value config user_name 2>/dev/null || true)"

  if ! has_store_value config git_user_name; then
    prompt_stored_value config git_user_name "Git author name" "$user_name" false true
    printf -v "$changed_var" '%s' "true"
  fi

  if ! has_store_value config git_user_email; then
    prompt_stored_value config git_user_email "Git author email" "" false true
    printf -v "$changed_var" '%s' "true"
  fi
}

github_token_login_once() {
  local token
  read -r -s -p "GitHub classic PAT with repo/gist scopes (blank to skip): " token
  echo
  if [[ -z "$token" ]]; then
    return 130
  fi
  printf '%s\n' "$token" | compose exec -T -u hermes "$SERVICE" gh auth login --hostname github.com --with-token
}

configure_github_and_git_identity() {
  local identity_changed_var="$1"
  local status

  echo
  echo "== GitHub and git identity =="
  if github_configured; then
    echo "GitHub CLI auth: already configured"
    derive_git_identity_from_github "$identity_changed_var" || true
  else
    if run_with_optional_interrupt "GitHub CLI auth" confirm "Authenticate GitHub CLI now"; then
      status=0
    else
      status=$?
    fi
    if [[ "$status" -eq 0 ]]; then
      if retry_optional_auth "GitHub CLI auth" github_token_login_once; then
        status=0
      else
        status=$?
      fi
      if [[ "$status" -eq 0 ]]; then
        echo "GitHub CLI auth: configured"
        derive_git_identity_from_github "$identity_changed_var" || true
      elif [[ "$status" -eq 130 ]]; then
        :
      else
        echo "GitHub CLI auth failed; continuing without GitHub auth." >&2
      fi
    elif [[ "$status" -eq 130 ]]; then
      echo "GitHub CLI auth skipped."
    else
      echo "GitHub CLI auth skipped."
    fi
  fi

  prompt_missing_git_identity "$identity_changed_var"
}

setup_google_workspace_impl() {
  local gsetup container_secret client_secret_path auth_url oauth_callback
  local client_secret_source temp_secret_path
  # shellcheck disable=SC2016 # Expanded inside the container by `sh -lc`.
  gsetup='/opt/hermes/.venv/bin/python "$HERMES_HOME/skills/productivity/google-workspace/scripts/setup.py"'
  container_secret="/opt/data/.hermes-google-client-secret.json.tmp"
  temp_secret_path=""

  echo
  echo "== Google Workspace =="

  if ! compose exec -T -u hermes "$SERVICE" sh -lc 'command -v gws >/dev/null'; then
    echo "Google Workspace CLI is not installed in the assistant container; skipping Google Workspace setup." >&2
    return 0
  fi

  if compose exec -T -u hermes "$SERVICE" sh -lc "$gsetup --check" >/dev/null 2>&1; then
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

  if compose exec -T -u hermes "$SERVICE" test -s /opt/data/google_client_secret.json; then
    echo "Google OAuth client secret: already stored"
  else
    cat <<'EOF'
Provide the OAuth Desktop client JSON.

VPS-friendly default: paste the JSON contents. Secret input is hidden. You can
also provide a file path if the JSON is already on this machine.
EOF

    setup_disable_echo
    read -r -p "Source (hidden): paste JSON, or type path/skip [paste]: " client_secret_source || client_secret_source=""
    echo
    client_secret_source="${client_secret_source:-paste}"

    case "$client_secret_source" in
      \{*)
        temp_secret_path="$(mktemp)"
        SETUP_TEMP_FILES+=("$temp_secret_path")
        chmod 600 "$temp_secret_path"
        cat <<'EOF'
Detected JSON at the prompt. Input remains hidden. If it spans multiple lines, continue pasting.
If the script keeps waiting after the final }, type END_GOOGLE_JSON.
EOF
        read_google_client_secret_json "$temp_secret_path" "$client_secret_source"
        if [[ ! -s "$temp_secret_path" ]]; then
          rm -f "$temp_secret_path"
          print_google_workspace_skip_instructions
          return 0
        fi
        client_secret_path="$temp_secret_path"
        ;;
      paste | p)
        setup_enable_echo
        temp_secret_path="$(mktemp)"
        SETUP_TEMP_FILES+=("$temp_secret_path")
        chmod 600 "$temp_secret_path"
        cat <<'EOF'
Paste the full OAuth client JSON now. Input is hidden.
The script continues automatically when the JSON is complete.
If it keeps waiting after the final }, type END_GOOGLE_JSON on its own line.
EOF
        read_google_client_secret_json "$temp_secret_path"
        if [[ ! -s "$temp_secret_path" ]]; then
          rm -f "$temp_secret_path"
          print_google_workspace_skip_instructions
          return 0
        fi
        client_secret_path="$temp_secret_path"
        ;;
      path | file | f)
        setup_enable_echo
        while true; do
          read -r -p "Path to OAuth Desktop client JSON (blank to skip): " client_secret_path
          if [[ -z "$client_secret_path" ]]; then
            print_google_workspace_skip_instructions
            return 0
          fi
          if [[ -f "$client_secret_path" ]]; then
            break
          fi
          echo "File not found: $client_secret_path"
        done
        ;;
      skip | s)
        setup_enable_echo
        print_google_workspace_skip_instructions
        return 0
        ;;
      *)
        setup_enable_echo
        echo "Unknown source: $client_secret_source" >&2
        print_google_workspace_skip_instructions
        return 0
        ;;
    esac

    SETUP_CONTAINER_TEMP_SECRET="$container_secret"
    compose cp "$client_secret_path" "$SERVICE:$container_secret" || return 1
    rm -f "$temp_secret_path"
    compose exec -T "$SERVICE" sh -lc "chown 10000:10000 '$container_secret' && chmod 600 '$container_secret'" || return 1
    if ! compose exec -T -u hermes "$SERVICE" sh -lc "$gsetup --client-secret '$container_secret'"; then
      compose exec -T "$SERVICE" rm -f "$container_secret"
      SETUP_CONTAINER_TEMP_SECRET=""
      echo "Google OAuth client secret was not stored. Check that you pasted the full Desktop OAuth JSON." >&2
      print_google_workspace_skip_instructions
      return 0
    fi
    compose exec -T "$SERVICE" rm -f "$container_secret"
    SETUP_CONTAINER_TEMP_SECRET=""
  fi

  if ! auth_url="$(compose exec -T -u hermes "$SERVICE" sh -lc "$gsetup --auth-url")"; then
    echo "Could not generate a Google auth URL. Rerun setup after checking the OAuth client JSON." >&2
    return 0
  fi

  while true; do
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
  GSETUP="/opt/hermes/.venv/bin/python $HERMES_HOME/skills/productivity/google-workspace/scripts/setup.py"
  $GSETUP --auth-url
  $GSETUP --auth-code 'PASTE_FULL_REDIRECT_URL_HERE'
EOF
      return 0
    fi

    if compose exec -T -u hermes "$SERVICE" sh -lc "$gsetup --auth-code \"\$1\"" sh "$oauth_callback"; then
      break
    fi

    echo "Google Workspace authorization failed." >&2
    if ! confirm "Try Google Workspace authorization again"; then
      echo "Google Workspace auth skipped."
      return 0
    fi
    if ! auth_url="$(compose exec -T -u hermes "$SERVICE" sh -lc "$gsetup --auth-url")"; then
      echo "Could not generate a Google auth URL. Rerun setup after checking the OAuth client JSON." >&2
      return 0
    fi
  done

  if compose exec -T -u hermes "$SERVICE" sh -lc "$gsetup --check-live"; then
    echo "Google Workspace auth: configured"
  else
    echo "Google Workspace token was stored, but live verification failed. Check enabled APIs and OAuth scopes." >&2
  fi
}

setup_google_workspace() {
  local status
  if run_with_optional_interrupt "Google Workspace setup" setup_google_workspace_impl; then
    status=0
  else
    status=$?
  fi
  if [[ "$status" -eq 130 ]]; then
    echo "Google Workspace setup skipped."
  elif [[ "$status" -ne 0 ]]; then
    echo "Google Workspace setup failed; continuing setup." >&2
  fi
  return 0
}

configure_local_profile
validate_container_profile

if ! docker info >/dev/null 2>&1; then
  echo "Docker is not running. Start Docker Desktop, then rerun scripts/setup.sh." >&2
  exit 1
fi

echo
echo "== Build and start =="
compose up -d --build
wait_for_container
wait_for_inner_docker_or_warn

identity_changed=false
configure_github_and_git_identity identity_changed
if [[ "$identity_changed" == "true" ]]; then
  echo
  echo "Applying git identity to the running assistant ..."
  compose up -d --force-recreate
  wait_for_container
  wait_for_inner_docker_or_warn
fi

echo
echo "== Interactive logins =="
run_optional_login_prompt "Run Hermes model setup now (recommended: DeepSeek V4 Flash via OpenCode Go)" "Hermes model setup" \
  compose exec -u hermes -it "$SERVICE" hermes setup model

run_optional_login_prompt "Run Codex device login now" "Codex device login" \
  compose exec -u hermes -it "$SERVICE" codex login --device-auth

run_optional_login_prompt "Run OpenCode auth login now" "OpenCode auth login" \
  compose exec -u hermes -it "$SERVICE" opencode auth login

run_optional_login_prompt "Run Cursor browser login now" "Cursor browser login" \
  compose exec -u hermes -it "$SERVICE" agent login

setup_google_workspace

echo
echo "== Smoke tests =="
smoke_status=0
scripts/smoke-test.sh "$SERVICE" || smoke_status=$?

echo
case "$smoke_status" in
  0)
    echo "Setup complete."
    echo "Dashboard: http://localhost:$(read_store_value config dashboard_port)"
    ;;
  2)
    echo "Setup finished, but optional smoke checks need attention."
    echo "Fix the warnings above, then rerun: scripts/smoke-test.sh"
    echo "Dashboard: http://localhost:$(read_store_value config dashboard_port)"
    ;;
  *)
    echo "Setup failed required smoke tests. Fix the failures above, then rerun: scripts/smoke-test.sh" >&2
    exit "$smoke_status"
    ;;
esac
