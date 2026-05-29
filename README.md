# Dockerized Hermes Coding Assistant

Run a Telegram-accessible [Hermes Agent](https://hermes-agent.nousresearch.com/docs/) that behaves like a real coding workstation, not a toy chatbot.

This repo packages Hermes with Codex CLI, OpenCode CLI, Cursor Agent CLI, GitHub CLI, optional Google Workspace tooling, a broad Ubuntu development toolbox, and an in-container Docker daemon. It is built for agents that need to clone repos, run tests, build containers, delegate coding tasks, inspect results, and keep working across restarts.

## Why This Exists

Most assistant setups are either too thin to be useful for real engineering work or too tied to one local machine. This repo is an opinionated middle ground:

- one command gets a persistent Telegram-accessible coding assistant running;
- every repo checkout, agent auth file, memory, and Docker layer lives in named volumes;
- the assistant can use Docker from inside Docker without host path mismatches;
- coding work is isolated in fresh git worktrees by default;
- Codex, OpenCode, and Cursor can all be used as local sub-agents;
- setup finishes with smoke tests instead of hoping auth and tools work.

The goal is a portable personal development machine for AI coding workflows: reproducible enough to run on a laptop or VPS, powerful enough to build and test serious repos, and explicit enough about attribution and branch safety to be trusted with public-facing work.

## What You Get

- Hermes Agent running from the official Nous image.
- Telegram as the chat surface, with localhost dashboard/API ports.
- Codex CLI, OpenCode CLI, and Cursor Agent CLI installed together.
- GitHub CLI wired through `GH_TOKEN` for repos, PRs, issues, and gists.
- Full dev toolbox: Node, Bun, Python, uv, Go, Rust, compilers, debuggers, `rg`, `fd`, `jq`, `yq`, `shellcheck`, `shfmt`, and more.
- Privileged Docker-in-Docker with Docker CLI, Compose, and Buildx.
- Persistent `/workbench` for canonical clones and per-task worktrees.
- Optional Google Workspace support for Gmail, Calendar, Drive, Docs, Sheets, and Contacts.
- Public attribution footer rules for commits, PRs, issue comments, reviews, and other external text.

## Opinionated Defaults

This is intentionally not a minimal production container. It is a trusted development environment for coding agents.

- **Power over sandbox minimalism:** privileged container, passwordless `sudo`, broad tools, and a real inner Docker daemon.
- **Docker-in-Docker over host socket:** avoids bind-mount path mismatches when agents run repo-local Docker commands from `/workbench`.
- **Worktrees by default:** canonical clones stay clean; each coding task gets `/workbench/<owner>/<repo>-worktrees/<task-slug>`.
- **Protected branches stay protected:** no commits directly on `main`, `master`, `develop`, `dev`, `prod`, `production`, `staging`, or `release` without a second explicit confirmation.
- **Delegation stays faithful:** when the user explicitly chooses Codex, OpenCode, or Cursor, Hermes passes the request through with only typo/grammar cleanup and minimal routing context.
- **Cursor stays repo-scoped:** Cursor runs from the task worktree, never from all of `/workbench`.
- **High-reasoning defaults:** Hermes uses DeepSeek V4 Pro high; Codex uses `xhigh`; OpenCode uses `max`.
- **Transparency by default:** public-facing text gets the configured Hermes attribution footer unless the user explicitly opts out.

## Requirements

- Docker with the Compose plugin.
- Privileged containers enabled. This is required for the in-container Docker daemon.
- Git.
- Telegram bot token from `@BotFather`.
- GitHub classic PAT with `repo` and `gist`; add `read:org` for org repos.
- 8 GB Docker/host memory minimum; 16 GB or more is better.
- Optional: Cursor API key for headless Cursor runs.
- Optional: Google OAuth Desktop client JSON for Gmail, Calendar, Drive, Docs, Sheets, or Contacts.

Dashboard and API ports bind to `127.0.0.1`. Telegram uses outbound polling, so normal chat use does not require public inbound ports.

## Setup

```bash
git clone <this-repo-url> hermes-assistant
cd hermes-assistant

cp .env.example .env
chmod 600 .env
vi .env

scripts/setup.sh
```

`scripts/setup.sh` prompts for missing values, builds the container, starts Hermes, runs optional auth flows, configures Google Workspace if requested, and finishes with smoke tests.

Important `.env` values:

| Key                                                | Purpose                                                                        |
| -------------------------------------------------- | ------------------------------------------------------------------------------ |
| `ASSISTANT_NAME`, `ASSISTANT_SLUG`, `USER_NAME`    | Assistant identity and Docker naming.                                          |
| `GIT_USER_NAME`, `GIT_USER_EMAIL`, `BRANCH_PREFIX` | Git author identity and branch prefix for workbench repos.                     |
| `TELEGRAM_BOT_TOKEN`, `TELEGRAM_ALLOWED_USERS`     | Telegram access.                                                               |
| `GH_TOKEN`                                         | GitHub auth for `gh`, git push, PRs, issues, and gists.                        |
| `CURSOR_API_KEY`                                   | Optional Cursor Agent auth for headless `agent -p`.                            |
| `DOCKERD_STORAGE_DRIVER`                           | Inner Docker storage driver. Keep `overlay2` unless setup tells you otherwise. |

Do not commit `.env` or exported backups.

## Operations

```bash
docker compose up -d
docker compose logs -f assistant
docker compose restart assistant
docker compose down
```

Open a shell or Hermes CLI:

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

Run smoke tests after setup or after changing auth:

```bash
scripts/smoke-test.sh
```

Required smoke checks cover Telegram, GitHub, Hermes, and the inner Docker daemon. Codex, OpenCode, Cursor, and Google Workspace report optional warnings when auth is missing or invalid.

Dashboard:

```text
http://localhost:<DASHBOARD_PORT>
```

## Model Defaults

| Runtime            | Default                                                |
| ------------------ | ------------------------------------------------------ |
| Hermes brain       | `opencode-go/deepseek-v4-pro`, reasoning effort `high` |
| Codex sub-agent    | `gpt-5.5`, reasoning effort `xhigh`                    |
| OpenCode sub-agent | `opencode-go/deepseek-v4-pro`, variant `max`           |
| Cursor sub-agent   | `composer-2.5`                                         |

## Docker And State

This is intentionally a powerful development container, not a hardened production service. It runs privileged, gives the `hermes` user passwordless `sudo`, and starts Docker-in-Docker so repo commands like this work normally:

```bash
docker run --rm -v "$PWD":/app -w /app node:lts npm test
```

Runtime state is stored in named Docker volumes:

| Volume                        | Contains                                                        |
| ----------------------------- | --------------------------------------------------------------- |
| `${ASSISTANT_SLUG}_data`      | Hermes config, memories, logs, instructions, and auth.          |
| `${ASSISTANT_SLUG}_workbench` | Canonical repo checkouts and task worktrees under `/workbench`. |
| `${ASSISTANT_SLUG}_docker`    | Inner Docker images, containers, volumes, and build cache.      |

## Google Workspace

Google Workspace is optional. During setup, answer yes at the Google prompt and provide an OAuth 2.0 Desktop client JSON. The setup stores:

- `/opt/data/google_client_secret.json`
- `/opt/data/google_token.json`

For non-interactive transfer:

```bash
GOOGLE_CLIENT_SECRET_B64="$(base64 -w0 /path/to/client_secret.json)" scripts/setup.sh
```

On macOS:

```bash
GOOGLE_CLIENT_SECRET_B64="$(base64 -i /path/to/client_secret.json | tr -d '\n')" scripts/setup.sh
```

Treat Google client secrets, Google tokens, OAuth callback URLs containing `code=`, `.env`, and backups as secrets.

## Public Attribution

When the assistant writes public-facing content on behalf of the user, it appends this footer unless explicitly asked not to:

```text
---
Authored by <ASSISTANT_NAME> (powered by Hermes Agent).
```

This applies to commit bodies, PR descriptions, PR reviews, issue comments, public gist text, release notes, and similar external text.

## Backup, Restore, Wipe

Create a backup:

```bash
scripts/backup-state.sh
```

Restore:

```bash
scripts/restore-state.sh <backup.tar.gz>
scripts/setup.sh
```

Backups include `.env`, Hermes state, repo checkouts, and inner Docker state. They contain secrets and can be large.

Wipe this assistant's Docker footprint:

```bash
scripts/clean-wipe.sh
scripts/clean-wipe.sh -y
```

Also prune unused Docker objects across the machine:

```bash
scripts/clean-wipe.sh -y --prune-system
```

Use `--prune-system` carefully; it can remove unrelated stopped containers and unused images.

## Files

| Path                                                                           | Purpose                                |
| ------------------------------------------------------------------------------ | -------------------------------------- |
| `Dockerfile`                                                                   | Builds Hermes plus tooling.            |
| `docker-compose.yml`                                                           | Runs the assistant and volumes.        |
| `.env.example`                                                                 | Environment template.                  |
| `templates/assistant/SOUL.md`                                                  | Assistant persona.                     |
| `templates/assistant/AGENTS.md`                                                | Main assistant operating rules.        |
| `templates/assistant/coding-agents/AGENTS.md`                                  | Shared Codex/OpenCode sub-agent rules. |
| `scripts/setup.sh`                                                             | Setup flow.                            |
| `scripts/smoke-test.sh`                                                        | Post-setup checks.                     |
| `scripts/backup-state.sh`, `scripts/restore-state.sh`, `scripts/clean-wipe.sh` | State management.                      |

## Troubleshooting

- Start with `scripts/smoke-test.sh`.
- For startup failures, run `docker compose logs assistant`.
- For auth issues, rerun the matching login command from the Operations section.
- If inner Docker fails, try `DOCKERD_STORAGE_DRIVER=fuse-overlayfs` in `.env`, then rebuild.
- If ports conflict, change `DASHBOARD_PORT` or `API_PORT` in `.env`.
