#!/bin/bash
# Add a new repo to PR automation
# Usage: ./add-repo.sh owner/repo [ANTHROPIC_API_KEY] [AGENT_TYPE]

REPO="$1"
API_KEY="$2"
AGENT_TYPE_ARG="$3"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

error() { echo -e "${RED}Error: $1${NC}" >&2; exit 1; }
info() { echo -e "${GREEN}$1${NC}"; }
warn() { echo -e "${YELLOW}$1${NC}"; }

NEEDS_ADMIN=()  # Track what needs admin to do

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

# Validate input
if [ -z "$REPO" ]; then
    echo "Usage: $0 owner/repo [ANTHROPIC_API_KEY] [AGENT_TYPE]"
    echo ""
    echo "Examples:"
    echo "  $0 myorg/myrepo"
    echo "  $0 myorg/myrepo sk-ant-..."
    echo "  $0 myorg/myrepo '' opencode     # Use OpenCode agent (no API key)"
    exit 1
fi

if [[ ! "$REPO" =~ ^[^/]+/[^/]+$ ]]; then
    error "Invalid repo format. Use: owner/repo"
fi

check_prerequisites

info "Adding $REPO to PR automation..."

# Step 1: Check repo exists and we have access
echo ""
echo "Step 1: Verifying repo access..."
if ! gh repo view "$REPO" &> /dev/null; then
    error "Cannot access $REPO. Check the repo exists and you have write access."
fi
info "  Repo accessible"

# Step 2: Add caller workflow file to repo
echo ""
echo "Step 2: Adding caller workflow file..."
CALLER_FILE="$(dirname "$0")/caller-workflow.yml"

if [ ! -f "$CALLER_FILE" ]; then
    error "caller-workflow.yml not found in $(dirname "$0")"
fi

# Check if workflow already exists
if gh api "repos/$REPO/contents/.github/workflows/pr-automation.yml" &> /dev/null; then
    warn "  Workflow file already exists, skipping"
else
    ENCODED=$(base64 < "$CALLER_FILE")
    if gh api "repos/$REPO/contents/.github/workflows/pr-automation.yml" \
        --method PUT \
        -f message="Add PR automation workflow (calls reusable workflow from pr-resolver)" \
        -f content="$ENCODED" > /dev/null 2>&1; then
        info "  Caller workflow added"
    else
        warn "  No write access - cannot add workflow file"
        NEEDS_ADMIN+=("Add workflow: copy caller-workflow.yml to .github/workflows/pr-automation.yml")
    fi
fi

# Step 3: Set RUNNER_TYPE variable
echo ""
echo "Step 3: Setting RUNNER_TYPE variable..."
# Check if variable exists
if gh api "repos/$REPO/actions/variables/RUNNER_TYPE" &> /dev/null 2>&1; then
    warn "  RUNNER_TYPE already set, skipping"
else
    if gh api "repos/$REPO/actions/variables" \
        --method POST \
        -f name="RUNNER_TYPE" \
        -f value="self-hosted" > /dev/null 2>&1; then
        info "  RUNNER_TYPE=self-hosted set"
    else
        warn "  No admin access - cannot set variable"
        NEEDS_ADMIN+=("Set variable: RUNNER_TYPE=self-hosted (Settings → Variables → Actions)")
    fi
fi

# Step 3b: Set AGENT_TYPE variable (if specified)
if [ -n "$AGENT_TYPE_ARG" ]; then
    echo ""
    echo "Step 3b: Setting AGENT_TYPE variable..."
    if gh api "repos/$REPO/actions/variables/AGENT_TYPE" &> /dev/null 2>&1; then
        warn "  AGENT_TYPE already set, skipping"
    else
        if gh api "repos/$REPO/actions/variables" \
            --method POST \
            -f name="AGENT_TYPE" \
            -f value="$AGENT_TYPE_ARG" > /dev/null 2>&1; then
            info "  AGENT_TYPE=$AGENT_TYPE_ARG set"
        else
            warn "  No admin access - cannot set variable"
            NEEDS_ADMIN+=("Set variable: AGENT_TYPE=$AGENT_TYPE_ARG (Settings → Variables → Actions)")
        fi
    fi
fi

# Step 4: Add to runner-config.toml
echo ""
echo "Step 4: Updating runner-config.toml..."
CONFIG_FILE="$(dirname "$0")/runner-config.toml"
if [ -f "$CONFIG_FILE" ]; then
    if grep -q "\"$REPO\"" "$CONFIG_FILE"; then
        warn "  Repo already in config, skipping"
    else
        # Add repo before closing bracket - works on both macOS and Linux
        awk -v repo="$REPO" '/^]$/ && !done {print "  \"" repo "\","; done=1} {print}' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
        info "  Added to config"
    fi
else
    warn "  Config file not found, skipping"
fi

# Step 5: Setup runner
echo ""
echo "Step 5: Setting up self-hosted runner..."
SETUP_SCRIPT="$(dirname "$0")/setup-runner.sh"
if [ -x "$SETUP_SCRIPT" ]; then
    if "$SETUP_SCRIPT" "$REPO" "$API_KEY"; then
        info "  Runner setup complete"
    else
        warn "  Runner setup failed - check error above"
        NEEDS_ADMIN+=("Setup runner: fix the error above and re-run './setup-runner.sh $REPO'")
    fi
else
    error "setup-runner.sh not found or not executable"
fi

# Summary
echo ""
if [ ${#NEEDS_ADMIN[@]} -eq 0 ]; then
    info "Done! $REPO is now configured for PR automation."
    echo ""
    echo "Test it:"
    echo "  1. Create a plan file in the repo (e.g., docs/plans/test.md)"
    echo "  2. Open a PR with the plan"
    echo "  3. Comment [action] on the PR"
else
    warn "Partially complete. Ask a repo admin to:"
    echo ""
    for item in "${NEEDS_ADMIN[@]}"; do
        echo "  - $item"
    done
    echo ""
    echo "Once done, test with [action] comment on a PR."
fi
