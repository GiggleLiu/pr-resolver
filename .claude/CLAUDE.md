# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

PR Automation system - include `[action]` or `[fix]` in PR body or comments to trigger Claude Code to execute plans or address review feedback. Uses GitHub Actions with self-hosted runners.

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
make round-trip                          # End-to-end test
```

## Architecture

```
PR Created / Comment Posted
       │
       ▼
Setup Job (GitHub-hosted) ──► Set "Waiting for runner..." status
       │
       ▼
Execute Job ──► Self-hosted Runner ──► Claude CLI
       │                                    │
       │                                    ▼
       │                            Read plan, implement,
       │                            commit, push
       │                                    │
       └──── Status Check (✓/✗) ◄───────────┘
```

**Flow:**
1. User creates PR with `[action]` in body OR comments `[action]` → GitHub triggers workflow
2. Setup job (always runs on GitHub-hosted) sets pending status immediately
3. Execute job waits for runner, checks out PR branch, finds plan file
4. Runs `claude --dangerously-skip-permissions` to execute plan
5. Claude commits, pushes, and posts summary comment
6. Workflow reports success/failure via commit status API

## Key Files

| File | Purpose |
|------|---------|
| `.github/workflows/pr-automation.yml` | Workflow triggered by PR creation/comments |
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

## Status Reporting

Status is shown directly in the PR's status checks (not comments):
- **Pending (Waiting for runner...)**: Setup complete, waiting for runner to pick up job
- **Pending (Running...)**: Runner picked up job, Claude is executing
- **Success**: Plan executed successfully
- **Failure**: Error occurred (check Actions log)

After execution, Claude posts a summary comment describing what was done.

## Runner Configuration

### Setup (Self-hosted)

```bash
# 1. Edit runner-config.toml, add repo to the repos array

# 2. Sync runners
make update

# 3. Set API key for all runners
make setup-key KEY=sk-ant-...
make restart
```

### Remove a Runner

```bash
# 1. Remove from runner-config.toml
# 2. Sync
make update
```

### GitHub-hosted Runner (Alternative)

Just add `ANTHROPIC_API_KEY` to repository secrets — no other setup needed.

The workflow uses `runs-on: ${{ vars.RUNNER_TYPE || 'ubuntu-latest' }}`:
- If `RUNNER_TYPE=self-hosted` → uses your self-hosted runner
- If not set → defaults to GitHub-hosted `ubuntu-latest`

## Development

The workflow (`pr-automation.yml`) has two jobs:

**Setup job** (runs on GitHub-hosted `ubuntu-latest`):
1. Extracts PR details (branch, SHA, command, instructions)
2. Sets pending status with "Waiting for runner..."
3. Outputs values for execute job

**Execute job** (runs on configured runner, depends on setup):
1. Updates status to "Running..."
2. Checks out PR branch, finds plan file
3. Validates API key, runs Claude with appropriate prompt
4. Checks output for authentication errors
5. Sets success/failure status

Claude is invoked with `--dangerously-skip-permissions` and `--max-turns 100` to allow autonomous execution within the sandboxed runner environment.
