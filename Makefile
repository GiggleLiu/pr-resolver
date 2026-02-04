# PR Resolver - GitHub Actions Runner Management
# Config: runner-config.toml (source of truth)

SHELL := /bin/bash
CONFIG_FILE := runner-config.toml
BASE_DIR := $(shell grep 'base_dir' $(CONFIG_FILE) 2>/dev/null | head -1 | cut -d'"' -f2 | sed "s|~|$$HOME|" || echo "$$HOME/actions-runners")
REPOS := $(shell grep -E '^\s*"[^/]+/[^"]+"' $(CONFIG_FILE) 2>/dev/null | tr -d ' ",')

.PHONY: help update status start stop restart list clean init-claude round-trip

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

start:
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
	@if claude plugins list 2>/dev/null | grep -q superpowers; then \
		echo "Superpowers: installed"; \
	else \
		echo "Superpowers: not found, installing..."; \
		claude plugins add anthropics/claude-code-superpowers --yes; \
	fi
	@echo ""
	@echo "Done."

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
	for i in 1 2 3 4 5 6 7 8 9 10; do \
		sleep 3; \
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
	for i in 1 2 3 4 5 6 7 8 9 10; do \
		sleep 3; \
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
