#!/usr/bin/env bash
# Verify the running assistant container and important external CLI auth.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

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
  docker compose exec -T "$SERVICE" "$@"
}

hermes_exec() {
  docker compose exec -T -u hermes "$SERVICE" "$@"
}

section "Container"
run_required "container responds" assistant_exec true
run_required "runtime instructions rendered" assistant_exec sh -lc '
  set -eu
  ! grep -R "<ASSISTANT_NAME>\|<USER_NAME>\|<GIT_USER_NAME>\|<GIT_USER_EMAIL>\|<BRANCH_PREFIX>" \
    /opt/data/SOUL.md /opt/data/AGENTS.md /opt/data/coding-agents/AGENTS.md >/dev/null
  test -n "${ASSISTANT_NAME:-}"
  test -n "${USER_NAME:-}"
  grep -F "# ${ASSISTANT_NAME}" /opt/data/SOUL.md >/dev/null
  grep -F "Primary operator: **${USER_NAME}**." /opt/data/SOUL.md >/dev/null
  grep -F "The primary operator is **${USER_NAME}**." /opt/data/AGENTS.md >/dev/null
  grep -F "The primary user is **${USER_NAME}**." /opt/data/coding-agents/AGENTS.md >/dev/null
  echo "  Assistant name: ${ASSISTANT_NAME}"
  echo "  Assistant slug: ${ASSISTANT_SLUG:-unset}"
  echo "  Primary operator: ${USER_NAME}"
  echo "  Git author: ${GIT_USER_NAME:-unset} <${GIT_USER_EMAIL:-unset}>"
'

section "Telegram"
run_required "bot token present and valid" assistant_exec sh -lc '
  set -eu
  test -n "${TELEGRAM_BOT_TOKEN:-}"
  test -n "${TELEGRAM_ALLOWED_USERS:-}"
  ok="$(curl -fsS "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getMe" | jq -r .ok)"
  test "$ok" = "true"
'

section "GitHub CLI"
run_required "GH_TOKEN auth, API, repo scope, and gist scope" assistant_exec sh -lc '
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
  agent status
  agent models >/dev/null
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
