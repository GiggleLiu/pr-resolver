# PR Automation

**Let Claude implement your plans.** Write a plan, open a PR, comment `[action]` — Claude executes it.

This is plan-driven development: you think, Claude codes.

## The Workflow

```
 You                                    Claude
  │                                       │
  │  1. Write plan (docs/plans/*.md)      │
  │  2. Open PR                           │
  │  3. Comment [action] ──────────────►  │
  │                                       │  4. Read plan
  │                                       │  5. Implement
  │                                       │  6. Commit & push
  │  7. Review changes  ◄──────────────   │
  │  8. Comment [fix] ─────────────────►  │
  │                                       │  9. Address feedback
  │  10. Merge ✓                          │
```

**That's it.** No context switching. No copy-pasting. Just review and merge.

## Quick Start

### 1. Add the workflow to your repo

```bash
mkdir -p .github/workflows
curl -o .github/workflows/pr-automation.yml \
  https://raw.githubusercontent.com/GiggleLiu/pr-resolver/main/.github/workflows/pr-automation.yml
git add .github/workflows && git commit -m "Add PR automation" && git push
```

### 2. Setup a runner

The workflow needs a GitHub Actions runner. Choose one:

| Option | Best for | Setup time |
|--------|----------|------------|
| **Self-hosted** | Daily use, fast execution | 5 min |
| **GitHub-hosted** | Occasional use, no local setup | 2 min |

#### Self-hosted (recommended)

```bash
# Get setup script
curl -O https://raw.githubusercontent.com/GiggleLiu/pr-resolver/main/.claude/setup-runner.sh
chmod +x setup-runner.sh

# Run it (get token from: Settings → Actions → Runners → New)
export ANTHROPIC_API_KEY="sk-ant-..."
./setup-runner.sh your-username/your-repo
```

#### GitHub-hosted

1. Edit `.github/workflows/pr-automation.yml`:
   ```yaml
   runs-on: ubuntu-latest  # was: self-hosted
   ```
2. Add `ANTHROPIC_API_KEY` to repo secrets (Settings → Secrets → Actions)

### 3. Try it

1. Create `docs/plans/test.md`:
   ```markdown
   # Test Plan
   1. Create a file `hello.txt` with content "Hello from Claude"
   2. Commit with message "Add hello.txt"
   ```
2. Open a PR with this file
3. Comment `[action]`
4. Watch Claude work (check the Actions tab)

## Commands

Comment these on any PR:

| Command | What happens |
|---------|--------------|
| `[action]` | Execute the plan file |
| `[fix]` | Address review comments |
| `[debug]` | Test the pipeline (creates a test comment) |

## Plan Files

Plans are detected in this order:
- `PLAN.md`
- `plan.md`
- `.claude/plan.md`
- `docs/plan.md`
- `docs/plans/*.md` (most recent)

## Writing Good Plans

A plan should be **specific and sequential**:

```markdown
# Add User Authentication

## Steps

1. Create `src/auth.py` with a `login(username, password)` function
   - Hash password with bcrypt
   - Return JWT token on success
   - Raise AuthError on failure

2. Add route in `src/routes.py`:
   - POST /login → call auth.login()
   - Return {"token": ...} or 401

3. Add tests in `tests/test_auth.py`:
   - test_login_success
   - test_login_wrong_password
   - test_login_unknown_user
```

**Tips:**
- Be explicit about file paths
- Include expected behavior
- Break large changes into numbered steps
- Reference existing code patterns when relevant

## Managing Multiple Repos

For teams managing many repos, use the runner management tools:

```bash
# Clone this repo for the tools
git clone https://github.com/GiggleLiu/pr-resolver.git
cd pr-resolver/.claude

# Edit config to add your repos
vi runner-config.toml

# Setup all runners at once
make -f runners.mk setup-all ANTHROPIC_API_KEY="sk-ant-..."

# Manage runners
make -f runners.mk status   # Check all
make -f runners.mk restart  # Restart all
make -f runners.mk stop     # Stop all
```

Configuration (`runner-config.toml`):
```toml
[runner]
base_dir = "~/actions-runners"

[[repos]]
repo = "your-org/repo1"

[[repos]]
repo = "your-org/repo2"
```

## How It Works

```
GitHub PR Comment
       │
       ▼
GitHub Actions ──► Self-hosted Runner ──► Claude CLI
       │                                      │
       │                                      ▼
       │                              Read plan, implement,
       │                              commit, push
       │                                      │
       └──── Status Check (✓/✗) ◄─────────────┘
```

1. You comment `[action]` on a PR
2. GitHub triggers the workflow
3. Runner executes Claude with the plan
4. Claude reads plan, writes code, commits, pushes
5. Workflow reports success/failure as PR status check

## Requirements

- [Anthropic API key](https://console.anthropic.com/) (for Claude)
- [GitHub CLI](https://cli.github.com/) (`gh`) - for runner setup
- macOS, Linux, or Windows with bash

## Troubleshooting

### Runner shows "offline"
```bash
cd ~/actions-runners/your-repo
./svc.sh status  # Check if running
./svc.sh start   # Start if stopped
```

### "Invalid API key" error
```bash
# Check .env has the key
cat ~/actions-runners/your-repo/.env

# Add if missing
echo "ANTHROPIC_API_KEY=sk-ant-..." >> ~/actions-runners/your-repo/.env
./svc.sh restart
```

### Workflow not triggering
- Ensure workflow file is on the **default branch** (usually `main`)
- Check Actions tab for any errors
- Verify your comment starts with `[action]` (case-sensitive)

## License

MIT
