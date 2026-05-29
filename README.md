# Dockerized Hermes Coding Assistant

Run a Telegram-accessible [Hermes Agent](https://hermes-agent.nousresearch.com/docs/) that behaves like a real coding workstation, not a toy chatbot.

This repo packages Hermes with Codex CLI, OpenCode CLI, Cursor Agent CLI, GitHub CLI, optional Google Workspace tooling, a broad Ubuntu development toolbox, and an in-container Docker daemon. It is built for agents that need to clone repos, run tests, build containers, delegate coding tasks, inspect results, and keep working across restarts.

## Why This Exists

Most assistant setups are either too thin to be useful for real engineering work or too tied to one local machine. This repo is an opinionated middle ground:

- one command gets a persistent Telegram-accessible coding assistant running;
- every repo checkout, agent auth file, memory, and Docker layer lives in named volumes;
- setup prompts for identity, ports, and credentials instead of asking you to edit a credential file;
- the assistant can use Docker from inside Docker without host path mismatches;
- coding work is isolated in fresh git worktrees by default;
- Codex is the default local coding sub-agent; OpenCode and Cursor are available when explicitly requested;
- setup finishes with smoke tests instead of hoping auth and tools work.

The goal is a portable personal development machine for AI coding workflows: reproducible enough to run on a laptop or VPS, powerful enough to build and test serious repos, and explicit enough about attribution and branch safety to be trusted with public-facing work.

## What You Get

- Hermes Agent running from the official Nous image.
- Telegram as the chat surface, with localhost dashboard/API ports.
- Codex CLI, OpenCode CLI, and Cursor Agent CLI installed together.
- GitHub CLI using its native auth store for repos, PRs, issues, and gists.
- Full dev toolbox: Node, Bun, Python, uv, Go, Rust, compilers, debuggers, `rg`, `fd`, `jq`, `yq`, `shellcheck`, `shfmt`, and more.
- Privileged Docker-in-Docker with Docker CLI, Compose, and Buildx.
- Persistent `/workbench` for canonical clones and per-task worktrees.
- Optional Google Workspace support for Gmail, Calendar, Drive, Docs, Sheets, and Contacts.
- Public attribution footer rules for commits, PRs, issue comments, reviews, and other external text.

## Opinionated Defaults

This is intentionally not a minimal production container. It is a trusted development environment for coding agents.

- **Power over sandbox minimalism:** privileged container, passwordless `sudo`, broad tools, and a real inner Docker daemon.
- **Docker-in-Docker over host socket:** avoids bind-mount path mismatches when agents run repo-local Docker commands from `/workbench`.
- **Prompted setup over editable secret files:** `scripts/setup.sh` asks for credentials and writes a local setup profile under `.assistant/`.
- **Native auth stores:** GitHub, Codex, OpenCode, Cursor, and Google auth are stored by the tools that consume them.
- **Worktrees by default:** canonical clones stay clean; each coding task gets `/workbench/<owner>/<repo>-worktrees/<task-slug>/`.
- **Protected branches stay protected:** no commits directly on `main`, `master`, `develop`, `dev`, `prod`, `production`, `staging`, or `release` without a second explicit confirmation.
- **Delegation stays faithful:** Hermes shows the exact sub-agent prompt before delegation, passes the user's request through with only typo/grammar cleanup and minimal routing context, and defaults to Codex unless the user explicitly chooses OpenCode or Cursor.
- **Cursor stays repo-scoped:** Cursor runs from the task worktree, never from all of `/workbench`.
- **High-reasoning coding defaults:** Hermes brain model setup is handled interactively during setup; default Codex delegation uses `gpt-5.5` with `xhigh`, and OpenCode uses `max` when selected.
- **Transparency by default:** public-facing text gets the configured Hermes attribution footer unless the user explicitly opts out.

## Requirements

- Docker with the Compose plugin.
- Privileged containers enabled. This is required for the in-container Docker daemon.
- Git.
- Telegram bot token from `@BotFather`.
- GitHub classic PAT with `repo` and `gist`; add `read:org` for org repos. Optional, but recommended.
- 8 GB Docker/host memory minimum; 16 GB or more is better.
- Optional: Google OAuth Desktop client JSON for Gmail, Calendar, Drive, Docs, Sheets, or Contacts.

Dashboard and API ports bind to `127.0.0.1`. Telegram uses outbound polling, so normal chat use does not require public inbound ports.

## Setup

```bash
git clone <this-repo-url> hermes-assistant
cd hermes-assistant
scripts/setup.sh
```

Setup prompts for:

| Prompt                              | Default / behavior                                                               |
| ----------------------------------- | -------------------------------------------------------------------------------- |
| Assistant name                      | Required. Used in persona, attribution, and generated instructions.              |
| Assistant slug                      | Optional. Defaults to a Docker-safe slug from the assistant name.                |
| User nickname                       | Required. This is how the assistant refers to the primary operator.              |
| Branch prefix                       | Optional. Defaults to the assistant slug.                                        |
| Dashboard/API localhost ports       | Defaults to `9119` and `8642`.                                                   |
| External API server                 | Defaults to disabled. If enabled, setup creates or prompts for an API key.       |
| Telegram bot token and allowed IDs  | Required for chat access.                                                        |
| GitHub auth                         | Optional. If configured, setup derives git author defaults from GitHub.          |
| Git author name/email               | Required. Prompted only when GitHub cannot provide them.                         |
| Hermes, Codex, OpenCode, Cursor     | Optional interactive auth flows.                                                 |
| Google Workspace                    | Optional OAuth setup by pasted JSON or local JSON file path.                     |

The local setup profile lives under `.assistant/`, which is ignored by git and mounted read-only into the container. Do not commit that directory.

Optional auth steps retry after failures. Press `Ctrl-C` during an optional auth
step to skip that step and continue setup.

## Operations

Use the wrapper so Compose receives the assistant slug and port values from the setup profile:

```bash
scripts/compose.sh up -d
scripts/compose.sh logs -f assistant
scripts/compose.sh restart assistant
scripts/compose.sh down
```

Open a shell or Hermes CLI:

```bash
scripts/compose.sh exec -u hermes -it assistant sh
scripts/compose.sh exec -u hermes -it assistant hermes
```

Re-run auth manually:

```bash
scripts/compose.sh exec -u hermes -it assistant hermes setup model
scripts/compose.sh exec -u hermes -it assistant codex login --device-auth
scripts/compose.sh exec -u hermes -it assistant opencode auth login
scripts/compose.sh exec -u hermes -it assistant agent login
scripts/compose.sh exec -u hermes -it assistant gh auth login
```

Run smoke tests after setup or after changing auth:

```bash
scripts/smoke-test.sh
```

Required smoke checks cover the container, Telegram, and Hermes. Inner Docker,
GitHub, Codex, OpenCode, Cursor, and Google Workspace report optional warnings
when unavailable or unauthenticated.

Dashboard:

```text
http://localhost:<dashboard-port>
```

## Model Defaults

| Runtime            | Default                                            |
| ------------------ | -------------------------------------------------- |
| Hermes brain       | Configured interactively by `hermes setup model`.  |
| Default sub-agent  | Codex CLI with `gpt-5.5`, reasoning effort `xhigh` |
| Codex sub-agent    | `gpt-5.5`, reasoning effort `xhigh`                |
| OpenCode sub-agent | `opencode-go/deepseek-v4-pro`, variant `max`       |
| Cursor sub-agent   | `composer-2.5`                                     |

## Docker And State

This is intentionally a powerful development container, not a hardened production service. It runs privileged, gives the `hermes` user passwordless `sudo`, and starts Docker-in-Docker so repo commands like this work normally:

```bash
docker run --rm -v "$PWD":/app -w /app node:lts npm test
```

Runtime state is stored in named Docker volumes:

| Volume                        | Contains                                                        |
| ----------------------------- | --------------------------------------------------------------- |
| `${assistant-slug}_data`      | Hermes config, memories, logs, instructions, and auth.          |
| `${assistant-slug}_workbench` | Canonical repo checkouts and task worktrees under `/workbench`. |
| `${assistant-slug}_docker`    | Inner Docker images, containers, volumes, and build cache.      |

The inner Docker daemon starts with `overlay2`. During setup, if that does not
become ready, setup retries with `fuse-overlayfs` and then `vfs`. `vfs` is slower
but works on more constrained nested VPS environments. To force a driver, edit
`.assistant/config/dockerd_storage_driver`, then recreate the container with
`scripts/compose.sh up -d --force-recreate`.

## Google Workspace

Google Workspace is optional. During setup, answer yes at the Google prompt and provide an OAuth 2.0 Desktop client JSON by pasting the JSON or giving a local file path. The setup stores:

- `/opt/data/google_client_secret.json`
- `/opt/data/google_token.json`

Treat Google client secrets, Google tokens, OAuth callback URLs containing `code=`, and full sensitive backups as secrets.

## Public Attribution

When the assistant writes public-facing content on behalf of the user, it appends this footer unless explicitly asked not to:

```text
---
Authored by <ASSISTANT_NAME> (powered by Hermes Agent).
```

This applies to commit bodies, PR descriptions, PR reviews, issue comments, public gist text, release notes, and similar external text.

## Backup, Restore, Wipe

Create a backup with setup profile config only:

```bash
scripts/backup-state.sh
```

Include runtime data, repo checkouts, or inner Docker state explicitly:

```bash
scripts/backup-state.sh --include-secrets --include-data --include-workbench --include-docker
```

Create a sensitive auth backup:

```bash
scripts/backup-state.sh --include-data --include-secrets
```

Restore:

```bash
scripts/restore-state.sh --yes <backup.tar.gz>
scripts/setup.sh
```

Default backups include only the non-secret setup profile. Runtime data,
workbench checkouts, and inner Docker layers require `--include-secrets`
because they can contain credentials and can be large. Inspect archives before
sharing.

Wipe this assistant's Docker footprint:

```bash
scripts/clean-wipe.sh
scripts/clean-wipe.sh -y
scripts/clean-wipe.sh --prune-builder-cache
```

Also prune unused Docker objects across the machine:

```bash
scripts/clean-wipe.sh -y --prune-system
```

Use `--prune-system` carefully; it can remove unrelated stopped containers and unused images.

## Files

| Path                                                                           | Purpose                                      |
| ------------------------------------------------------------------------------ | -------------------------------------------- |
| `Dockerfile`                                                                   | Builds Hermes plus tooling.                  |
| `docker-compose.yml`                                                           | Runs the assistant and volumes.              |
| `scripts/setup.sh`                                                             | Interactive setup flow.                      |
| `scripts/compose.sh`                                                           | Compose wrapper that loads the setup profile. |
| `scripts/lib/setup-store.sh`                                                   | Shared local setup profile helpers.          |
| `scripts/smoke-test.sh`                                                        | Post-setup checks.                           |
| `scripts/backup-state.sh`, `scripts/restore-state.sh`, `scripts/clean-wipe.sh` | State management.                            |
| `templates/assistant/SOUL.md`                                                  | Assistant persona.                           |
| `templates/assistant/AGENTS.md`                                                | Main assistant operating rules.              |
| `templates/assistant/coding-agents/AGENTS.md`                                  | Shared Codex/OpenCode sub-agent rules.       |

## Troubleshooting

- Start with `scripts/smoke-test.sh`.
- For startup failures, run `scripts/compose.sh logs assistant`.
- For auth issues, rerun the matching login command from the Operations section or rerun `scripts/setup.sh`.
- If ports conflict, edit `.assistant/config/dashboard_port` or `.assistant/config/api_port`, then run `scripts/compose.sh up -d --force-recreate`.
