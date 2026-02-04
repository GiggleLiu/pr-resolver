# Claude Automation Scripts

Scripts for automated PR processing with Claude Code.

## Quick Start

### One-time run (manual or cron)
```bash
./pr-cron.sh /path/to/workspace
```

### Continuous monitoring (daemon)
```bash
./pr-monitor.sh --workspace /path/to/workspace --interval 1800
```

### Interactive (using skill)
```bash
claude -p "/pr-executor"
```

## Scripts

| Script | Purpose | Best For |
|--------|---------|----------|
| `pr-cron.sh` | Simple one-shot execution | Cron jobs |
| `pr-monitor.sh` | Stateful daemon with deduplication | Background service |
| `pr-executor.sh` | Full-featured with detailed logging | Manual runs |

## Cron Setup

```bash
# Edit crontab
crontab -e

# Add (runs every 30 minutes)
*/30 * * * * /Users/jinguomini/rcode/.claude/scripts/pr-cron.sh /Users/jinguomini/rcode

# Or with logging
*/30 * * * * /Users/jinguomini/rcode/.claude/scripts/pr-cron.sh /Users/jinguomini/rcode >> /tmp/pr-cron.log 2>&1
```

## Systemd Service (Linux)

Create `/etc/systemd/system/pr-monitor.service`:
```ini
[Unit]
Description=PR Monitor for Claude Code
After=network.target

[Service]
Type=simple
User=youruser
WorkingDirectory=/path/to/workspace
ExecStart=/path/to/.claude/scripts/pr-monitor.sh --workspace /path/to/workspace
Restart=always
RestartSec=60

[Install]
WantedBy=multi-user.target
```

Then:
```bash
sudo systemctl enable pr-monitor
sudo systemctl start pr-monitor
```

## LaunchAgent (macOS)

Create `~/Library/LaunchAgents/com.claude.pr-monitor.plist`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.claude.pr-monitor</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Users/jinguomini/rcode/.claude/scripts/pr-cron.sh</string>
        <string>/Users/jinguomini/rcode</string>
    </array>
    <key>StartInterval</key>
    <integer>1800</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/pr-monitor.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/pr-monitor.error.log</string>
</dict>
</plist>
```

Then:
```bash
launchctl load ~/Library/LaunchAgents/com.claude.pr-monitor.plist
```

## PR Commands

Leave these comments on your PRs to trigger automation:

| Comment | Action |
|---------|--------|
| `[action]` | Execute plan file (PLAN.md) |
| `[fix]` | Address review comments |

## Status Comments (Bot Responses)

| Status | Meaning |
|--------|---------|
| `[executing]` | Plan execution started |
| `[done]` | Plan execution completed |
| `[waiting]` | Waiting for plan file |
| `[fixing]` | Addressing review comments |
| `[fixed]` | Review comments addressed |

## Logs

- `pr-cron.sh`: `.claude/logs/pr-cron-YYYYMMDD.log`
- `pr-monitor.sh`: `.claude/logs/pr-monitor.log`
- `pr-executor.sh`: `.claude/pr-executor.log`

## Requirements

- `gh` CLI authenticated (`gh auth login`)
- `claude` CLI installed and accessible
- `jq` for JSON parsing
