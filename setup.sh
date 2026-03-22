#!/usr/bin/env bash
#
# setup.sh — Install Tailscale + Node.js + Claude Code on a fresh Ubuntu/Debian server
#
# Usage: sudo ./setup.sh

LOGFILE="/var/log/remote-claude-setup.log"
SSH_BACKUP="/etc/ssh/sshd_config.backup.remote-claude"

# ── Colors ──────────────────────────────────────────────────────────────────

GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
RED=$'\033[0;31m'
BOLD=$'\033[1m'
NC=$'\033[0m'

# ── Helpers ─────────────────────────────────────────────────────────────────

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOGFILE"; }

auto_step() {
    printf "%s[AUTO]%s %s%s%s\n" "$GREEN" "$NC" "$BOLD" "$1" "$NC"
    log "AUTO: $1"
}

manual_step() {
    printf "%s[MANUAL]%s %s%s%s\n" "$YELLOW" "$NC" "$BOLD" "$1" "$NC"
    log "MANUAL: $1"
}

error() {
    printf "%s[ERROR]%s %s\n" "$RED" "$NC" "$1" >&2
    log "ERROR: $1"
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
    echo "    SSH hardening will disable root login, so a non-root user is required."
    echo ""

    while true; do
        read -rp "    Enter username to create (or existing non-root user): " TARGET_USER

        if [[ -z "$TARGET_USER" ]]; then
            error "Username cannot be empty. Try again."
            continue
        fi

        if [[ "$TARGET_USER" == "root" ]]; then
            error "Cannot use 'root' — SSH hardening disables root login. Choose another username."
            continue
        fi

        break
    done

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

# ── Step 3: Generate SSH keypair ──────────────────────────────────────────

auto_step "Generating SSH keypair for ${TARGET_USER}..."

SSH_DIR="${TARGET_HOME}/.ssh"
SSH_KEY="${SSH_DIR}/id_ed25519"

if [[ -f "$SSH_KEY" ]]; then
    echo "    SSH key already exists at $SSH_KEY — skipping."
else
    mkdir -p "$SSH_DIR"

    echo ""
    echo "    Set a passphrase to protect the key (recommended)."
    echo "    Leave empty for no passphrase."
    echo ""
    read -rsp "    Passphrase (or Enter for none): " SSH_PASSPHRASE
    echo ""
    if [[ -n "$SSH_PASSPHRASE" ]]; then
        read -rsp "    Confirm passphrase: " SSH_PASSPHRASE_CONFIRM
        echo ""
        if [[ "$SSH_PASSPHRASE" != "$SSH_PASSPHRASE_CONFIRM" ]]; then
            fail "Passphrases do not match."
        fi
    fi

    ssh-keygen -t ed25519 -f "$SSH_KEY" -N "$SSH_PASSPHRASE" -q
    chown -R "${TARGET_USER}:${TARGET_USER}" "$SSH_DIR"
    chmod 700 "$SSH_DIR"
    chmod 600 "$SSH_KEY"
    chmod 644 "${SSH_KEY}.pub"
    echo "    SSH keypair generated."
fi

# Add public key to authorized_keys
if ! grep -qf "${SSH_KEY}.pub" "${SSH_DIR}/authorized_keys" 2>/dev/null; then
    cat "${SSH_KEY}.pub" >> "${SSH_DIR}/authorized_keys"
    chown "${TARGET_USER}:${TARGET_USER}" "${SSH_DIR}/authorized_keys"
    chmod 600 "${SSH_DIR}/authorized_keys"
    echo "    Public key added to authorized_keys."
fi

log "SSH keypair generated for $TARGET_USER"

# ── Step 4: Save keys to your device (manual) ────────────────────────────

manual_step "Save these keys to your phone (Termius)."
echo ""
printf "    %sPrivate key%s (copy into Termius: Keychain > + > Key > paste):\n" "$BOLD" "$NC"
printf "    %s────────────────────────────────────────%s\n" "$YELLOW" "$NC"
cat "$SSH_KEY"
printf "    %s────────────────────────────────────────%s\n" "$YELLOW" "$NC"
echo ""
printf "    %sPublic key%s (for reference):\n" "$BOLD" "$NC"
printf "    %s────────────────────────────────────────%s\n" "$YELLOW" "$NC"
cat "${SSH_KEY}.pub"
printf "    %s────────────────────────────────────────%s\n" "$YELLOW" "$NC"
echo ""
printf "    %sAfter saving the private key, this will be used to connect.%s\n" "$BOLD" "$NC"

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
printf "    %ssudo tailscale up%s\n" "$BOLD" "$NC"
echo ""
echo "    A URL will appear — open it in your browser and sign in"
echo "    to your Tailscale account to authorize this server."

pause

# ── Step 8: Display Tailscale IP (manual) ─────────────────────────────────

manual_step "Save your Tailscale IP and set up your client device."
echo ""

TS_IP=$(tailscale ip -4 2>/dev/null || echo "unknown")
printf "    Your Tailscale IP: %s%s%s%s\n" "$BOLD" "$GREEN" "$TS_IP" "$NC"
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
printf "    %ssu - %s%s\n" "$BOLD" "$TARGET_USER" "$NC"
printf "    %sclaude%s\n" "$BOLD" "$NC"
echo ""
printf "    Inside Claude, type %s/login%s and press Enter.\n" "$BOLD" "$NC"
echo "    A URL will appear — open it in your browser, sign in to"
echo "    your Anthropic account, and paste the code back here."

pause

# ── Step 12: Summary ─────────────────────────────────────────────────────

echo ""
printf "%s%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n" "$GREEN" "$BOLD" "$NC"
printf "%s%s  Setup complete!%s\n" "$GREEN" "$BOLD" "$NC"
printf "%s%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n" "$GREEN" "$BOLD" "$NC"
echo ""
echo "  Connect from your phone (with Tailscale running):"
echo ""
echo "    1. Open Termius (or any SSH client)"
echo "    2. Connect to:"
printf "       %sssh %s@%s%s\n" "$BOLD" "$TARGET_USER" "$TS_IP" "$NC"
echo "    3. Run:"
printf "       %sclaude%s\n" "$BOLD" "$NC"
echo ""
echo "  Log file: $LOGFILE"
echo ""

log "Setup complete."
