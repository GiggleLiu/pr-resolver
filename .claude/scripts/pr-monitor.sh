#!/bin/bash
# PR Monitor - Lightweight daemon script for continuous PR monitoring
# Usage: ./pr-monitor.sh [--once] [--interval SECONDS] [--workspace DIR]
#
# This script monitors PRs and invokes Claude Code when commands are detected.
# Designed to run as a background service or cron job.

set -euo pipefail

# Configuration
WORKSPACE_DIR="."
INTERVAL=1800  # 30 minutes default
RUN_ONCE=false
CONFIG_FILE="${HOME}/.claude/pr-monitor.conf"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --once) RUN_ONCE=true; shift ;;
        --interval) INTERVAL="$2"; shift 2 ;;
        --workspace) WORKSPACE_DIR="$2"; shift 2 ;;
        --config) CONFIG_FILE="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [--once] [--interval SECONDS] [--workspace DIR] [--config FILE]"
            echo ""
            echo "Options:"
            echo "  --once        Run once and exit (for cron)"
            echo "  --interval    Seconds between checks (default: 1800)"
            echo "  --workspace   Root directory to scan for repos (default: .)"
            echo "  --config      Config file path (default: ~/.claude/pr-monitor.conf)"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Load config if exists
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

cd "$WORKSPACE_DIR"
WORKSPACE_DIR="$(pwd)"
LOG_DIR="${WORKSPACE_DIR}/.claude/logs"
mkdir -p "$LOG_DIR"

LOG_FILE="${LOG_DIR}/pr-monitor.log"
STATE_FILE="${LOG_DIR}/pr-monitor.state"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# Find all git repos
find_repos() {
    find "$WORKSPACE_DIR" -maxdepth 2 -type d -name ".git" 2>/dev/null | while read -r gitdir; do
        dirname "$gitdir"
    done
}

# Get last processed timestamp for a PR
get_last_processed() {
    local repo="$1"
    local pr="$2"
    local key="${repo}:${pr}"

    if [ -f "$STATE_FILE" ]; then
        grep "^${key}=" "$STATE_FILE" 2>/dev/null | cut -d= -f2 || echo ""
    fi
}

# Save last processed timestamp
save_last_processed() {
    local repo="$1"
    local pr="$2"
    local timestamp="$3"
    local key="${repo}:${pr}"

    touch "$STATE_FILE"
    if grep -q "^${key}=" "$STATE_FILE" 2>/dev/null; then
        sed -i.bak "s|^${key}=.*|${key}=${timestamp}|" "$STATE_FILE"
    else
        echo "${key}=${timestamp}" >> "$STATE_FILE"
    fi
}

# Check for new commands in PR comments
check_pr_commands() {
    local repo_dir="$1"
    local pr_number="$2"

    cd "$repo_dir"

    local last_processed
    last_processed=$(get_last_processed "$repo_dir" "$pr_number")

    # Get comments with timestamps
    local comments
    comments=$(gh pr view "$pr_number" --json comments \
        --jq '.comments[] | "\(.createdAt)|\(.body | split("\n")[0])"' 2>/dev/null || echo "")

    if [ -z "$comments" ]; then
        return
    fi

    local latest_timestamp=""
    local found_action=false
    local found_fix=false

    while IFS='|' read -r timestamp body; do
        [ -z "$timestamp" ] && continue
        latest_timestamp="$timestamp"

        # Skip if already processed
        if [ -n "$last_processed" ] && [[ "$timestamp" < "$last_processed" || "$timestamp" == "$last_processed" ]]; then
            continue
        fi

        # Check for commands at start of comment
        if [[ "$body" =~ ^\[action\] ]]; then
            found_action=true
        fi
        if [[ "$body" =~ ^\[fix\] ]]; then
            found_fix=true
        fi
    done <<< "$comments"

    # Process found commands
    if $found_action; then
        echo "action"
    fi
    if $found_fix; then
        echo "fix"
    fi

    # Update state
    if [ -n "$latest_timestamp" ]; then
        save_last_processed "$repo_dir" "$pr_number" "$latest_timestamp"
    fi
}

# Process a single PR with Claude
process_pr() {
    local repo_dir="$1"
    local pr_number="$2"
    local pr_branch="$3"
    local command="$4"

    cd "$repo_dir"
    log "Processing PR #${pr_number} in ${repo_dir} - command: [${command}]"

    # Invoke Claude with the pr-executor skill context
    claude --dangerously-skip-permissions --max-turns 100 -p "
You are processing PR #${pr_number} in repository ${repo_dir}.
The PR branch is: ${pr_branch}
Command received: [${command}]

Follow the /pr-executor skill workflow:

$(cat "${WORKSPACE_DIR}/.claude/skills/pr-executor.md" 2>/dev/null || echo "Skill file not found - use default behavior")

Execute the [${command}] command now for PR #${pr_number}.
Remember to:
1. Leave appropriate status comments ([executing]/[fixing])
2. Checkout the PR branch: git checkout ${pr_branch}
3. Make changes and run tests
4. Push and leave completion comments ([done]/[fixed])
"

    log "Completed processing PR #${pr_number} - [${command}]"
}

# Main scan function
scan_prs() {
    log "Starting PR scan..."

    for repo in $(find_repos); do
        [ ! -d "$repo/.git" ] && continue

        cd "$repo"

        # Check if repo has GitHub remote
        if ! gh repo view &>/dev/null 2>&1; then
            continue
        fi

        log "Scanning: $repo"

        # Get open PRs
        local prs
        prs=$(gh pr list --author @me --state open --json number,headRefName 2>/dev/null || echo "[]")

        [ "$prs" = "[]" ] && continue

        echo "$prs" | jq -r '.[] | "\(.number)|\(.headRefName)"' | while IFS='|' read -r number branch; do
            [ -z "$number" ] && continue

            # Check for commands
            local commands
            commands=$(check_pr_commands "$repo" "$number")

            for cmd in $commands; do
                process_pr "$repo" "$number" "$branch" "$cmd"
            done
        done
    done

    log "PR scan complete."
}

# Main loop
main() {
    log "PR Monitor started (workspace: $WORKSPACE_DIR, interval: ${INTERVAL}s)"

    # Verify gh is authenticated
    if ! gh auth status &>/dev/null; then
        log "ERROR: gh CLI not authenticated. Run 'gh auth login'"
        exit 1
    fi

    if $RUN_ONCE; then
        scan_prs
    else
        while true; do
            scan_prs
            log "Sleeping for ${INTERVAL} seconds..."
            sleep "$INTERVAL"
        done
    fi
}

main
