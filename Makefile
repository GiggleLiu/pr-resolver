# PR Resolver - GitHub Actions Runner Management
# Config: runner-config.toml (source of truth)

SHELL := /bin/bash
CONFIG_FILE := runner-config.toml
BASE_DIR := $(shell grep 'base_dir' $(CONFIG_FILE) 2>/dev/null | head -1 | cut -d'"' -f2 | sed "s|~|$$HOME|" || echo "$$HOME/actions-runners")
REPOS := $(shell grep -E '^\s*"[^/]+/[^"]+"' $(CONFIG_FILE) 2>/dev/null | tr -d ' ",')

.PHONY: help update status start stop restart list clean init-claude

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
