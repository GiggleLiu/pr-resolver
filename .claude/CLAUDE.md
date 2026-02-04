# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

PR Automation system - comment `[action]` or `[fix]` on GitHub PRs to trigger Claude Code to execute plans or address review feedback. Uses GitHub Actions with self-hosted runners.

## Commands

```bash
make help                                # Show all available targets
make add-repo REPO=owner/repo            # Full setup (workflow + runner + config)
make setup REPO=owner/repo               # Setup runner only
make status                              # Check all runner statuses
make start                               # Start all runners
make stop                                # Stop all runners
make restart                             # Restart all runners
make list                                # List configured repos
```

## Architecture

```
GitHub PR Comment
       │
       ▼
GitHub Actions ──► Self-hosted Runner ──► Claude CLI
       │                                      │
       │                                      ▼
       │                              Read plan, implement,
       │                              commit, push
       │                                      │
       └──── Status Check (✓/✗) ◄─────────────┘
```

**Flow:**
1. User comments `[action]` on PR → GitHub triggers workflow
2. Workflow checks out PR branch, finds plan file
3. Runs `claude --dangerously-skip-permissions` to execute plan
4. Claude commits, pushes, and posts summary comment
5. Workflow reports success/failure via commit status API

## Key Files

| File | Purpose |
|------|---------|
| `.github/workflows/pr-automation.yml` | Workflow triggered by PR comments |
| `add-repo.sh` | Full setup: workflow + runner + variable |
| `setup-runner.sh` | Runner-only setup script |
| `runner-config.toml` | Runner configuration |
| `Makefile` | Runner management commands |

## PR Commands

| Command | Action |
|---------|--------|
| `[action]` | Execute plan file (PLAN.md, plan.md, .claude/plan.md, docs/plan.md, or docs/plans/*.md) |
| `[fix]` | Fetch review comments and address them |
| `[debug]` | Test workflow pipeline (creates test comment) |

## Status Reporting

Status is shown directly in the PR's status checks (not comments):
- **Pending**: Workflow is running
- **Success**: Plan executed successfully
- **Failure**: Error occurred (check Actions log)

After execution, Claude posts a summary comment describing what was done.

## Runner Configuration

### Self-hosted Runner (Recommended)

```bash
# One-time setup
./setup-runner.sh owner/repo

# API key configuration
echo "ANTHROPIC_API_KEY=sk-ant-..." >> ~/actions-runners/repo-name/.env
```

Then set repository variable `RUNNER_TYPE=self-hosted` (Settings → Variables → Actions).

### GitHub-hosted Runner

Just add `ANTHROPIC_API_KEY` to repository secrets — no other setup needed.

### How Runner Selection Works

The workflow uses `runs-on: ${{ vars.RUNNER_TYPE || 'ubuntu-latest' }}`:
- If `RUNNER_TYPE` variable is set to `self-hosted` → uses your self-hosted runner
- If not set → defaults to GitHub-hosted `ubuntu-latest`

API key is loaded from secrets first, then falls back to runner's `.env` file.

## Multi-Repo Management

For managing runners across multiple repositories:

```bash
# Configure repos in runner-config.toml
make setup-all ANTHROPIC_API_KEY="sk-ant-..."
make status
make restart
```

## Development

The workflow (`pr-automation.yml`) has three main steps:

1. **Get PR details**: Extracts branch name, SHA, and command type
2. **Execute plan / Fix comments**: Runs Claude with appropriate prompt
3. **Set status**: Reports success/failure via commit status API

Claude is invoked with `--dangerously-skip-permissions` and `--max-turns 100` to allow autonomous execution within the sandboxed runner environment.
