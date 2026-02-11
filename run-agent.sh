#!/bin/bash
# Run an AI coding agent in non-interactive mode.
# Usage: ./run-agent.sh <agent> <model> <prompt> [output-file]
#
# Agents:
#   claude   - Claude Code CLI (Anthropic models)
#   opencode - OpenCode/Crush CLI (multi-provider: Kimi, OpenAI, Gemini, etc.)
#
# Examples:
#   ./run-agent.sh claude opus "Fix the bug" output.txt
#   ./run-agent.sh opencode moonshot/kimi-k2.5 "Explain this code"
#   ./run-agent.sh opencode openai/gpt-5-codex "Refactor the module"

set -o pipefail

AGENT="${1:?Usage: $0 <agent> <model> <prompt> [output-file]}"
MODEL="$2"
PROMPT="${3:?Prompt is required}"
OUTPUT="${4:-claude-output.txt}"

EXIT_CODE=0
case "$AGENT" in
  claude)
    claude --dangerously-skip-permissions \
      --model "${MODEL:-opus}" \
      --max-turns 500 \
      -p "$PROMPT" 2>&1 | tee "$OUTPUT" || EXIT_CODE=$?
    ;;
  opencode)
    opencode --model "${MODEL:-moonshot/kimi-k2.5}" \
      -p "$PROMPT" -q 2>&1 | tee "$OUTPUT" || EXIT_CODE=$?
    ;;
  *)
    echo "Error: Unknown agent '$AGENT'. Supported: claude, opencode" >&2
    exit 1
    ;;
esac

# Post-execution error detection (catches agents that exit 0 despite errors)
if [ -f "$OUTPUT" ] && grep -qiE "authenticat(e|ion)|unauthorized|forbidden|invalid.*key|api.*key.*invalid|API Error: 40[13]" "$OUTPUT"; then
  echo "Error: Authentication failure detected" >&2
  exit 1
fi

if [ "$AGENT" = "claude" ] && [ -f "$OUTPUT" ] && grep -q "Reached max turns" "$OUTPUT"; then
  echo "Error: Claude exhausted max turns without completing" >&2
  exit 1
fi

if [ ! -s "$OUTPUT" ]; then
  echo "Error: Agent produced no output" >&2
  exit 1
fi

exit $EXIT_CODE
