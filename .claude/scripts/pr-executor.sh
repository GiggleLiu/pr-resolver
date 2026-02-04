#!/bin/bash
# PR Executor - Automated PR processing script
# Usage: ./pr-executor.sh [workspace_dir]
#
# This script finds all repos, checks PRs for [action] and [fix] commands,
# and invokes Claude Code to process them.

set -euo pipefail

WORKSPACE_DIR="${1:-.}"
LOG_FILE="${WORKSPACE_DIR}/.claude/pr-executor.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# Find all git repos under workspace
find_repos() {
    find "$WORKSPACE_DIR" -maxdepth 2 -type d -name ".git" 2>/dev/null | while read -r gitdir; do
        dirname "$gitdir"
    done
}

# Check if comment is after the last status comment
is_new_command() {
    local pr_number="$1"
    local command="$2"

    # Get all comments with timestamps
    local comments
    comments=$(gh pr view "$pr_number" --json comments --jq '.comments[] | "\(.createdAt)|\(.body)"' 2>/dev/null || echo "")

    if [ -z "$comments" ]; then
        return 1
    fi

    # Find last status comment timestamp
    local last_status_time=""
    while IFS='|' read -r timestamp body; do
        if echo "$body" | grep -qE '^\[(executing|fixing|done|fixed|waiting)\]'; then
            last_status_time="$timestamp"
        fi
    done <<< "$comments"

    # Check for new command after last status
    while IFS='|' read -r timestamp body; do
        if [ -n "$last_status_time" ] && [[ "$timestamp" < "$last_status_time" ]]; then
            continue
        fi
        if echo "$body" | grep -qE "^\[${command}\]"; then
            return 0
        fi
    done <<< "$comments"

    return 1
}

# Find plan file in repo
find_plan_file() {
    local repo_dir="$1"
    local plan_files=("PLAN.md" "plan.md" ".claude/plan.md" "docs/plan.md")

    for pf in "${plan_files[@]}"; do
        if [ -f "$repo_dir/$pf" ]; then
            echo "$repo_dir/$pf"
            return 0
        fi
    done
    return 1
}

# Process a single PR
process_pr() {
    local repo_dir="$1"
    local pr_number="$2"
    local pr_branch="$3"

    cd "$repo_dir"
    log "Processing PR #$pr_number in $repo_dir"

    # Check for [action] command
    if is_new_command "$pr_number" "action"; then
        log "Found [action] command in PR #$pr_number"

        plan_file=$(find_plan_file "$repo_dir") || plan_file=""

        if [ -n "$plan_file" ]; then
            log "Found plan file: $plan_file"

            # Leave executing comment
            gh pr comment "$pr_number" --body "[executing] Starting plan execution from $plan_file..."

            # Checkout PR branch
            git fetch origin "$pr_branch"
            git checkout "$pr_branch"
            git pull origin "$pr_branch"

            # Execute plan with Claude
            claude --dangerously-skip-permissions --max-turns 100 -p "
Execute the plan in '$plan_file'.

Instructions:
1. Read the plan file carefully
2. Implement each step in order
3. After each significant change, run tests: make test OR cargo test
4. Commit changes with descriptive messages
5. Do NOT push yet - just implement and commit

Use the superpowers:subagent-driven-development skill if the plan has independent tasks.
"

            # Push changes
            git push origin "$pr_branch"

            # Leave done comment
            gh pr comment "$pr_number" --body "[done] Plan execution completed. Changes pushed to branch."
            log "Completed [action] for PR #$pr_number"
        else
            log "No plan file found for PR #$pr_number"
            gh pr comment "$pr_number" --body "[waiting] No plan file found. Please create one of:
- PLAN.md (repo root)
- plan.md (repo root)
- .claude/plan.md
- docs/plan.md

Then comment \`[action]\` again to trigger execution."
        fi
    fi

    # Check for [fix] command
    if is_new_command "$pr_number" "fix"; then
        log "Found [fix] command in PR #$pr_number"

        # Get repo owner/name
        local repo_info
        repo_info=$(gh repo view --json nameWithOwner --jq '.nameWithOwner')

        # Fetch review comments
        local review_comments
        review_comments=$(gh api "repos/$repo_info/pulls/$pr_number/comments" --jq '.[] | "File: \(.path):\(.line)\nComment: \(.body)\n---"' 2>/dev/null || echo "")

        local pr_reviews
        pr_reviews=$(gh api "repos/$repo_info/pulls/$pr_number/reviews" --jq '.[] | select(.body != "") | "Reviewer: \(.user.login) (\(.state))\nFeedback: \(.body)\n---"' 2>/dev/null || echo "")

        if [ -z "$review_comments" ] && [ -z "$pr_reviews" ]; then
            gh pr comment "$pr_number" --body "[fixed] No review comments found to address."
            log "No review comments for PR #$pr_number"
        else
            # Leave fixing comment
            gh pr comment "$pr_number" --body "[fixing] Addressing review comments..."

            # Checkout PR branch
            git fetch origin "$pr_branch"
            git checkout "$pr_branch"
            git pull origin "$pr_branch"

            # Create temp file with review comments
            local comments_file
            comments_file=$(mktemp)
            echo "=== Inline Review Comments ===" > "$comments_file"
            echo "$review_comments" >> "$comments_file"
            echo "" >> "$comments_file"
            echo "=== PR Reviews ===" >> "$comments_file"
            echo "$pr_reviews" >> "$comments_file"

            # Execute fixes with Claude
            claude --dangerously-skip-permissions --max-turns 50 -p "
Address the following PR review comments:

$(cat "$comments_file")

Instructions:
1. Read each comment and understand what change is requested
2. Make the requested changes to the code
3. If a comment is a question, improve the code or add clarifying comments
4. Run tests after changes: make test OR cargo test
5. Commit with message: 'Address PR review comments'
"

            rm -f "$comments_file"

            # Push changes
            git push origin "$pr_branch"

            # Leave fixed comment
            gh pr comment "$pr_number" --body "[fixed] Review comments addressed. Please re-review."
            log "Completed [fix] for PR #$pr_number"
        fi
    fi
}

# Main execution
main() {
    log "Starting PR executor scan..."

    # Ensure gh is authenticated
    if ! gh auth status &>/dev/null; then
        log "ERROR: gh CLI not authenticated. Run 'gh auth login' first."
        exit 1
    fi

    # Process each repo
    for repo in $(find_repos); do
        if [ ! -d "$repo/.git" ]; then
            continue
        fi

        cd "$repo"
        log "Checking repo: $repo"

        # Get open PRs authored by current user
        local prs
        prs=$(gh pr list --author @me --state open --json number,headRefName 2>/dev/null || echo "[]")

        if [ "$prs" = "[]" ] || [ -z "$prs" ]; then
            log "No open PRs in $repo"
            continue
        fi

        # Process each PR
        echo "$prs" | jq -r '.[] | "\(.number)|\(.headRefName)"' | while IFS='|' read -r number branch; do
            process_pr "$repo" "$number" "$branch"
        done
    done

    log "PR executor scan complete."
}

main "$@"
