# Multi-Agent PR Automation

Support two coding agents: **Claude Code** (native, for Anthropic models) and **OpenCode/Crush** (multi-provider, for Kimi/OpenAI/Gemini/etc). Per-repo configurability with runner-level defaults.

## Config Resolution

```
vars.AGENT_TYPE (per-repo)  ->  runner .env DEFAULT_AGENT  ->  'claude'
vars.AGENT_MODEL (per-repo) ->  agent-specific default
```

Examples:

| Repo | `AGENT_TYPE` | `AGENT_MODEL` | Result |
|------|-------------|---------------|--------|
| GiggleLiu/yao-rs | (unset) | (unset) | Claude Code + opus |
| CodingThrust/dyad | `opencode` | `moonshot/kimi-k2.5` | OpenCode + Kimi K2.5 |
| TensorBFS/omeinsum-rs | `opencode` | `openai/gpt-5-codex` | OpenCode + GPT-5 |

## Agent CLI Mapping

| Agent | Execute command | Auto-approve | Output |
|-------|----------------|-------------|--------|
| `claude` | `claude --dangerously-skip-permissions --model $MODEL --max-turns 500 -p "$PROMPT"` | `--dangerously-skip-permissions` | Streams to stdout |
| `opencode` | `opencode --model $MODEL -p "$PROMPT" -q` | Implicit in `-p` mode | `-q` = final message only |

## Authentication

### Claude Code (unchanged)

- **Self-hosted**: OAuth token file (`~/.claude-oauth-token`) or `ANTHROPIC_API_KEY` in runner `.env`
- **GitHub-hosted**: `ANTHROPIC_API_KEY` repo secret

### OpenCode

- **Self-hosted**: Pre-configured providers via `opencode.json` + API keys in `~/.local/share/opencode/auth.json`. Default provider: Moonshot (Kimi OAuth).
- **GitHub-hosted**: Provider API key passed as secret (e.g., `MOONSHOT_API_KEY`, `OPENAI_API_KEY`), configured via env vars at job time.

OpenCode provider config on self-hosted runner (`~/.config/opencode/opencode.json`):
```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "moonshot": {
      "options": {
        "baseURL": "https://api.moonshot.ai/v1"
      }
    }
  }
}
```

Setup once: `opencode` -> `/connect` -> select Moonshot -> enter API key.

## File Changes

### 1. `run-agent.sh` (new)

Wrapper script that translates agent type + model + prompt into the right CLI invocation.

```bash
#!/bin/bash
# Usage: ./run-agent.sh <agent> <model> <prompt> <output-file>
set -eo pipefail

AGENT="$1"
MODEL="$2"
PROMPT="$3"
OUTPUT="${4:-claude-output.txt}"

case "$AGENT" in
  claude)
    claude --dangerously-skip-permissions \
      --model "${MODEL:-opus}" \
      --max-turns 500 \
      -p "$PROMPT" 2>&1 | tee "$OUTPUT"
    ;;
  opencode)
    opencode --model "${MODEL:-moonshot/kimi-k2.5}" \
      -p "$PROMPT" -q 2>&1 | tee "$OUTPUT"
    ;;
  *)
    echo "Error: Unknown agent '$AGENT'. Supported: claude, opencode"
    exit 1
    ;;
esac
```

Error detection (after the agent exits):
- Claude: check for auth errors, max turns exhaustion
- OpenCode: check for auth errors, empty output

### 2. `pr-automation.yml` changes

**Acquire credentials step**: Add OpenCode credential handling.

```yaml
- name: Acquire credentials
  env:
    AGENT_TYPE: ${{ vars.AGENT_TYPE || 'claude' }}
    ANTHROPIC_API_KEY_SECRET: ${{ secrets.ANTHROPIC_API_KEY }}
    MOONSHOT_API_KEY_SECRET: ${{ secrets.MOONSHOT_API_KEY }}
    OPENAI_API_KEY_SECRET: ${{ secrets.OPENAI_API_KEY }}
  run: |
    case "$AGENT_TYPE" in
      claude)
        # ... existing Claude credential logic (unchanged) ...
        ;;
      opencode)
        # Self-hosted: pre-configured, nothing to do
        # GitHub-hosted: pass API key from secret
        if [ -n "$MOONSHOT_API_KEY_SECRET" ]; then
          echo "MOONSHOT_API_KEY=$MOONSHOT_API_KEY_SECRET" >> $GITHUB_ENV
        elif [ -n "$OPENAI_API_KEY_SECRET" ]; then
          echo "OPENAI_API_KEY=$OPENAI_API_KEY_SECRET" >> $GITHUB_ENV
        fi
        ;;
    esac
```

**Install step** (GitHub-hosted only): Add OpenCode install.

```yaml
- name: Install OpenCode CLI (GitHub-hosted, opencode agent)
  if: vars.RUNNER_TYPE != 'self-hosted' && (vars.AGENT_TYPE || 'claude') == 'opencode'
  run: |
    # Install opencode (Go binary)
    curl -fsSL https://opencode.ai/install.sh | bash
```

**Execute/Fix steps**: Replace inline `claude ...` calls with `run-agent.sh`.

```yaml
- name: Execute plan
  if: needs.setup.outputs.command == 'action'
  env:
    GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
    AGENT_TYPE: ${{ vars.AGENT_TYPE || 'claude' }}
    AGENT_MODEL: ${{ vars.AGENT_MODEL || '' }}
  run: |
    set -eo pipefail
    PROMPT="Execute the plan in '${{ steps.plan.outputs.file }}'.
    ...same prompt content..."

    ./run-agent.sh "$AGENT_TYPE" "$AGENT_MODEL" "$PROMPT" claude-output.txt

    # Error detection
    if grep -qiE "authenticat(e|ion)|unauthorized|forbidden" claude-output.txt; then
      echo "Error: Authentication failure detected"
      exit 1
    fi
```

### 3. `runner-config.toml` changes

Add `default_agent` field:

```toml
[runner]
base_dir = "~/actions-runners"
runner_version = "2.321.0"
default_agent = "claude"  # or "opencode"
repos = [
  "GiggleLiu/pr-resolver",
  ...
]
```

### 4. `Makefile` additions

```makefile
init-opencode:
	@echo "Checking OpenCode CLI setup..."
	@if command -v opencode &> /dev/null; then \
		echo "OpenCode: $$(opencode --version 2>/dev/null || echo 'installed')"; \
	else \
		echo "OpenCode: not found, installing..."; \
		curl -fsSL https://opencode.ai/install.sh | bash; \
	fi
	@echo "Run 'opencode' and use /connect to add providers."

init-agents: init-claude init-opencode
	@echo "All agents installed."
```

### 5. `add-repo.sh` changes

After setting `RUNNER_TYPE`, also offer to set `AGENT_TYPE`:

```bash
# Step 3b: Set AGENT_TYPE variable (if not default)
if [ -n "$AGENT_TYPE_ARG" ]; then
  gh api "repos/$REPO/actions/variables" \
    --method POST \
    -f name="AGENT_TYPE" \
    -f value="$AGENT_TYPE_ARG"
fi
```

## Prompt Differences

Claude Code has superpowers plugin commands (`/subagent-driven-development`, `/systematic-debugging`). These don't exist in OpenCode. The prompts need agent-specific variants:

**Claude prompt** (unchanged):
```
Use /subagent-driven-development to execute tasks
```

**OpenCode prompt** (generic):
```
Execute the tasks step by step. For each task, implement and test before moving on.
```

The `run-agent.sh` script OR the workflow can inject agent-specific prompt fragments.

## Implementation Plan

1. Add `run-agent.sh` wrapper script
2. Update `pr-automation.yml`:
   - Add `AGENT_TYPE` / `AGENT_MODEL` resolution
   - Add OpenCode install step (GitHub-hosted)
   - Add OpenCode credential acquisition
   - Replace `claude ...` calls with `./run-agent.sh`
   - Adjust prompts per agent (no superpowers for opencode)
3. Update `runner-config.toml` schema (add `default_agent`)
4. Add `init-opencode` and `init-agents` Makefile targets
5. Update `add-repo.sh` to accept optional `AGENT_TYPE` arg
6. Update `CLAUDE.md` documentation
7. Test: `make round-trip` with both agent types
