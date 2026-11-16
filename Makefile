CC ?= clang
CFLAGS ?= -Wall -Wextra -Werror -O2
FRAMEWORKS = -framework Foundation -framework AppKit -framework IOKit -lproc
ARCHS ?= -arch arm64 -arch x86_64

SRC = src/touchbar_guard.m
BIN_DIR = bin
BUILD_DIR = build
TARGET = $(BIN_DIR)/touchbar_guard

PLIST_NAME ?= com.github.touchbar_guard.plist
PLIST_SRC = launchd/$(PLIST_NAME)
SERVICE_LABEL ?= com.github.touchbar_guard
LEGACY_LABEL ?= com.yustyna.touchbar_guard
LEGACY_PLIST ?= $(INSTALL_PLIST_DIR)/com.yustyna.touchbar_guard.plist

INSTALL_BIN_DIR ?= /usr/local/bin
INSTALL_PLIST_DIR ?= /Library/LaunchDaemons
LOG_FILE ?= /var/log/touchbar_guard.log

.PHONY: all universal native clean install uninstall status logs test

all: universal

universal: $(TARGET)

$(TARGET): $(SRC)
	@mkdir -p $(BIN_DIR)
	@echo "==> Compiling universal binary (arm64 + x86_64)..."
	$(CC) $(CFLAGS) $(ARCHS) $(FRAMEWORKS) $(SRC) -o $(TARGET)
	@echo "==> Built: $(TARGET)"
	@file $(TARGET)

native:
	@mkdir -p $(BIN_DIR)
	@echo "==> Compiling native architecture binary..."
	$(CC) $(CFLAGS) $(FRAMEWORKS) $(SRC) -o $(TARGET)
	@echo "==> Built: $(TARGET)"
	@file $(TARGET)

clean:
	@echo "==> Cleaning build artifacts..."
	@rm -rf $(BIN_DIR) $(BUILD_DIR)
	@echo "==> Clean complete."

install: $(TARGET)
	@if [ "$$(id -u)" -ne 0 ]; then \
		echo "Error: 'make install' must be run as root (use: sudo make install)"; \
		exit 1; \
	fi
	@echo "==> Stopping existing service if running..."
	@-launchctl bootout system/$(SERVICE_LABEL) 2>/dev/null || true
	@-launchctl unload $(INSTALL_PLIST_DIR)/$(PLIST_NAME) 2>/dev/null || true
	@-launchctl bootout system/$(LEGACY_LABEL) 2>/dev/null || true
	@-launchctl unload $(LEGACY_PLIST) 2>/dev/null || true
	@-rm -f $(LEGACY_PLIST) 2>/dev/null || true
	@-killall touchbar_guard 2>/dev/null || true
	@sleep 1
	@echo "==> Installing binary to $(INSTALL_BIN_DIR)/touchbar_guard..."
	@mkdir -p $(INSTALL_BIN_DIR)
	@cp -f $(TARGET) $(INSTALL_BIN_DIR)/touchbar_guard
	@chown root:wheel $(INSTALL_BIN_DIR)/touchbar_guard
	@chmod 755 $(INSTALL_BIN_DIR)/touchbar_guard
	@echo "==> Installing LaunchDaemon plist to $(INSTALL_PLIST_DIR)/$(PLIST_NAME)..."
	@cp -f $(PLIST_SRC) $(INSTALL_PLIST_DIR)/$(PLIST_NAME)
	@chown root:wheel $(INSTALL_PLIST_DIR)/$(PLIST_NAME)
	@chmod 644 $(INSTALL_PLIST_DIR)/$(PLIST_NAME)
	@echo "==> Initializing log file at $(LOG_FILE)..."
	@touch $(LOG_FILE)
	@chmod 644 $(LOG_FILE)
	@echo "==> Registering and starting daemon via launchd..."
	@launchctl bootstrap system $(INSTALL_PLIST_DIR)/$(PLIST_NAME) 2>/dev/null || launchctl load -w $(INSTALL_PLIST_DIR)/$(PLIST_NAME)
	@sleep 1
	@echo "==> Installation complete! Service status:"
	@$(INSTALL_BIN_DIR)/touchbar_guard --status
	@echo "==> Recent daemon logs:"
	@tail -n 10 $(LOG_FILE) 2>/dev/null || true

uninstall:
	@if [ "$$(id -u)" -ne 0 ]; then \
		echo "Error: 'make uninstall' must be run as root (use: sudo make uninstall)"; \
		exit 1; \
	fi
	@echo "==> Stopping launchd daemon..."
	@-launchctl bootout system/$(SERVICE_LABEL) 2>/dev/null || true
	@-launchctl unload $(INSTALL_PLIST_DIR)/$(PLIST_NAME) 2>/dev/null || true
	@-launchctl bootout system/$(LEGACY_LABEL) 2>/dev/null || true
	@-launchctl unload $(LEGACY_PLIST) 2>/dev/null || true
	@-killall touchbar_guard 2>/dev/null || true
	@echo "==> Removing installed files..."
	@rm -f $(INSTALL_PLIST_DIR)/$(PLIST_NAME)
	@rm -f $(LEGACY_PLIST)
	@rm -f $(INSTALL_BIN_DIR)/touchbar_guard
	@echo "==> Ensuring ControlStrip is thawed (SIGCONT)..."
	@-killall -CONT ControlStrip 2>/dev/null || true
	@echo "==> Uninstall complete."

status:
	@if [ -x $(INSTALL_BIN_DIR)/touchbar_guard ]; then \
		$(INSTALL_BIN_DIR)/touchbar_guard --status; \
	elif [ -x $(TARGET) ]; then \
		$(TARGET) --status; \
	else \
		echo "touchbar_guard binary not found. Run 'make' first."; \
	fi
	@echo ""
	@echo "=== launchd Status ==="
	@launchctl list | grep -E "touchbar_guard|ControlStrip" || echo "No matching launchd job found."

logs:
	@if [ -f $(LOG_FILE) ]; then \
		tail -f $(LOG_FILE); \
	else \
		echo "Log file $(LOG_FILE) does not exist."; \
	fi

test: $(TARGET)
	@echo "==> Testing CLI flags..."
	$(TARGET) --version
	$(TARGET) --help
	$(TARGET) --status
	@echo "==> Testing invalid argument handling (must fail)..."
	@if $(TARGET) --nonexistent-option 2>/dev/null; then \
		echo "Error: Daemon accepted invalid option"; exit 1; \
	else \
		echo "==> Invalid option correctly rejected."; \
	fi
	@echo "==> Testing manual freeze and thaw cycle..."
	$(TARGET) --freeze
	$(TARGET) --status
	$(TARGET) --thaw
	$(TARGET) --status
	@echo "==> All automated tests passed successfully."
