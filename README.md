# PR Webhook Automation

Automate PR workflows with Claude Code using a plan-driven development approach.

## Workflow

```
1. Create a PR with a plan file (e.g., docs/plans/feature-design.md)
2. Comment [action] on the PR
3. Claude reads the plan, implements it, and pushes commits
4. Review the changes, leave feedback
5. Comment [fix] to have Claude address review comments
6. Repeat until ready to merge
```

This enables a "write the plan, not the code" workflow where you describe **what** to build and Claude handles the implementation.

### Works with Superpowers Toolkit

Combine with [claude-superpowers](https://github.com/anthropics/claude-superpowers) for end-to-end automation:

```
/superpowers:brainstorming  →  Design the feature interactively
/superpowers:writing-plans  →  Generate detailed implementation plan
git push & create PR        →  Push plan to a new branch
[action]                    →  Claude executes the plan autonomously
```

## Features

- **Event-driven**: GitHub webhooks trigger jobs instantly (no polling)
- **Reliable**: SQLite job queue with deduplication and failure handling
- **Secure**: HMAC signature verification, configurable user allowlist
- **Simple**: Single Python server, no external dependencies beyond `cloudflared`

## Quick Start

```bash
# 1. Clone and setup
git clone https://github.com/user/pr-resolver.git
cd pr-resolver
make setup

# 2. Start services
make services-start

# 3. Verify
make status
```

## PR Commands

Comment on any PR to trigger automation:

| Command | Action |
|---------|--------|
| `[action]` | Execute the plan file |
| `[fix]` | Address review comments |
| `[status]` | Check queue status |
| `[debug]` | Test the full pipeline |

Plan files are detected in order: `PLAN.md`, `plan.md`, `.claude/plan.md`, `docs/plan.md`, or any file in `docs/plans/*.md`.

## Architecture

```
GitHub PR Comment
       │
       ▼
GitHub Webhook ──► Cloudflare Tunnel ──► Webhook Server ──► Job Queue ──► Claude
                                              │                              │
                                              └────── Status Comments ◄──────┘
```

## Configuration

After `make setup`, edit `.claude/webhook/config.toml`:

```toml
[github]
username = "your-username"      # Only your comments trigger jobs
webhook_secret = "..."          # Generated during setup

[worker]
timeout_minutes = 30            # Max job runtime
max_turns = 100                 # Max Claude API turns

# Option 1: List repos explicitly
[[repos]]
github = "owner/repo"
path = "~/projects/repo"

# Option 2: Watch all repos in a directory
[repos_dir]
path = "~/projects"
max_depth = 2
```

## Make Targets

```bash
make help              # Show all targets

# Setup
make setup             # Full setup wizard
make install-deps      # Install Python dependencies

# Services (launchd)
make services-start    # Start webhook + tunnel
make services-stop     # Stop all services
make services-status   # Check status

# Manual (for testing)
make webhook-start     # Start webhook server
make tunnel-start      # Start tunnel

# Monitoring
make status            # Health check
make logs              # Tail all logs
```

## Adding Webhooks

Use the GitHub CLI to add webhooks:

```bash
WEBHOOK_URL="https://your-tunnel.trycloudflare.com/webhook"
SECRET=$(grep webhook_secret .claude/webhook/config.toml | cut -d'"' -f2)

gh api repos/OWNER/REPO/hooks --method POST --input - <<EOF
{"config":{"url":"$WEBHOOK_URL","content_type":"json","secret":"$SECRET"},"events":["issue_comment"],"active":true}
EOF
```

Or add webhooks for all repos in a directory:

```bash
for dir in ~/projects/*/; do
  repo=$(cd "$dir" && git remote get-url origin 2>/dev/null | sed -E 's|.*github.com[:/]||;s|\.git$||')
  [ -n "$repo" ] && gh api "repos/$repo/hooks" --method POST --input - <<EOF
{"config":{"url":"$WEBHOOK_URL","content_type":"json","secret":"$SECRET"},"events":["issue_comment"],"active":true}
EOF
done
```

## Directory Structure

```
pr-resolver/
├── .claude/
│   ├── webhook/
│   │   ├── server.py          # FastAPI server + worker
│   │   ├── config.toml        # Your config (git-ignored)
│   │   └── config.example.toml
│   ├── scripts/
│   │   ├── setup-webhook.sh   # Setup wizard
│   │   └── start-tunnel.sh    # Quick tunnel helper
│   ├── launchd/               # macOS service plists
│   └── logs/                  # Log files (git-ignored)
├── docs/plans/                # Design documents
├── Makefile
├── CLAUDE.md
└── README.md
```

## Requirements

- Python 3.9+
- [Claude Code CLI](https://claude.ai/code)
- [GitHub CLI](https://cli.github.com/) (`gh`)
- [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/install-and-setup/tunnel-guide/) (`cloudflared`)

## Troubleshooting

### Cloudflare Login Zone Selection

When `cloudflared tunnel login` asks you to select a zone, pick **any zone** you have access to. This is just for authentication.

### PATH Issues in launchd

If `gh` or `claude` commands fail, ensure `/opt/homebrew/bin` (or your install path) is in the PATH environment variable in the launchd plist.

### Quick Tunnel Mode (Alternative)

If you cannot use named tunnels (e.g., Cloudflare Universal SSL unavailable in your region), use Quick Tunnel mode:

```bash
.claude/scripts/start-tunnel.sh
```

This script:
1. Starts a Quick Tunnel (URL changes on restart)
2. Automatically updates all GitHub webhook URLs
3. Prints the new tunnel URL

Run this script each time you restart the tunnel.

## License

MIT
