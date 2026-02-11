# PR Resolver - GitHub Actions Runner Management
# Config: runner-config.toml (source of truth)

SHELL := /bin/bash
CONFIG_FILE := runner-config.toml
BASE_DIR := $(shell grep 'base_dir' $(CONFIG_FILE) 2>/dev/null | head -1 | cut -d'"' -f2 | sed "s|~|$$HOME|" || echo "$$HOME/actions-runners")
REPOS := $(shell grep -E '^\s*"[^/]+/[^"]+"' $(CONFIG_FILE) 2>/dev/null | tr -d ' ",')

.PHONY: help update status start stop restart list clean init-claude init-opencode init-agents setup-key refresh-oauth install-refresh uninstall-refresh sync-workflow round-trip

help:
	@echo "PR Resolver - Runner Management"
	@echo ""
	@echo "Workflow:"
	@echo "  1. Edit runner-config.toml (add/remove repos)"
	@echo "  2. Run: make update"
	@echo ""
	@echo "Commands:"
	@echo "  make update                  # Sync runners with config"
	@echo "  make status                  # Show all runner status"
	@echo "  make start                   # Start all runners"
	@echo "  make stop                    # Stop all runners"
	@echo "  make restart                 # Restart all runners"
	@echo "  make list                    # List configured repos"
	@echo "  make clean                   # Clean caches (saves ~3GB)"
	@echo "  make init-claude             # Install Claude CLI + superpowers"
	@echo "  make init-opencode           # Install OpenCode CLI"
	@echo "  make init-agents             # Install all agent CLIs"
	@echo "  make setup-key KEY=sk-ant-...  # Set API key for all runners"
	@echo "  make refresh-oauth           # Refresh OAuth token file"
	@echo "  make install-refresh         # Auto-refresh OAuth every 6h"
	@echo "  make uninstall-refresh       # Remove auto-refresh"
	@echo "  make sync-workflow           # Install caller workflow to all repos"
	@echo "  make round-trip              # End-to-end test (creates PR, runs [action], [fix])"
	@echo ""
	@echo "Config: $(CONFIG_FILE)"
	@echo "Runners: $(BASE_DIR)"

update:
	@echo "Syncing runners with $(CONFIG_FILE)..."
	@echo ""
	@# Add missing runners
	@for repo in $(REPOS); do \
		REPO_NAME=$$(echo "$$repo" | tr '/' '-'); \
		RUNNER_DIR="$(BASE_DIR)/$$REPO_NAME"; \
		if [ -d "$$RUNNER_DIR" ] && [ -f "$$RUNNER_DIR/.runner" ]; then \
			echo "[skip] $$repo (already exists)"; \
		else \
			echo "[add] $$repo"; \
			./add-repo.sh "$$repo" || true; \
		fi; \
	done
	@echo ""
	@# Remove unlisted runners
	@for dir in $(BASE_DIR)/*/; do \
		if [ -f "$$dir/.runner" ]; then \
			NAME=$$(basename "$$dir"); \
			FOUND=0; \
			for repo in $(REPOS); do \
				REPO_NAME=$$(echo "$$repo" | tr '/' '-'); \
				if [ "$$NAME" = "$$REPO_NAME" ]; then FOUND=1; break; fi; \
			done; \
			if [ $$FOUND -eq 0 ]; then \
				echo "[remove] $$NAME (not in config)"; \
				(cd "$$dir" && ./svc.sh stop 2>/dev/null) || true; \
				(cd "$$dir" && ./svc.sh uninstall 2>/dev/null) || true; \
				rm -rf "$$dir"; \
			fi; \
		fi; \
	done
	@echo ""
	@echo "Done. Run 'make status' to verify."

status:
	@echo "Runner Status ($(BASE_DIR)):"
	@echo ""
	@for dir in $(BASE_DIR)/*/; do \
		if [ -f "$$dir/.runner" ]; then \
			name=$$(basename "$$dir"); \
			status=$$(cd "$$dir" && ./svc.sh status 2>&1 | grep -o 'Started\|Stopped' || echo 'Unknown'); \
			printf "  %-40s %s\n" "$$name" "$$status"; \
		fi \
	done

refresh-oauth:
	@if [ "$$(uname)" = "Darwin" ]; then \
		TOKEN_JSON=$$(security find-generic-password -s "Claude Code-credentials" -a "$$(whoami)" -w 2>/dev/null || echo ""); \
		if [ -n "$$TOKEN_JSON" ]; then \
			ACCESS_TOKEN=$$(echo "$$TOKEN_JSON" | jq -r '.claudeAiOauth.accessToken' 2>/dev/null); \
			EXPIRES_MS=$$(echo "$$TOKEN_JSON" | jq -r '.claudeAiOauth.expiresAt' 2>/dev/null); \
			NOW_MS=$$(($$(date +%s) * 1000)); \
			if [ -n "$$EXPIRES_MS" ] && [ "$$EXPIRES_MS" -le "$$NOW_MS" ] 2>/dev/null; then \
				echo "Token expired, refreshing via claude CLI..."; \
				timeout 30 claude -p "ping" --max-turns 1 > /dev/null 2>&1 || true; \
				TOKEN_JSON=$$(security find-generic-password -s "Claude Code-credentials" -a "$$(whoami)" -w 2>/dev/null || echo ""); \
				ACCESS_TOKEN=$$(echo "$$TOKEN_JSON" | jq -r '.claudeAiOauth.accessToken' 2>/dev/null); \
				EXPIRES_MS=$$(echo "$$TOKEN_JSON" | jq -r '.claudeAiOauth.expiresAt' 2>/dev/null); \
				NOW_MS=$$(($$(date +%s) * 1000)); \
				if [ -n "$$EXPIRES_MS" ] && [ "$$EXPIRES_MS" -le "$$NOW_MS" ] 2>/dev/null; then \
					echo "Error: Token still expired after refresh. Run 'claude' interactively to re-login."; \
					exit 1; \
				fi; \
			fi; \
			if [ -n "$$ACCESS_TOKEN" ] && [ "$$ACCESS_TOKEN" != "null" ]; then \
				echo "$$ACCESS_TOKEN" > "$$HOME/.claude-oauth-token"; \
				chmod 600 "$$HOME/.claude-oauth-token"; \
				echo "OAuth token written to ~/.claude-oauth-token"; \
			else \
				echo "Error: Could not extract token from Keychain"; \
				exit 1; \
			fi; \
		else \
			echo "Error: No Claude credentials in Keychain. Run 'claude' to login first."; \
			exit 1; \
		fi; \
	else \
		echo "Not on macOS - skipping (use credentials file or API key instead)"; \
	fi

REFRESH_LABEL := com.pr-resolver.refresh-oauth
REFRESH_PLIST := $(HOME)/Library/LaunchAgents/$(REFRESH_LABEL).plist

install-refresh:
	@if [ "$$(uname)" = "Darwin" ]; then \
		echo '<?xml version="1.0" encoding="UTF-8"?>' > "$(REFRESH_PLIST)"; \
		echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' >> "$(REFRESH_PLIST)"; \
		echo '<plist version="1.0"><dict>' >> "$(REFRESH_PLIST)"; \
		echo '  <key>Label</key><string>$(REFRESH_LABEL)</string>' >> "$(REFRESH_PLIST)"; \
		echo '  <key>ProgramArguments</key><array>' >> "$(REFRESH_PLIST)"; \
		echo '    <string>/usr/bin/make</string>' >> "$(REFRESH_PLIST)"; \
		echo '    <string>-C</string>' >> "$(REFRESH_PLIST)"; \
		echo '    <string>$(CURDIR)</string>' >> "$(REFRESH_PLIST)"; \
		echo '    <string>refresh-oauth</string>' >> "$(REFRESH_PLIST)"; \
		echo '  </array>' >> "$(REFRESH_PLIST)"; \
		echo '  <key>StartInterval</key><integer>3600</integer>' >> "$(REFRESH_PLIST)"; \
		echo '  <key>RunAtLoad</key><true/>' >> "$(REFRESH_PLIST)"; \
		echo '  <key>StandardOutPath</key><string>/tmp/refresh-oauth.log</string>' >> "$(REFRESH_PLIST)"; \
		echo '  <key>StandardErrorPath</key><string>/tmp/refresh-oauth.log</string>' >> "$(REFRESH_PLIST)"; \
		echo '</dict></plist>' >> "$(REFRESH_PLIST)"; \
		launchctl unload "$(REFRESH_PLIST)" 2>/dev/null || true; \
		launchctl load "$(REFRESH_PLIST)"; \
		echo "LaunchAgent installed: refresh OAuth every hour"; \
		echo ""; \
		HOOK_PATH="$(CURDIR)/pre-job.sh"; \
		for dir in $(BASE_DIR)/*/; do \
			if [ -f "$$dir/.runner" ]; then \
				name=$$(basename "$$dir"); \
				grep -v "ACTIONS_RUNNER_HOOK_JOB_STARTED" "$$dir/.env" > "$$dir/.env.tmp" 2>/dev/null || true; \
				mv "$$dir/.env.tmp" "$$dir/.env"; \
				echo "ACTIONS_RUNNER_HOOK_JOB_STARTED=$$HOOK_PATH" >> "$$dir/.env"; \
				echo "  [hook] $$name"; \
			fi; \
		done; \
		echo ""; \
		echo "Pre-job hook installed for all runners"; \
		echo "Log: /tmp/refresh-oauth.log"; \
	else \
		SCRIPT_PATH="$(CURDIR)/refresh-oauth.sh"; \
		echo '#!/bin/bash' > "$$SCRIPT_PATH"; \
		echo 'cd "$(CURDIR)" && make refresh-oauth' >> "$$SCRIPT_PATH"; \
		chmod +x "$$SCRIPT_PATH"; \
		(crontab -l 2>/dev/null | grep -v "refresh-oauth"; echo "0 */6 * * * $$SCRIPT_PATH >> /tmp/refresh-oauth.log 2>&1") | crontab -; \
		echo "Cron installed: refresh OAuth every 6 hours"; \
	fi

uninstall-refresh:
	@if [ "$$(uname)" = "Darwin" ]; then \
		launchctl unload "$(REFRESH_PLIST)" 2>/dev/null || true; \
		rm -f "$(REFRESH_PLIST)"; \
		echo "LaunchAgent removed"; \
	else \
		crontab -l 2>/dev/null | grep -v "refresh-oauth" | crontab - || true; \
		rm -f "$(CURDIR)/refresh-oauth.sh"; \
		echo "Cron removed"; \
	fi

start: refresh-oauth
	@echo "Starting all runners..."
	@for dir in $(BASE_DIR)/*/; do \
		if [ -f "$$dir/svc.sh" ]; then \
			(cd "$$dir" && ./svc.sh start 2>/dev/null) || true; \
		fi \
	done
	@$(MAKE) -s status

stop:
	@echo "Stopping all runners..."
	@for dir in $(BASE_DIR)/*/; do \
		if [ -f "$$dir/svc.sh" ]; then \
			(cd "$$dir" && ./svc.sh stop 2>/dev/null) || true; \
		fi \
	done

restart: stop start

list:
	@echo "Configured repos:"
	@for repo in $(REPOS); do \
		echo "  $$repo"; \
	done

clean:
	@echo "Cleaning runner caches..."
	@echo "Before: $$(du -sh $(BASE_DIR) | cut -f1)"
	@rm -f $(BASE_DIR)/*/*.tar.gz
	@rm -rf $(BASE_DIR)/*/_work/_update
	@echo "After:  $$(du -sh $(BASE_DIR) | cut -f1)"
	@echo ""
	@echo "Note: _work/_tool/ kept (cached tools). To remove: rm -rf $(BASE_DIR)/*/_work/_tool"

setup-key:
	@if [ -z "$(KEY)" ]; then \
		echo "Error: KEY required"; \
		echo "Usage: make setup-key KEY=sk-ant-..."; \
		exit 1; \
	fi
	@echo "Setting API key for all runners..."
	@for dir in $(BASE_DIR)/*/; do \
		if [ -f "$$dir/.runner" ]; then \
			name=$$(basename "$$dir"); \
			if grep -q "ANTHROPIC_API_KEY" "$$dir/.env" 2>/dev/null; then \
				sed -i.bak "s|^ANTHROPIC_API_KEY=.*|ANTHROPIC_API_KEY=$(KEY)|" "$$dir/.env" && rm -f "$$dir/.env.bak"; \
				echo "  [updated] $$name"; \
			else \
				echo "ANTHROPIC_API_KEY=$(KEY)" >> "$$dir/.env"; \
				echo "  [added] $$name"; \
			fi; \
		fi; \
	done
	@echo "Done. Run 'make restart' to apply."

sync-workflow:
	@echo "Syncing caller workflow to all repos..."
	@WORKFLOW_CONTENT=$$(cat caller-workflow.yml | base64); \
	for repo in $(REPOS); do \
		[ "$$repo" = "GiggleLiu/pr-resolver" ] && echo "  $$repo... [skip: uses reusable workflow directly]" && continue; \
		echo "  $$repo..."; \
		SHA=$$(gh api repos/$$repo/contents/.github/workflows/pr-automation.yml --jq '.sha' 2>/dev/null || echo ""); \
		if [ -n "$$SHA" ]; then \
			gh api -X PUT repos/$$repo/contents/.github/workflows/pr-automation.yml \
				-f message="Switch to reusable workflow from pr-resolver" \
				-f content="$$WORKFLOW_CONTENT" \
				-f sha="$$SHA" \
				--silent 2>/dev/null && echo "    [updated]" || echo "    [failed]"; \
		else \
			gh api -X PUT repos/$$repo/contents/.github/workflows/pr-automation.yml \
				-f message="Add PR automation workflow" \
				-f content="$$WORKFLOW_CONTENT" \
				--silent 2>/dev/null && echo "    [created]" || echo "    [failed]"; \
		fi; \
	done
	@echo "Done."

init-claude:
	@echo "Checking Claude CLI and superpowers setup..."
	@echo ""
	@if command -v claude &> /dev/null; then \
		echo "Claude CLI: $$(claude --version 2>/dev/null || echo 'installed')"; \
	else \
		echo "Claude CLI: not found, installing..."; \
		npm install -g @anthropic-ai/claude-code; \
	fi
	@echo ""
	@if claude plugin list 2>/dev/null | grep -q superpowers; then \
		echo "Superpowers: installed"; \
	else \
		echo "Superpowers: not found, installing..."; \
		claude plugin install anthropics/claude-code-superpowers; \
	fi
	@echo ""
	@echo "Done."

init-opencode:
	@echo "Checking OpenCode CLI setup..."
	@echo ""
	@if command -v opencode &> /dev/null; then \
		echo "OpenCode: $$(opencode --version 2>/dev/null || echo 'installed')"; \
	else \
		echo "OpenCode: not found, installing..."; \
		curl -fsSL https://opencode.ai/install.sh | bash; \
	fi
	@echo ""
	@echo "Done. Run 'opencode' and use /connect to add providers (e.g., Moonshot for Kimi)."

init-agents: init-claude init-opencode
	@echo ""
	@echo "All agents installed."

round-trip:
	@echo "=== Round-trip test ==="
	@BRANCH="test/round-trip-$$(date +%s)"; \
	REPO=$$(gh repo view --json nameWithOwner -q .nameWithOwner); \
	echo ""; \
	echo "Step 1: Create branch and plan file..."; \
	git checkout -b $$BRANCH; \
	mkdir -p docs/plans; \
	echo "# Round-trip Test Plan" > docs/plans/test.md; \
	echo "" >> docs/plans/test.md; \
	echo "Create a file \`test-output.txt\` with content:" >> docs/plans/test.md; \
	echo "\`\`\`" >> docs/plans/test.md; \
	echo "Round-trip test successful!" >> docs/plans/test.md; \
	echo "Timestamp: $$(date)" >> docs/plans/test.md; \
	echo "\`\`\`" >> docs/plans/test.md; \
	git add docs/plans/test.md; \
	git commit -m "Add round-trip test plan"; \
	git push -u origin $$BRANCH; \
	echo ""; \
	echo "Step 2: Create PR..."; \
	PR_URL=$$(gh pr create --title "Round-trip test" --body "Automated test of PR automation pipeline." --head $$BRANCH); \
	PR_NUM=$$(echo $$PR_URL | grep -o '[0-9]*$$'); \
	echo "Created PR #$$PR_NUM"; \
	echo ""; \
	echo "Step 3: Trigger [action]..."; \
	gh pr comment $$PR_NUM --body "[action]"; \
	echo ""; \
	echo "Step 4: Waiting for [action] workflow..."; \
	PREV_RUN=$$(gh run list --workflow=pr-automation.yml --limit 1 --json databaseId -q '.[0].databaseId' 2>/dev/null); \
	for i in 1 2 3 4 5 6; do \
		sleep 10; \
		RUN_ID=$$(gh run list --workflow=pr-automation.yml --limit 1 --json databaseId -q '.[0].databaseId' 2>/dev/null); \
		[ -n "$$RUN_ID" ] && [ "$$RUN_ID" != "$$PREV_RUN" ] && break; \
		echo "  waiting for workflow to start..."; \
	done; \
	if [ -n "$$RUN_ID" ] && [ "$$RUN_ID" != "$$PREV_RUN" ]; then \
		echo "  Workflow: $$RUN_ID"; \
		gh run watch $$RUN_ID --exit-status || echo "  Workflow failed (continuing...)"; \
	else \
		echo "  Warning: Could not find new workflow run"; \
	fi; \
	echo ""; \
	echo "Step 5: Trigger [fix]..."; \
	gh pr comment $$PR_NUM --body "[fix] Clean up the plan file after test."; \
	PREV_RUN=$$RUN_ID; \
	echo ""; \
	echo "Step 6: Waiting for [fix] workflow..."; \
	for i in 1 2 3 4 5 6; do \
		sleep 10; \
		RUN_ID=$$(gh run list --workflow=pr-automation.yml --limit 1 --json databaseId -q '.[0].databaseId' 2>/dev/null); \
		[ -n "$$RUN_ID" ] && [ "$$RUN_ID" != "$$PREV_RUN" ] && break; \
		echo "  waiting for workflow to start..."; \
	done; \
	if [ -n "$$RUN_ID" ] && [ "$$RUN_ID" != "$$PREV_RUN" ]; then \
		echo "  Workflow: $$RUN_ID"; \
		gh run watch $$RUN_ID --exit-status || echo "  Workflow failed (continuing...)"; \
	else \
		echo "  Warning: Could not find new workflow run"; \
	fi; \
	echo ""; \
	echo "Step 7: Close PR..."; \
	gh pr close $$PR_NUM --delete-branch; \
	echo ""; \
	echo "=== Round-trip complete ==="; \
	git checkout main
