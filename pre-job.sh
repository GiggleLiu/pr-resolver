#!/bin/bash
# Pre-job hook: refresh OAuth token before every runner job.
# Triggers the refresh LaunchAgent (which has Keychain access)
# and waits for the token file to be updated.

LABEL="com.pr-resolver.refresh-oauth"
TOKEN_FILE="$HOME/.claude-oauth-token"

if [ "$(uname)" != "Darwin" ]; then
  exit 0
fi

BEFORE=$(stat -f %m "$TOKEN_FILE" 2>/dev/null || echo 0)
launchctl kickstart "gui/$(id -u)/$LABEL" 2>/dev/null || exit 0

# Wait up to 10s for the file to be updated
for i in $(seq 1 20); do
  AFTER=$(stat -f %m "$TOKEN_FILE" 2>/dev/null || echo 0)
  [ "$AFTER" -gt "$BEFORE" ] && echo "OAuth token refreshed" && exit 0
  sleep 0.5
done
echo "Warning: OAuth refresh did not complete in time"
