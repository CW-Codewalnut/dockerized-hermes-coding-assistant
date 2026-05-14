# Dockerized Hermes Coding Assistant

A publishable Docker setup for running [Hermes Agent](https://hermes-agent.nousresearch.com/docs/) as a Telegram-accessible coding assistant with Codex and OpenCode sub-agents.

## What This Includes

- Hermes Agent from the official Nous Research image.
- Telegram gateway for chat access.
- Codex CLI and OpenCode CLI for delegated coding work.
- GitHub CLI wired through `GH_TOKEN` for repos and gists.
- Node.js installed through `nvm` using the current LTS line.
- Runtime state in named Docker volumes, not host folders.
- Assistant-specific Docker names from `ASSISTANT_SLUG`, so multiple agents can run side by side.

## Repo Layout

Tracked source files:

| Path                                       | Purpose                                           |
| ------------------------------------------ | ------------------------------------------------- |
| `templates/assistant/SOUL.md`                 | Assistant persona template.                       |
| `templates/assistant/AGENTS.md`               | Main assistant workflow template.                 |
| `templates/assistant/coding-agents/AGENTS.md` | Codex/OpenCode workflow template.                 |
| `scripts/setup.sh`                         | Interactive one-command setup.                    |
| `scripts/clean-wipe.sh`                    | Removes this assistant's Docker footprint.        |
| `scripts/backup-state.sh`                  | Exports Docker volumes plus `.env`.               |
| `scripts/restore-state.sh`                 | Restores exported Docker volumes on another host. |

Template placeholders are rendered into `/opt/data` at container startup. Runtime instruction files should never contain unresolved placeholder tokens.

Runtime state:

| Storage                                     | Contains                                                            |
| ------------------------------------------- | ------------------------------------------------------------------- |
| `${ASSISTANT_SLUG}_data` Docker volume      | Hermes config, memories, sessions, logs, Codex/OpenCode auth.       |
| `${ASSISTANT_SLUG}_workbench` Docker volume | Persistent project checkouts under `/workbench/<owner>/<repo>`.     |
| `.env`                                      | Local identity, Telegram token, GitHub token, ports, Docker limits. |

Do not commit `.env` or exported volume backups.

## Setup

Copy the env file, fill what you already know, then run the setup script:

```bash
cp .env.example .env
$EDITOR .env
chmod 600 .env
scripts/setup.sh
```

The script will:

- prompt for missing `.env` values;
- build and start Docker;
- seed Hermes runtime instructions with your assistant/user names;
- run `hermes setup model`;
- run Codex device login;
- run OpenCode auth login;
- verify Telegram, GitHub repo/gist access, Codex/OpenCode state, and Hermes status.

Model defaults:

| Runtime            | Default                                                |
| ------------------ | ------------------------------------------------------ |
| Hermes brain       | `opencode-go/deepseek-v4-pro`, reasoning effort `high` |
| Codex sub-agent    | `gpt-5.5`, reasoning effort `high`                     |
| OpenCode sub-agent | `opencode-go/deepseek-v4-pro`, variant `high`          |

Runtime timeouts:

| Setting                   | Default                                                 |
| ------------------------- | ------------------------------------------------------- |
| Hermes gateway inactivity | `7200` seconds                                          |
| Gateway warning           | `3600` seconds                                          |
| Terminal command timeout  | `7200` seconds                                          |
| Long coding-agent runs    | Background process with `process wait` / `poll` / `log` |

## Env Values

Important `.env` fields:

| Key                                            | Meaning                                                                          |
| ---------------------------------------------- | -------------------------------------------------------------------------------- |
| `ASSISTANT_NAME`                               | Human-readable assistant name.                                                   |
| `ASSISTANT_SLUG`                               | Docker-safe slug used for container/image/volume names.                          |
| `USER_NAME`                                    | Primary user or team name.                                                       |
| `GIT_USER_NAME`, `GIT_USER_EMAIL`              | Commit author identity inside workbench repos.                                   |
| `BRANCH_PREFIX`                                | Prefix for assistant-created task branches.                                      |
| `DASHBOARD_PORT`, `API_PORT`                   | Localhost ports, useful when running multiple agents.                            |
| `DOCKER_MEMORY`, `DOCKER_CPUS`                 | Container limits. Defaults are `4G` memory and `12.0` CPUs; adjust for the host. |
| `TELEGRAM_BOT_TOKEN`, `TELEGRAM_ALLOWED_USERS` | Telegram access.                                                                 |
| `GH_TOKEN`                                     | Classic GitHub PAT for `gh`, git pushes, and GitHub Gists.                       |

Recommended GitHub PAT scopes:

- `repo`
- `gist`
- `read:org` if you use org repos

Leave `delete_repo`, `admin:*`, and `workflow` disabled.
GitHub's classic PAT model exposes gist read/create access as a single `gist` scope.

## Day-To-Day

Use the Compose service name `assistant`; the actual container name is `${ASSISTANT_SLUG}`.

```bash
docker compose up -d
docker compose logs -f assistant
docker compose restart assistant
docker compose down
docker compose exec -u hermes -it assistant hermes
```

Re-run interactive auth/setup:

```bash
docker compose exec -u hermes -it assistant hermes setup model
docker compose exec -u hermes -it assistant codex login --device-auth
docker compose exec -u hermes -it assistant opencode auth login
```

Dashboard:

```text
http://localhost:<DASHBOARD_PORT>
```

## Coding Workflow

The assistant keeps long-lived checkouts in the `${ASSISTANT_SLUG}_workbench` volume at `/workbench/<owner>/<repo>`, similar to a developer's `~/codes`.
The entrypoint fixes `/workbench` ownership on every boot so the Hermes runtime user can create owner/repo directories and clone normally.

Default behavior:

| User asks                   | Assistant does                                                     |
| --------------------------- | ------------------------------------------------------------------ |
| Explain code                | Uses GitHub search first; opens a local checkout only if needed.   |
| Read or create gists        | Uses `gh gist`; creates secret gists unless public is requested.   |
| Trivial mechanical edit     | Handles it directly in the persistent checkout.                    |
| Reasoning-heavy coding task | Delegates to Codex or OpenCode; asks which one if unspecified.     |
| Long Codex/OpenCode run     | Starts it in the background and monitors it with the process tool. |
| Push or open PR             | Only happens after explicit approval.                              |

## Backup And Migration

Export state:

```bash
scripts/backup-state.sh
```

This writes a tarball containing `.env`, the Hermes data volume, and the workbench volume. It contains secrets and repo checkouts.

On another host:

```bash
git clone <your-repo-url> hermes-assistant
cd hermes-assistant
# copy the backup tarball here
scripts/restore-state.sh <backup.tar.gz>
scripts/setup.sh
```

If you move to an untrusted/shared host, rotate `GH_TOKEN`, Telegram token, and provider auth.

## Clean Wipe

Remove this assistant's containers, images, volumes, legacy host runtime folders, and Docker builder cache while preserving `.env` and source files:

```bash
scripts/clean-wipe.sh
```

Skip confirmation:

```bash
scripts/clean-wipe.sh -y
```

Also prune unused Docker objects across the whole machine:

```bash
scripts/clean-wipe.sh -y --prune-system
```

Use `--prune-system` carefully: it can delete stopped containers and unused images from unrelated projects. It does not delete Docker volumes unless explicitly asked.

## Troubleshooting

| Symptom                       | Try                                                                                               |
| ----------------------------- | ------------------------------------------------------------------------------------------------- |
| Container exits immediately   | `docker compose logs assistant`                                                                   |
| Telegram bot does not respond | Check `TELEGRAM_BOT_TOKEN` and `TELEGRAM_ALLOWED_USERS`.                                          |
| GitHub auth fails             | Check `GH_TOKEN`, then recreate with `docker compose up -d`.                                      |
| Gist access fails             | Regenerate `GH_TOKEN` with the `gist` scope, then recreate with `docker compose up -d`.           |
| Codex says not logged in      | `docker compose exec -u hermes -it assistant codex login --device-auth`                           |
| Codex task times out          | Increase `agent.gateway_timeout` and `terminal.timeout` in `/opt/data/config.yaml`, then restart. |
| OpenCode says no provider     | `docker compose exec -u hermes -it assistant opencode auth login`                                 |
| Model errors or 401s          | `docker compose exec -u hermes assistant hermes status`, then rerun model setup.                  |
| Port conflict                 | Change `DASHBOARD_PORT` or `API_PORT` in `.env`.                                                  |
