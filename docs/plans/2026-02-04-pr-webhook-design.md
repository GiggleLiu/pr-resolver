# PR Webhook System Design

## Problem

The current polling-based PR executor has four reliability issues:
1. **Silent failures** - Claude errors out with no indication on the PR
2. **Missed commands** - Script doesn't detect commands that were posted
3. **Partial execution** - Starts work but never finishes or posts completion
4. **State corruption** - Re-processes old commands or skips new ones

## Solution

Replace polling with an event-driven webhook server using Cloudflare Tunnel.

## Architecture

```
GitHub PR Comment
       │
       ▼
┌─────────────────┐
│  GitHub Webhook │ ─── POST to tunnel URL
└─────────────────┘
       │
       ▼
┌─────────────────┐
│ Cloudflare      │ ─── Tunnels traffic to localhost
│ Tunnel          │
└─────────────────┘
       │
       ▼
┌─────────────────┐
│ Webhook Server  │ ─── Python FastAPI (localhost:8787)
│                 │
└─────────────────┘
       │
       ▼
┌─────────────────┐
│  Job Queue      │ ─── SQLite file (persistent)
└─────────────────┘
       │
       ▼
┌─────────────────┐
│  Worker         │ ─── Sequential processing
│  (same process) │     Invokes Claude Code
└─────────────────┘
       │
       ▼
┌─────────────────┐
│  GitHub API     │ ─── Posts status comments
│  (gh CLI)       │
└─────────────────┘
```

## Components

### Webhook Server (FastAPI)

Receives GitHub `issue_comment` events:
```python
POST /webhook
{
  "action": "created",
  "comment": {
    "body": "[action] do it",
    "created_at": "2024-...",
    "id": 123456
  },
  "issue": {
    "number": 42,
    "pull_request": {...}
  },
  "repository": {
    "full_name": "user/repo",
    "clone_url": "..."
  },
  "sender": {
    "login": "username"
  }
}
```

**Validation:**
- Only `issue_comment` events with `action == "created"`
- Only PRs (has `pull_request` field)
- Only configured GitHub username (prevents others triggering bot)
- Verifies webhook secret (HMAC-SHA256)

**Command parsing:**
- First line starts with `[action]`, `[fix]`, or `[status]`

### Job Queue (SQLite)

```sql
CREATE TABLE jobs (
  id INTEGER PRIMARY KEY,
  repo TEXT NOT NULL,
  pr_number INTEGER NOT NULL,
  branch TEXT NOT NULL,
  command TEXT NOT NULL,
  comment_id INTEGER UNIQUE NOT NULL,
  status TEXT DEFAULT 'pending',
  error TEXT,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  started_at TIMESTAMP,
  finished_at TIMESTAMP
);

CREATE INDEX idx_status ON jobs(status);
CREATE INDEX idx_comment_id ON jobs(comment_id);
```

- `comment_id` is unique for deduplication (GitHub may retry webhooks)
- Status: `pending` → `running` → `done`/`failed`

### Worker

Runs in same process, processes jobs sequentially:

```
1. Poll queue for oldest "pending" job
2. Mark job as "running", record started_at
3. Post [executing] or [fixing] comment to PR
4. Clone/fetch repo, checkout PR branch
5. Invoke Claude Code with timeout (30 min)
6. On success: mark "done", post [done]/[fixed]
7. On failure: mark "failed", post [failed] with error
8. Repeat
```

**Timeout handling:**
- Subprocess spawned with 30 minute timeout
- On timeout: kill process, post `[timeout]` comment
- Mark job as `failed` with reason "timeout"

### Cloudflare Tunnel

Exposes localhost:8787 to the internet with HTTPS.

**Two Options:**

1. **Quick Tunnel (for testing)** - URL changes on restart
   ```bash
   cloudflared tunnel --url http://localhost:8787
   # Outputs: https://random-words.trycloudflare.com
   ```

2. **Named Tunnel (for production)** - Requires Cloudflare DNS setup
   ```bash
   cloudflared tunnel login
   cloudflared tunnel create pr-webhook
   # Then configure DNS in Cloudflare dashboard:
   # Add CNAME record: webhook.yourdomain.com → <tunnel-id>.cfargotunnel.com
   cloudflared tunnel run pr-webhook
   ```

**Note:** The `*.cfargotunnel.com` URL does NOT work directly for named tunnels.
You must configure a DNS CNAME record pointing to the tunnel, OR use Quick Tunnel mode.

### GitHub Webhook Configuration

- URL: `https://<your-tunnel-url>/webhook`
- Content type: `application/json`
- Secret: Random string stored in config
- Events: "Issue comments" only

Create webhooks via CLI:
```bash
gh api repos/OWNER/REPO/hooks --method POST --input - <<EOF
{"config":{"url":"$URL","content_type":"json","secret":"$SECRET"},"events":["issue_comment"],"active":true}
EOF
```

## Commands

| Command | Action |
|---------|--------|
| `[action]` | Execute plan file |
| `[fix]` | Address review comments |
| `[status]` | Reply with queue position / job status |

## Status Comments

| Status | When | Example |
|--------|------|---------|
| `[queued]` | Webhook received | "Job queued. Position: 1" |
| `[executing]` | Worker starts | "Starting plan execution..." |
| `[progress]` | Every 5 min | "Step 2/4: Running tests..." |
| `[done]` | Success | "Plan executed. 3 commits pushed." |
| `[fixed]` | Success | "Addressed 4 review comments." |
| `[failed]` | Error | "Failed: cargo test exit code 1" |
| `[timeout]` | 30 min limit | "Job exceeded 30 minute limit." |

## Error Handling

| Problem | Solution |
|---------|----------|
| Silent failures | Always post `[failed]` with error details |
| Missed commands | Webhook guarantees delivery |
| Partial execution | Timeout + cleanup + failure comment |
| State corruption | SQLite source of truth + comment_id dedup |

## File Structure

```
.claude/
├── webhook/
│   ├── server.py           # FastAPI server + worker
│   ├── config.toml         # Settings
│   ├── jobs.db             # SQLite (auto-created)
│   └── requirements.txt    # Dependencies
├── scripts/
│   └── setup-webhook.sh    # One-time setup
└── launchd/
    ├── com.claude.webhook.plist   # Webhook server service
    └── com.claude.tunnel.plist    # Cloudflare tunnel service
```

## Configuration (config.toml)

```toml
[server]
host = "127.0.0.1"
port = 8787

[github]
username = "your-github-username"
webhook_secret = "your-secret-here"

[worker]
timeout_minutes = 30
progress_interval_minutes = 5
max_turns = 100

[paths]
log_dir = "~/.claude/logs"

# Option 1: Scan a directory for repos
[repos_dir]
path = "~/projects"
max_depth = 2

# Option 2: Explicit repo list
# [[repos]]
# github = "owner/repo"
# path = "~/projects/repo"
```

## Known Issues & Solutions

### PATH Not Found for gh/git/claude
The server runs with a minimal PATH. Solution: `SUBPROCESS_ENV` dict in server.py:
```python
SUBPROCESS_ENV = {
    **os.environ,
    "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + os.environ.get("PATH", ""),
}
```
All `subprocess.run()` calls must use `env=SUBPROCESS_ENV`.

### Named Tunnel URL Not Working
Named tunnels (created with `cloudflared tunnel create`) require DNS configuration.
The `*.cfargotunnel.com` URL only resolves after adding a CNAME record in Cloudflare DNS.
For testing, use Quick Tunnel instead: `cloudflared tunnel --url http://localhost:8787`

## Services (macOS LaunchAgents)

Both services:
- Start on login
- Restart on crash (5 second delay)
- Log stdout/stderr to files

**Webhook server:** `~/Library/LaunchAgents/com.claude.webhook.plist`
**Cloudflare tunnel:** `~/Library/LaunchAgents/com.claude.tunnel.plist`

## Implementation Plan

1. Create webhook server (server.py)
2. Create SQLite schema and job queue logic
3. Create worker with Claude invocation
4. Create config file and setup script
5. Create launchd plist files
6. Test end-to-end locally with ngrok
7. Switch to Cloudflare Tunnel for production
8. Update CLAUDE.md with new setup instructions
