# remote-claude

One script to set up Claude Code on any fresh Ubuntu/Debian server. One script to tear it down.

## Prerequisites

- A fresh Ubuntu or Debian server (tested on Ubuntu 24.04)
- SSH access (root or sudo user)
- A [Tailscale](https://tailscale.com) account
- An [Anthropic](https://console.anthropic.com) account

## Quick Start

```bash
git clone https://github.com/bis-code/remote-claude.git
cd remote-claude
sudo ./setup.sh
```

The script walks you through everything interactively.

## What Gets Installed

| Component | Purpose |
|-----------|---------|
| **Tailscale** | Secure private network — connect from anywhere without exposing ports |
| **Node.js 22** | Runtime required by Claude Code |
| **Claude Code** | Anthropic's CLI for Claude |

SSH is also hardened: password authentication and root login are disabled.

## Manual Steps

The setup script pauses at a few steps that need your input:

1. **Create user** — Enter a non-root username (the script creates it with sudo access)
2. **SSH passphrase** — Optionally set a passphrase for the generated SSH key (or press Enter for none)
3. **Save SSH key** — The script generates a keypair and displays both keys. Copy the private key into Termius
4. **Tailscale auth** — Run `sudo tailscale up` and authenticate via the URL
5. **Save Tailscale IP** — The script displays it; you'll use it to connect
6. **Claude login** — Launch `claude` and run `/login` to authenticate

Everything else is automatic.

## Connecting From Your Phone

### 1. Install Tailscale

- **iOS**: [App Store](https://apps.apple.com/app/tailscale/id1470499037)
- **Android**: [Google Play](https://play.google.com/store/apps/details?id=com.tailscale.ipn)

Open Tailscale, sign in with the same account you used on the server. Your phone and server are now on the same private network — no port forwarding, no public IP needed.

### 2. Install Termius

- **iOS**: [App Store](https://apps.apple.com/app/termius-terminal-ssh-client/id549039908)
- **Android**: [Google Play](https://play.google.com/store/apps/details?id=com.server.auditor.ssh.client)

### 3. Import SSH Key

In Termius, go to **Keychain > + > Key** and paste the private key that the setup script displayed.

If you set a passphrase during setup, enter it when prompted.

### 4. Connect

Create a new host in Termius:

| Field | Value |
|-------|-------|
| **Hostname** | Your Tailscale IP (e.g. `100.x.y.z`) |
| **Username** | The user you created during setup |
| **Key** | The SSH key you just imported |

Connect, then run:

```bash
claude
```

That's it. You're coding with Claude on your remote server from your phone.

## Teardown

To remove everything and restore the server to its original state:

```bash
sudo ./teardown.sh
```

This removes Claude Code, Node.js, Tailscale, and restores your original SSH config. Optionally removes the user account too.

## FAQ

**Is this safe to run?**
Yes. Read the script — it's ~100 lines of straightforward bash. It installs three things, hardens SSH, and backs up your config before changing it.

**Can I run setup.sh twice?**
Yes. It's idempotent — it skips components that are already installed.

**What if something goes wrong?**
Check the log at `/var/log/remote-claude-setup.log`. Run `sudo ./teardown.sh` to start fresh.

**Does this work on Arm servers?**
Yes. Tailscale, Node.js, and Claude Code all support arm64.

## License

MIT
