#!/bin/bash
# PR Cron - Simple one-shot script for cron jobs
# Usage: Add to crontab: */30 * * * * /path/to/pr-cron.sh /path/to/workspace
#
# This is a minimal wrapper that:
# 1. Finds repos with actionable PRs
# 2. Invokes Claude Code for each one

set -euo pipefail

WORKSPACE="${1:-$(pwd)}"
cd "$WORKSPACE"

LOG_FILE="${WORKSPACE}/.claude/logs/pr-cron-$(date +%Y%m%d).log"
mkdir -p "$(dirname "$LOG_FILE")"

exec >> "$LOG_FILE" 2>&1
echo ""
echo "=========================================="
echo "[$(date)] PR Cron started"
echo "=========================================="

# Verify gh auth
if ! gh auth status &>/dev/null; then
    echo "ERROR: gh not authenticated"
    exit 1
fi

# Find repos
repos=$(find "$WORKSPACE" -maxdepth 2 -type d -name ".git" 2>/dev/null | xargs -I {} dirname {} || true)

for repo in $repos; do
    cd "$repo" || continue

    # Skip if not a GitHub repo
    gh repo view &>/dev/null 2>&1 || continue

    echo "[$(date)] Checking: $repo"

    # Get PRs
    prs=$(gh pr list --author @me --state open --json number,headRefName,comments 2>/dev/null || echo "[]")
    [ "$prs" = "[]" ] && continue

    # Process each PR
    echo "$prs" | jq -c '.[]' | while read -r pr; do
        number=$(echo "$pr" | jq -r '.number')
        branch=$(echo "$pr" | jq -r '.headRefName')

        # Get latest comment body (first line only)
        latest_comment=$(echo "$pr" | jq -r '.comments[-1].body // ""' | head -n1)

        # Check for commands
        if [[ "$latest_comment" =~ ^\[action\] ]]; then
            echo "[$(date)] Found [action] in PR #$number"

            cd "$repo"
            claude --dangerously-skip-permissions --max-turns 80 -p "
Process [action] command for PR #${number} in $(pwd).

1. First, check if a plan file exists (PLAN.md, plan.md, .claude/plan.md, or docs/plan.md)
2. If plan exists:
   - Comment: gh pr comment $number --body '[executing] Starting plan execution...'
   - Checkout branch: git fetch origin $branch && git checkout $branch && git pull
   - Read and execute the plan
   - Run tests (make test or cargo test)
   - Commit changes
   - Push: git push origin $branch
   - Comment: gh pr comment $number --body '[done] Plan executed. Changes pushed.'
3. If no plan:
   - Comment: gh pr comment $number --body '[waiting] No plan file found. Please create PLAN.md and comment [action] again.'
"
        fi

        if [[ "$latest_comment" =~ ^\[fix\] ]]; then
            echo "[$(date)] Found [fix] in PR #$number"

            # Get review comments
            repo_name=$(gh repo view --json nameWithOwner -q '.nameWithOwner')
            review_comments=$(gh api "repos/${repo_name}/pulls/${number}/comments" --jq '.[].body' 2>/dev/null | head -20 || true)
            pr_reviews=$(gh api "repos/${repo_name}/pulls/${number}/reviews" --jq '.[] | select(.body != "") | .body' 2>/dev/null | head -10 || true)

            cd "$repo"
            claude --dangerously-skip-permissions --max-turns 60 -p "
Process [fix] command for PR #${number} in $(pwd).

1. Comment: gh pr comment $number --body '[fixing] Addressing review feedback...'
2. Checkout: git fetch origin $branch && git checkout $branch && git pull
3. Address these review comments:

=== Inline Comments ===
${review_comments:-"(none)"}

=== PR Reviews ===
${pr_reviews:-"(none)"}

4. For each comment, make the requested changes
5. Run tests (make test or cargo test)
6. Commit: git commit -am 'Address PR review feedback'
7. Push: git push origin $branch
8. Comment: gh pr comment $number --body '[fixed] Review feedback addressed.'
"
        fi
    done
done

echo "[$(date)] PR Cron complete"
