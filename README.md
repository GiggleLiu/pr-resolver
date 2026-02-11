# PR Automation

GitHub Action runner that **uses AI coding agents to implement your plans.** Write a plan, open a PR, comment `[action]` — the agent executes it.

Supports **Claude Code** (Anthropic) and **OpenCode/Crush** (multi-provider: Kimi, OpenAI, Gemini, etc.) — configurable per repo.

**Purposes**

- Share AI subscriptions to resolve pull requests across multiple repos.
- Enforce structured development workflows to improve code quality.
- Avoid annoying permission prompts when executing plans.

## The Workflow

```
 You                                    Agent
  │                                       │
  │  1. Write plan (docs/plans/*.md)      │
  │  2. Open PR with [action] in body ──► │
  │     (or comment [action] later)       │  3. Read plan
  │                                       │  4. Implement
  │                                       │  5. Commit & push
  │  6. Review changes  ◄──────────────   │
  │  7. Comment [fix] ─────────────────►  │
  │                                       │  8. Address feedback
  │  9. Merge ✓                           │
```

**That's it.** No context switching. No copy-pasting. Just review and merge.

## Quick Start

### 1. Add the workflow to your repo

```bash
mkdir -p .github/workflows
curl -o .github/workflows/pr-automation.yml \
  https://raw.githubusercontent.com/GiggleLiu/pr-resolver/main/caller-workflow.yml
git add .github/workflows && git commit -m "Add PR automation" && git push
```

This installs a thin caller that references the [reusable workflow](https://docs.github.com/en/actions/using-workflows/reusing-workflows) in this repo. Updates to the workflow logic are picked up automatically.

### 2. Setup a runner

The workflow needs a GitHub Actions runner. Choose one:

| Option | Best for | Setup time |
|--------|----------|------------|
| **Self-hosted** | Daily use, fast execution | 5 min |
| **GitHub-hosted** | Occasional use, no local setup | 2 min |

#### Self-hosted (recommended)

```bash
# Clone this repo
git clone https://github.com/GiggleLiu/pr-resolver.git
cd pr-resolver

# Install agent CLIs (Claude Code + OpenCode)
make init-agents

# Add your repo to config (edit runner-config.toml, add to repos array)

# Sync runners (sets up workflow, runner, and config)
make update

# Authentication:

# Claude Code (choose one):
make setup-key KEY=sk-ant-...     # Option A: API key (pay per use)
claude && make install-refresh    # Option B: OAuth with Max/Pro subscription

# OpenCode (for Kimi/OpenAI/Gemini):
opencode                          # Launch TUI, use /connect to add providers

make restart                      # Starts runners (also refreshes token)
```

#### GitHub-hosted

Add the appropriate API key as a repo secret (Settings → Secrets → Actions):
- Claude agent: `ANTHROPIC_API_KEY`
- OpenCode agent: `MOONSHOT_API_KEY` or `OPENAI_API_KEY`

Set `AGENT_TYPE` repo variable if not using the default (`claude`). No other setup needed — the workflow defaults to GitHub-hosted runners.

### 3. Try it

1. Create `docs/plans/test.md`:
   ```markdown
   # Test Plan
   1. Create a file `hello.txt` with content "Hello from Claude"
   2. Commit with message "Add hello.txt"
   ```
2. Open a PR with `[action]` in the description (or comment `[action]` after)
3. Watch Claude work (check the Actions tab)

## Commands

| Command | What happens |
|---------|--------------|
| `[action]` | Execute the plan file |
| `[fix]` | Address review comments AND fix CI failures |
| `[debug]` | Test the pipeline (creates a test comment) |

**Two ways to trigger:**
- **PR body**: Include command anywhere when creating the PR
- **Comment**: Post a comment that starts with the command

## Plan Files

Plans are detected in this order:
- `PLAN.md`
- `plan.md`
- `.claude/plan.md`
- `docs/plan.md`
- `docs/plans/*.md` (most recent)

## Writing Good Plans

**Use `/brainstorm` to write plans.** If you have [superpowers](https://github.com/anthropics/claude-code-superpowers) installed, just tell Claude your idea:

```
/brainstorm add user authentication to the app
```

Claude will ask clarifying questions, explore approaches, and write a detailed plan to `docs/plans/`. This is the recommended way to create plans.

**Start from a GitHub issue:** Use `/issue-to-pr` to convert an issue directly into a PR:

```
/issue-to-pr 42
```

This fetches the issue, brainstorms solutions with you, writes a plan, and creates a PR with `[action]` to auto-trigger execution.

> **Note:** Copy `.claude/skills/issue-to-pr.md` from this repo to your target repo's `.claude/skills/` directory to enable this skill.

## Configuration

### Repo Variables

Set these as repo variables (Settings → Variables → Actions):

| Variable | Default | Purpose |
|----------|---------|---------|
| `RUNNER_TYPE` | `ubuntu-latest` | Set to `self-hosted` for self-hosted runners |
| `AGENT_TYPE` | `claude` | Agent CLI: `claude` or `opencode` |
| `AGENT_MODEL` | (agent default) | Model override (e.g., `opus`, `moonshot/kimi-k2.5`, `openai/gpt-5-codex`) |

### Managing Multiple Repos

Edit `runner-config.toml` and run `make update`:

```toml
# runner-config.toml
[runner]
base_dir = "~/actions-runners"
repos = [
  "your-org/repo1",
  "your-org/repo2",
]
```

```bash
make update                    # Sync: add missing runners, remove unlisted
make status                    # Check all runner statuses
make start / stop / restart    # Control runners
make setup-key KEY=sk-ant-...  # Set API key for all runners
make refresh-oauth             # Manually refresh OAuth token file
make install-refresh           # Auto-refresh OAuth every 6h
make sync-workflow             # Install caller workflow to all repos
make init-claude               # Install Claude CLI + superpowers
make init-opencode             # Install OpenCode CLI
make init-agents               # Install all agent CLIs
make round-trip                # End-to-end test
```

## How It Works

```
PR Created / Comment Posted
       │
       ▼
Caller Workflow (in repo) ──► Reusable Workflow (pr-resolver)
       │                                │
       ▼                                ▼
Setup Job (GitHub-hosted) ──► Set pending status
       │
       ▼
Execute Job (self-hosted) ──► Acquire credentials ──► run-agent.sh
       │                                                    │
       │                                              ┌─────┴─────┐
       │                                           Claude     OpenCode
       │                                           Code       /Crush
       │                                              └─────┬─────┘
       └──── Status Check (✓/✗) ◄──────────────────────────┘
```

1. You create a PR with `[action]` in body (or comment `[action]`)
2. Caller workflow in your repo triggers the reusable workflow from pr-resolver
3. Setup job runs on GitHub-hosted runner, sets pending status
4. Execute job acquires credentials and runs the configured agent via `run-agent.sh`
5. Agent reads plan, writes code, commits, pushes
6. Workflow reports success/failure as PR status check

**Reusable workflow**: Other repos reference this repo's workflow via `@main`. Updates to the workflow logic propagate automatically — no need to sync workflow files.

## Authentication

### Claude Code

| Method | Best for | Setup |
|--------|----------|-------|
| **API key** | Pay per use, never expires | `make setup-key KEY=sk-ant-...` |
| **OAuth (Max/Pro)** | Subscription users | `claude` once + `make install-refresh` |

**OAuth details (self-hosted macOS):**
- Runner LaunchAgents can't access the macOS Keychain directly (`SessionCreate=true` isolates the security session)
- `make refresh-oauth` extracts the token from Keychain and writes it to `~/.claude-oauth-token`
- `make install-refresh` sets up:
  - A **pre-job hook** on every runner — triggers a token refresh before each job, guaranteeing a fresh token
  - A **LaunchAgent** that refreshes hourly as a safety net
- If the token is expired, it runs `claude -p "ping"` to trigger a refresh before extracting

### OpenCode

On self-hosted runners, configure providers interactively: `opencode` → `/connect` → select provider (Moonshot, OpenAI, etc.) → enter API key. Keys persist in `~/.local/share/opencode/auth.json`.

On GitHub-hosted runners, add the provider API key as a repo secret (`MOONSHOT_API_KEY` or `OPENAI_API_KEY`).

## Requirements

- **Agent CLI** (at least one):
  - [Claude Code](https://claude.ai/code) - `make init-claude`
  - [OpenCode/Crush](https://opencode.ai/) - `make init-opencode`
- **Authentication** (depends on agent):
  - Claude: [Anthropic API key](https://console.anthropic.com/) or Max/Pro OAuth
  - OpenCode: Provider API key (Moonshot, OpenAI, etc.)
- [GitHub CLI](https://cli.github.com/) (`gh`) - for runner setup

## Troubleshooting

### Runner shows "offline"
```bash
make status   # Check all runners
make start    # Start all runners
```

### "Invalid API key" or "OAuth token has expired" error
```bash
# Option A: Set API key for all runners
make setup-key KEY=sk-ant-...
make restart

# Option B: Refresh OAuth token
make refresh-oauth
make restart

# If token keeps expiring, ensure auto-refresh is running:
make install-refresh
```

### Workflow not triggering
- Ensure workflow file is on the **default branch** (usually `main`)
- Check Actions tab for any errors
- For comments: must start with `[action]` (case-sensitive)
- For PR body: `[action]` can be anywhere in the text

### Status stuck on "Waiting for runner..."
Your self-hosted runner isn't picking up the job:
```bash
make status   # Check runner status
make start    # Start runners if offline
```

## License

MIT
