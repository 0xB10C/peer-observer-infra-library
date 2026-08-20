# Secrets Management

This guide covers setting up encrypted secrets using Agenix.

> **Tip**: The template dev shell defines helpers for the common secret-management tasks. `gen-wg-key node01`, for example, handles step 4 below and outputs the public key to copy into `infra.nix` in step 5. Run `infra-help` from the dev shell for the complete list. The manual instructions explain what the helpers do under the hood.

## Understanding the Key Types

This infrastructure uses several cryptographic keys. Understanding their purposes helps avoid confusion.

### Key Summary

| Key Type | Location | Purpose |
|----------|----------|---------|
| **Your SSH Key** | `~/.ssh/id_ed25519` (or `id_rsa`) | Admin access to VPS hosts |
| **VPS Host SSH Key** | `/etc/ssh/ssh_host_ed25519_key` | Proves VPS identity + decrypts secrets |
| **Your Age Key** | `~/.age/key.txt` | Encrypt/decrypt secrets locally |
| **WireGuard Key** | Encrypted in git | VPN tunnel between hosts |

### How They Work Together

```
┌─────────────────────────────────────────────────────────────────┐
│                      YOUR LOCAL MACHINE                         │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Your SSH Key (~/.ssh/id_ed25519)                              │
│  └── Proves your identity when you SSH into VPS hosts          │
│                                                                 │
│  Your Age Key (~/.age/key.txt)                                 │
│  └── Lets you encrypt secrets that VPS hosts can decrypt       │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
        │
        │ SSH (admin access)
        ▼
┌─────────────────────────────────────────────────────────────────┐
│                         VPS HOST                                │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  VPS Host SSH Key (/etc/ssh/ssh_host_ed25519_key)              │
│  ├── Proves "I am the real server" when you connect            │
│  └── Decrypts .age secrets during NixOS activation             │
│                                                                 │
│  WireGuard Key (/run/agenix/wireguard-private-key)             │
│  └── Creates encrypted VPN tunnel to other hosts               │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Why Age Uses SSH Host Keys

A clever feature of `age` is that it can encrypt to SSH ed25519 public keys:

1. **No extra key distribution** - VPS hosts already have SSH keys from installation
2. **Secrets decrypt automatically** - The host uses its existing SSH key
3. **You're always a recipient** - Your age key lets you edit secrets locally

When you encrypt a secret, you specify **two recipients**:
- Your age public key (so you can edit/view secrets)
- The VPS host's SSH public key (so the server can decrypt at boot)

### WireGuard is Host-to-Host Only

WireGuard creates an encrypted tunnel between your VPS hosts - **not** between your local machine and the servers. You use SSH for admin access.

```
┌──────────────┐                 ┌─────────────┐                 ┌─────────────┐
│ Your Machine │───── SSH ──────►│  VPS Node   │◄══ WireGuard ══►│ VPS Websvr  │
│              │                 │             │   (10.21.x.x)   │             │
└──────────────┘                 └─────────────┘                 └─────────────┘
```

## Step-by-Step Setup

### 1. Generate Your Age Key (One-Time)

```bash
# Create directory if needed
mkdir -p ~/.age

# Generate keypair
age-keygen -o ~/.age/key.txt

# Note the public key (starts with "age1...")
cat ~/.age/key.txt | grep "public key"
```

**Keep `~/.age/key.txt` safe!** Back it up securely - you need it to edit secrets.

The dev-shell helpers (`rekey`, `view-secret`) read your identity from `$AGE_IDENTITY`, defaulting to `~/.age/key.txt`. Set `AGE_IDENTITY` if your key lives elsewhere.

### 2. Get Host SSH Public Keys

After initial deployment with `setup = true`, get each host's SSH public key:

```bash
ssh-keyscan <node01-ip> 2>/dev/null
ssh-keyscan <web01-ip> 2>/dev/null
```

> **Note**: `age` supports **ed25519** and **RSA** (2048+ bit) SSH keys, but not ECDSA or DSA. Look for an `ssh-ed25519` or `ssh-rsa` line in the output.

> **Note**: `ssh-keyscan` ignores your `~/.ssh/config` — use raw IP addresses, and add `-p <port>` for non-standard SSH ports (see [Troubleshooting](troubleshooting.md#ssh-keyscan-ignores-ssh-config)).

Output looks like:
```
<ip> ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA...
```

### 3. Configure secrets/secrets.nix

```nix
let
  # Your age public key (from step 1)
  user = "age1abc123...";

  # Host SSH public keys (from step 2)
  # Use the key part only, not the IP prefix
  node01 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA...";
  web01 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA...";
in
{
  # Node secrets
  "wireguard-private-key-node01.age".publicKeys = [ node01 user ];

  # Webserver secrets
  "wireguard-private-key-web01.age".publicKeys = [ web01 user ];
  "grafana-admin-password-web01.age".publicKeys = [ web01 user ];
}
```

### 4. Generate and Encrypt Secrets

From the dev shell (recommended):
```bash
gen-wg-key node01
gen-wg-key web01
gen-grafana-password web01
```

**Manually** — The dev-shell helpers automate the following. This explains what happens under the hood:

#### WireGuard Keys

The recommended approach encrypts secrets directly without temporary files:

```bash
#!/usr/bin/env bash
# Generate and encrypt WireGuard key for node01

# Generate keypair in memory
PRIVATE_KEY=$(wg genkey)
PUBLIC_KEY=$(echo "$PRIVATE_KEY" | wg pubkey)

# Get encryption recipients
USER_KEY="age1..."        # Your age public key
HOST_KEY="ssh-ed25519 AAAA..."  # Host's SSH public key
HOST_KEY_FILE=$(mktemp)
trap 'rm -f "$HOST_KEY_FILE"' EXIT
printf '%s\n' "$HOST_KEY" > "$HOST_KEY_FILE"

# Encrypt private key directly to .age file
echo "$PRIVATE_KEY" | age -r "$USER_KEY" -R "$HOST_KEY_FILE" \
  -o secrets/wireguard-private-key-node01.age

echo "Public key for infra.nix: $PUBLIC_KEY"
```

**Important**: Save the public key output - you'll add it to `infra.nix`.

Repeat for each host (node01, web01, etc.).

#### Grafana Password

```bash
#!/usr/bin/env bash
PASSWORD=$(openssl rand -base64 32)

USER_KEY="age1..."
HOST_KEY="ssh-ed25519 AAAA..."  # web01's SSH key
HOST_KEY_FILE=$(mktemp)
trap 'rm -f "$HOST_KEY_FILE"' EXIT
printf '%s\n' "$HOST_KEY" > "$HOST_KEY_FILE"

echo "$PASSWORD" | age -r "$USER_KEY" -R "$HOST_KEY_FILE" \
  -o secrets/grafana-admin-password-web01.age

echo "Grafana password (save this!): $PASSWORD"
```

### 5. Update WireGuard Public Keys in infra.nix

Replace `PLACEHOLDER` values with actual public keys:

```nix
nodes = {
  node01 = {
    wireguard = {
      ip = "10.21.0.1";
      pubkey = "abc123...=";  # From step 4
    };
  };
};

webservers = {
  web01 = {
    wireguard = {
      ip = "10.21.1.1";
      pubkey = "xyz789...=";  # From step 4
    };
  };
};
```

### 6. Disable Setup Mode and Deploy

```nix
nodes = {
  node01 = {
    setup = false;  # Secrets now required
  };
};
```

Then deploy:

```bash
nix develop
deploy node01
deploy web01
```

## Re-keying Secrets

If you need to change encryption recipients (new host key, etc.):

```bash
rekey
# Or manually: cd secrets && agenix -r -i ~/.age/key.txt
```

This re-encrypts all secrets with current recipients from `secrets.nix`.

## Viewing/Editing Secrets

```bash
# View a secret
view-secret wireguard-private-key-node01.age
# Or manually: age -d -i ~/.age/key.txt secrets/wireguard-private-key-node01.age

# Edit with agenix (from dev shell, inside secrets/ directory)
nix develop
cd secrets && agenix -e wireguard-private-key-node01.age -i ~/.age/key.txt
```

## Required Secrets Per Host Type

### Nodes
- `wireguard-private-key-<hostname>.age`

### Webservers
- `wireguard-private-key-<hostname>.age`
- `grafana-admin-password-<hostname>.age`

## Quick Reference (dev shell)

| Command | Description |
|---------|-------------|
| `gen-wg-key <host>` | Generate and encrypt WireGuard key |
| `gen-grafana-password <host>` | Generate and encrypt Grafana password |
| `get-host-key <host> [port]` | Get SSH host key from a deployed host |
| `rekey` | Re-encrypt all secrets after key changes |
| `view-secret <file>` | Decrypt and display a secret |

## Troubleshooting

For decryption failures ("no secret key" during deploy, can't edit secrets locally) and lost-key recovery, see [Secrets Issues in Troubleshooting](troubleshooting.md#secrets-issues).
