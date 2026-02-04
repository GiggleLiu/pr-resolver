# PR Automation

GitHub Action runner that **uses Claude superpowers to implement your plans.** Write a plan, open a PR, comment `[action]` — Claude executes it.

**Purposes**

- Share Claude Max account to resolve pull requests across multiple repos.
- Enforce superpower subagent-driven development to improve code quality.
- Avoid annoying permission prompts when executing plans in Claude Code.

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
# Clone this repo
git clone https://github.com/GiggleLiu/pr-resolver.git
cd pr-resolver

# Install Claude CLI and superpowers plugin
make init-claude

# Add your repo to config (edit runner-config.toml, add to repos array)

# Sync runners (sets up workflow, runner, and config)
make update

# Set API key for all runners
make setup-key KEY=sk-ant-...
make restart
```

#### GitHub-hosted

Just add `ANTHROPIC_API_KEY` to repo secrets (Settings → Secrets → Actions).

No other setup needed — the workflow defaults to GitHub-hosted runners.

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
| `[fix]` | Address review comments AND fix CI failures |
| `[debug]` | Test the pipeline (creates a test comment) |

## Plan Files

Plans are detected in this order:
- `PLAN.md`
- `plan.md`
- `.claude/plan.md`
- `docs/plan.md`
- `docs/plans/*.md` (most recent)

## Writing Good Plans

**Use `/brainstorm` to write plans.** If you have [superpowers](https://github.com/anthropics/claude-code-superpowers) installed, just tell Claude your idea:

```
/brainstorm add user authentication to the app
```

Claude will ask clarifying questions, explore approaches, and write a detailed plan to `docs/plans/`. This is the recommended way to create plans.

## Managing Multiple Repos

Edit `runner-config.toml` and run `make update`:

```toml
# runner-config.toml
[runner]
base_dir = "~/actions-runners"
repos = [
  "your-org/repo1",
  "your-org/repo2",
]
```

```bash
make update                  # Sync: add missing runners, remove unlisted
make status                  # Check all runner statuses
make start / stop / restart  # Control runners
make setup-key KEY=sk-ant-...  # Set API key for all runners
make init-claude             # Install Claude CLI + superpowers
make round-trip              # End-to-end test
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
make status   # Check all runners
make start    # Start all runners
```

### "Invalid API key" error
```bash
# Set API key for all runners at once
make setup-key KEY=sk-ant-...
make restart
```

### Workflow not triggering
- Ensure workflow file is on the **default branch** (usually `main`)
- Check Actions tab for any errors
- Verify your comment starts with `[action]` (case-sensitive)

## License

MIT
