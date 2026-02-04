#!/bin/bash
# Setup script for PR Webhook System
# Run this once to set up the webhook server and Cloudflare tunnel

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$(dirname "$SCRIPT_DIR")"
WEBHOOK_DIR="$CLAUDE_DIR/webhook"
LAUNCHD_DIR="$CLAUDE_DIR/launchd"

echo "========================================"
echo "PR Webhook Setup"
echo "========================================"
echo ""

# Check dependencies
echo "Checking dependencies..."

if ! command -v gh &>/dev/null; then
    echo "ERROR: gh CLI not found. Install with: brew install gh"
    exit 1
fi

if ! gh auth status &>/dev/null; then
    echo "ERROR: gh not authenticated. Run: gh auth login"
    exit 1
fi

if ! command -v python3 &>/dev/null; then
    echo "ERROR: python3 not found"
    exit 1
fi

if ! command -v claude &>/dev/null; then
    echo "ERROR: claude CLI not found"
    exit 1
fi

echo "✓ All dependencies found"
echo ""

# Install Python dependencies
echo "Installing Python dependencies..."
pip3 install -r "$WEBHOOK_DIR/requirements.txt" --quiet
echo "✓ Python dependencies installed"
echo ""

# Install cloudflared
if ! command -v cloudflared &>/dev/null; then
    echo "Installing cloudflared..."
    if [[ "$(uname)" == "Darwin" ]]; then
        brew install cloudflared
    else
        echo "Please install cloudflared manually: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/"
        exit 1
    fi
fi
echo "✓ cloudflared installed"
echo ""

# Cloudflare login
echo "Checking Cloudflare authentication..."
if ! cloudflared tunnel list &>/dev/null 2>&1; then
    echo "Please log in to Cloudflare (this will open a browser)..."
    cloudflared tunnel login
fi
echo "✓ Cloudflare authenticated"
echo ""

# Create tunnel
TUNNEL_NAME="pr-webhook"
if ! cloudflared tunnel list | grep -q "$TUNNEL_NAME"; then
    echo "Creating Cloudflare tunnel '$TUNNEL_NAME'..."
    cloudflared tunnel create "$TUNNEL_NAME"
fi

# Get tunnel ID
TUNNEL_ID=$(cloudflared tunnel list --output json | python3 -c "import sys,json; tunnels=json.load(sys.stdin); print(next((t['id'] for t in tunnels if t['name']=='$TUNNEL_NAME'), ''))")

if [ -z "$TUNNEL_ID" ]; then
    echo "ERROR: Could not get tunnel ID"
    exit 1
fi

echo "✓ Tunnel created: $TUNNEL_NAME (ID: $TUNNEL_ID)"
echo ""

# Create tunnel config
TUNNEL_CONFIG="$HOME/.cloudflared/config.yml"
mkdir -p "$HOME/.cloudflared"

cat > "$TUNNEL_CONFIG" << EOF
tunnel: $TUNNEL_ID
credentials-file: $HOME/.cloudflared/$TUNNEL_ID.json

ingress:
  - hostname: pr-webhook.example.com
    service: http://localhost:8787
  - service: http_status:404
EOF

echo "✓ Tunnel config created at $TUNNEL_CONFIG"
echo ""

# Get the tunnel URL
TUNNEL_URL="https://$TUNNEL_ID.cfargotunnel.com"
echo "========================================"
echo "Your webhook URL: $TUNNEL_URL/webhook"
echo "========================================"
echo ""

# Create config.toml
CONFIG_FILE="$WEBHOOK_DIR/config.toml"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Creating config.toml..."

    # Generate webhook secret
    WEBHOOK_SECRET=$(openssl rand -hex 32)

    # Get GitHub username
    GH_USER=$(gh api user --jq '.login')

    # Get log dir path
    LOG_DIR="$CLAUDE_DIR/logs"

    cat > "$CONFIG_FILE" << EOF
[server]
host = "127.0.0.1"
port = 8787

[github]
username = "$GH_USER"
webhook_secret = "$WEBHOOK_SECRET"

[worker]
timeout_minutes = 30
max_turns = 100
progress_interval_minutes = 5

[paths]
log_dir = "$LOG_DIR"

# Add repositories to watch below
# Each repo needs a GitHub webhook configured pointing to your tunnel URL

# Example:
# [[repos]]
# github = "owner/repo-name"
# path = "~/projects/repo-name"

# Or watch all repos in a directory:
# [repos_dir]
# path = "~/projects"
# max_depth = 2
EOF

    echo "✓ Config created at $CONFIG_FILE"
    echo ""
    echo "IMPORTANT: Your webhook secret is: $WEBHOOK_SECRET"
    echo "You'll need this when configuring the GitHub webhook."
    echo ""
    echo "NEXT: Edit $CONFIG_FILE to add repositories to watch."
else
    echo "Config already exists at $CONFIG_FILE"
    WEBHOOK_SECRET=$(grep 'webhook_secret' "$CONFIG_FILE" | cut -d'"' -f2)
fi
echo ""

# Create launchd plist files
echo "Creating launchd service files..."
mkdir -p "$LAUNCHD_DIR"

# Webhook server plist
cat > "$LAUNCHD_DIR/com.claude.webhook.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.claude.webhook</string>
    <key>ProgramArguments</key>
    <array>
        <string>$(which python3)</string>
        <string>$WEBHOOK_DIR/server.py</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>WEBHOOK_CONFIG</key>
        <string>$WEBHOOK_DIR/config.toml</string>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin</string>
    </dict>
    <key>WorkingDirectory</key>
    <string>$WEBHOOK_DIR</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$LOG_DIR/webhook-stdout.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/webhook-stderr.log</string>
</dict>
</plist>
EOF

# Tunnel plist
cat > "$LAUNCHD_DIR/com.claude.tunnel.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.claude.tunnel</string>
    <key>ProgramArguments</key>
    <array>
        <string>$(which cloudflared)</string>
        <string>tunnel</string>
        <string>run</string>
        <string>$TUNNEL_NAME</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$LOG_DIR/tunnel-stdout.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/tunnel-stderr.log</string>
</dict>
</plist>
EOF

echo "✓ Launchd plist files created"
echo ""

# Print next steps
echo "========================================"
echo "Setup Complete!"
echo "========================================"
echo ""
echo "NEXT STEPS:"
echo ""
echo "1. Configure GitHub webhook for each repo:"
echo "   - Go to: https://github.com/<owner>/<repo>/settings/hooks/new"
echo "   - Payload URL: $TUNNEL_URL/webhook"
echo "   - Content type: application/json"
echo "   - Secret: $WEBHOOK_SECRET"
echo "   - Events: Select 'Issue comments' only"
echo ""
echo "2. Start the services:"
echo "   # Install launchd services"
echo "   cp $LAUNCHD_DIR/*.plist ~/Library/LaunchAgents/"
echo "   launchctl load ~/Library/LaunchAgents/com.claude.tunnel.plist"
echo "   launchctl load ~/Library/LaunchAgents/com.claude.webhook.plist"
echo ""
echo "3. Or run manually for testing:"
echo "   # Terminal 1: Start tunnel"
echo "   cloudflared tunnel run $TUNNEL_NAME"
echo ""
echo "   # Terminal 2: Start webhook server"
echo "   cd $WEBHOOK_DIR && python3 server.py"
echo ""
echo "4. Test by commenting '[status]' on a PR"
echo ""
