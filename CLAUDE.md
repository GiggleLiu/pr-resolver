# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

PR Webhook Automation system - event-driven PR processing using GitHub webhooks and Claude Code. Comment `[action]` or `[fix]` on PRs to trigger automated plan execution or review fixes.

## Commands

```bash
make help              # Show all available targets
make setup             # Full setup (deps + webhook wizard)
make services-start    # Start webhook + tunnel services (launchd)
make services-stop     # Stop all services
make services-status   # Check if services are running
make status            # Check webhook health and queue length
make logs              # Tail all logs
make webhook-start     # Start server manually (foreground)
make tunnel-start      # Start tunnel manually (foreground)
```

## Architecture

```
GitHub PR Comment
       │
       ▼
GitHub Webhook ──► Cloudflare Tunnel ──► FastAPI Server ──► SQLite Queue ──► Claude Worker
       │                (8787)                 │                                    │
       │                                       │                                    │
       └─────────────────────────────── Status Comments ◄───────────────────────────┘
```

**Flow:**
1. User comments `[action]` on PR → GitHub sends webhook
2. Server validates signature, checks repo is configured, queues job
3. Worker picks job, posts `[executing]`, invokes `claude` subprocess
4. On completion, posts `[done]` or `[failed]` with details

## Key Files

| File | Purpose |
|------|---------|
| `.claude/webhook/server.py` | FastAPI server + SQLite queue + worker thread |
| `.claude/webhook/config.toml` | Repos to watch, credentials, timeouts |
| `.claude/scripts/setup-webhook.sh` | One-time setup wizard |
| `.claude/launchd/*.plist` | macOS service definitions |

## Configuration

Repos are configured in `.claude/webhook/config.toml`:

```toml
# Explicit list
[[repos]]
github = "owner/repo"
path = "~/projects/repo"

# Or scan a directory
[repos_dir]
path = "~/projects"
max_depth = 2
```

Only configured repos accept webhook commands. Unconfigured repos are silently ignored.

## PR Commands

| Command | Action |
|---------|--------|
| `[action]` | Execute plan file (PLAN.md, plan.md, .claude/plan.md, or docs/plan.md) |
| `[fix]` | Fetch review comments and address them |
| `[status]` | Reply with queue length (immediate, no job created) |

## Status Comments

| Status | Meaning |
|--------|---------|
| `[queued]` | Job added to queue with position |
| `[executing]` | Plan execution started |
| `[fixing]` | Addressing review comments |
| `[done]` | Plan completed successfully |
| `[fixed]` | Review comments addressed |
| `[failed]` | Error with details |
| `[timeout]` | Exceeded time limit (default 30 min) |
| `[waiting]` | No plan file found |

## Adding Webhooks via CLI

```bash
# Get values from config
WEBHOOK_URL="https://<tunnel-id>.cfargotunnel.com/webhook"
SECRET=$(grep webhook_secret .claude/webhook/config.toml | cut -d'"' -f2)

# Create webhook
gh api repos/OWNER/REPO/hooks --method POST --input - <<EOF
{"config":{"url":"$WEBHOOK_URL","content_type":"json","secret":"$SECRET"},"events":["issue_comment"],"active":true}
EOF
```

## Development

The server is a single Python file with three components:

1. **Webhook endpoint** (`POST /webhook`)
   - Validates HMAC-SHA256 signature
   - Filters: only `issue_comment` events, only PRs, only configured user, only configured repos
   - Queues job or handles `[status]` immediately

2. **Job queue** (SQLite `jobs` table)
   - Columns: repo, pr_number, branch, command, comment_id (unique), status, error, timestamps
   - Deduplicates by comment_id (GitHub may retry webhooks)

3. **Worker** (background thread)
   - Polls every 5 seconds for pending jobs
   - Processes sequentially (no parallelism)
   - Spawns `claude` with 30-minute timeout

## Testing

```bash
# Terminal 1: Start tunnel
make tunnel-start

# Terminal 2: Start server
make webhook-start

# Terminal 3: Test endpoint
curl http://localhost:8787/health
make test-webhook
```
