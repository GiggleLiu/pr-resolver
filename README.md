# PR Webhook Automation

Automated PR processing system using GitHub webhooks and Claude Code. Trigger plan execution or review fixes by commenting on PRs.

### Quick Start

```bash
# One-time setup
make setup

# Start services (auto-restart on boot)
make services-start

# Check status
make status
```

### PR Commands

Comment on any PR to trigger automation:

| Command | Action |
|---------|--------|
| `[action]` | Execute the plan file (PLAN.md) |
| `[fix]` | Address review comments |
| `[status]` | Check queue status |

### Make Targets

```bash
make help              # Show all available targets
```

**Setup:**
```bash
make setup             # Full setup (deps + webhook wizard)
make install-deps      # Install Python dependencies only
make webhook-setup     # Run webhook setup wizard
```

**Services (launchd - recommended):**
```bash
make services-install  # Install launchd services
make services-start    # Start all services
make services-stop     # Stop all services
make services-status   # Check service status
```

**Services (manual - for testing):**
```bash
make webhook-start     # Start webhook server (foreground)
make tunnel-start      # Start Cloudflare tunnel (foreground)
make webhook-stop      # Stop webhook server
make tunnel-stop       # Stop tunnel
```

**Monitoring:**
```bash
make status            # Check webhook health and queue
make logs              # Tail all logs
make logs-webhook      # Tail webhook server logs
make logs-tunnel       # Tail tunnel logs
```

**Maintenance:**
```bash
make clean-logs        # Remove log files older than 7 days
make test-webhook      # Test webhook endpoint
```

## Architecture

```
GitHub PR Comment
       │
       ▼
GitHub Webhook ──► Cloudflare Tunnel ──► Webhook Server ──► Job Queue ──► Claude Worker
                                              │                                │
                                              └──────── Status Comments ◄──────┘
```

See [docs/plans/2026-02-04-pr-webhook-design.md](./docs/plans/2026-02-04-pr-webhook-design.md) for detailed design.

## Configuration

After running `make setup`, edit `.claude/webhook/config.toml`:

```toml
[github]
username = "your-username"      # Only your comments trigger jobs
webhook_secret = "..."          # Generated during setup

[worker]
timeout_minutes = 30            # Max job runtime
max_turns = 100                 # Max Claude API turns

[paths]
log_dir = "~/.claude/logs"

# Repositories to watch - add each repo you want to automate
[[repos]]
github = "owner/repo1"          # GitHub repo (owner/name)
path = "~/projects/repo1"       # Local path to the repo

[[repos]]
github = "owner/repo2"
path = "~/projects/repo2"

# Alternative: watch all repos in a directory
# [repos_dir]
# path = "~/projects"
# max_depth = 2
```

Only configured repositories will accept webhook commands. Unconfigured repos are ignored.

## Directory Structure

```
pr-webhook/
├── .claude/
│   ├── webhook/           # Webhook server
│   │   ├── server.py      # FastAPI app + worker
│   │   ├── config.toml    # Your configuration
│   │   └── jobs.db        # SQLite job queue (auto-created)
│   ├── scripts/           # Setup and utility scripts
│   ├── skills/            # Claude Code skills
│   ├── launchd/           # macOS service plists (auto-created)
│   └── logs/              # Log files
├── docs/plans/            # Design documents
├── Makefile               # Automation commands
├── CLAUDE.md              # Claude Code guidance
└── README.md              # This file
```

## How It Works

1. You configure which repos to watch in `config.toml`
2. For each repo, add a GitHub webhook pointing to your tunnel URL
3. When you comment `[action]` or `[fix]` on a PR, GitHub sends a webhook
4. The server queues the job and Claude Code executes it
5. Status comments (`[executing]`, `[done]`, `[failed]`) are posted back to the PR

## Setup Notes

### Cloudflare Login

When `cloudflared tunnel login` asks you to select a zone, **pick any zone** you have access to. This is just for authentication - your tunnel will use a free `*.cfargotunnel.com` URL regardless of which zone you select.

### Adding Webhooks via CLI

Instead of configuring webhooks through GitHub's web UI, you can use `gh`:

```bash
# Get your webhook URL and secret from config
WEBHOOK_URL="https://<tunnel-id>.cfargotunnel.com/webhook"
SECRET=$(grep webhook_secret .claude/webhook/config.toml | cut -d'"' -f2)

# Create webhook for a repo
gh api repos/OWNER/REPO/hooks --method POST --input - <<EOF
{
  "config": {"url": "$WEBHOOK_URL", "content_type": "json", "secret": "$SECRET"},
  "events": ["issue_comment"],
  "active": true
}
EOF
```

### Adding Webhooks for All Repos in a Directory

```bash
for dir in ~/projects/*/; do
  cd "$dir"
  repo=$(git remote get-url origin 2>/dev/null | sed -E 's|.*github.com[:/]||;s|\.git$||')
  [ -n "$repo" ] && gh api "repos/$repo/hooks" --method POST --input - <<EOF
{"config":{"url":"$WEBHOOK_URL","content_type":"json","secret":"$SECRET"},"events":["issue_comment"],"active":true}
EOF
done
```

## License

MIT
