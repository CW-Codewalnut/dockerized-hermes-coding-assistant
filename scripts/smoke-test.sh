#!/usr/bin/env bash
# Verify the running assistant container and important external CLI auth.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# shellcheck source=scripts/lib/setup-store.sh
source "$ROOT/scripts/lib/setup-store.sh"
assistant_store_init "$ROOT"

SERVICE="${1:-assistant}"
REQUIRED_FAILED=0
OPTIONAL_FAILED=0

section() {
  echo
  echo "== $1 =="
}

ok() {
  echo "  ok - $1"
}

required_fail() {
  echo "  FAIL - $1" >&2
  REQUIRED_FAILED=1
}

optional_fail() {
  echo "  warn - $1" >&2
  OPTIONAL_FAILED=1
}

run_required() {
  local label="$1"
  shift
  if "$@"; then
    ok "$label"
  else
    required_fail "$label"
  fi
}

run_optional() {
  local label="$1"
  shift
  if "$@"; then
    ok "$label"
  else
    optional_fail "$label"
  fi
}

assistant_exec() {
  compose exec -T "$SERVICE" "$@"
}

hermes_exec() {
  compose exec -T -u hermes "$SERVICE" "$@"
}

section "Container"
run_required "container responds" assistant_exec true
run_required "runtime instructions rendered" assistant_exec sh -lc '
  set -eu
  config_dir="${ASSISTANT_CONFIG_DIR:-/run/hermes-assistant/config}"
  assistant_name="$(sed -n "1p" "$config_dir/assistant_name")"
  assistant_slug="$(sed -n "1p" "$config_dir/assistant_slug")"
  user_name="$(sed -n "1p" "$config_dir/user_name")"
  git_user_name="$(sed -n "1p" "$config_dir/git_user_name")"
  git_user_email="$(sed -n "1p" "$config_dir/git_user_email")"

  ! grep -R "<ASSISTANT_NAME>\|<USER_NAME>\|<GIT_USER_NAME>\|<GIT_USER_EMAIL>\|<BRANCH_PREFIX>" \
    /opt/data/SOUL.md /opt/data/AGENTS.md /opt/data/coding-agents/AGENTS.md >/dev/null
  test -n "$assistant_name"
  test -n "$user_name"
  grep -F "# ${assistant_name}" /opt/data/SOUL.md >/dev/null
  grep -F "Primary operator: **${user_name}**." /opt/data/SOUL.md >/dev/null
  grep -F "The primary operator is **${user_name}**." /opt/data/AGENTS.md >/dev/null
  grep -F "The primary user is **${user_name}**." /opt/data/coding-agents/AGENTS.md >/dev/null
  echo "  Assistant name: ${assistant_name}"
  echo "  Assistant slug: ${assistant_slug}"
  echo "  Primary operator: ${user_name}"
  echo "  Git author: ${git_user_name} <${git_user_email}>"
'

section "Telegram"
run_required "bot token present and valid" assistant_exec sh -lc '
  set -eu
  secrets_dir="${ASSISTANT_SECRETS_DIR:-/run/hermes-assistant/secrets}"
  token="$(sed -n "1p" "$secrets_dir/telegram_bot_token")"
  allowed_users="$(sed -n "1p" "$secrets_dir/telegram_allowed_users")"
  test -n "$token"
  test -n "$allowed_users"
  ok="$(curl -fsS "https://api.telegram.org/bot${token}/getMe" | jq -r .ok)"
  test "$ok" = "true"
'

section "GitHub CLI"
run_optional "GitHub CLI auth, API, repo scope, and gist scope" hermes_exec sh -lc '
  set -eu
  gh auth status -h github.com >/dev/null
  login="$(gh api user --jq .login)"
  echo "  GitHub account: $login"
  scopes="$(gh api -i /user 2>/dev/null | tr -d "\r" | awk -F": " "tolower(\$1)==\"x-oauth-scopes\" {print \$2; exit}")"
  scope_csv=",$(printf "%s" "$scopes" | tr -d " "),"
  case "$scope_csv" in
    *,repo,*) ;;
    *) echo "missing repo scope" >&2; exit 1 ;;
  esac
  case "$scope_csv" in
    *,gist,*) ;;
    *) echo "missing gist scope" >&2; exit 1 ;;
  esac
  gh gist list --limit 1 >/dev/null
'

section "Inner Docker"
run_required "Docker daemon, Compose, and Buildx" hermes_exec sh -lc '
  set -eu
  docker version --format "Docker client/server: {{.Client.Version}} / {{.Server.Version}}"
  docker compose version
  docker buildx version
'

section "Hermes"
run_required "Hermes status" hermes_exec hermes status

section "Codex CLI"
run_optional "Codex version, doctor when available, and login status" hermes_exec sh -lc '
  set -eu
  codex --version
  if codex doctor --help >/dev/null 2>&1; then
    codex doctor
  else
    echo "  codex doctor: not available in this installed version"
  fi
  codex login status
'

section "OpenCode CLI"
run_optional "OpenCode version, auth list, configured auth file, and model catalog" hermes_exec sh -lc '
  set -eu
  opencode --version
  opencode auth list
  test -s "$HOME/.local/share/opencode/auth.json"
  opencode models opencode-go >/dev/null
'

section "Cursor CLI"
run_optional "Cursor version, auth status, and model list" hermes_exec sh -lc '
  set -eu
  agent --version
  status_log="$(mktemp)"
  models_log="$(mktemp)"
  cleanup() {
    rm -f "$status_log" "$models_log"
  }
  trap cleanup EXIT

  cursor_ready_quiet() {
    agent status >"$status_log" 2>&1 && agent models >"$models_log" 2>&1
  }

  cursor_auth_hint() {
    if [ -s "$HOME/.cursor/cli-config.json" ] &&
      grep -Eiq "\"(auth|token|api[_-]?key|access[_-]?token|refresh[_-]?token|user|email|account)\"" "$HOME/.cursor/cli-config.json"; then
      return 0
    fi
    find "$HOME/.cursor" "$HOME/.local/share/cursor-agent" \
      -type f ! -name cli-config.json ! -name "*.lock" -size +0c \
      -print -quit 2>/dev/null | grep -q .
  }

  attempts=1
  delay_seconds="${CURSOR_SMOKE_DELAY_SECONDS:-5}"
  if cursor_auth_hint; then
    attempts="${CURSOR_SMOKE_ATTEMPTS:-6}"
  fi

  attempt=1
  while [ "$attempt" -le "$attempts" ]; do
    if cursor_ready_quiet; then
      cat "$status_log"
      exit 0
    fi
    if [ "$attempt" -lt "$attempts" ]; then
      echo "  Cursor auth not ready yet; retrying in ${delay_seconds}s ..."
      sleep "$delay_seconds"
    fi
    attempt=$((attempt + 1))
  done
  cat "$status_log" >&2
  cat "$models_log" >&2
  exit 1
'

section "Google Workspace"
run_optional "gws installed and Google Workspace auth live check" hermes_exec sh -lc '
  set -eu
  gws --version | head -n1
  test -s /opt/data/google_token.json
  /opt/hermes/.venv/bin/python "$HERMES_HOME/skills/productivity/google-workspace/scripts/setup.py" --check-live
'

echo
if [[ "$REQUIRED_FAILED" -ne 0 ]]; then
  echo "Smoke tests failed. Fix the required failures above and rerun scripts/smoke-test.sh." >&2
  exit 1
fi

if [[ "$OPTIONAL_FAILED" -ne 0 ]]; then
  echo "Required smoke tests passed, but one or more optional integrations are not configured or failed." >&2
  exit 2
fi

echo "All smoke tests passed."
