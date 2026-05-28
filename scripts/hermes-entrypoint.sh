#!/usr/bin/env bash
# Hermes assistant container init hook.
#
# Startup chores before Hermes services start:
#
# 1. Symlink the global coding-agent AGENTS.md into the per-tool config dirs
#    for tools that support a global rules file (codex at $HOME/.codex,
#    opencode at $HOME/.config/opencode). Cursor CLI reads AGENTS.md from the
#    workspace root and nested subdirectories, so this same file is symlinked
#    to /workbench/AGENTS.md and Cursor runs with /workbench as its workspace.
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
  assistant_name="$(printf '%s' "${ASSISTANT_NAME:-Hermes Assistant}" | sed -e 's/[\/&|]/\\&/g')"
  user_name="$(printf '%s' "${USER_NAME:-the user}" | sed -e 's/[\/&|]/\\&/g')"
  git_user_name="$(printf '%s' "${GIT_USER_NAME:-Your Name}" | sed -e 's/[\/&|]/\\&/g')"
  git_user_email="$(printf '%s' "${GIT_USER_EMAIL:-you@example.com}" | sed -e 's/[\/&|]/\\&/g')"
  branch_prefix="$(printf '%s' "${BRANCH_PREFIX:-assistant}" | sed -e 's/[\/&|]/\\&/g')"
  cp "$src" "$dst"
  sed -i \
    -e "s|<ASSISTANT_NAME>|$assistant_name|g" \
    -e "s|<USER_NAME>|$user_name|g" \
    -e "s|<GIT_USER_NAME>|$git_user_name|g" \
    -e "s|<GIT_USER_EMAIL>|$git_user_email|g" \
    -e "s|<BRANCH_PREFIX>|$branch_prefix|g" \
    "$dst"
}

needs_render() {
  local dst="$1"
  [[ ! -f "$dst" ]] && return 0
  grep -q '<ASSISTANT_NAME>\|<USER_NAME>\|<GIT_USER_NAME>\|<GIT_USER_EMAIL>\|<BRANCH_PREFIX>' "$dst" && return 0
  grep -q 'Replace these placeholders before running the assistant:' "$dst" && return 0
  return 1
}

if needs_render /opt/data/SOUL.md && [[ -f "$TEMPLATE_DATA/SOUL.md" ]]; then
  render_template "$TEMPLATE_DATA/SOUL.md" /opt/data/SOUL.md
fi

if needs_render /opt/data/AGENTS.md && [[ -f "$TEMPLATE_DATA/AGENTS.md" ]]; then
  render_template "$TEMPLATE_DATA/AGENTS.md" /opt/data/AGENTS.md
fi

if needs_render "$RULES_SRC" && [[ -f "$TEMPLATE_DATA/coding-agents/AGENTS.md" ]]; then
  render_template "$TEMPLATE_DATA/coding-agents/AGENTS.md" "$RULES_SRC"
fi

if [[ ! -f /opt/data/config.yaml ]]; then
  cat > /opt/data/config.yaml <<'EOF'
model:
  provider: opencode-go
  default: deepseek-v4-pro
  base_url: https://opencode.ai/zen/go/v1
  api_mode: chat_completions

agent:
  reasoning_effort: high
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
    - CURSOR_API_KEY

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

if [[ -f /opt/data/config.yaml ]] \
  && ! grep -q '^[[:space:]]*-[[:space:]]*CURSOR_API_KEY[[:space:]]*$' /opt/data/config.yaml; then
  if grep -q '^[[:space:]]*-[[:space:]]*GH_TOKEN[[:space:]]*$' /opt/data/config.yaml; then
    sed -i '/^[[:space:]]*-[[:space:]]*GH_TOKEN[[:space:]]*$/a\    - CURSOR_API_KEY' /opt/data/config.yaml
  elif grep -q '^[[:space:]]*env_passthrough:[[:space:]]*$' /opt/data/config.yaml; then
    sed -i '/^[[:space:]]*env_passthrough:[[:space:]]*$/a\    - CURSOR_API_KEY' /opt/data/config.yaml
  else
    echo "hermes-entrypoint: WARNING could not add CURSOR_API_KEY to terminal.env_passthrough in /opt/data/config.yaml" >&2
  fi
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
  ln -sf "$RULES_SRC" /workbench/AGENTS.md
  chown -h 10000:10000 /workbench/AGENTS.md 2>/dev/null || true
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

# Reasoning effort — codex CLI does NOT expose this as a flag, config.toml is
# the only knob. Values: minimal | low | medium | high | xhigh. We default to
# "high" to match the default Hermes brain config (reasoning_effort: high). Edit this
# file directly to change it; the entrypoint only writes this file once and
# leaves an existing one alone.
model_reasoning_effort = "high"
EOF
fi

OPENCODE_JSON=/opt/data/.config/opencode/opencode.json
if [[ ! -f "$OPENCODE_JSON" ]]; then
  cat > "$OPENCODE_JSON" <<'EOF'
{
  "$schema": "https://opencode.ai/config.json",
  "model": "opencode-go/deepseek-v4-pro",
  "permission": {
    "edit": "allow",
    "bash": "allow",
    "write": "allow",
    "webfetch": "allow"
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
