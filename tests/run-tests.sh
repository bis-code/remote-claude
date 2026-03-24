#!/usr/bin/env bash
#
# run-tests.sh — Run all tests for remote-claude scripts inside Docker containers
#
# Usage: ./tests/run-tests.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0

report() {
    local status="$1" name="$2"
    if [[ "$status" == "PASS" ]]; then
        echo -e "  ${GREEN}PASS${NC}  $name"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC}  $name"
        FAIL=$((FAIL + 1))
    fi
}

echo ""
echo -e "${BOLD}Building test images...${NC}"
echo ""

docker build -q -t rc-test-ubuntu -f "$PROJECT_DIR/tests/Dockerfile.ubuntu" "$PROJECT_DIR" > /dev/null 2>&1
docker build -q -t rc-test-alpine -f "$PROJECT_DIR/tests/Dockerfile.alpine" "$PROJECT_DIR" > /dev/null 2>&1

echo -e "${BOLD}Running tests...${NC}"
echo ""

# ── Test: Non-root fails ──────────────────────────────────────────────────

OUTPUT=$(docker run --rm rc-test-ubuntu bash -c \
    'useradd -m testuser 2>/dev/null; su - testuser -c "bash /opt/remote-claude/setup.sh" 2>&1; echo "EXIT:$?"')

if echo "$OUTPUT" | grep -q "Please run as root" && echo "$OUTPUT" | grep -q "EXIT:1"; then
    report "PASS" "setup.sh rejects non-root execution"
else
    report "FAIL" "setup.sh rejects non-root execution"
    echo "    Output: $OUTPUT"
fi

# ── Test: Wrong OS (Alpine) ──────────────────────────────────────────────

OUTPUT=$(docker run --rm rc-test-alpine bash -c \
    '/opt/remote-claude/setup.sh 2>&1; echo "EXIT:$?"')

if echo "$OUTPUT" | grep -q "requires Ubuntu or Debian" && echo "$OUTPUT" | grep -q "EXIT:1"; then
    report "PASS" "setup.sh rejects non-Ubuntu/Debian OS"
else
    report "FAIL" "setup.sh rejects non-Ubuntu/Debian OS"
    echo "    Output: $OUTPUT"
fi

# ── Test: SSH config backup + hardening ──────────────────────────────────

OUTPUT=$(docker run --rm rc-test-ubuntu bash -c '
    export SUDO_USER=testuser
    useradd -m testuser 2>/dev/null
    sed "s/^pause()/pause_disabled()/" /opt/remote-claude/setup.sh > /tmp/setup-auto.sh
    sed -i "1i pause() { return; }" /tmp/setup-auto.sh
    # Stub out curl to skip Tailscale/Node downloads, fake tailscale command
    sed -i "s|curl -fsSL.*tailscale.com.*|echo \"tailscale stubbed\" #|" /tmp/setup-auto.sh
    sed -i "s|curl -fsSL.*nodesource.*|echo \"nodesource stubbed\" #|" /tmp/setup-auto.sh
    echo "#!/bin/bash" > /usr/local/bin/tailscale && echo "echo 100.64.0.1" >> /usr/local/bin/tailscale && chmod +x /usr/local/bin/tailscale
    echo "#!/bin/bash" > /usr/local/bin/claude && chmod +x /usr/local/bin/claude
    chmod +x /tmp/setup-auto.sh
    printf "\n" | timeout 60 bash /tmp/setup-auto.sh 2>&1 || true
    echo "---CHECKS---"
    [ -f /etc/ssh/sshd_config.backup.remote-claude ] && echo "BACKUP:exists" || echo "BACKUP:missing"
    grep "^PasswordAuthentication no" /etc/ssh/sshd_config && echo "PASSAUTH:hardened" || echo "PASSAUTH:not-hardened"
    grep "^PermitRootLogin no" /etc/ssh/sshd_config && echo "ROOTLOGIN:hardened" || echo "ROOTLOGIN:not-hardened"
')

if echo "$OUTPUT" | grep -q "BACKUP:exists" && \
   echo "$OUTPUT" | grep -q "PASSAUTH:hardened" && \
   echo "$OUTPUT" | grep -q "ROOTLOGIN:hardened"; then
    report "PASS" "SSH config backed up and hardened"
else
    report "FAIL" "SSH config backed up and hardened"
    echo "$OUTPUT" | grep -E "(BACKUP|PASSAUTH|ROOTLOGIN|ERROR)" | head -5
fi

# ── Test: SSH keypair auto-generated ──────────────────────────────────────

OUTPUT=$(docker run --rm rc-test-ubuntu bash -c '
    export SUDO_USER=testuser
    useradd -m testuser 2>/dev/null
    sed "s/^pause()/pause_disabled()/" /opt/remote-claude/setup.sh > /tmp/setup-auto.sh
    sed -i "1i pause() { return; }" /tmp/setup-auto.sh
    chmod +x /tmp/setup-auto.sh
    printf "\n" | timeout 30 bash /tmp/setup-auto.sh 2>&1 || true
    echo "---CHECKS---"
    [ -f /home/testuser/.ssh/id_ed25519 ] && echo "PRIVKEY:exists" || echo "PRIVKEY:missing"
    [ -f /home/testuser/.ssh/id_ed25519.pub ] && echo "PUBKEY:exists" || echo "PUBKEY:missing"
    [ -f /home/testuser/.ssh/authorized_keys ] && echo "AUTHKEYS:exists" || echo "AUTHKEYS:missing"
    grep -qf /home/testuser/.ssh/id_ed25519.pub /home/testuser/.ssh/authorized_keys 2>/dev/null && echo "AUTHKEYS:contains-pubkey" || echo "AUTHKEYS:missing-pubkey"
    stat -c "%a" /home/testuser/.ssh 2>/dev/null | grep -q "700" && echo "PERMS-DIR:700" || echo "PERMS-DIR:wrong"
    stat -c "%a" /home/testuser/.ssh/id_ed25519 2>/dev/null | grep -q "600" && echo "PERMS-KEY:600" || echo "PERMS-KEY:wrong"
    stat -c "%U" /home/testuser/.ssh/id_ed25519 2>/dev/null | grep -q "testuser" && echo "OWNER:correct" || echo "OWNER:wrong"
')

if echo "$OUTPUT" | grep -q "PRIVKEY:exists" && \
   echo "$OUTPUT" | grep -q "PUBKEY:exists" && \
   echo "$OUTPUT" | grep -q "AUTHKEYS:contains-pubkey" && \
   echo "$OUTPUT" | grep -q "PERMS-DIR:700" && \
   echo "$OUTPUT" | grep -q "PERMS-KEY:600" && \
   echo "$OUTPUT" | grep -q "OWNER:correct"; then
    report "PASS" "SSH keypair generated with correct permissions and authorized_keys"
else
    report "FAIL" "SSH keypair generated with correct permissions and authorized_keys"
    echo "$OUTPUT" | grep -E "(PRIVKEY|PUBKEY|AUTHKEYS|PERMS|OWNER|ERROR)" | head -10
fi

# ── Test: SSH keypair idempotent (skip if exists) ────────────────────────

OUTPUT=$(docker run --rm rc-test-ubuntu bash -c '
    export SUDO_USER=testuser
    useradd -m testuser 2>/dev/null
    # Create an existing key with known content
    mkdir -p /home/testuser/.ssh
    echo "EXISTING_KEY" > /home/testuser/.ssh/id_ed25519
    chown -R testuser:testuser /home/testuser/.ssh
    sed "s/^pause()/pause_disabled()/" /opt/remote-claude/setup.sh > /tmp/setup-auto.sh
    sed -i "1i pause() { return; }" /tmp/setup-auto.sh
    chmod +x /tmp/setup-auto.sh
    timeout 30 bash /tmp/setup-auto.sh 2>&1 || true
    echo "---CHECKS---"
    cat /home/testuser/.ssh/id_ed25519
')

if echo "$OUTPUT" | grep -q "EXISTING_KEY" && echo "$OUTPUT" | grep -q "already exists"; then
    report "PASS" "SSH keypair not overwritten if already exists"
else
    report "FAIL" "SSH keypair not overwritten if already exists"
    echo "$OUTPUT" | tail -5
fi

# ── Test: User creation ──────────────────────────────────────────────────

OUTPUT=$(docker run --rm rc-test-ubuntu bash -c '
    export SUDO_USER=""
    # Rename pause, prepend no-op pause, leave username read intact
    sed "s/^pause()/pause_disabled()/" /opt/remote-claude/setup.sh > /tmp/setup-auto.sh
    sed -i "1i pause() { return; }" /tmp/setup-auto.sh
    chmod +x /tmp/setup-auto.sh
    printf "claudeuser\n\n" | timeout 30 bash /tmp/setup-auto.sh 2>&1 || true
    echo "---CHECKS---"
    id claudeuser 2>/dev/null && echo "USER:created" || echo "USER:missing"
    groups claudeuser 2>/dev/null | grep -q sudo && echo "SUDO:yes" || echo "SUDO:no"
')

if echo "$OUTPUT" | grep -q "USER:created" && echo "$OUTPUT" | grep -q "SUDO:yes"; then
    report "PASS" "User creation with sudo group"
else
    report "FAIL" "User creation with sudo group"
    echo "$OUTPUT" | grep -E "(USER|SUDO|ERROR)" | head -5
fi

# ── Test: Idempotent SSH backup (don't overwrite existing backup) ────────

OUTPUT=$(docker run --rm rc-test-ubuntu bash -c '
    export SUDO_USER=testuser
    useradd -m testuser 2>/dev/null
    # Create a fake backup with known content
    echo "ORIGINAL_BACKUP" > /etc/ssh/sshd_config.backup.remote-claude
    sed "s/^pause()/pause_disabled()/" /opt/remote-claude/setup.sh > /tmp/setup-auto.sh
    sed -i "1i pause() { return; }" /tmp/setup-auto.sh
    sed -i "s|curl -fsSL.*tailscale.com.*|echo \"stubbed\" #|" /tmp/setup-auto.sh
    sed -i "s|curl -fsSL.*nodesource.*|echo \"stubbed\" #|" /tmp/setup-auto.sh
    echo "#!/bin/bash" > /usr/local/bin/tailscale && echo "echo 100.64.0.1" >> /usr/local/bin/tailscale && chmod +x /usr/local/bin/tailscale
    echo "#!/bin/bash" > /usr/local/bin/claude && chmod +x /usr/local/bin/claude
    chmod +x /tmp/setup-auto.sh
    printf "\n" | timeout 60 bash /tmp/setup-auto.sh 2>&1 || true
    echo "---CHECKS---"
    cat /etc/ssh/sshd_config.backup.remote-claude
')

if echo "$OUTPUT" | grep -q "ORIGINAL_BACKUP"; then
    report "PASS" "SSH backup not overwritten on re-run (idempotent)"
else
    report "FAIL" "SSH backup not overwritten on re-run (idempotent)"
fi

# ── Test: Teardown non-root fails ────────────────────────────────────────

OUTPUT=$(docker run --rm rc-test-ubuntu bash -c \
    'useradd -m testuser 2>/dev/null; su - testuser -c "bash /opt/remote-claude/teardown.sh" 2>&1; echo "EXIT:$?"')

if echo "$OUTPUT" | grep -q "Please run as root" && echo "$OUTPUT" | grep -q "EXIT:1"; then
    report "PASS" "teardown.sh rejects non-root execution"
else
    report "FAIL" "teardown.sh rejects non-root execution"
    echo "    Output: $OUTPUT"
fi

# ── Test: Teardown on clean system (nothing installed) ───────────────────

OUTPUT=$(docker run --rm rc-test-ubuntu bash -c '
    echo "y" | /opt/remote-claude/teardown.sh 2>&1
    echo "EXIT:$?"
')

if echo "$OUTPUT" | grep -q "not installed" && echo "$OUTPUT" | grep -q "EXIT:0"; then
    report "PASS" "teardown.sh skips gracefully on clean system"
else
    report "FAIL" "teardown.sh skips gracefully on clean system"
    echo "$OUTPUT" | tail -10
fi

# ── Test: Teardown restores SSH config ───────────────────────────────────

OUTPUT=$(docker run --rm rc-test-ubuntu bash -c '
    # Create a backup to restore
    echo "PasswordAuthentication yes" > /etc/ssh/sshd_config.backup.remote-claude
    echo "PermitRootLogin yes" >> /etc/ssh/sshd_config.backup.remote-claude
    # Harden current config (simulating post-setup state)
    echo "PasswordAuthentication no" > /etc/ssh/sshd_config
    echo "PermitRootLogin no" >> /etc/ssh/sshd_config
    # Run teardown with "y" for confirm, "n" for user removal
    printf "y\nn\n" | /opt/remote-claude/teardown.sh 2>&1
    echo "---CHECKS---"
    grep "PasswordAuthentication yes" /etc/ssh/sshd_config && echo "RESTORED:yes" || echo "RESTORED:no"
    [ -f /etc/ssh/sshd_config.backup.remote-claude ] && echo "BACKUP:remains" || echo "BACKUP:cleaned"
')

if echo "$OUTPUT" | grep -q "RESTORED:yes" && echo "$OUTPUT" | grep -q "BACKUP:cleaned"; then
    report "PASS" "teardown.sh restores SSH config and removes backup"
else
    report "FAIL" "teardown.sh restores SSH config and removes backup"
    echo "$OUTPUT" | grep -E "(RESTORED|BACKUP|ERROR)" | head -5
fi

# ── Test: Teardown aborts on "n" ─────────────────────────────────────────

OUTPUT=$(docker run --rm rc-test-ubuntu bash -c '
    echo "n" | /opt/remote-claude/teardown.sh 2>&1
    echo "EXIT:$?"
')

if echo "$OUTPUT" | grep -q "Aborted" && echo "$OUTPUT" | grep -q "EXIT:0"; then
    report "PASS" "teardown.sh aborts on 'n' confirmation"
else
    report "FAIL" "teardown.sh aborts on 'n' confirmation"
    echo "$OUTPUT" | tail -5
fi

# ── Fuzz: Empty username shows error and re-prompts ──────────────────────

OUTPUT=$(docker run --rm rc-test-ubuntu bash -c '
    export SUDO_USER=""
    # Feed empty then valid username then empty passphrase
    printf "\nvaliduser\n\n" | timeout 15 /opt/remote-claude/setup.sh 2>&1 || true
    echo "---CHECKS---"
    echo "$?"
')

if echo "$OUTPUT" | grep -q "cannot be empty"; then
    report "PASS" "fuzz: empty username shows error and re-prompts"
else
    report "FAIL" "fuzz: empty username shows error and re-prompts"
    echo "$OUTPUT" | tail -5
fi

# ── Fuzz: Root username rejected with explanation ────────────────────────

OUTPUT=$(docker run --rm rc-test-ubuntu bash -c '
    export SUDO_USER=""
    # Feed root then valid username then empty passphrase
    printf "root\nvaliduser\n\n" | timeout 15 /opt/remote-claude/setup.sh 2>&1 || true
')

if echo "$OUTPUT" | grep -q "Cannot use.*root" && echo "$OUTPUT" | grep -q "disables root login"; then
    report "PASS" "fuzz: root username rejected with explanation"
else
    report "FAIL" "fuzz: root username rejected with explanation"
    echo "$OUTPUT" | tail -5
fi

# ── Fuzz: Username with special chars rejected ───────────────────────────

OUTPUT=$(docker run --rm rc-test-ubuntu bash -c '
    export SUDO_USER=""
    # Feed injection attempt then valid username then empty passphrase
    printf "test;rm\ntest\$(cmd)\nvalid-user\n\n" | timeout 15 /opt/remote-claude/setup.sh 2>&1 || true
')

if echo "$OUTPUT" | grep -q "Invalid username" && echo "$OUTPUT" | grep -q "valid-user"; then
    report "PASS" "fuzz: username with special chars rejected (injection prevented)"
else
    report "FAIL" "fuzz: username with special chars rejected (injection prevented)"
    echo "$OUTPUT" | tail -5
fi

# ── Fuzz: Teardown refuses to delete root ────────────────────────────────

OUTPUT=$(docker run --rm rc-test-ubuntu bash -c '
    printf "y\ny\nroot\n" | /opt/remote-claude/teardown.sh 2>&1
')

if echo "$OUTPUT" | grep -q "Cannot remove root"; then
    report "PASS" "fuzz: teardown refuses to delete root user"
else
    report "FAIL" "fuzz: teardown refuses to delete root user"
    echo "$OUTPUT" | tail -5
fi

# ── Fuzz: Teardown rejects nonexistent user ──────────────────────────────

OUTPUT=$(docker run --rm rc-test-ubuntu bash -c '
    printf "y\ny\nnosuchuser999\n" | /opt/remote-claude/teardown.sh 2>&1
')

if echo "$OUTPUT" | grep -q "does not exist"; then
    report "PASS" "fuzz: teardown rejects nonexistent user"
else
    report "FAIL" "fuzz: teardown rejects nonexistent user"
    echo "$OUTPUT" | tail -5
fi

# ── Test: Tailscale installs successfully ────────────────────────────────

echo -e "  ${YELLOW}...${NC}  Tailscale install (network download, may take a minute)"

OUTPUT=$(docker run --rm rc-test-ubuntu bash -c '
    export SUDO_USER=testuser
    useradd -m testuser 2>/dev/null
    # Extract just the Tailscale install step from setup.sh
    if command -v tailscale &>/dev/null; then
        echo "ALREADY_INSTALLED"
    else
        curl -fsSL https://tailscale.com/install.sh | sh 2>&1 || echo "INSTALL_FAILED"
    fi
    echo "---CHECKS---"
    command -v tailscale &>/dev/null && echo "TAILSCALE:installed" || echo "TAILSCALE:missing"
' 2>&1)

if echo "$OUTPUT" | grep -q "TAILSCALE:installed"; then
    report "PASS" "Tailscale installs successfully in container"
else
    report "FAIL" "Tailscale installs successfully in container"
    echo "$OUTPUT" | tail -5
fi

# ── Test: Node.js 22 installs successfully ───────────────────────────────

echo -e "  ${YELLOW}...${NC}  Node.js install (network download, may take a minute)"

OUTPUT=$(docker run --rm rc-test-ubuntu bash -c '
    apt-get update -qq 2>/dev/null
    apt-get install -y -qq ca-certificates curl gnupg 2>/dev/null
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg 2>/dev/null
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" \
        > /etc/apt/sources.list.d/nodesource.list
    apt-get update -qq 2>/dev/null
    apt-get install -y -qq nodejs 2>/dev/null
    echo "---CHECKS---"
    command -v node &>/dev/null && echo "NODE:installed" || echo "NODE:missing"
    node --version 2>/dev/null | grep -q "v22" && echo "NODE:v22" || echo "NODE:wrong-version"
    command -v npm &>/dev/null && echo "NPM:installed" || echo "NPM:missing"
' 2>&1)

if echo "$OUTPUT" | grep -q "NODE:installed" && echo "$OUTPUT" | grep -q "NODE:v22" && echo "$OUTPUT" | grep -q "NPM:installed"; then
    report "PASS" "Node.js 22 installs successfully in container"
else
    report "FAIL" "Node.js 22 installs successfully in container"
    echo "$OUTPUT" | grep -E "(NODE|NPM|ERROR)" | head -5
fi

# ── Test: Claude Code installs via npm ───────────────────────────────────

echo -e "  ${YELLOW}...${NC}  Claude Code install (npm global, may take a minute)"

OUTPUT=$(docker run --rm rc-test-ubuntu bash -c '
    apt-get update -qq 2>/dev/null
    apt-get install -y -qq ca-certificates curl gnupg 2>/dev/null
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg 2>/dev/null
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" \
        > /etc/apt/sources.list.d/nodesource.list
    apt-get update -qq 2>/dev/null
    apt-get install -y -qq nodejs 2>/dev/null
    npm install -g @anthropic-ai/claude-code 2>/dev/null
    echo "---CHECKS---"
    command -v claude &>/dev/null && echo "CLAUDE:installed" || echo "CLAUDE:missing"
' 2>&1)

if echo "$OUTPUT" | grep -q "CLAUDE:installed"; then
    report "PASS" "Claude Code installs successfully via npm"
else
    report "FAIL" "Claude Code installs successfully via npm"
    echo "$OUTPUT" | tail -5
fi

# ── Test: Teardown removes Node.js + Claude Code ────────────────────────

echo -e "  ${YELLOW}...${NC}  Teardown removal (installs then removes)"

OUTPUT=$(docker run --rm rc-test-ubuntu bash -c '
    # Install Node.js first so teardown has something to remove
    apt-get update -qq 2>/dev/null
    apt-get install -y -qq ca-certificates curl gnupg 2>/dev/null
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg 2>/dev/null
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" \
        > /etc/apt/sources.list.d/nodesource.list
    apt-get update -qq 2>/dev/null
    apt-get install -y -qq nodejs 2>/dev/null
    npm install -g @anthropic-ai/claude-code 2>/dev/null
    # Create SSH backup so teardown restores it
    echo "original" > /etc/ssh/sshd_config.backup.remote-claude
    # Run teardown (y to confirm, n to skip user removal)
    printf "y\nn\n" | /opt/remote-claude/teardown.sh 2>&1
    echo "---CHECKS---"
    command -v claude &>/dev/null && echo "CLAUDE:still-there" || echo "CLAUDE:removed"
    command -v node &>/dev/null && echo "NODE:still-there" || echo "NODE:removed"
    [ -f /etc/apt/sources.list.d/nodesource.list ] && echo "REPO:still-there" || echo "REPO:removed"
' 2>&1)

if echo "$OUTPUT" | grep -q "CLAUDE:removed" && echo "$OUTPUT" | grep -q "NODE:removed" && echo "$OUTPUT" | grep -q "REPO:removed"; then
    report "PASS" "teardown.sh removes Claude Code + Node.js + nodesource repo"
else
    report "FAIL" "teardown.sh removes Claude Code + Node.js + nodesource repo"
    echo "$OUTPUT" | grep -E "(CLAUDE|NODE|REPO|ERROR)" | head -5
fi

# ── Test: Idempotency — full setup twice ─────────────────────────────────

echo -e "  ${YELLOW}...${NC}  Idempotency: setup twice (network, takes longer)"

OUTPUT=$(docker run --rm rc-test-ubuntu bash -c "
    export SUDO_USER=testuser
    useradd -m testuser 2>/dev/null
    # Override pause to auto-skip manual steps
    sed 's/^pause()/pause_disabled()/' /opt/remote-claude/setup.sh > /tmp/setup-auto.sh
    sed -i '1i pause() { return; }' /tmp/setup-auto.sh
    chmod +x /tmp/setup-auto.sh
    # Run setup twice (feed empty passphrase each time)
    printf '\n' | timeout 120 bash /tmp/setup-auto.sh 2>&1 || true
    echo '=== SECOND RUN ==='
    printf '\n' | timeout 120 bash /tmp/setup-auto.sh 2>&1 || true
    echo '---CHECKS---'
    command -v node &>/dev/null && echo 'NODE:installed' || echo 'NODE:missing'
    command -v claude &>/dev/null && echo 'CLAUDE:installed' || echo 'CLAUDE:missing'
    [ -f /etc/ssh/sshd_config.backup.remote-claude ] && echo 'BACKUP:exists' || echo 'BACKUP:missing'
" 2>&1)

if echo "$OUTPUT" | grep -q "already installed" && echo "$OUTPUT" | grep -q "NODE:installed"; then
    report "PASS" "setup.sh is idempotent (second run skips installed components)"
else
    report "FAIL" "setup.sh is idempotent (second run skips installed components)"
    echo "$OUTPUT" | grep -E "(already|NODE|CLAUDE|BACKUP|ERROR)" | tail -10
fi

# ── Test: setup.sh uses fixed-string grep for authorized_keys ──────────

OUTPUT=$(grep -n 'grep.*authorized_keys' "$PROJECT_DIR/setup.sh")

if echo "$OUTPUT" | grep -q 'grep -qFf\|grep.*-F.*-f\|grep.*--fixed-strings'; then
    report "PASS" "authorized_keys check uses fixed-string grep"
else
    report "FAIL" "authorized_keys check uses fixed-string grep (uses regex grep instead)"
    echo "    Found: $OUTPUT"
fi

# ── Test: setup.sh uses strict mode ────────────────────────────────────

OUTPUT=$(head -10 "$PROJECT_DIR/setup.sh")

if echo "$OUTPUT" | grep -q 'set -euo pipefail'; then
    report "PASS" "setup.sh enables strict mode (set -euo pipefail)"
else
    report "FAIL" "setup.sh enables strict mode (set -euo pipefail)"
fi

# ── Test: teardown.sh uses strict mode ─────────────────────────────────

OUTPUT=$(head -10 "$PROJECT_DIR/teardown.sh")

if echo "$OUTPUT" | grep -q 'set -euo pipefail'; then
    report "PASS" "teardown.sh enables strict mode (set -euo pipefail)"
else
    report "FAIL" "teardown.sh enables strict mode (set -euo pipefail)"
fi

# ── Test: Teardown cleans sudoers.d even without user removal ──────────

OUTPUT=$(docker run --rm rc-test-ubuntu bash -c '
    useradd -m testuser 2>/dev/null
    echo "testuser ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/testuser
    chmod 440 /etc/sudoers.d/testuser
    # Run teardown: y to confirm, n to skip user removal
    printf "y\nn\n" | /opt/remote-claude/teardown.sh 2>&1
    echo "---CHECKS---"
    [ -f /etc/sudoers.d/testuser ] && echo "SUDOERS:remains" || echo "SUDOERS:cleaned"
')

if echo "$OUTPUT" | grep -q "SUDOERS:cleaned"; then
    report "PASS" "teardown.sh cleans sudoers.d even without user removal"
else
    report "FAIL" "teardown.sh cleans sudoers.d even without user removal"
    echo "$OUTPUT" | grep -E "(SUDOERS|ERROR)" | head -5
fi

# ── Summary ──────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
TOTAL=$((PASS + FAIL))
if [[ $FAIL -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}  All $TOTAL tests passed${NC}"
else
    echo -e "${RED}${BOLD}  $FAIL/$TOTAL tests failed${NC}"
fi
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

exit $FAIL
