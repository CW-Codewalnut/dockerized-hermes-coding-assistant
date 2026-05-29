#!/usr/bin/env bash
# Hermes assistant container init hook.
#
# Startup chores before Hermes services start:
#
# 1. Symlink the global coding-agent AGENTS.md into the per-tool config dirs
#    for tools that support a global rules file (codex at $HOME/.codex,
#    opencode at $HOME/.config/opencode). Cursor is invoked from the target
#    repo directory and relies on repo-local Cursor rules instead of a shared
#    /workbench-level rule file.
#
# 2. Chown the persistent state and workbench volumes to hermes. Docker named
#    volumes can first appear as root:root, which prevents the hermes runtime
#    user from creating /workbench/<owner>/<repo> checkouts.
#
# 3. Chown the auth subtrees to hermes. They may have been created or written
#    by root previously (e.g. when `docker exec <assistant-container> codex
#    login` defaulted to root). Without this, hermes-owned subprocesses can't
#    read auth/config files and the sub-agents look unauthenticated.
#
# This hook runs as root under the base image's s6 /init before Hermes services
# start, which is the window where chown and persistent-volume setup are possible.
set -euo pipefail

TEMPLATE_DATA="/opt/hermes-assistant/templates/assistant"
RULES_SRC="/opt/data/coding-agents/AGENTS.md"

mkdir -p /opt/data /opt/data/coding-agents /workbench

render_template() {
  local src="$1"
  local dst="$2"
  local assistant_name user_name git_user_name git_user_email branch_prefix
  assistant_name="$(escape_template_value "$(runtime_env ASSISTANT_NAME "Hermes Assistant")")"
  user_name="$(escape_template_value "$(runtime_env USER_NAME "the user")")"
  git_user_name="$(escape_template_value "$(runtime_env GIT_USER_NAME "Your Name")")"
  git_user_email="$(escape_template_value "$(runtime_env GIT_USER_EMAIL "you@example.com")")"
  branch_prefix="$(escape_template_value "$(runtime_env BRANCH_PREFIX "assistant")")"
  cp "$src" "$dst"
  sed -i \
    -e "s|<ASSISTANT_NAME>|$assistant_name|g" \
    -e "s|<USER_NAME>|$user_name|g" \
    -e "s|<GIT_USER_NAME>|$git_user_name|g" \
    -e "s|<GIT_USER_EMAIL>|$git_user_email|g" \
    -e "s|<BRANCH_PREFIX>|$branch_prefix|g" \
    "$dst"
}

runtime_env() {
  local key="$1"
  local fallback="$2"
  local value=""
  value="${!key:-}"
  if [[ -z "$value" && -f "/run/s6/container_environment/$key" ]]; then
    value="$(tr -d '\000' < "/run/s6/container_environment/$key")"
  fi
  printf '%s' "${value:-$fallback}"
}

escape_template_value() {
  printf '%s' "$1" | sed -e 's/[\/&|]/\\&/g'
}

# Render operational instructions from the current environment on every start
# so .env identity changes are reflected after container recreation.
if [[ -f "$TEMPLATE_DATA/SOUL.md" ]]; then
  render_template "$TEMPLATE_DATA/SOUL.md" /opt/data/SOUL.md
fi

if [[ -f "$TEMPLATE_DATA/AGENTS.md" ]]; then
  render_template "$TEMPLATE_DATA/AGENTS.md" /opt/data/AGENTS.md
fi

if [[ -f "$TEMPLATE_DATA/coding-agents/AGENTS.md" ]]; then
  render_template "$TEMPLATE_DATA/coding-agents/AGENTS.md" "$RULES_SRC"
fi

if [[ ! -f /opt/data/config.yaml ]]; then
  cat > /opt/data/config.yaml <<'EOF'
agent:
  max_turns: 150
  gateway_timeout: 7200
  gateway_timeout_warning: 3600
  clarify_timeout: 600

terminal:
  backend: local
  cwd: /workbench
  timeout: 7200
  persistent_shell: true
  env_passthrough:
    - GH_TOKEN
    - GITHUB_TOKEN
    - CURSOR_API_KEY
    - DOCKER_HOST
    - DOCKER_BUILDKIT
    - COMPOSE_DOCKER_CLI_BUILD

dashboard:
  enabled: true
  host: 0.0.0.0
  port: 9119

security:
  redact_secrets: true

mcp_servers:
  workbench:
    command: npx
    args:
      - -y
      - "@modelcontextprotocol/server-filesystem"
      - /workbench

session_reset:
  mode: both
  idle_minutes: 1440
  at_hour: 4
EOF
fi

if [[ -f /opt/data/config.yaml ]] &&
  ! grep -Eq '^[[:space:]]*-[[:space:]]*GITHUB_TOKEN[[:space:]]*$' /opt/data/config.yaml &&
  grep -Eq '^[[:space:]]*-[[:space:]]*GH_TOKEN[[:space:]]*$' /opt/data/config.yaml; then
  sed -i '/^[[:space:]]*-[[:space:]]*GH_TOKEN[[:space:]]*$/a\    - GITHUB_TOKEN' /opt/data/config.yaml
fi

chown -R 10000:10000 /opt/data/SOUL.md /opt/data/AGENTS.md /opt/data/coding-agents /opt/data/config.yaml 2>/dev/null || true
chown -R 10000:10000 /workbench 2>/dev/null || true

# Disable Hermes' per-profile subprocess HOME isolation.
#
# Hermes' tools/environments/local.py::_make_run_env() overrides HOME for
# spawned subprocesses to ${HERMES_HOME}/home/ — but ONLY when that directory
# exists. If left enabled, coding agents spawned through the assistant's
# terminal tool would write auth + state under /opt/data/home, while interactive
# `docker compose exec -u hermes assistant <tool> login` writes to /opt/data.
# We don't need the isolation — hermes' real HOME (/opt/data) is already
# persistent — so we delete the marker dir on every boot to keep all coding-agent
# invocations looking at the same auth/config paths.
rm -rf /opt/data/home

mkdir -p \
  /opt/data/.codex \
  /opt/data/.cursor \
  /opt/data/.local/share/cursor-agent \
  /opt/data/.local/share/opencode \
  /opt/data/.config/opencode

if [[ -f "$RULES_SRC" ]]; then
  ln -sf "$RULES_SRC" /opt/data/.codex/AGENTS.md
  ln -sf "$RULES_SRC" /opt/data/.config/opencode/AGENTS.md
else
  echo "hermes-entrypoint: WARNING $RULES_SRC missing; coding agents will run without global rules" >&2
fi

if [[ -n "${GIT_USER_NAME:-}" ]]; then
  git config --system user.name "$GIT_USER_NAME"
fi

if [[ -n "${GIT_USER_EMAIL:-}" ]]; then
  git config --system user.email "$GIT_USER_EMAIL"
fi

# Seed "yolo" defaults for the coding sub-agents. The assistant spawns tools
# headlessly via Telegram — there is no human at a terminal to approve prompts.
# Defense in depth: data/AGENTS.md also tells the assistant to pass the matching CLI
# flags explicitly, so if either layer is bypassed the other still applies.
#
# Only writes if the file doesn't already exist — `codex login` later creates
# a minimal config.toml; we want our version to be the one that lands first.
# To reset to fresh defaults: delete the file and restart the container.
CODEX_TOML=/opt/data/.codex/config.toml
if [[ ! -f "$CODEX_TOML" ]]; then
  cat > "$CODEX_TOML" <<'EOF'
# Hermes assistant managed defaults for headless codex invocations.
#
# Yolo permissions — required because the assistant spawns codex with no human at a
# terminal to approve prompts.
approval_policy = "never"
sandbox_mode    = "danger-full-access"
model           = "gpt-5.5"

# Reasoning effort — codex CLI does NOT expose this as a dedicated flag,
# so config.toml is the durable default. Values: minimal | low | medium |
# high | xhigh. Edit this file directly to change it; the entrypoint only
# writes this file once and leaves an existing one alone.
model_reasoning_effort = "xhigh"
EOF
fi

OPENCODE_JSON=/opt/data/.config/opencode/opencode.json
if [[ ! -f "$OPENCODE_JSON" ]]; then
  cat > "$OPENCODE_JSON" <<'EOF'
{
  "$schema": "https://opencode.ai/config.json",
  "model": "opencode-go/deepseek-v4-pro",
  "permission": {
    "read": "allow",
    "edit": "allow",
    "glob": "allow",
    "grep": "allow",
    "list": "allow",
    "bash": "allow",
    "write": "allow",
    "task": "allow",
    "external_directory": "allow",
    "todowrite": "allow",
    "webfetch": "allow",
    "websearch": "allow",
    "lsp": "allow",
    "skill": "allow",
    "question": "allow",
    "doom_loop": "allow"
  }
}
EOF
fi

CURSOR_JSON=/opt/data/.cursor/cli-config.json
if [[ ! -f "$CURSOR_JSON" ]]; then
  cat > "$CURSOR_JSON" <<'EOF'
{
  "version": 1,
  "editor": {
    "vimMode": false
  },
  "permissions": {
    "allow": [],
    "deny": []
  }
}
EOF
fi

# Best-effort: on Docker Desktop's virtiofs the chown may be a no-op because
# UID is rewritten by the filesharing layer. Either way the hermes user ends
# up able to read these paths because /opt/data is already mapped to hermes.
chown -R 10000:10000 /opt/data/.codex /opt/data/.local /opt/data/.config 2>/dev/null || true
chown -R 10000:10000 /opt/data/.cursor 2>/dev/null || true
