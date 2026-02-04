---
name: pr-executor
description: Check pending PRs across all repos, execute plans on [action] command, fix issues on [fix] command
---

# PR Executor Skill

Automatically process pending PRs across all repositories under the current folder.

## Workflow Overview

1. Discover all git repositories under current folder
2. For each repo, find open PRs authored by current user
3. Process commands in PR comments:
   - `[action]` - Execute the plan file
   - `[fix]` - Address PR review comments

**Approach:** Use the **subagent-driven-development** superpower when executing plans: read the plan, extract tasks, dispatch a fresh subagent per task, and run two-stage review (spec compliance then code quality) after each task. Do not execute the whole plan in one monolithic pass.

## Execution Steps

### Step 1: Discover Repositories

Find all git repos under the current folder:

```bash
find . -maxdepth 2 -type d -name ".git" | xargs -I {} dirname {}
```

### Step 2: For Each Repository

For each repo, get open PRs:

```bash
cd <repo> && gh pr list --author @me --state open --json number,title,headRefName
```

### Step 3: Process Each PR

For each PR, fetch comments and check for actionable commands:

```bash
gh pr view <number> --json comments --jq '.comments[] | "\(.createdAt) \(.body)"'
```

#### Command Detection Logic

1. Find the last `[executing]` or `[fixing]` comment timestamp
2. Check comments AFTER that timestamp for new commands
3. A command is valid only if it appears at the **beginning** of a comment body

### Step 4: Handle [action] Command

When `[action]` is found in a new comment:

1. **Check for plan file** in the repo:
   - Look for: `PLAN.md`, `plan.md`, `.claude/plan.md`, or `docs/plan.md`

2. **If plan file exists:**
   ```bash
   # Leave executing comment
   gh pr comment <number> --body "[executing] Starting plan execution..."
   ```

   Then execute the plan using the **subagent-driven-development** superpower:
   - Read the plan file and use the subagent-driven-development skill (do not use a single Task with a generic "execute the plan" prompt).
   - Extract tasks from the plan, create a TodoWrite, and dispatch a **fresh subagent per task**.
   - After each task: run spec-compliance review, then code-quality review; fix and re-review until approved before moving to the next task.
   - When all tasks are done, run a final code review and use finishing-a-development-branch if appropriate.

   After completion:
   ```bash
   # Push changes
   git push

   # Update PR description if needed
   gh pr edit <number> --body "..."

   # Leave done comment
   gh pr comment <number> --body "[done] Plan execution completed. Changes pushed."
   ```

3. **If NO plan file:**
   ```bash
   gh pr comment <number> --body "[waiting] No plan file found. Please create one of:
   - PLAN.md (repo root)
   - plan.md (repo root)
   - .claude/plan.md
   - docs/plan.md

   Then comment [action] again to trigger execution."
   ```

### Step 5: Handle [fix] Command

When `[fix]` is found in a new comment:

1. **Fetch all review comments:**
   ```bash
   # Get PR review comments (inline code comments)
   gh api repos/{owner}/{repo}/pulls/<number>/comments --jq '.[] | {path: .path, line: .line, body: .body}'

   # Get PR reviews with body
   gh api repos/{owner}/{repo}/pulls/<number>/reviews --jq '.[] | select(.body != "") | {user: .user.login, state: .state, body: .body}'

   # Get conversation comments
   gh pr view <number> --json comments --jq '.comments[] | {user: .author.login, body: .body}'
   ```

2. **Leave fixing comment:**
   ```bash
   gh pr comment <number> --body "[fixing] Addressing review comments..."
   ```

3. **Use Task tool to address each comment:**
   ```
   Task(subagent_type="general-purpose", prompt="
     Address the following PR review comments:
     <comments>

     For each comment:
     1. Read the file and understand the context
     2. Make the requested changes
     3. If the comment is a question, add a code comment or improve the code to answer it
     4. Run tests to verify changes don't break anything
   ")
   ```

4. **After completion:**
   ```bash
   git add -A && git commit -m "Address PR review comments" && git push
   gh pr comment <number> --body "[fixed] Review comments addressed. Please re-review."
   ```

## Command Reference

| Command | Trigger | Action |
|---------|---------|--------|
| `[action]` | New comment starting with `[action]` | Execute plan file via subagent |
| `[fix]` | New comment starting with `[fix]` | Address all review comments |

## Status Comments

| Status | Meaning |
|--------|---------|
| `[executing]` | Plan execution in progress |
| `[done]` | Plan execution completed |
| `[waiting]` | Waiting for user action (e.g., create plan) |
| `[fixing]` | Addressing review comments |
| `[fixed]` | Review comments addressed |

## Example PR Comment Flow

```
User: [action] Please implement the feature
Bot:  [executing] Starting plan execution...
Bot:  [done] Plan execution completed. Changes pushed.

Reviewer: Please add error handling for edge case X
User: [fix]
Bot:  [fixing] Addressing review comments...
Bot:  [fixed] Review comments addressed. Please re-review.
```

## Headless Mode Execution

To run this skill in fully automated mode:

```bash
claude --dangerously-skip-permissions -p "/pr-executor"
```

Or with a cron job:
```bash
# Check PRs every 30 minutes
*/30 * * * * cd /path/to/workspace && claude --dangerously-skip-permissions --max-turns 50 -p "/pr-executor"
```

## Implementation Notes

- **Plan execution:** Use the subagent-driven-development superpower (fresh subagent per task + two-stage review), not a single monolithic Task.
- Always check for new commands AFTER the last status comment to avoid re-processing
- Use `--json` output from `gh` for reliable parsing
- Verify repo has proper git remote before attempting PR operations
- Handle rate limiting gracefully (GitHub API limits)
