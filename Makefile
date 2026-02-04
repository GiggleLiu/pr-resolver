# PR Resolver - GitHub Actions Runner Management
# Usage: make setup REPO=owner/repo ANTHROPIC_API_KEY=sk-ant-...

SHELL := /bin/bash
CONFIG_FILE := runner-config.toml
BASE_DIR := $(shell grep 'base_dir' $(CONFIG_FILE) 2>/dev/null | head -1 | cut -d'"' -f2 | sed "s|~|$$HOME|" || echo "$$HOME/actions-runners")
REPOS := $(shell grep '^\s*repo\s*=' $(CONFIG_FILE) 2>/dev/null | cut -d'"' -f2)

.PHONY: help add-repo setup setup-all status start stop restart remove list migrate clean

help:
	@echo "PR Resolver - Runner Management"
	@echo ""
	@echo "Quick Start:"
	@echo "  make add-repo REPO=owner/repo                # Full setup (workflow + runner + config)"
	@echo ""
	@echo "Manual Setup:"
	@echo "  make setup REPO=owner/repo                   # Setup runner only"
	@echo "  make setup-all ANTHROPIC_API_KEY=...        # Setup all from config"
	@echo ""
	@echo "Runner Management:"
	@echo "  make status                                  # Show all runner status"
	@echo "  make start                                   # Start all runners"
	@echo "  make stop                                    # Stop all runners"
	@echo "  make restart                                 # Restart all runners"
	@echo "  make remove REPO=owner/repo [KEEP_DATA=1]   # Remove a runner"
	@echo "  make list                                    # List configured repos"
	@echo "  make clean                                   # Clean caches (saves ~3GB)"
	@echo ""
	@echo "Config: $(CONFIG_FILE)"
	@echo "Runners: $(BASE_DIR)"

add-repo:
	@if [ -z "$(REPO)" ]; then \
		echo "Error: REPO required"; \
		echo "Usage: make add-repo REPO=owner/repo ANTHROPIC_API_KEY=sk-ant-..."; \
		exit 1; \
	fi
	./add-repo.sh "$(REPO)" "$(ANTHROPIC_API_KEY)"

setup:
	@if [ -z "$(REPO)" ]; then \
		echo "Error: REPO required"; \
		echo "Usage: make setup REPO=owner/repo ANTHROPIC_API_KEY=sk-ant-..."; \
		exit 1; \
	fi
	./setup-runner.sh "$(REPO)" "$(ANTHROPIC_API_KEY)"

setup-all:
	@if [ -z "$(ANTHROPIC_API_KEY)" ]; then \
		echo "Error: ANTHROPIC_API_KEY required"; \
		echo "Usage: make setup-all ANTHROPIC_API_KEY=sk-ant-..."; \
		exit 1; \
	fi
	@for repo in $(REPOS); do \
		echo ""; \
		echo "=== Setting up $$repo ==="; \
		./setup-runner.sh "$$repo" "$(ANTHROPIC_API_KEY)" || true; \
	done

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

remove:
	@if [ -z "$(REPO)" ]; then \
		echo "Error: REPO required"; \
		echo "Usage: make remove REPO=owner/repo [KEEP_DATA=1]"; \
		echo "  KEEP_DATA=1  Unregister runner but keep directory (.env, logs, etc.)"; \
		exit 1; \
	fi
	@REPO_NAME=$$(echo "$(REPO)" | tr '/' '-'); \
	RUNNER_DIR="$(BASE_DIR)/$$REPO_NAME"; \
	if [ -d "$$RUNNER_DIR" ]; then \
		echo "Stopping runner $$REPO_NAME..."; \
		(cd "$$RUNNER_DIR" && ./svc.sh stop 2>/dev/null) || true; \
		(cd "$$RUNNER_DIR" && ./svc.sh uninstall 2>/dev/null) || true; \
		if [ "$(KEEP_DATA)" = "1" ]; then \
			echo "Unregistered runner (kept directory: $$RUNNER_DIR)"; \
			echo "To re-register: make setup REPO=$(REPO)"; \
		else \
			rm -rf "$$RUNNER_DIR"; \
			echo "Removed $$RUNNER_DIR"; \
		fi \
	else \
		echo "Runner not found: $$RUNNER_DIR"; \
	fi

list:
	@echo "Configured repos:"
	@for repo in $(REPOS); do \
		echo "  $$repo"; \
	done

migrate:
	@echo "Migrating runners to $(BASE_DIR)..."
	@mkdir -p "$(BASE_DIR)"
	@for old_dir in ~/actions-runner ~/actions-runner-*; do \
		if [ -d "$$old_dir" ] && [ -f "$$old_dir/.runner" ]; then \
			name=$$(basename "$$old_dir" | sed 's/^actions-runner-//; s/^actions-runner$$//'); \
			if [ -z "$$name" ]; then \
				name=$$(grep -o '"[^"]*"' "$$old_dir/.runner" | head -1 | tr -d '"' | tr '/' '-'); \
			fi; \
			new_dir="$(BASE_DIR)/$$name"; \
			if [ ! -d "$$new_dir" ]; then \
				echo "  $$old_dir -> $$new_dir"; \
				(cd "$$old_dir" && ./svc.sh stop 2>/dev/null) || true; \
				(cd "$$old_dir" && ./svc.sh uninstall 2>/dev/null) || true; \
				mv "$$old_dir" "$$new_dir"; \
				(cd "$$new_dir" && ./svc.sh install && ./svc.sh start) || true; \
			else \
				echo "  Skipping $$old_dir ($$new_dir exists)"; \
			fi \
		fi \
	done
	@echo "Done. Run 'make status' to verify."

clean:
	@echo "Cleaning runner caches..."
	@echo "Before: $$(du -sh $(BASE_DIR) | cut -f1)"
	@rm -f $(BASE_DIR)/*/*.tar.gz
	@rm -rf $(BASE_DIR)/*/_work/_update
	@echo "After:  $$(du -sh $(BASE_DIR) | cut -f1)"
	@echo ""
	@echo "Note: _work/_tool/ kept (cached tools). To remove: rm -rf $(BASE_DIR)/*/_work/_tool"
