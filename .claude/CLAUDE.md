# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

PR Automation system - include `[action]` or `[fix]` in PR body or comments to trigger Claude Code to execute plans or address review feedback. Uses GitHub Actions with self-hosted runners.

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
Execute Job ──► Self-hosted Runner ──► Read OAuth token ──► Claude CLI
       │                                                        │
       │                                                        ▼
       │                                                Read plan, implement,
       │                                                commit, push
       │                                                        │
       └──── Status Check (✓/✗) ◄───────────────────────────────┘
```

**Flow:**
1. User creates PR with `[action]` in body OR comments `[action]` → caller workflow triggers reusable workflow
2. Setup job (always runs on GitHub-hosted) sets pending status immediately
3. Execute job reads OAuth from `~/.claude-oauth-token` (or uses API key), runs Claude
4. Claude commits, pushes, and posts summary comment
5. Workflow reports success/failure via commit status API

## Key Files

| File | Purpose |
|------|---------|
| `.github/workflows/pr-automation.yml` | Reusable workflow (workflow_call + direct triggers) |
| `caller-workflow.yml` | Template deployed to other repos (thin caller) |
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
| `CLAUDE_MODEL` | `opus` | Claude model to use (e.g., `opus`, `sonnet`) |

## Authentication

OAuth tokens are read from `~/.claude-oauth-token` at job time. This file is written by `make refresh-oauth` (called automatically by `make start`/`restart`). On macOS, the token is extracted from the Keychain; runner LaunchAgents can't access the Keychain directly due to `SessionCreate=true`.

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

# 3. Authentication (choose one):

# Option A: API key (pay per use, never expires)
make setup-key KEY=sk-ant-...

# Option B: OAuth with Max/Pro subscription
claude                  # Login interactively once
make install-refresh    # Auto-refresh token every 6h

# 4. Start runners (also refreshes OAuth)
make restart
```

### GitHub-hosted Runner (Alternative)

Just add `ANTHROPIC_API_KEY` to repository secrets — no other setup needed.

The workflow uses `runs-on: ${{ vars.RUNNER_TYPE || 'ubuntu-latest' }}`:
- If `RUNNER_TYPE=self-hosted` → uses your self-hosted runner
- If not set → defaults to GitHub-hosted `ubuntu-latest`
