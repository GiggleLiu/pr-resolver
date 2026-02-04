#!/bin/bash
# Setup a self-hosted GitHub Actions runner for a repository
# Usage: ./setup-runner.sh owner/repo [API_KEY]
# Config: runner-config.toml

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/runner-config.toml"

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

# Derive runner name from repo
REPO_NAME=$(echo "$REPO" | tr '/' '-')
RUNNER_DIR="$BASE_DIR/$REPO_NAME"

echo "Setting up runner for $REPO"
echo "  Directory: $RUNNER_DIR"
echo "  Version: $RUNNER_VERSION"

# Check if already exists
if [ -d "$RUNNER_DIR" ] && [ -f "$RUNNER_DIR/.runner" ]; then
  echo "Runner already exists at $RUNNER_DIR"
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
  curl -sL "$RUNNER_URL" | tar xz
fi

# Get registration token
echo "Getting registration token..."
TOKEN=$(gh api "repos/$REPO/actions/runners/registration-token" --method POST --jq '.token')

# Configure
echo "Configuring runner..."
./config.sh --url "https://github.com/$REPO" --token "$TOKEN" --unattended --name "$(hostname -s)-${REPO_NAME}" --labels "self-hosted,$(uname -s),$(uname -m)"

# Add API key if provided
if [ -n "$API_KEY" ]; then
  echo "ANTHROPIC_API_KEY=$API_KEY" >> .env
  echo "Added API key to .env"
fi

# Install and start service
echo "Installing service..."
./svc.sh install
./svc.sh start

echo ""
echo "✓ Runner setup complete for $REPO"
echo "  Directory: $RUNNER_DIR"
echo "  Status: $(./svc.sh status 2>&1 | grep -o 'Started\|Stopped' || echo 'Unknown')"
