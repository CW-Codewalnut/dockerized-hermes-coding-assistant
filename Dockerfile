# Hermes Agent + coding sub-agents (Codex CLI, OpenCode CLI, Cursor CLI) + gh CLI
# + the usual coding-agent toolkit. Built on top of the official Nous image.
FROM nousresearch/hermes-agent:latest

USER root
ENV DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Bun lives at /usr/local/bin; `bun install -g <pkg>` writes binaries here too.
ENV BUN_INSTALL=/usr/local
ENV NVM_DIR=/usr/local/nvm

# ---------------------------------------------------------------------------
# Apt repos: official GitHub CLI plus the coding-agent toolkit.
# Node comes from nvm below so the image follows the current LTS line.
# ---------------------------------------------------------------------------
RUN apt-get update \
       && apt-get install -y --no-install-recommends ca-certificates curl gnupg \
       && install -d -m 0755 /etc/apt/keyrings \
       # GitHub CLI
       && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
       | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
       && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
       && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
       > /etc/apt/sources.list.d/github-cli.list \
       && apt-get update \
       # Coding-agent toolkit. Kept lean — agents bring per-repo toolchains themselves.
       && apt-get install -y --no-install-recommends \
       gh \
       git openssh-client \
       ripgrep fd-find tree jq file patch diffutils less \
       vim-tiny nano \
       python3 python3-pip python3-venv \
       wget unzip zip \
       tini \
       # bubblewrap: codex CLI uses it for filesystem-sandboxed tool execution.
       # Bwrap needs unprivileged user namespaces; Docker Desktop's Linux VM has
       # them on by default. If codex still fails with `bwrap: setting up uid map`
       # add `cap_add: [SYS_ADMIN]` or `security_opt: [seccomp=unconfined]` to
       # docker-compose.yml. Don't make the container `privileged: true`.
       bubblewrap \
       && ln -sf /usr/bin/fdfind /usr/local/bin/fd \
       && apt-get clean \
       && rm -rf /var/lib/apt/lists/*

# Node.js via nvm. Install and activate the current LTS line, then symlink the
# selected node/npm/npx binaries into PATH for non-login Docker exec sessions.
RUN mkdir -p "$NVM_DIR" \
       && curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | PROFILE=/dev/null bash \
       && source "$NVM_DIR/nvm.sh" \
       && nvm install --lts \
       && nvm alias default 'lts/*' \
       && nvm use --silent default \
       && NODE_PREFIX="$(dirname "$(dirname "$(nvm which default)")")" \
       && ln -sf "$NODE_PREFIX/bin/node" /usr/local/bin/node \
       && ln -sf "$NODE_PREFIX/bin/npm" /usr/local/bin/npm \
       && ln -sf "$NODE_PREFIX/bin/npx" /usr/local/bin/npx \
       && printf '%s\n' \
       'export NVM_DIR=/usr/local/nvm' \
       '[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"' \
       'nvm use --silent default >/dev/null 2>&1 || true' \
       > /etc/profile.d/nvm.sh

# uv (provides `uvx`) — pinned-binary install.
RUN curl -LsSf https://astral.sh/uv/install.sh | sh \
       && mv /root/.local/bin/uv /usr/local/bin/uv \
       && mv /root/.local/bin/uvx /usr/local/bin/uvx

# Bun — fast JS runtime / package manager. Installed via official script with
# BUN_INSTALL=/usr/local so the bun binary lands on PATH.
RUN curl -fsSL https://bun.com/install | bash

# Global agent CLIs — installed via bun for speed where the tools are npm packages.
#   - Codex CLI → ChatGPT Plus/Pro subscription (device-auth)
#   - OpenCode  → same OpenCode Go subscription as the Hermes brain
#   - gws       → Google Workspace CLI backend for Hermes' google-workspace skill
# Bun writes global binaries to $BUN_INSTALL/bin (= /usr/local/bin), already on PATH.
RUN bun install -g @openai/codex opencode-ai @googleworkspace/cli@0.22.5

# Cursor Agent CLI — installed from Cursor's official Linux installer. The
# installer normally writes into $HOME/.local; using /opt/cursor-agent keeps the
# binary outside the persistent /opt/data volume while still readable by hermes.
RUN install -d -m 0755 /opt/cursor-agent \
       && NO_COLOR=1 HOME=/opt/cursor-agent bash -c 'curl -fsSL https://cursor.com/install | bash' \
       && ln -sf /opt/cursor-agent/.local/bin/agent /usr/local/bin/agent \
       && ln -sf /opt/cursor-agent/.local/bin/cursor-agent /usr/local/bin/cursor-agent \
       && chown -R 10000:10000 /opt/cursor-agent \
       && chmod -R u+rwX,go+rX /opt/cursor-agent

# Configure git: let gh act as the credential helper for github.com so
# `git push` works without ever materialising the PAT on disk.
# The commit author identity is configured at container startup from
# GIT_USER_NAME and GIT_USER_EMAIL in .env.
RUN git config --system credential.https://github.com.helper "" \
       && git config --system --add credential.https://github.com.helper "!gh auth git-credential" \
       && git config --system credential.https://gist.github.com.helper "" \
       && git config --system --add credential.https://gist.github.com.helper "!gh auth git-credential" \
       && git config --system init.defaultBranch main \
       && git config --system pull.rebase false

# Symlink the Hermes CLI onto /usr/local/bin so `docker compose exec assistant
# hermes ...` works. The hermes binary lives inside Hermes' Python venv at
# /opt/hermes/.venv/bin/hermes and is only on PATH while the venv is activated
# (the base entrypoint sources activate before exec'ing hermes). Interactive
# `docker exec` sessions don't re-source the activate script, so the binary
# was unreachable from the shell. The shebang inside the binary points at
# the venv's python by absolute path, so calling it via symlink uses the
# right interpreter without needing activation.
RUN ln -sf /opt/hermes/.venv/bin/hermes /usr/local/bin/hermes \
       && printf '%s\n' '#!/usr/bin/env sh' 'exec /opt/hermes/.venv/bin/python "$@"' > /usr/local/bin/python \
       && chmod +x /usr/local/bin/python

# Patch Hermes' base entrypoint to stop creating ${HERMES_HOME}/home/.
#
# The base entrypoint (/opt/hermes/docker/entrypoint.sh) has a line:
#   mkdir -p "$HERMES_HOME"/{cron,sessions,logs,hooks,memories,skills,skins,plans,workspace,home}
#
# That trailing `home` triggers hermes_constants.get_subprocess_home() to
# return ${HERMES_HOME}/home (it returns the path iff the dir exists). Hermes
# then spawns codex/opencode/cursor subprocesses with HOME=/opt/data/home, which
# misses the auth files at /opt/data/.codex/auth.json + tool equivalents —
# even though `codex login` correctly wrote them. Net effect: the assistant
# reports "not logged in" no matter how many times the user actually logs in.
#
# We don't need per-profile subprocess HOME isolation — hermes' real HOME
# (/opt/data) is already persistent Docker volume state. Removing the `,home` keeps
# subprocess HOME consistent with interactive shells, so all coding-agent CLIs
# converge on persistent auth/config state under /opt/data.
#
# Idempotent: newer Hermes images may already omit the `home` directory from
# this mkdir list. In that case, keep building and let the runtime shim's
# `rm -rf /opt/data/home` remain the fallback.
RUN F=/opt/hermes/docker/entrypoint.sh \
       && if grep -q ',workspace,home}' "$F"; then \
            sed -i 's|,workspace,home}|,workspace}|' "$F" \
            && grep -q ',workspace}' "$F"; \
          else \
            echo "Hermes entrypoint no longer has workspace,home brace pattern; leaving as-is"; \
          fi \
       && ! grep -q ',workspace,home}' "$F"

# Patch Hermes' WAL-fallback marker list to handle "database is locked".
#
# gateway/run.py runs two background tasks that both call kanban_db.connect()
# at startup — the kanban dispatcher and the kanban notifier. Each invokes
# apply_wal_with_fallback() → `PRAGMA journal_mode=WAL` to convert the journal.
# On Docker Desktop's bind-mount FS the conversion needs an exclusive lock;
# the second concurrent caller sees `database is locked` — which is NOT in
# hermes_state._WAL_INCOMPAT_MARKERS upstream, so the fallback doesn't fire
# and the dispatcher's first tick crashes (visible in errors.log as a one-shot
# sqlite3.OperationalError at boot). state.db avoids this because only one
# process opens it at startup.
#
# Adding the marker lets the fallback fire on this race too — both tasks end
# up in DELETE mode, same outcome state.db already gets on this FS. Newer
# Hermes images may already include or restructure this marker list; in that
# case, keep building instead of failing the image build.
RUN F=/opt/hermes/hermes_state.py \
       && if grep -q '"database is locked"' "$F"; then \
            echo "Hermes WAL fallback already handles database is locked"; \
          elif grep -q '"disk i/o error",' "$F"; then \
            sed -i '/"disk i\/o error",/a\    "database is locked",     # Docker Desktop bind-mount race between concurrent WAL pragmas' "$F" \
            && grep -q '"database is locked"' "$F"; \
          else \
            echo "Hermes WAL fallback marker list changed; leaving as-is"; \
          fi

# Sanity-check the toolchain at build time so failures surface early.
RUN node --version && npm --version && bun --version && uv --version \
       && codex --version && opencode --version && agent --version && cursor-agent --version \
       && gws --version && python --version \
       && gh --version && git --version \
       && rg --version | head -n1 && fd --version && jq --version || true

# Entrypoint shim: wires the coding-agent global AGENTS.md into the places
# codex and opencode look at, prepares Cursor state, then hands off to the
# original Hermes entrypoint.
# See scripts/hermes-entrypoint.sh for why this is runtime and not buildtime.
COPY templates/assistant /opt/hermes-assistant/templates/assistant
COPY scripts/hermes-entrypoint.sh /usr/local/bin/hermes-entrypoint.sh
RUN chmod +x /usr/local/bin/hermes-entrypoint.sh
ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/usr/local/bin/hermes-entrypoint.sh"]

WORKDIR /opt/data
