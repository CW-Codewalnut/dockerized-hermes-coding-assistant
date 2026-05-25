# Dockerized Hermes Coding Assistant

A publishable Docker setup for running [Hermes Agent](https://hermes-agent.nousresearch.com/docs/) as a Telegram-accessible coding assistant with Codex and OpenCode sub-agents.

## What This Includes

- Hermes Agent from the official Nous Research image.
- Telegram gateway for chat access.
- Codex CLI and OpenCode CLI for delegated coding work.
- Google Workspace access through Hermes' built-in `google-workspace` skill and the `gws` CLI.
- GitHub CLI wired through `GH_TOKEN` for repos and gists.
- Node.js installed through `nvm` using the current LTS line.
- Runtime state in named Docker volumes, not host folders.
- Assistant-specific Docker names from `ASSISTANT_SLUG`, so multiple agents can run side by side.

## Repo Layout

Tracked source files:

| Path                                          | Purpose                                           |
| --------------------------------------------- | ------------------------------------------------- |
| `templates/assistant/SOUL.md`                 | Assistant persona template.                       |
| `templates/assistant/AGENTS.md`               | Main assistant workflow template.                 |
| `templates/assistant/coding-agents/AGENTS.md` | Codex/OpenCode workflow template.                 |
| `scripts/setup.sh`                            | Interactive one-command setup.                    |
| `scripts/clean-wipe.sh`                       | Removes this assistant's Docker footprint.        |
| `scripts/backup-state.sh`                     | Exports Docker volumes plus `.env`.               |
| `scripts/restore-state.sh`                    | Restores exported Docker volumes on another host. |

Template placeholders are rendered into `/opt/data` at container startup. Runtime instruction files should never contain unresolved placeholder tokens.

Runtime state:

| Storage                                     | Contains                                                            |
| ------------------------------------------- | ------------------------------------------------------------------- |
| `${ASSISTANT_SLUG}_data` Docker volume      | Hermes config, memories, sessions, logs, Codex/OpenCode/Google auth. |
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
- optionally set up Google Workspace OAuth;
- verify Telegram, GitHub repo/gist access, Codex/OpenCode state, Google Workspace CLI/auth status, and Hermes status.

If you skip Google Workspace during onboarding, rerun `scripts/setup.sh` later and answer yes at the Google Workspace prompt.

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

Google Workspace auth, if skipped during onboarding:

```bash
scripts/setup.sh
```

Dashboard:

```text
http://localhost:<DASHBOARD_PORT>
```

## Google Workspace

Hermes already includes the `google-workspace` skill. This image installs `gws` so the skill can prefer Google's Workspace CLI for broader API coverage, while keeping Hermes' Python fallback available.

No `.env` value is needed for normal user-consent OAuth. Google credential files are stored in the `${ASSISTANT_SLUG}_data` Docker volume:

| Path                                  | Purpose                                      |
| ------------------------------------- | -------------------------------------------- |
| `/opt/data/google_client_secret.json` | OAuth 2.0 Desktop client downloaded from GCP |
| `/opt/data/google_token.json`         | Refreshable user token created by setup      |

One-time Google Cloud setup:

1. Create or select a Google Cloud project: <https://console.cloud.google.com/projectselector2/home/dashboard>
2. Enable the APIs you need: Gmail API, Google Calendar API, Google Drive API, Google Sheets API, Google Docs API, and People API.
3. Create OAuth credentials at <https://console.cloud.google.com/apis/credentials>.
4. Use application type `Desktop app`.
5. If the OAuth app is in testing mode, add your Google account as a test user at <https://console.cloud.google.com/auth/audience>.
6. Download the client secret JSON.

The onboarding script handles the copy and OAuth exchange. Run:

```bash
scripts/setup.sh
```

Answer yes at the Google Workspace prompt, provide the host path to the downloaded OAuth client JSON, open the printed URL, then paste the full redirected `http://localhost:1/?code=...` URL back into the script. The localhost page failing to load is expected.

Manual equivalent:

```bash
docker compose cp /path/to/client_secret.json assistant:/tmp/google_client_secret.json
docker compose exec assistant sh -lc 'chown 10000:10000 /tmp/google_client_secret.json && chmod 600 /tmp/google_client_secret.json'
docker compose exec -u hermes -it assistant bash
GSETUP="python $HERMES_HOME/skills/productivity/google-workspace/scripts/setup.py"
$GSETUP --client-secret /tmp/google_client_secret.json
rm -f /tmp/google_client_secret.json
$GSETUP --auth-url
```

Open the printed URL in your browser, approve access, and copy the full redirected URL from the browser address bar.

Back in the container shell:

```bash
$GSETUP --auth-code 'PASTE_FULL_REDIRECT_URL_HERE'
$GSETUP --check-live
```

Verify useful reads:

```bash
GAPI="python $HERMES_HOME/skills/productivity/google-workspace/scripts/google_api.py"
$GAPI calendar list
$GAPI drive search "mimeType='application/pdf'" --raw-query --max 5

export GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE=/opt/data/google_token.json
gws drive files list --params '{"pageSize": 5}'
gws --version
```

For daily use, ask Hermes to use Google Workspace. For direct terminal work, use the `GAPI` wrapper above when you want the stable Hermes JSON contract, or set `GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE=/opt/data/google_token.json` and use `gws` directly for broader Workspace API coverage.

Safety rules:

- Do not commit or paste `google_client_secret.json`, `google_token.json`, OAuth URLs containing `code=`, or exported volume backups.
- Confirm with the user before sending email, creating/deleting calendar events, sharing/deleting Drive files, or modifying Docs/Sheets.
- Prefer OAuth user consent for this personal assistant. Avoid Google Workspace domain-wide delegation unless you have a specific org-wide service-account use case.

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
| `gws` command missing         | Rebuild the image with `docker compose up -d --build`.                                            |
| Google says not authenticated | Run the Google Workspace setup flow and verify `/opt/data/google_token.json` exists.              |
| Google API returns 403        | Enable the API in Google Cloud Console, or revoke and re-authorize if scopes are missing.          |
| Codex says not logged in      | `docker compose exec -u hermes -it assistant codex login --device-auth`                           |
| Codex task times out          | Increase `agent.gateway_timeout` and `terminal.timeout` in `/opt/data/config.yaml`, then restart. |
| OpenCode says no provider     | `docker compose exec -u hermes -it assistant opencode auth login`                                 |
| Model errors or 401s          | `docker compose exec -u hermes assistant hermes status`, then rerun model setup.                  |
| Port conflict                 | Change `DASHBOARD_PORT` or `API_PORT` in `.env`.                                                  |
