# Dockerized Hermes Coding Assistant

Run a personal [Hermes Agent](https://hermes-agent.nousresearch.com/docs/) as a Telegram-accessible coding assistant.

This repository packages Hermes with local coding sub-agents, persistent Docker state, GitHub access, and optional Google Workspace access so someone can clone the repo, fill a `.env`, run one setup script, and get a usable assistant.

## What You Get

- Hermes Agent running from the official Nous Research image.
- Telegram as the chat surface.
- Local coding agents inside the same Docker container:
  - Codex CLI
  - OpenCode CLI
  - Cursor Agent CLI
- GitHub CLI wired through `GH_TOKEN` for cloning, pushing, PRs, issues, and gists.
- Optional Google Workspace support through Hermes' bundled `google-workspace` skill and `gws`.
- Persistent state in Docker named volumes, not host folders.
- Long-lived project checkouts under `/workbench/<owner>/<repo>`.
- Assistant-specific Docker names from `ASSISTANT_SLUG`, so multiple assistants can run on one machine.

## Requirements

- Docker with the Compose plugin.
- Git.
- A Telegram bot token from `@BotFather`.
- A GitHub classic PAT with the scopes listed below.
- At least 4 GB Docker memory. More is better for large repos.
- Optional: Cursor API key for headless Cursor CLI runs.
- Optional: Google OAuth Desktop client JSON for Gmail, Calendar, Drive, Docs, Sheets, and Contacts.

The Compose file binds dashboard and API ports to `127.0.0.1` only. Telegram access works through outbound polling/web requests, so a VPS does not need public inbound ports for normal chat use.

## Quick Start

```bash
git clone <this-repo-url> hermes-assistant
cd hermes-assistant

cp .env.example .env
chmod 600 .env
vi .env

scripts/setup.sh
```

The setup script will:

- prompt for missing `.env` values;
- build and start the Docker container;
- render assistant instructions from `templates/assistant/`;
- run Hermes model setup if you choose;
- run Codex and OpenCode login flows if you choose;
- configure Cursor through `CURSOR_API_KEY` or `agent login`;
- optionally configure Google Workspace OAuth;
- verify Telegram, GitHub, coding-agent state, Google Workspace, and Hermes status.

If you skip an optional login during setup, rerun `scripts/setup.sh` later.

## Required `.env` Values

Start from `.env.example`. These are the fields most people need to understand:

| Key                               | Purpose                                                                   |
| --------------------------------- | ------------------------------------------------------------------------- |
| `ASSISTANT_NAME`                  | Human-readable assistant name shown in runtime instructions.              |
| `ASSISTANT_SLUG`                  | Docker-safe name for container, image, network, and volumes.              |
| `USER_NAME`                       | Primary user or team name.                                                |
| `GIT_USER_NAME`, `GIT_USER_EMAIL` | Commit author identity inside workbench repos.                            |
| `BRANCH_PREFIX`                   | Prefix for assistant-created task branches.                               |
| `DASHBOARD_PORT`, `API_PORT`      | Localhost ports for the dashboard and OpenAI-compatible API.              |
| `DOCKER_MEMORY`, `DOCKER_CPUS`    | Docker resource limits.                                                   |
| `TELEGRAM_BOT_TOKEN`              | Bot token from `@BotFather`.                                              |
| `TELEGRAM_ALLOWED_USERS`          | Comma-separated Telegram numeric user IDs allowed to talk to Hermes.      |
| `GH_TOKEN`                        | GitHub classic PAT used by `gh` and git credential helper.                |
| `CURSOR_API_KEY`                  | Optional Cursor user API key for reliable headless `agent -p` automation. |

Recommended GitHub PAT scopes:

- `repo`
- `gist`
- `read:org` if you use org repos

Leave these disabled unless you know you need them:

- `delete_repo`
- `admin:*`
- `workflow`
- broad account/package/project/notification scopes

For Cursor, prefer `CURSOR_API_KEY` on VPS or Docker installs. It authenticates the Cursor CLI as your Cursor account and avoids browser handoff inside the container. Generate one from [Cursor user API keys](https://cursor.com/dashboard/api?section=user-keys#user-api-keys). Browser login with `agent login` is still available for interactive local setups.

## Model Defaults

| Runtime            | Default                                                |
| ------------------ | ------------------------------------------------------ |
| Hermes brain       | `opencode-go/deepseek-v4-pro`, reasoning effort `high` |
| Codex sub-agent    | `gpt-5.5`, reasoning effort `high`                     |
| OpenCode sub-agent | `opencode-go/deepseek-v4-pro`, variant `high`          |
| Cursor sub-agent   | `composer-2.5`                                         |

Cursor CLI exposes `--model`, but the installed CLI does not expose a separate reasoning-effort flag. The templates tell Hermes not to invent one.

## Daily Operations

Use the Compose service name `assistant`; the actual container name is `${ASSISTANT_SLUG}`.

```bash
docker compose up -d
docker compose logs -f assistant
docker compose restart assistant
docker compose down
```

Open an interactive shell or Hermes CLI:

```bash
docker compose exec -u hermes -it assistant sh
docker compose exec -u hermes -it assistant hermes
```

Re-run auth manually:

```bash
docker compose exec -u hermes -it assistant hermes setup model
docker compose exec -u hermes -it assistant codex login --device-auth
docker compose exec -u hermes -it assistant opencode auth login
docker compose exec -u hermes -it assistant agent login
```

Dashboard:

```text
http://localhost:<DASHBOARD_PORT>
```

## Updating An Existing Install Without Losing State

The important rule: do not delete the Docker volumes. State lives in `${ASSISTANT_SLUG}_data` and `${ASSISTANT_SLUG}_workbench`.

Safe update flow:

```bash
cd /path/to/hermes-assistant

# 1. Back up volumes and .env first.
scripts/backup-state.sh

# 2. Pull the new repository code.
# If you changed tracked files locally, commit or stash those changes first.
git pull

# 3. Add any new .env keys introduced by the update.
# Example for Cursor CLI support:
grep -q '^CURSOR_API_KEY=' .env || printf '\nCURSOR_API_KEY=\n' >> .env
vi .env

# 4. Rebuild and recreate the container while keeping named volumes.
docker compose up -d --build
```

Never use these for a normal update:

```bash
docker compose down -v
docker volume rm ...
scripts/clean-wipe.sh
```

Those remove state.

### Updating Runtime Instructions

The entrypoint renders `SOUL.md`, `AGENTS.md`, and `coding-agents/AGENTS.md` into `/opt/data` on first boot. It does not overwrite already-customized runtime instructions.

If an update changes the templates and you want the running assistant to pick them up, back up and regenerate only the instruction files:

```bash
docker compose exec -u hermes assistant sh -lc '
  cp /opt/data/AGENTS.md /opt/data/AGENTS.md.before-template-update
  cp /opt/data/coding-agents/AGENTS.md /opt/data/coding-agents/AGENTS.md.before-template-update
'

docker compose exec assistant sh -lc '
  rm -f /opt/data/AGENTS.md /opt/data/coding-agents/AGENTS.md
'

docker compose up -d --force-recreate
```

This preserves memories, sessions, auth, config, logs, and `/workbench` checkouts. It only regenerates those instruction files from the latest templates.

## Backups And Migration

Create an export:

```bash
scripts/backup-state.sh
```

The backup includes:

- `.env`
- the Hermes data volume
- the workbench volume

It contains secrets and repository checkouts. Store it carefully.

Restore on another host:

```bash
git clone <this-repo-url> hermes-assistant
cd hermes-assistant
scripts/restore-state.sh <backup.tar.gz>
scripts/setup.sh
```

If you restore to an untrusted or shared host, rotate `GH_TOKEN`, Telegram token, Cursor API key, Google OAuth credentials, and provider auth.

## Google Workspace

Google Workspace is optional. Enable it if you want Hermes to use Gmail, Calendar, Drive, Docs, Sheets, or Contacts.

During `scripts/setup.sh`, answer yes at the Google Workspace prompt and provide an OAuth 2.0 Desktop client JSON. The script stores credentials in the data volume:

| Path                                  | Purpose                                  |
| ------------------------------------- | ---------------------------------------- |
| `/opt/data/google_client_secret.json` | OAuth Desktop client from Google Cloud.  |
| `/opt/data/google_token.json`         | Refreshable user token created by setup. |

Create the OAuth client:

1. Open <https://console.cloud.google.com/projectselector2/home/dashboard>.
2. Create or select a project.
3. Enable the APIs you need: Gmail, Calendar, Drive, Sheets, Docs, People.
4. Open <https://console.cloud.google.com/apis/credentials>.
5. Create an `OAuth client ID` for a `Desktop app`.
6. If the app is in testing mode, add your account at <https://console.cloud.google.com/auth/audience>.
7. Download the JSON.

For VPS automation:

```bash
GOOGLE_CLIENT_SECRET_B64="$(base64 -w0 /path/to/client_secret.json)" scripts/setup.sh
```

On macOS:

```bash
GOOGLE_CLIENT_SECRET_B64="$(base64 -i /path/to/client_secret.json | tr -d '\n')" scripts/setup.sh
```

Verify later:

```bash
docker compose exec -u hermes assistant \
  sh -lc '/opt/hermes/.venv/bin/python "$HERMES_HOME/skills/productivity/google-workspace/scripts/setup.py" --check-live'
```

Treat Google client secrets, Google tokens, OAuth redirect URLs containing `code=`, and exported backups as secrets.

## Coding Workflow

Hermes keeps long-lived checkouts in `/workbench/<owner>/<repo>` inside the `${ASSISTANT_SLUG}_workbench` volume. It fetches and reuses those repos across tasks.

Default assistant behavior:

| User asks                   | Assistant does                                                          |
| --------------------------- | ----------------------------------------------------------------------- |
| Explain code                | Uses GitHub search first; clones only if needed.                        |
| Read or create gists        | Uses `gh gist`; creates secret gists unless public is requested.        |
| Trivial mechanical edit     | Handles it directly.                                                    |
| Reasoning-heavy coding task | Delegates to Codex, OpenCode, or Cursor; asks which one if unspecified. |
| Long coding-agent run       | Starts it in the background and monitors it.                            |
| Push, commit, or open PR    | Only after explicit user approval.                                      |

The assistant delegates by running local CLI processes inside the same container. The templates use these invocation shapes:

```bash
codex exec \
  --model gpt-5.5 \
  --config 'model_reasoning_effort="high"' \
  --dangerously-bypass-approvals-and-sandbox \
  "<task prompt>"
```

```bash
opencode run \
  --model opencode-go/deepseek-v4-pro \
  --variant high \
  --dir /workbench/<owner>/<repo> \
  --dangerously-skip-permissions \
  "<task prompt>"
```

Cursor delegation uses the local Cursor Agent CLI, not Cursor Background Agents:

```bash
agent -p \
  --workspace /workbench \
  --model composer-2.5 \
  --force \
  --trust \
  --sandbox disabled \
  --output-format text \
  "Work only in /workbench/<owner>/<repo>. <task prompt>"
```

Codex and OpenCode get the shared rules through their global config directories. Cursor reads `AGENTS.md` from the workspace, so the entrypoint also symlinks the shared coding-agent rules to `/workbench/AGENTS.md`. Repo-local nested `AGENTS.md` files can add more specific Cursor instructions.

Cursor ACP mode is available as `agent acp` for custom Agent Client Protocol clients, but normal Telegram delegation uses local headless `agent -p`.

## Repository Layout

| Path                                          | Purpose                                       |
| --------------------------------------------- | --------------------------------------------- |
| `Dockerfile`                                  | Builds Hermes plus coding-agent tooling.      |
| `docker-compose.yml`                          | Runs the assistant service and named volumes. |
| `.env.example`                                | Environment template. Copy to `.env`.         |
| `templates/assistant/SOUL.md`                 | Assistant persona template.                   |
| `templates/assistant/AGENTS.md`               | Main assistant operating instructions.        |
| `templates/assistant/coding-agents/AGENTS.md` | Shared sub-agent instructions.                |
| `scripts/setup.sh`                            | Interactive setup and verification.           |
| `scripts/backup-state.sh`                     | Exports `.env` plus Docker volumes.           |
| `scripts/restore-state.sh`                    | Restores exported state on another host.      |
| `scripts/clean-wipe.sh`                       | Removes this assistant's Docker footprint.    |

Runtime state:

| Storage                                     | Contains                                                              |
| ------------------------------------------- | --------------------------------------------------------------------- |
| `${ASSISTANT_SLUG}_data` Docker volume      | Hermes config, memories, sessions, logs, rendered instructions, auth. |
| `${ASSISTANT_SLUG}_workbench` Docker volume | Persistent project checkouts under `/workbench`.                      |
| `.env`                                      | Local identity, tokens, ports, Docker limits.                         |

Do not commit `.env` or exported backups.

## Clean Wipe

Use this only when you intentionally want to remove the assistant's Docker footprint.

```bash
scripts/clean-wipe.sh
scripts/clean-wipe.sh -y
```

Also prune unused Docker objects across the whole machine:

```bash
scripts/clean-wipe.sh -y --prune-system
```

Use `--prune-system` carefully. It can delete stopped containers and unused images from unrelated projects.

## Troubleshooting

| Symptom                       | Try                                                                                               |
| ----------------------------- | ------------------------------------------------------------------------------------------------- |
| Container exits immediately   | `docker compose logs assistant`                                                                   |
| Telegram bot does not respond | Check `TELEGRAM_BOT_TOKEN` and `TELEGRAM_ALLOWED_USERS`.                                          |
| GitHub auth fails             | Check `GH_TOKEN`, then recreate with `docker compose up -d`.                                      |
| Gist access fails             | Regenerate `GH_TOKEN` with the `gist` scope, then recreate with `docker compose up -d`.           |
| `gws` command missing         | Rebuild with `docker compose up -d --build`.                                                      |
| Google says not authenticated | Run the Google Workspace setup flow and verify `/opt/data/google_token.json`.                     |
| Google API returns 403        | Enable the API in Google Cloud Console, or revoke and re-authorize if scopes are missing.         |
| Codex says not logged in      | `docker compose exec -u hermes -it assistant codex login --device-auth`                           |
| OpenCode says no provider     | `docker compose exec -u hermes -it assistant opencode auth login`                                 |
| Cursor says not authenticated | Set `CURSOR_API_KEY` in `.env` and recreate with `docker compose up -d`, or run `agent login`.    |
| Coding-agent task times out   | Increase `agent.gateway_timeout` and `terminal.timeout` in `/opt/data/config.yaml`, then restart. |
| Model errors or 401s          | `docker compose exec -u hermes assistant hermes status`, then rerun model setup.                  |
| Port conflict                 | Change `DASHBOARD_PORT` or `API_PORT` in `.env`.                                                  |
