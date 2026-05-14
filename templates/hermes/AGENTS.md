# Operating environment for <ASSISTANT_NAME>

This file is project-scoped operational context: installed tools, filesystem layout, and workflow rules. Identity and voice live separately in `SOUL.md`.

Replace these placeholders before running the assistant:

| Placeholder        | Meaning                                                                |
| ------------------ | ---------------------------------------------------------------------- |
| `<ASSISTANT_NAME>` | The name/persona of this Hermes assistant.                             |
| `<USER_NAME>`      | The primary human operator.                                            |
| `<GIT_USER_NAME>`  | Git author name configured through `.env`.                             |
| `<GIT_USER_EMAIL>` | Git author email configured through `.env`.                            |
| `<BRANCH_PREFIX>`  | Branch prefix for assistant-created branches, for example `assistant`. |

The primary operator is **<USER_NAME>**. Commits made inside this container should use `<GIT_USER_NAME> <<GIT_USER_EMAIL>>`, configured from `GIT_USER_NAME` and `GIT_USER_EMAIL` in `.env`.

## Filesystem layout

| Path          | Backing store           | Permissions | Purpose                                                                   |
| ------------- | ----------------------- | ----------- | ------------------------------------------------------------------------- |
| `/workbench/` | Docker workbench volume | read-write  | Persistent project checkouts, similar to a host `~/codes` folder.         |
| `/opt/data/`  | Docker data volume      | read-write  | Assistant state: config, memories, skills, logs, and sub-agent auth dirs. |
| `/tmp/`       | Container tmpfs         | read-write  | Ephemeral files. Wiped on restart.                                        |

The host's source-code folders are not mounted. Keep coding projects under `/workbench`, reuse them across tasks, and treat GitHub as the remote source of truth.

## Project workspace rule

- All repo work happens inside `/workbench/<owner>/<repo>/`.
- Reuse existing checkouts. Do not create duplicate clones for every task.
- Clone only when the repo is missing locally.
- Fetch before starting work so the local checkout knows about the current remote state.
- Create a new task branch for edits unless the user explicitly asks to use an existing branch.
- Never write outside `/workbench/` unless updating assistant-owned state under `/opt/data/`.

## Coding workflow

When the user asks you to change code, follow this workflow:

1. Identify the repo. If the owner is unclear, use `gh search repos <name> --owner @me` or `gh repo list --limit 50`. Ask if it is still ambiguous.
2. Reuse or create the local checkout:

   ```bash
   mkdir -p /workbench/<owner>
   if [ ! -d /workbench/<owner>/<repo>/.git ]; then
     gh repo clone <owner>/<repo> /workbench/<owner>/<repo>
   fi
   cd /workbench/<owner>/<repo>
   git fetch --all --prune
   ```

3. Check the worktree and create a task branch:

   ```bash
   git status --short
   DEFAULT_BRANCH="$(gh repo view <owner>/<repo> --json defaultBranchRef -q .defaultBranchRef.name)"
   git switch "$DEFAULT_BRANCH"
   git pull --ff-only
   git switch -c <BRANCH_PREFIX>/<short-task-slug>
   ```

   If the worktree already has changes, inspect them before switching branches or pulling. Preserve unrelated user or previous-agent changes. If those changes belong to the current task, continue on the appropriate existing branch instead of creating a duplicate. Use `kebab-case` for new branch slugs, max 6 words.

4. Decide whether to handle the task directly or delegate it.

   Handle directly only when the task is truly trivial and mechanical, such as:
   - a one-line typo or copy edit;
   - a README wording tweak;
   - a small config value replacement;
   - a single obvious import/path/name correction;
   - running a single read-only command or showing a diff.

   Delegate to a coding sub-agent for anything that needs even a little reasoning, including:
   - bug fixes;
   - test failures;
   - code review;
   - behavior changes;
   - refactors;
   - dependency/tooling changes;
   - multi-file edits;
   - unclear requirements;
   - anything where you need to inspect call flow, understand architecture, or choose between alternatives.

   If the user named a sub-agent, use that one. If not, ask one focused question: `Use Codex or OpenCode for this?`

5. Coding sub-agent defaults:

   Before invoking either tool, check its current help output if you are unsure about flags:

   ```bash
   codex --help
   opencode --help
   ```

   Use these model defaults unless the user explicitly overrides them:
   - Codex CLI: `gpt-5.5` with reasoning effort `high`.
   - OpenCode CLI: `opencode-go/deepseek-v4-pro` with variant `high`.

   Headless permission flags are required because there is no human at a terminal to approve prompts:
   - Codex: pass `--dangerously-bypass-approvals-and-sandbox`.
   - OpenCode: pass `--dangerously-skip-permissions`.

   Preferred invocation shapes:

   ```bash
   codex exec \
     --model gpt-5.5 \
     --config 'model_reasoning_effort="high"' \
     --dangerously-bypass-approvals-and-sandbox \
     "<task prompt>"

   opencode run \
     --model opencode-go/deepseek-v4-pro \
     --variant high \
     --dir /workbench/<owner>/<repo> \
     --dangerously-skip-permissions \
     "<task prompt>"
   ```

   Codex reasoning effort is configured in `~/.codex/config.toml` and can also be overridden with `--config 'model_reasoning_effort="high"'`; do not invent a dedicated reasoning flag if the installed version does not expose one.

6. Long-running coding tasks:

   Codex runs often take longer than normal shell commands. For anything likely to run more than a few minutes, start it as a background terminal process instead of a short foreground command:

   ```text
   terminal(command="<codex or opencode command>", background=true, notify_on_complete=true, pty=true)
   process(action="poll", session_id="<session_id>")
   process(action="wait", session_id="<session_id>", timeout=7200)
   process(action="log", session_id="<session_id>")
   ```

   Use `process(action="wait")` when you can block, `poll` for periodic progress checks, and `log` before summarizing or retrying. If a wait call times out, do not assume the coding agent failed; poll or read the log, then continue waiting unless the process is clearly stuck. Kill a Codex/OpenCode process only when the user asks, the process is obviously hung, or you need to stop a duplicate run you started by mistake.

   The default Hermes config gives terminal commands and gateway inactivity a two-hour budget. For tasks that may exceed that, tell the user before starting and continue with background polling instead of launching duplicate coding-agent runs.

7. Review the sub-agent result instead of forwarding it blindly. Check `git diff`, run focused tests when available, and verify the change is scoped to the request.

8. Show the diff and stop:

   ```bash
   DEFAULT_BRANCH="$(gh repo view <owner>/<repo> --json defaultBranchRef -q .defaultBranchRef.name)"
   git -C /workbench/<owner>/<repo> diff "$DEFAULT_BRANCH"
   ```

9. Commit, push, or open a PR only when the user explicitly asks.

## Coding best practices

- Start by reading the smallest useful surface: README, package manifests, test scripts, and the files directly implicated by the task.
- Use `rg` / `fd` for discovery and project-native tools for parsing, formatting, and tests.
- Prefer existing patterns, APIs, package managers, and test conventions over introducing new ones.
- Keep edits scoped. Do not perform opportunistic refactors.
- Preserve unrelated user changes. If a worktree is dirty, understand the diff before editing.
- Run the narrowest meaningful verification first, then broader tests when the blast radius justifies it.
- For reviews, lead with concrete risks and file/line references. Do not summarize before findings.
- For PR work, prepare concise titles and bodies, include test results, and do not push until explicitly asked.
- Keep context files short and durable. Put stable rules here; put transient facts in memory only when the user asks.

## When to clone vs stay remote

| Ask                                       | Action                                                                                       |
| ----------------------------------------- | -------------------------------------------------------------------------------------------- |
| "What does X do?" / "Where is Y defined?" | Use `gh search code 'X repo:<owner>/<name>'` first; clone only if the snippet is not enough. |
| "Search all my repos for X"               | Use `gh search code 'X user:@me'`; no clone needed.                                          |
| "Review PR #N on owner/repo"              | Use `gh pr view`, `gh pr diff`, and `gh pr review`; no clone needed.                         |
| "Modify / fix / add / refactor"           | Reuse or clone the project under `/workbench/<owner>/<repo>`, then branch.                   |
| "Run tests in repo X"                     | Reuse or clone the project under `/workbench/<owner>/<repo>` and run tests there.            |

## Tools installed

| Category      | Tools                                                  |
| ------------- | ------------------------------------------------------ |
| Coding agents | `codex`, `opencode`                                    |
| GitHub        | `gh` with auth from `GH_TOKEN`                         |
| Git           | `git` with `gh` as credential helper                   |
| JS/TS         | `node` 20, `npm`, `npx`, `bun`                         |
| Python        | `python3`, `pip`, `uv`, `uvx`                          |
| Search/files  | `rg`, `fd`, `tree`, `find`, `less`, `vim-tiny`, `nano` |
| Data          | `jq`                                                   |
| Network       | `curl`, `wget`, `openssh-client`                       |
| Patching      | `diff`, `patch`                                        |
| Archives      | `unzip`, `zip`, `tar`                                  |

Prefer existing tools over ad hoc scripts. Use `rg` for text search and `jq` for JSON.

## MCP servers

- `workbench` provides writable structured filesystem access to `/workbench`.
- Add optional OAuth MCP servers, such as Google Drive, in `config.yaml` after the first boot.

GitHub is intentionally handled through the `gh` CLI rather than an MCP server.

## Public attribution footer

When you directly compose public GitHub text, such as issue comments or PR review bodies, append this footer after customizing the placeholders:

```text
---
Authored by <ASSISTANT_NAME> (powered by Hermes Agent).
```

Do not add the footer to code comments or commit messages. Skip it only if the user explicitly asks.

## Rules

- Stay inside `/workbench/` for repo work.
- Do not push, open PRs, or commit unless the user explicitly asks.
- Never paste secrets into chat, including `GH_TOKEN`, `TELEGRAM_BOT_TOKEN`, or anything from `.env`.
- Keep changes scoped to the requested task.
- Surface sub-agent errors clearly.
- Cite relevant lines when answering code questions.
- Check `--help` before using uncertain CLI flags.
