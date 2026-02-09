# Quick Start Guide

This guide walks you through deploying peer-observer infrastructure from scratch.

## What You Can Deploy

| Scenario | What You Get |
|----------|--------------|
| **Node(s) only** | Data collection, Prometheus metrics endpoint, WebSocket API. Add a webserver later if needed. |
| **Node(s) + webserver** | Full deployment with Grafana dashboards, fork-observer, addrman-observer. The typical setup. |

This guide covers both scenarios. Skip the webserver sections if you only need nodes.

## Prerequisites

- **Nix** with flakes enabled
  ```bash
  # Add to ~/.config/nix/nix.conf or /etc/nix/nix.conf:
  experimental-features = nix-command flakes
  ```
- Root SSH access to target servers

The dev shell (`nix develop`) provides all other required tools: `age`, `wireguard-tools`, `just`, `agenix`, `nixos-anywhere`.

### Recommended Server Specs

| Component | Specs |
|-----------|-------|
| Node (pruned) | 4 CPU, 8GB RAM, 100GB disk |
| Node (full) | 4 CPU, 8GB RAM, 2TB SSD |
| Webserver | 2–4 CPU, 4GB RAM, 50GB disk |

Smaller instances may work for testing or low-traffic deployments.

## Step 1: Initialize Your Repository

```bash
mkdir my-peer-observer && cd my-peer-observer
nix flake init --template github:peer-observer/infra-library
git init && git add flake.nix
nix develop  # Enter dev shell
```

This gives you:
```text
.
├── flake.nix          # Nix flake definition
├── infra.nix          # Your infrastructure configuration
├── justfile           # Automation recipes (deploy, secrets, etc.)
├── hosts/             # Host-specific configs (disko, hardware)
└── secrets/
    ├── secrets.nix    # Agenix encryption recipients
    └── .gitignore
```

## Step 2: Configure Your Infrastructure

Edit `infra.nix` and address the `FIXME` comments. The file is well-documented with inline instructions. Key items to configure:

**Global settings:**
- `admin.username` — your SSH login username
- `admin.sshPubKeys` — your SSH public key(s)
- `system.stateVersion` — set to the [most recent NixOS version](https://nixos.org/manual/nixos/stable/options.html#opt-system.stateVersion) (e.g., `"25.11"`)

**Per-node settings:**
- `wireguard.pubkey` — fill in after Step 5 (secrets)
- `extraModules` — uncomment the disko and hardware-configuration lines, update paths
- `bitcoind` — configure chain, pruning, etc.

**Webserver settings (optional — skip if you only need nodes):**
- `domain` — public domain name that resolves to this server
- `grafana.admin_user` — Grafana admin username
- `security.acme` — accept terms and set email for HTTPS certificates

> **Note**: All hosts start with `setup = true`. This enables initial deployment without secrets — services that require secrets (WireGuard, etc.) are skipped. You'll set `setup = false` in Step 6 after secrets are configured.

See [Configuration Reference](configuration.md) for all available options.

## Step 3: Set Up Disk Partitioning

Create disko configuration for each host:

```bash
mkdir -p hosts/node01
mkdir -p hosts/web01  # if deploying a webserver
```

Copy the [disko.nix file from the infra-demo](https://github.com/peer-observer/infra-demo/blob/master/hosts/hal/disko.nix) into each host directory (e.g., `hosts/node01/disko.nix`, `hosts/web01/disko.nix`).

You must then change the `id` in `let` bindings at the top of the file for each host to match the target server's disk identifier:
- `id` — the disk identifier. Run `lsblk -o NAME,SIZE,TYPE,ID-LINK -d` on the target server and use the `ID-LINK` value (e.g., `scsi-0QEMU_QEMU_HARDDISK_...`)

## Step 4: Initial Deployment

> **Important**: Nix flakes require all referenced files to be tracked by git. Before deploying, ensure your configuration files are added:
> ```bash
> git add infra.nix hosts/
> ```

> **Tip**: Open an extra SSH session to the server before running this command. If something goes wrong, you'll still have access. See [Troubleshooting](troubleshooting.md) for recovery options.

> **Warning**: This WIPES the target disk!

**Using justfile:**
```bash
just initial-deploy node01 root@<server-ip>
```

**Without justfile:**
```bash
nix run github:nix-community/nixos-anywhere -- \
  --generate-hardware-config nixos-generate-config ./hosts/node01/hardware-configuration.nix \
  --flake .#node01 \
  --target-host root@<server-ip> \
  --build-on remote
```

The server will reboot. You can then SSH as your admin user:
```bash
ssh node01  # or ssh <username>@<server-ip>
```

> **Tip**: Configure `~/.ssh/config` with your server names for easier access.

Repeat for each host (web01 if deploying a webserver).

## Step 5: Configure Secrets

See [Secrets Management](secrets.md) for detailed instructions on how secrets work. The justfile automates most of the process:

```bash
# 1. Generate your age key (one-time)
age-keygen -o ~/.age/key.txt
# Note the public key (starts with "age1...")

# 2. Get host SSH keys and update secrets/secrets.nix
ssh-keyscan <node01-ip> 2>/dev/null

# 3. Generate and encrypt secrets
just gen-wg-key node01
just gen-wg-key web01           # if deploying a webserver
just gen-grafana-password web01  # if deploying a webserver

# 4. Update infra.nix with WireGuard public keys (output from step 3)
```

## Step 6: Full Deployment

1. Set `setup = false` for all hosts in `infra.nix` — this enables WireGuard VPN and all services that require secrets
2. Track the new secrets and config changes in git:
   ```bash
   git add infra.nix secrets/*.age
   ```
3. Deploy:

**Using justfile:**
```bash
just deploy node01
just deploy web01  # if deploying a webserver
```

**Without justfile:**
```bash
nixos-rebuild switch --flake .#node01 --target-host node01 --build-host node01 --sudo
nixos-rebuild switch --flake .#web01 --target-host web01 --build-host web01 --sudo  # if deploying a webserver
```

## What's Running

After deployment, each **node** runs:
- Bitcoin Core with USDT tracepoints
- peer-observer extractors (eBPF, RPC, P2P)
- NATS message broker
- Prometheus metrics exporter (over WireGuard)
- WebSocket API (over WireGuard)
- nginx (serves compressed metrics and debug logs over WireGuard)

If you deployed a **webserver**, it runs:
- Grafana dashboards
- Prometheus (scrapes all nodes)
- fork-observer
- addrman-observer
- nginx with Let's Encrypt

Check service status:
```bash
ssh node01
systemctl status bitcoind-mainnet
systemctl status peer-observer-ebpf-extractor
journalctl -u bitcoind-mainnet -f
```

## Ongoing Maintenance

```bash
# Update flake inputs (pulls latest peer-observer, nixpkgs, etc.)
nix flake update
```

**Using justfile:**
```bash
just deploy node01
just deploy web01
just rekey  # Re-encrypt secrets after changing keys in secrets.nix
```

**Without justfile:**
```bash
nixos-rebuild switch --flake .#node01 --target-host node01 --build-host node01 --sudo
nixos-rebuild switch --flake .#web01 --target-host web01 --build-host web01 --sudo
cd secrets && agenix -r  # Re-encrypt secrets
```

Run `just` to see all available commands.

### Alternative Deployment Method

If the native `nixos-rebuild --target-host` approach fails (network issues, SSH configuration problems, or building from macOS where cross-compilation isn't supported), you can copy your configuration to the host and build locally:

```bash
# 1. Copy configuration to the host
rsync -avz --delete --exclude='.git' . node01:/tmp/nixos-config/

# 2. SSH in and rebuild locally
ssh node01 "cd /tmp/nixos-config && sudo nixos-rebuild switch --flake .#node01"
```

This approach:
- Works from any OS (including macOS)
- Avoids cross-compilation issues
- Useful when `--build-host` remote builds timeout or fail

## Next Steps

- [Configuration Reference](configuration.md) - All available options
- [Secrets Management](secrets.md) - Understanding keys and encryption
- [Troubleshooting](troubleshooting.md) - Common issues
