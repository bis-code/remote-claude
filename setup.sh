#!/usr/bin/env bash
#
# setup.sh — Install Tailscale + Node.js + Claude Code on a fresh Ubuntu/Debian server
#
# Usage: sudo ./setup.sh

LOGFILE="/var/log/remote-claude-setup.log"
SSH_BACKUP="/etc/ssh/sshd_config.backup.remote-claude"

# ── Colors ──────────────────────────────────────────────────────────────────

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ── Helpers ─────────────────────────────────────────────────────────────────

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOGFILE"; }

auto_step() {
    local msg="$1"
    echo -e "${GREEN}[AUTO]${NC} ${BOLD}${msg}${NC}"
    log "AUTO: $msg"
}

manual_step() {
    local msg="$1"
    echo -e "${YELLOW}[MANUAL]${NC} ${BOLD}${msg}${NC}"
    log "MANUAL: $msg"
}

error() {
    local msg="$1"
    echo -e "${RED}[ERROR]${NC} ${msg}" >&2
    log "ERROR: $msg"
}

pause() {
    echo ""
    read -rp "    Press Enter when ready to continue..."
    echo ""
}

fail() {
    error "$1"
    exit 1
}

# ── Step 1: Detect OS ──────────────────────────────────────────────────────

auto_step "Detecting OS and checking permissions..."

if [[ ! -f /etc/os-release ]]; then
    fail "Cannot detect OS. /etc/os-release not found."
fi

. /etc/os-release

if [[ "$ID" != "ubuntu" && "$ID" != "debian" ]]; then
    fail "This script requires Ubuntu or Debian. Detected: $ID"
fi

if [[ $EUID -ne 0 ]]; then
    fail "Please run as root: sudo ./setup.sh"
fi

echo "    OS: $PRETTY_NAME"
log "OS: $PRETTY_NAME"

# ── Step 2: Create non-root user ──────────────────────────────────────────

auto_step "Checking for non-root user..."

# If invoked via sudo, SUDO_USER is set
TARGET_USER="${SUDO_USER:-}"

if [[ -z "$TARGET_USER" || "$TARGET_USER" == "root" ]]; then
    echo "    You're running as root without a non-root user."
    read -rp "    Enter username to create (or existing to use): " TARGET_USER

    if [[ -z "$TARGET_USER" ]]; then
        fail "Username cannot be empty."
    fi

    if ! id "$TARGET_USER" &>/dev/null; then
        auto_step "Creating user '$TARGET_USER'..."
        adduser --disabled-password --gecos "" "$TARGET_USER" >> "$LOGFILE" 2>&1 || fail "Failed to create user $TARGET_USER"
        usermod -aG sudo "$TARGET_USER" >> "$LOGFILE" 2>&1
        echo "    User '$TARGET_USER' created and added to sudo group."
    else
        echo "    User '$TARGET_USER' already exists."
    fi
else
    echo "    Using user: $TARGET_USER"
fi

TARGET_HOME=$(eval echo "~$TARGET_USER")
log "Target user: $TARGET_USER, home: $TARGET_HOME"

# ── Step 3: SSH key generation (manual) ───────────────────────────────────

manual_step "Generate an SSH key on your LOCAL machine (not this server)."
echo ""
echo "    On your local machine, run:"
echo -e "    ${BOLD}ssh-keygen -t ed25519${NC}"
echo ""
echo "    Skip this if you already have a key at ~/.ssh/id_ed25519"

pause

# ── Step 4: Copy SSH key to server (manual) ───────────────────────────────

manual_step "Copy your SSH key to this server."
echo ""
echo "    On your local machine, run:"
echo -e "    ${BOLD}ssh-copy-id ${TARGET_USER}@$(hostname -I | awk '{print $1}')${NC}"
echo ""
echo "    This allows passwordless SSH login."

pause

# ── Step 5: Harden SSH ────────────────────────────────────────────────────

auto_step "Hardening SSH configuration..."

if [[ -f /etc/ssh/sshd_config ]]; then
    if [[ ! -f "$SSH_BACKUP" ]]; then
        cp /etc/ssh/sshd_config "$SSH_BACKUP"
        echo "    Backed up sshd_config to $SSH_BACKUP"
        log "Backed up sshd_config"
    else
        echo "    Backup already exists at $SSH_BACKUP"
    fi

    # Apply hardening
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
    sed -i 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config

    systemctl restart sshd >> "$LOGFILE" 2>&1 || systemctl restart ssh >> "$LOGFILE" 2>&1
    echo "    SSH hardened: password auth disabled, root login disabled."
    log "SSH hardened and restarted"
else
    error "sshd_config not found — skipping SSH hardening."
fi

# ── Step 6: Install Tailscale ─────────────────────────────────────────────

auto_step "Installing Tailscale..."

if command -v tailscale &>/dev/null; then
    echo "    Tailscale already installed: $(tailscale version | head -1)"
else
    curl -fsSL https://tailscale.com/install.sh | sh >> "$LOGFILE" 2>&1 || fail "Tailscale installation failed."
    echo "    Tailscale installed."
fi

# ── Step 7: Authenticate Tailscale (manual) ───────────────────────────────

manual_step "Authenticate Tailscale."
echo ""
echo "    Run this command:"
echo -e "    ${BOLD}sudo tailscale up${NC}"
echo ""
echo "    A URL will appear — open it in your browser and sign in"
echo "    to your Tailscale account to authorize this server."

pause

# ── Step 8: Display Tailscale IP (manual) ─────────────────────────────────

manual_step "Save your Tailscale IP and set up your client device."
echo ""

TS_IP=$(tailscale ip -4 2>/dev/null || echo "unknown")
echo -e "    Your Tailscale IP: ${BOLD}${GREEN}${TS_IP}${NC}"
echo ""
echo "    Save this IP — you'll use it to connect."
echo ""
echo "    Now install Tailscale on your phone:"
echo "      iOS:     https://apps.apple.com/app/tailscale/id1470499037"
echo "      Android: https://play.google.com/store/apps/details?id=com.tailscale.ipn"
echo ""
echo "    Sign in with the same Tailscale account. Both devices will"
echo "    be on the same private network — no port forwarding needed."

pause

# ── Step 9: Install Node.js 22 ───────────────────────────────────────────

auto_step "Installing Node.js 22..."

if command -v node &>/dev/null; then
    NODE_VER=$(node --version)
    echo "    Node.js already installed: $NODE_VER"
else
    apt-get update -qq >> "$LOGFILE" 2>&1
    apt-get install -y -qq ca-certificates curl gnupg >> "$LOGFILE" 2>&1

    mkdir -p /etc/apt/keyrings
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg >> "$LOGFILE" 2>&1

    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" \
        > /etc/apt/sources.list.d/nodesource.list

    apt-get update -qq >> "$LOGFILE" 2>&1
    apt-get install -y -qq nodejs >> "$LOGFILE" 2>&1 || fail "Node.js installation failed."
    echo "    Node.js installed: $(node --version)"
fi

# ── Step 10: Install Claude Code ──────────────────────────────────────────

auto_step "Installing Claude Code..."

if command -v claude &>/dev/null; then
    echo "    Claude Code already installed."
else
    npm install -g @anthropic-ai/claude-code >> "$LOGFILE" 2>&1 || fail "Claude Code installation failed."
    echo "    Claude Code installed."
fi

# ── Step 11: Authenticate Claude Code (manual) ───────────────────────────

manual_step "Authenticate Claude Code."
echo ""
echo "    Switch to your user and launch Claude:"
echo -e "    ${BOLD}su - ${TARGET_USER}${NC}"
echo -e "    ${BOLD}claude${NC}"
echo ""
echo "    Inside Claude, type ${BOLD}/login${NC} and press Enter."
echo "    A URL will appear — open it in your browser, sign in to"
echo "    your Anthropic account, and paste the code back here."

pause

# ── Step 12: Summary ─────────────────────────────────────────────────────

echo ""
echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}${BOLD}  Setup complete!${NC}"
echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  Connect from your phone/laptop (with Tailscale running):"
echo ""
echo "    1. Open Termius (or any SSH client)"
echo "    2. Connect to:"
echo -e "       ${BOLD}ssh ${TARGET_USER}@${TS_IP}${NC}"
echo "    3. Run:"
echo -e "       ${BOLD}claude${NC}"
echo ""
echo "  Log file: $LOGFILE"
echo ""

log "Setup complete."
