#!/usr/bin/env bash
#
# teardown.sh — Reverse everything setup.sh installed
#
# Usage: sudo ./teardown.sh

set -euo pipefail

SSH_BACKUP="/etc/ssh/sshd_config.backup.remote-claude"

# ── Colors ──────────────────────────────────────────────────────────────────

GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
RED=$'\033[0;31m'
BOLD=$'\033[1m'
NC=$'\033[0m'

# ── Helpers ─────────────────────────────────────────────────────────────────

info()  { printf "%s[INFO]%s  %s\n" "$GREEN" "$NC" "$1"; }
warn()  { printf "%s[SKIP]%s  %s\n" "$YELLOW" "$NC" "$1"; }
error() { printf "%s[ERROR]%s %s\n" "$RED" "$NC" "$1" >&2; }

# ── Pre-flight ──────────────────────────────────────────────────────────────

if [[ $EUID -ne 0 ]]; then
    error "Please run as root: sudo ./teardown.sh"
    exit 1
fi

# ── Step 1: Confirm ────────────────────────────────────────────────────────

echo ""
printf "%sThis will remove:%s\n" "$BOLD" "$NC"
echo "  - Claude Code (npm global package)"
echo "  - Node.js (and nodesource repo)"
echo "  - Tailscale"
echo "  - SSH hardening (restore original config)"
echo ""
read -rp "Continue? (y/n) " CONFIRM || true

if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "Aborted."
    exit 0
fi

echo ""

# ── Step 2: Remove Claude Code ─────────────────────────────────────────────

if command -v claude &>/dev/null; then
    info "Removing Claude Code..."
    npm uninstall -g @anthropic-ai/claude-code 2>/dev/null || true
    info "Claude Code removed."
else
    warn "Claude Code not installed — skipping."
fi

# ── Step 3: Remove Node.js ─────────────────────────────────────────────────

if command -v node &>/dev/null; then
    info "Removing Node.js..."
    apt-get remove -y --purge nodejs 2>/dev/null || true
    rm -f /etc/apt/sources.list.d/nodesource.list
    rm -f /etc/apt/keyrings/nodesource.gpg
    apt-get autoremove -y 2>/dev/null || true
    info "Node.js removed."
else
    warn "Node.js not installed — skipping."
fi

# ── Step 4: Remove Tailscale ──────────────────────────────────────────────

if command -v tailscale &>/dev/null; then
    info "Removing Tailscale..."
    tailscale down 2>/dev/null || true
    apt-get remove -y --purge tailscale 2>/dev/null || true
    apt-get autoremove -y 2>/dev/null || true
    info "Tailscale removed."
else
    warn "Tailscale not installed — skipping."
fi

# ── Step 5: Restore SSH config ────────────────────────────────────────────

if [[ -f "$SSH_BACKUP" ]]; then
    info "Restoring original SSH config from backup..."
    cp "$SSH_BACKUP" /etc/ssh/sshd_config
    rm "$SSH_BACKUP"
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
    info "SSH config restored."
else
    warn "No SSH backup found at $SSH_BACKUP — skipping."
fi

# ── Step 6: Remove passwordless sudo entries ─────────────────────────────

for SUDOER_FILE in /etc/sudoers.d/*; do
    [[ -f "$SUDOER_FILE" ]] || continue
    if grep -q "ALL=(ALL) NOPASSWD:ALL" "$SUDOER_FILE" 2>/dev/null; then
        info "Removing passwordless sudo config: $(basename "$SUDOER_FILE")"
        rm -f "$SUDOER_FILE"
    fi
done

# ── Step 7: Optionally remove user ────────────────────────────────────────

echo ""
read -rp "Remove a user account too? (y/n) " REMOVE_USER || true

if [[ "$REMOVE_USER" == "y" || "$REMOVE_USER" == "Y" ]]; then
    read -rp "Username to remove: " DEL_USER || true

    if [[ -z "$DEL_USER" ]]; then
        error "No username given — skipping."
    elif [[ "$DEL_USER" == "root" ]]; then
        error "Cannot remove root — skipping."
    elif ! id "$DEL_USER" &>/dev/null; then
        error "User '$DEL_USER' does not exist — skipping."
    else
        deluser --remove-home "$DEL_USER" 2>/dev/null || true
        rm -f "/etc/sudoers.d/$DEL_USER"
        info "User '$DEL_USER', home directory, and sudoers entry removed."
    fi
fi

# ── Step 8: Done ──────────────────────────────────────────────────────────

echo ""
printf "%s%sClean. Server is back to fresh state.%s\n" "$GREEN" "$BOLD" "$NC"
echo ""
