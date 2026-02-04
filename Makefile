# rcode Workspace Makefile
# Scientific computing workspace with PR automation

.PHONY: help setup install-deps webhook-setup webhook-start webhook-stop \
        tunnel-start tunnel-stop services-install services-start services-stop \
        services-status logs logs-webhook logs-tunnel clean-logs test-webhook \
        status

# Default target
help:
	@echo "rcode Workspace Management"
	@echo ""
	@echo "Setup:"
	@echo "  make setup            - Full setup (deps + webhook)"
	@echo "  make install-deps     - Install Python dependencies"
	@echo "  make webhook-setup    - Run webhook setup wizard"
	@echo ""
	@echo "Services (manual):"
	@echo "  make webhook-start    - Start webhook server (foreground)"
	@echo "  make webhook-stop     - Stop webhook server"
	@echo "  make tunnel-start     - Start Cloudflare tunnel (foreground)"
	@echo "  make tunnel-stop      - Stop Cloudflare tunnel"
	@echo ""
	@echo "Services (launchd - auto-start on boot):"
	@echo "  make services-install - Install launchd services"
	@echo "  make services-start   - Start all services"
	@echo "  make services-stop    - Stop all services"
	@echo "  make services-status  - Check service status"
	@echo ""
	@echo "Monitoring:"
	@echo "  make status           - Check webhook health and queue"
	@echo "  make logs             - Tail all logs"
	@echo "  make logs-webhook     - Tail webhook server logs"
	@echo "  make logs-tunnel      - Tail tunnel logs"
	@echo ""
	@echo "Maintenance:"
	@echo "  make clean-logs       - Remove old log files"
	@echo "  make test-webhook     - Test webhook endpoint"

# =============================================================================
# Setup
# =============================================================================

setup: install-deps webhook-setup
	@echo "Setup complete!"

install-deps:
	@echo "Installing Python dependencies..."
	pip3 install -r .claude/webhook/requirements.txt
	@echo "Done."

webhook-setup:
	@echo "Running webhook setup wizard..."
	.claude/scripts/setup-webhook.sh

# =============================================================================
# Manual Service Control
# =============================================================================

webhook-start:
	@echo "Starting webhook server..."
	@cd .claude/webhook && WEBHOOK_CONFIG=config.toml python3 server.py

webhook-stop:
	@echo "Stopping webhook server..."
	@pkill -f "python3.*server.py" || echo "Webhook server not running"

tunnel-start:
	@echo "Starting Cloudflare tunnel..."
	cloudflared tunnel run pr-webhook

tunnel-stop:
	@echo "Stopping Cloudflare tunnel..."
	@pkill -f "cloudflared tunnel run" || echo "Tunnel not running"

# =============================================================================
# Launchd Services (macOS)
# =============================================================================

LAUNCHD_DIR := $(HOME)/Library/LaunchAgents
WEBHOOK_PLIST := com.claude.webhook.plist
TUNNEL_PLIST := com.claude.tunnel.plist

services-install:
	@echo "Installing launchd services..."
	@mkdir -p $(LAUNCHD_DIR)
	@cp .claude/launchd/$(WEBHOOK_PLIST) $(LAUNCHD_DIR)/
	@cp .claude/launchd/$(TUNNEL_PLIST) $(LAUNCHD_DIR)/
	@echo "Services installed. Run 'make services-start' to start them."

services-start: services-install
	@echo "Starting services..."
	@launchctl load $(LAUNCHD_DIR)/$(TUNNEL_PLIST) 2>/dev/null || true
	@launchctl load $(LAUNCHD_DIR)/$(WEBHOOK_PLIST) 2>/dev/null || true
	@sleep 2
	@$(MAKE) services-status

services-stop:
	@echo "Stopping services..."
	@launchctl unload $(LAUNCHD_DIR)/$(WEBHOOK_PLIST) 2>/dev/null || true
	@launchctl unload $(LAUNCHD_DIR)/$(TUNNEL_PLIST) 2>/dev/null || true
	@echo "Services stopped."

services-status:
	@echo "Service status:"
	@echo -n "  Webhook server: "
	@launchctl list | grep -q com.claude.webhook && echo "running" || echo "stopped"
	@echo -n "  Cloudflare tunnel: "
	@launchctl list | grep -q com.claude.tunnel && echo "running" || echo "stopped"

# =============================================================================
# Monitoring
# =============================================================================

status:
	@echo "Checking webhook health..."
	@curl -s http://localhost:8787/health 2>/dev/null | python3 -m json.tool || echo "Webhook server not responding"

logs:
	@echo "Tailing all logs (Ctrl+C to stop)..."
	@tail -f .claude/logs/*.log

logs-webhook:
	@echo "Tailing webhook logs (Ctrl+C to stop)..."
	@tail -f .claude/logs/webhook*.log

logs-tunnel:
	@echo "Tailing tunnel logs (Ctrl+C to stop)..."
	@tail -f .claude/logs/tunnel*.log

# =============================================================================
# Maintenance
# =============================================================================

clean-logs:
	@echo "Removing log files older than 7 days..."
	@find .claude/logs -name "*.log" -mtime +7 -delete 2>/dev/null || true
	@echo "Done."

test-webhook:
	@echo "Testing webhook endpoint..."
	@curl -s -X POST http://localhost:8787/webhook \
		-H "Content-Type: application/json" \
		-H "X-GitHub-Event: ping" \
		-d '{"zen": "test"}' | python3 -m json.tool || echo "Failed to reach webhook"
