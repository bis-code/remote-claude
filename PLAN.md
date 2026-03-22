# remote-claude — Implementation Plan

One script to set up Claude Code on any fresh server. One script to tear it down.

## Context

YouTube video deliverable: "I Built a Remote Claude Code Setup" (idea-0e376dc9).
Open-source repo: `bis-code/remote-claude`.

## Deliverables

### 1. setup.sh

Interactive script that installs Tailscale + Node.js + Claude Code on a fresh Ubuntu server.
Pauses at manual steps with clear instructions.

**Flow:**

| Step | Type | What it does |
|------|------|-------------|
| 1 | AUTO | Detect OS (Ubuntu/Debian required), check sudo/root |
| 2 | AUTO | Create non-root user if running as root (ask for username) |
| 3 | MANUAL (pause) | Instruct user to generate SSH key locally: `ssh-keygen -t ed25519` |
| 4 | MANUAL (pause) | Instruct user to copy key to server: `ssh-copy-id user@server` |
| 5 | AUTO | Backup `/etc/ssh/sshd_config`, harden SSH (disable password auth, disable root login), restart sshd |
| 6 | AUTO | Install Tailscale via official install script |
| 7 | MANUAL (pause) | Run `sudo tailscale up`, user authenticates via URL |
| 8 | MANUAL (pause) | Display Tailscale IP (`tailscale ip -4`), instruct user to save it |
| 9 | AUTO | Install Node.js 22 via nodesource |
| 10 | AUTO | Install Claude Code via npm |
| 11 | MANUAL (pause) | Run `claude`, instruct user to run `/login` and authenticate |
| 12 | PRINT | Summary: "Done. Connect from Termius using Tailscale IP. Run `claude`." |

**Implementation details:**
- Each manual step: print colored instructions, wait for user to press Enter
- Each auto step: print what it's doing, show progress
- Colors: green for AUTO, yellow for MANUAL, red for errors
- Backup SSH config to `/etc/ssh/sshd_config.backup.remote-claude`
- Check if each component already installed (idempotent — skip if present)
- Fail fast on errors with clear message
- No `set -e` — handle errors per-step with meaningful messages
- Log everything to `/var/log/remote-claude-setup.log`

### 2. teardown.sh

Reverses everything setup.sh did.

**Flow:**

| Step | What it does |
|------|-------------|
| 1 | Confirm with user ("This will remove Claude Code, Node.js, Tailscale. Continue? y/n") |
| 2 | Remove Claude Code: `npm uninstall -g @anthropic-ai/claude-code` |
| 3 | Remove Node.js: remove nodesource repo + `apt remove nodejs` |
| 4 | Remove Tailscale: `tailscale down` + remove via package manager |
| 5 | Restore SSH config from backup (if backup exists) + restart sshd |
| 6 | Ask: "Remove user account too? (y/n)" — if yes, remove user + home dir |
| 7 | Print: "Clean. Server is back to fresh state." |

**Implementation details:**
- Each step prints what it's removing
- Skip steps where component isn't installed
- SSH config restored from `/etc/ssh/sshd_config.backup.remote-claude`
- User removal is optional and asked separately

### 3. README.md

**Sections:**
- What this does (1 paragraph)
- Prerequisites (fresh Ubuntu/Debian server, SSH access, Tailscale account, Anthropic account)
- Quick start: `git clone ... && cd remote-claude && sudo ./setup.sh`
- What gets installed (Tailscale, Node.js 22, Claude Code)
- Manual steps explained (SSH key, Tailscale auth, Claude /login)
- Connecting from your device (Termius, any SSH client)
- Teardown: `sudo ./teardown.sh`
- FAQ: "Is this safe to run?" — yes, read the script, it's ~80 lines

## Non-goals

- No Docker
- No dev tools (zsh, tmux, languages)
- No shell customization
- No config files or .env

## Testing

- Test on fresh Ubuntu 24.04 (Hetzner CAX21)
- Verify setup.sh completes cleanly
- Verify teardown.sh restores to fresh state
- Verify idempotency (running setup.sh twice doesn't break anything)

## GitHub

- Repo: `bis-code/remote-claude`
- License: MIT
- Init with git, push to GitHub
