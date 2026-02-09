# Secrets Management

This guide covers setting up encrypted secrets using Agenix.

> **Tip**: The template includes a `justfile` with automation recipes. Commands like `just gen-wg-key node01` handle step 4 below (the justfile outputs the public key for you to copy into `infra.nix` in step 5). The manual instructions explain what the automation does under the hood.

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

### 2. Get Host SSH Public Keys

After initial deployment with `setup = true`, get each host's SSH public key:

```bash
ssh-keyscan <node01-ip> 2>/dev/null
ssh-keyscan <web01-ip> 2>/dev/null
```

> **Note**: `age` supports **ed25519** and **RSA** (2048+ bit) SSH keys, but not ECDSA or DSA. Look for an `ssh-ed25519` or `ssh-rsa` line in the output.

> **Note**: `ssh-keyscan` ignores your `~/.ssh/config` entirely — it doesn't read port settings or hostname aliases. You must use raw IP addresses, and if your hosts use a non-standard SSH port, add `-p <port>`:
> ```bash
> ssh-keyscan -p 8188 <node01-ip> 2>/dev/null
> ```

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

**With justfile** (recommended):
```bash
just gen-wg-key node01
just gen-wg-key web01
just gen-grafana-password web01
```

**Manually** — The justfile automates the following. This explains what happens under the hood:

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

# Encrypt private key directly to .age file
echo "$PRIVATE_KEY" | age -r "$USER_KEY" -r "$HOST_KEY" \
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

echo "$PASSWORD" | age -r "$USER_KEY" -r "$HOST_KEY" \
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
just deploy node01
just deploy web01
```

## Re-keying Secrets

If you need to change encryption recipients (new host key, etc.):

```bash
just rekey
# Or manually: cd secrets && agenix -r
```

This re-encrypts all secrets with current recipients from `secrets.nix`.

## Viewing/Editing Secrets

```bash
# View a secret
just view-secret wireguard-private-key-node01.age
# Or manually: age -d secrets/wireguard-private-key-node01.age

# Edit with agenix (from dev shell, inside secrets/ directory)
nix develop
cd secrets && agenix -e wireguard-private-key-node01.age
```

## Required Secrets Per Host Type

### Nodes
- `wireguard-private-key-<hostname>.age`

### Webservers
- `wireguard-private-key-<hostname>.age`
- `grafana-admin-password-<hostname>.age`

## Quick Reference (justfile)

| Command | Description |
|---------|-------------|
| `just gen-wg-key <host>` | Generate and encrypt WireGuard key |
| `just gen-grafana-password <host>` | Generate and encrypt Grafana password |
| `just get-host-key <host> [port]` | Get SSH host key from a deployed host |
| `just rekey` | Re-encrypt all secrets after key changes |
| `just view-secret <file>` | Decrypt and display a secret |

## Troubleshooting

### "no secret key" during deploy

The host can't decrypt secrets. Check:
1. Host SSH public key in `secrets.nix` matches actual key on server
2. Re-encrypt secrets: `just rekey` (or `cd secrets && agenix -r`)

### Can't decrypt locally

Your age key isn't a recipient. Check:
1. Your age public key is in `secrets.nix` for that secret
2. Re-encrypt: `cd secrets && agenix -r`

### Lost age key

If you lose `~/.age/key.txt`:
1. Generate new key: `age-keygen -o ~/.age/key.txt`
2. Update `secrets.nix` with new public key
3. SSH to each host, manually retrieve secrets, re-encrypt

This is why backing up your age key is critical.
