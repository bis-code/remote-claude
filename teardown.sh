#!/usr/bin/env bash
#
# teardown.sh — Reverse everything setup.sh installed
#
# Usage: sudo ./teardown.sh

SSH_BACKUP="/etc/ssh/sshd_config.backup.remote-claude"

# ── Colors ──────────────────────────────────────────────────────────────────

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

# ── Helpers ─────────────────────────────────────────────────────────────────

info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
warn()  { echo -e "${YELLOW}[SKIP]${NC}  $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

# ── Pre-flight ──────────────────────────────────────────────────────────────

if [[ $EUID -ne 0 ]]; then
    error "Please run as root: sudo ./teardown.sh"
    exit 1
fi

# ── Step 1: Confirm ────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}This will remove:${NC}"
echo "  - Claude Code (npm global package)"
echo "  - Node.js (and nodesource repo)"
echo "  - Tailscale"
echo "  - SSH hardening (restore original config)"
echo ""
read -rp "Continue? (y/n) " CONFIRM

if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "Aborted."
    exit 0
fi

echo ""

# ── Step 2: Remove Claude Code ─────────────────────────────────────────────

if command -v claude &>/dev/null; then
    info "Removing Claude Code..."
    npm uninstall -g @anthropic-ai/claude-code 2>/dev/null
    info "Claude Code removed."
else
    warn "Claude Code not installed — skipping."
fi

# ── Step 3: Remove Node.js ─────────────────────────────────────────────────

if command -v node &>/dev/null; then
    info "Removing Node.js..."
    apt-get remove -y --purge nodejs 2>/dev/null
    rm -f /etc/apt/sources.list.d/nodesource.list
    rm -f /etc/apt/keyrings/nodesource.gpg
    apt-get autoremove -y 2>/dev/null
    info "Node.js removed."
else
    warn "Node.js not installed — skipping."
fi

# ── Step 4: Remove Tailscale ──────────────────────────────────────────────

if command -v tailscale &>/dev/null; then
    info "Removing Tailscale..."
    tailscale down 2>/dev/null
    apt-get remove -y --purge tailscale 2>/dev/null
    apt-get autoremove -y 2>/dev/null
    info "Tailscale removed."
else
    warn "Tailscale not installed — skipping."
fi

# ── Step 5: Restore SSH config ────────────────────────────────────────────

if [[ -f "$SSH_BACKUP" ]]; then
    info "Restoring original SSH config from backup..."
    cp "$SSH_BACKUP" /etc/ssh/sshd_config
    rm "$SSH_BACKUP"
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null
    info "SSH config restored."
else
    warn "No SSH backup found at $SSH_BACKUP — skipping."
fi

# ── Step 6: Optionally remove user ────────────────────────────────────────

echo ""
read -rp "Remove a user account too? (y/n) " REMOVE_USER

if [[ "$REMOVE_USER" == "y" || "$REMOVE_USER" == "Y" ]]; then
    read -rp "Username to remove: " DEL_USER

    if [[ -z "$DEL_USER" ]]; then
        error "No username given — skipping."
    elif [[ "$DEL_USER" == "root" ]]; then
        error "Cannot remove root — skipping."
    elif ! id "$DEL_USER" &>/dev/null; then
        error "User '$DEL_USER' does not exist — skipping."
    else
        deluser --remove-home "$DEL_USER" 2>/dev/null
        info "User '$DEL_USER' and home directory removed."
    fi
fi

# ── Step 7: Done ──────────────────────────────────────────────────────────

echo ""
echo -e "${GREEN}${BOLD}Clean. Server is back to fresh state.${NC}"
echo ""
