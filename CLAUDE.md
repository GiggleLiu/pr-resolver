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
| `[debug]` | Test full pipeline round-trip (Claude posts [pass] or [fail]) |

## Status Comments

| Status | Meaning |
|--------|---------|
| `[queued]` | Job added to queue with position |
| `[done]` | Plan completed successfully |
| `[fixed]` | Review comments addressed |
| `[failed]` | Error with details |
| `[timeout]` | Exceeded time limit (default 30 min) |
| `[waiting]` | No plan file found |

Note: `[executing]`/`[fixing]` comments were removed to reduce PR noise. Only `[queued]` is posted when a job starts.

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

## Quick Tunnel Mode (China / SSL issues)

If Cloudflare's Universal SSL isn't available (common in China), use Quick Tunnel:

```bash
# Start Quick Tunnel with auto-webhook-update
.claude/scripts/start-tunnel.sh
```

This script:
1. Temporarily moves named tunnel credentials aside (they interfere with Quick Tunnel)
2. Starts a fresh Quick Tunnel
3. Automatically updates all GitHub webhook URLs to the new tunnel URL
4. Prints the new URL and PID

Quick Tunnel URLs change on each restart, so run this script whenever you restart the tunnel.

### Why Quick Tunnel?

Named tunnels require:
- Domain with nameservers pointing to Cloudflare
- Universal SSL certificate coverage for subdomains
- Proper DNS CNAME record pointing to `<tunnel-id>.cfargotunnel.com`

In environments where Universal SSL isn't available, the named tunnel will return 502 errors. Quick Tunnels work around this by using Cloudflare's `trycloudflare.com` domain which has SSL already configured.
