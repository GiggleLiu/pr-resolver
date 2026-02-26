#!/bin/bash
# Run an AI coding agent in non-interactive mode.
# Usage: ./run-agent.sh <agent> <model> <prompt> [output-file]
#
# Agents:
#   codex    - OpenAI Codex CLI (default)
#   claude   - Claude Code CLI (Anthropic models)
#   opencode - OpenCode/Crush CLI (multi-provider: Kimi, OpenAI, Gemini, etc.)
#
# Examples:
#   ./run-agent.sh codex "" "Fix the bug" output.txt          # uses default model
#   ./run-agent.sh codex o4-mini "Fix the bug" output.txt
#   ./run-agent.sh claude opus "Fix the bug" output.txt
#   ./run-agent.sh opencode moonshotai-cn/kimi-k2.5 "Explain this code"

set -o pipefail

AGENT="${1:?Usage: $0 <agent> <model> <prompt> [output-file]}"
MODEL="$2"
PROMPT="${3:?Prompt is required}"
OUTPUT="${4:-claude-output.txt}"

EXIT_CODE=0
case "$AGENT" in
  codex)
    CODEX_ARGS=(exec --full-auto -c model_reasoning_effort=high)
    [ -n "$MODEL" ] && CODEX_ARGS+=(-m "$MODEL")
    codex "${CODEX_ARGS[@]}" \
      "$PROMPT" 2>&1 | tee "$OUTPUT" || EXIT_CODE=$?
    ;;
  claude)
    claude --dangerously-skip-permissions \
      --model "${MODEL:-opus}" \
      --max-turns 500 \
      -p "$PROMPT" 2>&1 | tee "$OUTPUT" || EXIT_CODE=$?
    ;;
  opencode)
    opencode run -m "${MODEL:-moonshotai-cn/kimi-k2.5}" \
      "$PROMPT" 2>&1 | tee "$OUTPUT" || EXIT_CODE=$?
    ;;
  *)
    echo "Error: Unknown agent '$AGENT'. Supported: codex, claude, opencode" >&2
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
