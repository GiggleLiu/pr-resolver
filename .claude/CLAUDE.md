# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

PR Automation system - include `[action]` or `[fix]` in PR body or comments to trigger an AI coding agent to execute plans or address review feedback. Supports **Claude Code** (Anthropic) and **OpenCode/Crush** (multi-provider: Kimi, OpenAI, Gemini, etc.). Uses GitHub Actions with self-hosted runners.

The workflow is defined once in this repo and called as a **reusable workflow** by other repos via `uses: GiggleLiu/pr-resolver/.github/workflows/pr-automation.yml@main`.

## Commands

```bash
make update                              # Sync runners with config (add/remove)
make status                              # Check all runner statuses
make start                               # Start all runners (auto-refreshes OAuth)
make stop                                # Stop all runners
make restart                             # Restart all runners (auto-refreshes OAuth)
make list                                # List configured repos
make clean                               # Clean caches (saves ~3GB)
make init-claude                         # Install Claude CLI + superpowers
make init-opencode                       # Install OpenCode CLI
make init-agents                         # Install all agent CLIs
make setup-key KEY=sk-ant-...            # Set API key for all runners
make refresh-oauth                       # Refresh OAuth token file from Keychain
make install-refresh                     # Auto-refresh OAuth every 6h (LaunchAgent/cron)
make uninstall-refresh                   # Remove auto-refresh
make sync-workflow                       # Install caller workflow to all repos
make round-trip                          # End-to-end test
```

## Architecture

```
PR Created / Comment Posted
       │
       ▼
Caller Workflow (in each repo) ──► Reusable Workflow (this repo)
       │                                    │
       ▼                                    ▼
Setup Job (GitHub-hosted) ──► Set "Waiting for runner..." status
       │
       ▼
Execute Job ──► Self-hosted Runner ──► Acquire credentials ──► run-agent.sh
       │                                                           │
       │                                                     ┌─────┴─────┐
       │                                                  Claude     OpenCode
       │                                                  Code       /Crush
       │                                                     └─────┬─────┘
       │                                                     Implement,
       │                                                     commit, push
       │                                                        │
       └──── Status Check (✓/✗) ◄───────────────────────────────┘
```

**Flow:**
1. User creates PR with `[action]` in body OR comments `[action]` → caller workflow triggers reusable workflow
2. Setup job (always runs on GitHub-hosted) sets pending status immediately
3. Execute job acquires credentials and runs the configured agent via `run-agent.sh`
4. Agent commits, pushes, and posts summary comment
5. Workflow reports success/failure via commit status API

## Key Files

| File | Purpose |
|------|---------|
| `.github/workflows/pr-automation.yml` | Reusable workflow (workflow_call + direct triggers) |
| `caller-workflow.yml` | Template deployed to other repos (thin caller) |
| `run-agent.sh` | Agent wrapper script (translates agent type → CLI invocation) |
| `runner-config.toml` | Source of truth for managed repos |
| `Makefile` | Runner management commands |
| `add-repo.sh` | Setup script (called by make update) |
| `setup-runner.sh` | Runner setup (called by add-repo.sh) |

## PR Commands

| Command | Action |
|---------|--------|
| `[action]` | Execute plan file (PLAN.md, plan.md, .claude/plan.md, docs/plan.md, or docs/plans/*.md) |
| `[fix]` | Fix review comments AND CI failures |
| `[debug]` | Test workflow pipeline (creates test comment) |

**Trigger methods:**
- **PR creation**: Include command anywhere in the PR body
- **Comment**: Post a comment that starts with the command

## Configuration Variables

Set these as repo variables (Settings → Variables → Actions):

| Variable | Default | Purpose |
|----------|---------|---------|
| `RUNNER_TYPE` | `ubuntu-latest` | Set to `self-hosted` for self-hosted runners |
| `AGENT_TYPE` | `claude` | Agent CLI to use: `claude` or `opencode` |
| `AGENT_MODEL` | (agent default) | Model override (e.g., `opus`, `moonshot/kimi-k2.5`, `openai/gpt-5-codex`) |

## Agents

| Agent | CLI | Default Model | Auth |
|-------|-----|---------------|------|
| `claude` | Claude Code | `opus` | `ANTHROPIC_API_KEY` secret or OAuth token file |
| `opencode` | OpenCode/Crush | `moonshot/kimi-k2.5` | Pre-configured providers (self-hosted) or API key secrets |

The `run-agent.sh` wrapper translates `AGENT_TYPE` + `AGENT_MODEL` into the correct CLI invocation. Claude Code gets superpowers plugin commands; OpenCode gets generic step-by-step instructions.

## Authentication

### Claude Code

OAuth tokens are read from `~/.claude-oauth-token` at job time. This file is written by `make refresh-oauth` (called automatically by `make start`/`restart`). On macOS, the token is extracted from the Keychain; runner LaunchAgents can't access the Keychain directly due to `SessionCreate=true`.

### OpenCode

On self-hosted runners, providers are pre-configured via `opencode` → `/connect` (API keys stored in `~/.local/share/opencode/auth.json`). Default provider: Moonshot (Kimi). On GitHub-hosted runners, pass `MOONSHOT_API_KEY` or `OPENAI_API_KEY` as repo secrets.

**Auto-refresh:** `make install-refresh` sets up:
- A **pre-job hook** (`pre-job.sh`) on every runner — uses `launchctl kickstart` to trigger the refresh LaunchAgent before each job, guaranteeing a fresh token at job time
- A **LaunchAgent** (macOS) or cron (Linux) that refreshes hourly as a safety net
- If the token is expired, it runs `claude -p "ping"` to trigger Claude CLI's internal refresh before extracting

### Why OAuth is hard on macOS (design notes)

The core problem: GitHub Actions runner's `svc.sh` installs a LaunchAgent with `SessionCreate=true`, which creates an isolated security session. This means the runner process **cannot** access the user's login Keychain — `security find-generic-password` silently returns nothing.

Approaches that **don't work**:
- Reading Keychain directly from the workflow step (same isolated session)
- Using a pre-job hook to read Keychain (runs in same runner process)
- Using cron to refresh (cron also can't access Keychain on macOS)
- Specifying explicit keychain path (still blocked by session isolation)
- Storing token in runner `.env` file (stale when interactive `claude` rotates it)

**Solution** — three-layer approach:
1. **Pre-job hook** (`ACTIONS_RUNNER_HOOK_JOB_STARTED` in runner `.env`) calls `launchctl kickstart gui/UID/com.pr-resolver.refresh-oauth` to trigger a separate LaunchAgent
2. **Refresh LaunchAgent** (`com.pr-resolver.refresh-oauth`) runs **without** `SessionCreate`, so it has Keychain access. It extracts the token and writes `~/.claude-oauth-token`
3. **Workflow** reads the token file in the "Acquire credentials" step

This guarantees a fresh token at every job start. The hourly LaunchAgent timer is a safety net.

## Runner Configuration

### Setup (Self-hosted)

```bash
# 1. Edit runner-config.toml, add repo to the repos array

# 2. Sync runners
make update

# 3. Install agents
make init-agents        # Installs both Claude Code and OpenCode

# 4. Authentication:

# Claude Code (choose one):
make setup-key KEY=sk-ant-...           # Option A: API key
claude && make install-refresh          # Option B: OAuth

# OpenCode:
opencode                # Launch TUI, use /connect to add providers (Moonshot, OpenAI, etc.)

# 5. Start runners (also refreshes Claude OAuth)
make restart
```

### GitHub-hosted Runner (Alternative)

Add the appropriate API key as a repository secret:
- Claude agent: `ANTHROPIC_API_KEY`
- OpenCode agent: `MOONSHOT_API_KEY` or `OPENAI_API_KEY`

Set `AGENT_TYPE` repo variable if not using the default (`claude`).

The workflow uses `runs-on: ${{ vars.RUNNER_TYPE || 'ubuntu-latest' }}`:
- If `RUNNER_TYPE=self-hosted` → uses your self-hosted runner
- If not set → defaults to GitHub-hosted `ubuntu-latest`
