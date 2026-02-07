# Reattach Makefile

PROJECT_ROOT := $(shell pwd)
REATTACHD_PATH := $(PROJECT_ROOT)/reattachd/target/release/reattachd
CLOUDFLARED_PATH := $(shell which cloudflared)
CARGO := $(HOME)/.cargo/bin/cargo
LOG_DIR := $(HOME)/Library/Logs/Reattach
LAUNCH_AGENTS_DIR := $(HOME)/Library/LaunchAgents

# APNs configuration (override in config.local.mk)
APNS_KEY_BASE64 ?=
APNS_KEY_ID ?=
APNS_TEAM_ID ?=
APNS_BUNDLE_ID ?=

# Include local config if exists
-include config.local.mk

.PHONY: all build install uninstall start stop restart reinstall logs clean install-hooks uninstall-hooks

all: build

# Build reattachd
build:
	cd reattachd && $(CARGO) build --release

# Install launchd services
install: build
	@mkdir -p $(LOG_DIR)
	@mkdir -p $(LAUNCH_AGENTS_DIR)
	@sed -e 's|{{REATTACHD_PATH}}|$(REATTACHD_PATH)|g' \
	     -e 's|{{LOG_DIR}}|$(LOG_DIR)|g' \
	     -e 's|{{APNS_KEY_BASE64}}|$(APNS_KEY_BASE64)|g' \
	     -e 's|{{APNS_KEY_ID}}|$(APNS_KEY_ID)|g' \
	     -e 's|{{APNS_TEAM_ID}}|$(APNS_TEAM_ID)|g' \
	     -e 's|{{APNS_BUNDLE_ID}}|$(APNS_BUNDLE_ID)|g' \
	     launchd/com.kumabook.reattachd.plist > $(LAUNCH_AGENTS_DIR)/com.kumabook.reattachd.plist
	@sed -e 's|{{CLOUDFLARED_PATH}}|$(CLOUDFLARED_PATH)|g' \
	     -e 's|{{LOG_DIR}}|$(LOG_DIR)|g' \
	     launchd/com.kumabook.cloudflared-reattach.plist > $(LAUNCH_AGENTS_DIR)/com.kumabook.cloudflared-reattach.plist
	@echo "Installed launchd services"
	@echo "  - $(LAUNCH_AGENTS_DIR)/com.kumabook.reattachd.plist"
	@echo "  - $(LAUNCH_AGENTS_DIR)/com.kumabook.cloudflared-reattach.plist"
	@echo ""
	@echo "Run 'make start' to start services"

# Uninstall launchd services
uninstall: stop
	@rm -f $(LAUNCH_AGENTS_DIR)/com.kumabook.reattachd.plist
	@rm -f $(LAUNCH_AGENTS_DIR)/com.kumabook.cloudflared-reattach.plist
	@echo "Uninstalled launchd services"

# Start services
start:
	@launchctl load $(LAUNCH_AGENTS_DIR)/com.kumabook.reattachd.plist 2>/dev/null || true
	@launchctl load $(LAUNCH_AGENTS_DIR)/com.kumabook.cloudflared-reattach.plist 2>/dev/null || true
	@echo "Started services"

# Stop services
stop:
	@launchctl unload $(LAUNCH_AGENTS_DIR)/com.kumabook.reattachd.plist 2>/dev/null || true
	@launchctl unload $(LAUNCH_AGENTS_DIR)/com.kumabook.cloudflared-reattach.plist 2>/dev/null || true
	@echo "Stopped services"

# Restart services
restart: stop start

reinstall: stop install start

# View logs
logs:
	@echo "=== reattachd logs ==="
	@tail -50 $(LOG_DIR)/reattachd.log 2>/dev/null || echo "No logs yet"
	@echo ""
	@echo "=== reattachd error logs ==="
	@tail -20 $(LOG_DIR)/reattachd.error.log 2>/dev/null || echo "No error logs"
	@echo ""
	@echo "=== cloudflared logs ==="
	@tail -50 $(LOG_DIR)/cloudflared-reattach.log 2>/dev/null || echo "No logs yet"

# Follow logs in real-time
logs-follow:
	@tail -f $(LOG_DIR)/reattachd.log $(LOG_DIR)/cloudflared-reattach.log

# Check service status
status:
	@echo "=== Service Status ==="
	@launchctl list | grep -E "kumabook\.(reattachd|cloudflared)" || echo "No services running"
	@echo ""
	@echo "=== Process Check ==="
	@ps aux | grep -E "(reattachd|cloudflared.*reattach)" | grep -v grep || echo "No processes found"

# Install coding agent hooks (Claude Code + Codex)
install-hooks:
	@reattachd hooks install

# Uninstall coding agent hooks (Claude Code + Codex)
uninstall-hooks:
	@reattachd hooks uninstall

# Clean build artifacts
clean:
	cd reattachd && cargo clean
