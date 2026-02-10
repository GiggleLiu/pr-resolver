# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

PR Automation system - include `[action]` or `[fix]` in PR body or comments to trigger Claude Code to execute plans or address review feedback. Uses GitHub Actions with self-hosted runners.

The workflow is defined once in this repo and called as a **reusable workflow** by other repos via `uses: GiggleLiu/pr-resolver/.github/workflows/pr-automation.yml@main`.

## Commands

```bash
make update                              # Sync runners with config (add/remove)
make status                              # Check all runner statuses
make start                               # Start all runners
make stop                                # Stop all runners
make restart                             # Restart all runners
make list                                # List configured repos
make clean                               # Clean caches (saves ~3GB)
make init-claude                         # Install Claude CLI + superpowers
make setup-key KEY=sk-ant-...            # Set API key for all runners
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
Execute Job ──► Self-hosted Runner ──► Acquire OAuth ──► Claude CLI
       │                                                      │
       │                                                      ▼
       │                                              Read plan, implement,
       │                                              commit, push
       │                                                      │
       └──── Status Check (✓/✗) ◄─────────────────────────────┘
```

**Flow:**
1. User creates PR with `[action]` in body OR comments `[action]` → caller workflow triggers reusable workflow
2. Setup job (always runs on GitHub-hosted) sets pending status immediately
3. Execute job acquires OAuth from Keychain (or uses API key), runs Claude
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

OAuth tokens are acquired **at job time** from the macOS Keychain (self-hosted) or from `ANTHROPIC_API_KEY` secret (GitHub-hosted). No scheduled refresh needed.

## Runner Configuration

### Setup (Self-hosted)

```bash
# 1. Edit runner-config.toml, add repo to the repos array

# 2. Sync runners
make update

# 3. Authentication (choose one):

# Option A: API key (pay per use, never expires)
make setup-key KEY=sk-ant-...

# Option B: OAuth with Max/Pro subscription (no setup needed)
# Just run 'claude' interactively once to login.
# The workflow acquires the token from Keychain at job time.

# 4. Restart runners
make restart
```

### GitHub-hosted Runner (Alternative)

Just add `ANTHROPIC_API_KEY` to repository secrets — no other setup needed.

The workflow uses `runs-on: ${{ vars.RUNNER_TYPE || 'ubuntu-latest' }}`:
- If `RUNNER_TYPE=self-hosted` → uses your self-hosted runner
- If not set → defaults to GitHub-hosted `ubuntu-latest`
