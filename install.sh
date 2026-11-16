#!/usr/bin/env bash
# ==============================================================================
# touchbar_guard - Installation Script
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_SRC="${SCRIPT_DIR}/bin/touchbar_guard"
PLIST_SRC="${SCRIPT_DIR}/launchd/com.github.touchbar_guard.plist"
INSTALL_BIN="/usr/local/bin/touchbar_guard"
INSTALL_PLIST="/Library/LaunchDaemons/com.github.touchbar_guard.plist"
SERVICE_LABEL="com.github.touchbar_guard"
LOG_FILE="/var/log/touchbar_guard.log"

echo -e "${BOLD}======================================================${RESET}"
echo -e "${BOLD}     TouchBar Guard Installer (macOS Shield)           ${RESET}"
echo -e "${BOLD}======================================================${RESET}"

# 1. OS & Architecture Check
log_step "Checking System Environment..."
OS_NAME="$(uname -s)"
if [ "$OS_NAME" != "Darwin" ]; then
    log_error "This software is exclusively designed for Apple macOS (Darwin)."
    exit 1
fi

ARCH_NAME="$(uname -m)"
OS_VERSION="$(sw_vers -productVersion)"
log_info "Detected macOS ${OS_VERSION} (${ARCH_NAME})"

if [ "$ARCH_NAME" != "arm64" ] && [ "$ARCH_NAME" != "x86_64" ]; then
    log_error "Unsupported hardware architecture: ${ARCH_NAME}"
    exit 1
fi

# 2. Privilege Escalation Check
if [ "$EUID" -ne 0 ]; then
    log_warn "Installation requires administrative privileges (root/sudo)."
    log_info "Re-running script with sudo..."
    exec sudo "$0" "$@"
fi

# 3. Build Check
log_step "Verifying / Building Binary..."
log_info "Ensuring universal binary is compiled and up to date..."
(cd "$SCRIPT_DIR" && make universal)

# 4. Stop existing instance
log_step "Stopping any running instances..."
launchctl bootout "system/${SERVICE_LABEL}" 2>/dev/null || true
launchctl unload "$INSTALL_PLIST" 2>/dev/null || true
for legacy in /Library/LaunchDaemons/*touchbar_guard*.plist; do
    if [ -f "$legacy" ] && [ "$legacy" != "$INSTALL_PLIST" ]; then
        legacy_label="$(basename "$legacy" .plist)"
        launchctl bootout "system/${legacy_label}" 2>/dev/null || true
        launchctl unload "$legacy" 2>/dev/null || true
        rm -f "$legacy" 2>/dev/null || true
    fi
done
killall touchbar_guard 2>/dev/null || true
sleep 1

# 5. Install Binary
log_step "Installing touchbar_guard binary to ${INSTALL_BIN}..."
mkdir -p "$(dirname "$INSTALL_BIN")"
cp -f "$BIN_SRC" "$INSTALL_BIN"
chown root:wheel "$INSTALL_BIN"
chmod 755 "$INSTALL_BIN"
log_success "Binary installed and permissions set (755 root:wheel)."

# 6. Install LaunchDaemon Plist
log_step "Installing LaunchDaemon plist to ${INSTALL_PLIST}..."
mkdir -p "$(dirname "$INSTALL_PLIST")"
cp -f "$PLIST_SRC" "$INSTALL_PLIST"
chown root:wheel "$INSTALL_PLIST"
chmod 644 "$INSTALL_PLIST"
log_success "LaunchDaemon plist installed (644 root:wheel)."

# 7. Initialize Log File
log_step "Setting up log file at ${LOG_FILE}..."
touch "$LOG_FILE"
chmod 644 "$LOG_FILE"

# 8. Register and Start Service via launchd
log_step "Registering and starting service via launchd..."
if launchctl bootstrap system "$INSTALL_PLIST" 2>/dev/null; then
    log_success "Service successfully registered via launchctl bootstrap."
elif launchctl load -w "$INSTALL_PLIST" 2>/dev/null; then
    log_success "Service successfully loaded via launchctl load."
else
    log_error "Failed to register LaunchDaemon with launchctl."
    exit 1
fi

sleep 1

# 9. Verification
log_step "Verifying Service Status..."
"$INSTALL_BIN" --status || true

echo ""
log_step "Recent Daemon Logs (${LOG_FILE}):"
tail -n 8 "$LOG_FILE" 2>/dev/null || log_warn "No log entries yet."

echo -e "\n${BOLD}${GREEN}✔ TouchBar Guard has been successfully installed and activated!${RESET}\n"
