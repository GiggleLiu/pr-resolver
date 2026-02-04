# PR Webhook System Implementation Plan

## Overview
Implement event-driven PR automation using GitHub webhooks, replacing the polling-based approach.

## Tasks

### 1. Create webhook server (server.py)
- FastAPI app with `/webhook` endpoint and `/health` endpoint
- GitHub webhook signature verification (HMAC-SHA256)
- Parse `issue_comment` events, extract command from first line
- Filter: only PRs, only configured username, only `[action]`/`[fix]`/`[status]`
- Return 200 quickly, queue job for processing

### 2. Create SQLite job queue
- Schema: jobs table with id, repo, pr_number, branch, command, comment_id, status, error, timestamps
- Functions: create_job(), get_pending_job(), update_job_status()
- Deduplication by comment_id
- Initialize DB on startup

### 3. Create worker
- Background thread that polls queue every 5 seconds
- For each pending job:
  - Mark as running, post `[executing]`/`[fixing]` to PR
  - Clone/fetch repo, checkout branch
  - Invoke `claude` subprocess with timeout (30 min)
  - On success: mark done, post `[done]`/`[fixed]`
  - On failure: mark failed, post `[failed]` with error

### 4. Create config and requirements
- config.toml: server settings, github username, webhook secret, paths
- requirements.txt: fastapi, uvicorn, tomli

### 5. Create setup script
- Install cloudflared if needed
- Guide user through tunnel creation
- Guide user through GitHub webhook setup
- Create config.toml from template

### 6. Create launchd plist files
- com.claude.webhook.plist for the webhook server
- com.claude.tunnel.plist for cloudflared
- Instructions in README

### 7. Test and document
- Test locally with ngrok first
- Update .claude/scripts/README.md with new setup
- Update CLAUDE.md with webhook info
