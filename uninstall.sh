#!/usr/bin/env bash
# ==============================================================================
# touchbar_guard - Uninstallation Script
# ==============================================================================
set -euo pipefail

# ANSI Color Codes
BOLD="\033[1m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
BLUE="\033[1;34m"
CYAN="\033[1;36m"
RESET="\033[0m"

log_info()    { echo -e "${BLUE}[INFO]${RESET} $1"; }
log_success() { echo -e "${GREEN}[OK]${RESET}   $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${RESET} $1"; }
log_error()   { echo -e "${RED}[ERROR]${RESET} $1"; }
log_step()    { echo -e "\n${BOLD}${CYAN}==>${RESET} ${BOLD}$1${RESET}"; }

INSTALL_BIN="/usr/local/bin/touchbar_guard"
INSTALL_PLIST="/Library/LaunchDaemons/com.yustyna.touchbar_guard.plist"
SERVICE_LABEL="com.yustyna.touchbar_guard"
LOG_FILE="/var/log/touchbar_guard.log"

echo -e "${BOLD}======================================================${RESET}"
echo -e "${BOLD}     TouchBar Guard Uninstaller                        ${RESET}"
echo -e "${BOLD}======================================================${RESET}"

# Privilege Escalation Check
if [ "$EUID" -ne 0 ]; then
    log_warn "Uninstallation requires administrative privileges (root/sudo)."
    log_info "Re-running script with sudo..."
    exec sudo "$0" "$@"
fi

# 1. Stop and Unregister Service
log_step "Stopping LaunchDaemon..."
launchctl bootout "system/${SERVICE_LABEL}" 2>/dev/null || true
launchctl unload "$INSTALL_PLIST" 2>/dev/null || true
killall touchbar_guard 2>/dev/null || true
log_success "Daemon stopped."

# 2. Safety thaw ControlStrip
log_step "Ensuring ControlStrip is thawed (SIGCONT)..."
killall -CONT ControlStrip 2>/dev/null || true
log_success "ControlStrip thawed."

# 3. Remove Installed Files
log_step "Removing installed files..."
if [ -f "$INSTALL_PLIST" ]; then
    rm -f "$INSTALL_PLIST"
    log_success "Removed ${INSTALL_PLIST}"
fi

if [ -f "$INSTALL_BIN" ]; then
    rm -f "$INSTALL_BIN"
    log_success "Removed ${INSTALL_BIN}"
fi

# Clean up log file if desired
if [ -f "$LOG_FILE" ]; then
    log_info "Log file preserved at ${LOG_FILE}. (You may remove it manually if desired: rm -f ${LOG_FILE})"
fi

echo -e "\n${BOLD}${GREEN}✔ TouchBar Guard has been cleanly uninstalled.${RESET}\n"
