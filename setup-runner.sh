#!/bin/bash
# Setup a self-hosted GitHub Actions runner for a repository
# Usage: ./setup-runner.sh owner/repo [API_KEY]
# Config: runner-config.toml

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/runner-config.toml"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

error() { echo -e "${RED}Error: $1${NC}" >&2; exit 1; }
info() { echo -e "${GREEN}$1${NC}"; }
warn() { echo -e "${YELLOW}$1${NC}"; }

# Check prerequisites
check_prerequisites() {
    if ! command -v gh &> /dev/null; then
        error "GitHub CLI (gh) is required but not installed.
Install it from: https://cli.github.com/
  macOS:   brew install gh
  Ubuntu:  sudo apt install gh
  Windows: winget install GitHub.cli"
    fi

    if ! gh auth status &> /dev/null; then
        error "GitHub CLI not authenticated. Run: gh auth login"
    fi
}

# Read base_dir from config or use default
if [ -f "$CONFIG_FILE" ]; then
  BASE_DIR=$(grep 'base_dir' "$CONFIG_FILE" | head -1 | cut -d'"' -f2 | sed "s|~|$HOME|")
  RUNNER_VERSION=$(grep 'runner_version' "$CONFIG_FILE" | head -1 | cut -d'"' -f2)
else
  BASE_DIR="$HOME/actions-runners"
  RUNNER_VERSION="2.321.0"
fi

REPO="$1"
API_KEY="${2:-$ANTHROPIC_API_KEY}"

if [ -z "$REPO" ]; then
  echo "Usage: $0 owner/repo [ANTHROPIC_API_KEY]"
  echo "Example: $0 GiggleLiu/yao-rs"
  echo ""
  echo "Config file: $CONFIG_FILE"
  echo "Base directory: $BASE_DIR"
  exit 1
fi

if [[ ! "$REPO" =~ ^[^/]+/[^/]+$ ]]; then
    error "Invalid repo format. Use: owner/repo"
fi

check_prerequisites

# Derive runner name from repo
REPO_NAME=$(echo "$REPO" | tr '/' '-')
RUNNER_DIR="$BASE_DIR/$REPO_NAME"

echo "Setting up runner for $REPO"
echo "  Directory: $RUNNER_DIR"
echo "  Version: $RUNNER_VERSION"

# Check if already exists
if [ -d "$RUNNER_DIR" ] && [ -f "$RUNNER_DIR/.runner" ]; then
  warn "Runner already exists at $RUNNER_DIR"
  echo "To reconfigure, first remove: rm -rf $RUNNER_DIR"
  exit 1
fi

# Create directory
mkdir -p "$RUNNER_DIR"
cd "$RUNNER_DIR"

# Download runner if not present
if [ ! -f "./config.sh" ]; then
  echo "Downloading runner..."
  ARCH=$(uname -m)
  OS=$(uname -s | tr '[:upper:]' '[:lower:]')
  if [ "$OS" = "darwin" ]; then
    if [ "$ARCH" = "arm64" ]; then
      RUNNER_URL="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-osx-arm64-${RUNNER_VERSION}.tar.gz"
    else
      RUNNER_URL="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-osx-x64-${RUNNER_VERSION}.tar.gz"
    fi
  else
    if [ "$ARCH" = "x86_64" ]; then
      RUNNER_URL="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
    else
      RUNNER_URL="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-arm64-${RUNNER_VERSION}.tar.gz"
    fi
  fi
  if ! curl -sL "$RUNNER_URL" | tar xz; then
    error "Failed to download runner from $RUNNER_URL"
  fi
fi

# Get registration token (requires admin access)
echo "Getting registration token..."
TOKEN=$(gh api "repos/$REPO/actions/runners/registration-token" --method POST --jq '.token' 2>&1)

if [ -z "$TOKEN" ] || [[ "$TOKEN" == *"Must have admin rights"* ]] || [[ "$TOKEN" == *"Not Found"* ]]; then
  # Clean up the directory we created
  cd ..
  rm -rf "$RUNNER_DIR"
  error "Cannot get registration token. This requires admin access to $REPO.

Ask a repo admin to either:
  1. Run this script themselves, or
  2. Give you admin access temporarily, or
  3. Create a registration token manually:
     Settings → Actions → Runners → New self-hosted runner"
fi

# Configure
echo "Configuring runner..."
if ! ./config.sh --url "https://github.com/$REPO" --token "$TOKEN" --unattended --name "$(hostname -s)-${REPO_NAME}" --labels "self-hosted,$(uname -s),$(uname -m)"; then
  error "Failed to configure runner. Check the error above."
fi

# Add API key if provided
if [ -n "$API_KEY" ]; then
  echo "ANTHROPIC_API_KEY=$API_KEY" >> .env
  info "Added API key to .env"
else
  warn "No API key provided. Add it later:"
  echo "  echo 'ANTHROPIC_API_KEY=sk-ant-...' >> $RUNNER_DIR/.env"
fi

# Install and start service
echo "Installing service..."
if ! ./svc.sh install; then
  error "Failed to install service"
fi

if ! ./svc.sh start; then
  error "Failed to start service"
fi

echo ""
info "Runner setup complete for $REPO"
echo "  Directory: $RUNNER_DIR"
echo "  Status: $(./svc.sh status 2>&1 | grep -o 'Started\|Stopped' || echo 'Unknown')"
