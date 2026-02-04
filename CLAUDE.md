# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

PR Webhook Automation system - event-driven PR processing using GitHub webhooks and Claude Code.

## Commands

```bash
make help              # Show all available targets
make setup             # Full setup (deps + webhook wizard)
make services-start    # Start webhook + tunnel services
make services-stop     # Stop all services
make status            # Check webhook health and queue
make logs              # Tail all logs
```

## Architecture

```
GitHub PR Comment
       │
       ▼
GitHub Webhook ──► Cloudflare Tunnel ──► FastAPI Server ──► SQLite Queue ──► Claude Worker
                                              │                                    │
                                              └────────── Status Comments ◄────────┘
```

## Key Files

- `.claude/webhook/server.py` - FastAPI webhook server + job worker
- `.claude/webhook/config.toml` - Configuration (repos to watch, credentials)
- `.claude/scripts/setup-webhook.sh` - One-time setup wizard

## Configuration

Repos to watch are configured in `.claude/webhook/config.toml`:

```toml
[[repos]]
github = "owner/repo"
path = "~/projects/repo"
```

Only configured repos accept webhook commands.

## PR Commands

| Command | Action |
|---------|--------|
| `[action]` | Execute plan file (PLAN.md) |
| `[fix]` | Address review comments |
| `[status]` | Check queue status |

## Status Comments

| Status | Meaning |
|--------|---------|
| `[queued]` | Job added to queue |
| `[executing]` | Plan execution started |
| `[done]` | Completed successfully |
| `[failed]` | Error with details |
| `[timeout]` | Exceeded time limit |

## Development

The webhook server is Python (FastAPI). Key components:

1. **Webhook endpoint** (`/webhook`) - Receives GitHub events, validates signature, queues jobs
2. **Job queue** (SQLite) - Persists jobs with deduplication by comment_id
3. **Worker** (background thread) - Processes jobs sequentially, invokes Claude Code

## Testing

```bash
# Start server manually for testing
make webhook-start

# In another terminal, start tunnel
make tunnel-start

# Test the endpoint
make test-webhook
```
