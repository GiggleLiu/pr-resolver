#!/bin/bash
# Start Quick Tunnel and auto-update GitHub webhook URLs
#
# The Quick Tunnel URL changes on every restart, so this script:
# 1. Starts a fresh Quick Tunnel (without named tunnel credentials)
# 2. Captures the new URL
# 3. Updates all GitHub webhook URLs automatically
#
# Usage: ./start-tunnel.sh
#
# Note: Named tunnel credentials are temporarily moved aside because they
# interfere with Quick Tunnel routing. This is a workaround for environments
# where Cloudflare's Universal SSL isn't available (e.g., China).

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../webhook/config.toml"
LOG_DIR="$SCRIPT_DIR/../logs"
REPOS_DIR=$(grep -A1 '\[repos_dir\]' "$CONFIG_FILE" | grep path | cut -d'"' -f2 | sed "s|~|$HOME|")
CLOUDFLARED_DIR="$HOME/.cloudflared"
CREDS_BACKUP_DIR="$CLOUDFLARED_DIR/creds.bak"

# Get webhook secret from config
SECRET=$(grep webhook_secret "$CONFIG_FILE" | cut -d'"' -f2)

# Kill any existing tunnel
echo "Stopping existing tunnels..."
pkill -f "cloudflared tunnel" 2>/dev/null || true
sleep 2

# Move named tunnel credentials aside (they interfere with Quick Tunnel)
echo "Preparing for Quick Tunnel..."
mkdir -p "$CREDS_BACKUP_DIR"
if [ -f "$CLOUDFLARED_DIR/config.yml" ]; then
    mv "$CLOUDFLARED_DIR/config.yml" "$CREDS_BACKUP_DIR/" 2>/dev/null || true
fi
for f in "$CLOUDFLARED_DIR"/*.json; do
    [ -f "$f" ] && mv "$f" "$CREDS_BACKUP_DIR/" 2>/dev/null || true
done

# Start Quick Tunnel
echo "Starting Quick Tunnel..."
TUNNEL_LOG="$LOG_DIR/tunnel-quicktunnel.log"
nohup cloudflared tunnel --url http://localhost:8787 > "$TUNNEL_LOG" 2>&1 &
TUNNEL_PID=$!

# Wait for tunnel URL (up to 30 seconds)
echo "Waiting for tunnel URL..."
TUNNEL_URL=""
for i in {1..30}; do
    TUNNEL_URL=$(grep -o 'https://[^[:space:]]*trycloudflare.com' "$TUNNEL_LOG" 2>/dev/null | head -1)
    if [ -n "$TUNNEL_URL" ]; then
        break
    fi
    sleep 1
done

if [ -z "$TUNNEL_URL" ]; then
    echo "ERROR: Failed to get tunnel URL after 30 seconds"
    echo "Check log: $TUNNEL_LOG"
    # Restore credentials
    mv "$CREDS_BACKUP_DIR"/* "$CLOUDFLARED_DIR/" 2>/dev/null || true
    kill $TUNNEL_PID 2>/dev/null || true
    exit 1
fi

WEBHOOK_URL="$TUNNEL_URL/webhook"
echo "Tunnel URL: $WEBHOOK_URL"

# Update all GitHub webhooks
echo "Updating GitHub webhooks..."
cd "$REPOS_DIR"
updated=0
for dir in */; do
    repo=$(cd "$dir" && git remote get-url origin 2>/dev/null | sed -n 's/.*github.com[:/]\(.*\)\.git/\1/p' || git remote get-url origin 2>/dev/null | sed -n 's/.*github.com[:/]\(.*\)/\1/p')
    if [ -n "$repo" ]; then
        hook_id=$(gh api "repos/$repo/hooks" --jq '.[] | select(.config.url | test("trycloudflare|jinguo-group")) | .id' 2>/dev/null | head -1)
        if [ -n "$hook_id" ]; then
            echo "  Updating $repo..."
            gh api "repos/$repo/hooks/$hook_id" --method PATCH --silent --input - <<EOF
{"config":{"url":"$WEBHOOK_URL","content_type":"json","secret":"$SECRET"}}
EOF
            ((updated++))
        fi
    fi
done

echo ""
echo "============================================"
echo "  Quick Tunnel Started Successfully"
echo "============================================"
echo "URL:      $WEBHOOK_URL"
echo "PID:      $TUNNEL_PID"
echo "Log:      $TUNNEL_LOG"
echo "Updated:  $updated webhooks"
echo ""
echo "To stop:  kill $TUNNEL_PID"
echo "To check: curl $TUNNEL_URL/health"
echo "============================================"

# Save PID for easy stopping
echo $TUNNEL_PID > "$LOG_DIR/tunnel.pid"
