# Configuration Reference

Complete reference for `infra.nix` configuration options. For a guided setup walkthrough, see the [Quick Start Guide](quickstart.md).

## Global Configuration

Settings applied to all hosts.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `admin.username` | string | — (required) | Admin user created on all hosts for SSH access. Cannot be `"root"`. |
| `admin.sshPubKeys` | list of strings | — (required) | SSH public keys added to the admin user's `authorized_keys`. Must not be empty. |
| `extraConfig` | attrs | `{}` | NixOS configuration applied to all hosts (e.g., `system.stateVersion`, `time.timeZone`). |

### Infrastructure Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `agenixSecretsDir` | path | — (required) | Path to the directory containing `.age` encrypted secret files. Used by all hosts to locate WireGuard keys and Grafana passwords. |

```nix
agenixSecretsDir = ./secrets;
```

### Global Options

```nix
global = {
  admin = {
    username = "myuser";
    sshPubKeys = [ "ssh-... ..." ];
  };
  extraConfig = {
    system.stateVersion = "25.11";  # Use the most recent NixOS version
  };
};
```

## Node Configuration

Each node runs a Bitcoin Core instance, peer-observer extractors and tools, and a NATS message broker. See [Architecture](architecture.md) for how these components interact.

### Host Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `id` | int (u8) | — (required) | Unique numeric ID. By convention, should match the last octet of the WireGuard IP (e.g., `id = 1` with `wireguard.ip = "10.21.0.1"`). Must be unique across all nodes. |
| `arch` | string | `"x86_64-linux"` | Host architecture. Use `"aarch64-linux"` for ARM servers. |
| `setup` | bool | `false` | Setup mode — skips secret requirements for initial deployment with `nixos-anywhere`. Set to `false` after configuring secrets (see [Secrets Management](secrets.md)). |
| `description` | string | `null` | Optional host description. May be displayed publicly. |
| `wireguard.ip` | string | — (required) | WireGuard VPN address. Use `10.21.0.x` for nodes. |
| `wireguard.pubkey` | string | — (required) | WireGuard public key. Generate with `wg genkey \| wg pubkey`. |
| `extraConfig` | attrs | `{}` | Additional NixOS configuration for this host. |
| `extraModules` | list | `[]` | Additional NixOS modules (e.g., disko, hardware-configuration). |

### Bitcoin Core

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `bitcoind.chain` | enum | `"main"` | Network: `"main"`, `"test"`, `"testnet4"`, `"signet"`, `"regtest"`. |
| `bitcoind.prune` | int | `4000` | Pruning target in MB. Set to `0` for a full (non-pruned) node. |
| `bitcoind.dataDir` | string or null | `null` (auto) | Data directory. Defaults to `/var/lib/bitcoind-mainnet/` when null (the service is named `"mainnet"` for backwards compatibility, regardless of chain). Override if using a separate data drive. |
| `bitcoind.customPort` | port or null | `null` | Custom P2P port. When null, uses the chain default (8333 mainnet, 18333 testnet3, 48333 testnet4, 38333 signet, 18444 regtest). |
| `bitcoind.package` | package | built-in | Bitcoin Core package. Override for custom builds (see [Custom Bitcoin Core Builds](#custom-bitcoin-core-builds)). |
| `bitcoind.extraConfig` | string | `""` | Extra lines appended to `bitcoin.conf`. Use `bitcoin.conf` syntax. |
| `bitcoind.banlistScript` | string or null | `null` | Shell script executed after `bitcoind` starts. Has access to `RPC_BAN_USER` and `RPC_BAN_PW` environment variables. |

Example — banning a subnet after startup:

```nix
bitcoind.banlistScript = ''
  bitcoin-cli setban 192.168.1.0/24 add 31536000
'';
```

### Network Connectivity

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `bitcoind.net.useTor` | bool | `false` | Enable Tor connectivity and accept inbound Tor connections. |
| `bitcoind.net.useI2P` | bool | `false` | Enable I2P connectivity and accept inbound I2P connections. |
| `bitcoind.net.useCJDNS` | bool | `false` | Enable CJDNS connectivity and accept inbound CJDNS connections. |
| `bitcoind.net.useASMap` | bool | `false` | Use an [ASMap](https://asmap.org) file for improved peer diversity across autonomous systems. |

### Detailed Logging

Controls Bitcoin Core debug log verbosity and retention. When enabled, verbose log categories (`net`, `mempoolrej`, etc.) are activated. Logs are rotated daily and compressed.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `bitcoind.detailedLogging.enable` | bool | `true` | Enable verbose debug log categories. |
| `bitcoind.detailedLogging.logsToKeep` | int (u16) | `4` | Number of rotated log files to keep. Logs rotate daily, so `4` means 4 days of history. |
| `bitcoind.detailedLogging.printToConsole` | bool | `false` | Also print debug logs to the systemd journal. Useful for testing, noisy in production. |

### Observer Integration

Controls which webserver services this node participates in. Enabling fork-observer or addrman-observer binds the Bitcoin Core RPC port to the WireGuard interface so the webserver can reach it. See [Security Boundaries](architecture.md#security-boundaries) for details.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `fork-observer.enable` | bool | `true` | Expose this node to fork-observer on the webserver. |
| `addrman-observer.enable` | bool | `true` | Expose this node to addrman-observer on the webserver. |
| `peer-observer.addrLookup` | bool | `false` | Enable the address connectivity lookup tool. This tool connects to IP addresses received via `addr(v2)` messages — it actively reaches out to the network and may leak the node's IP address. |

## Webserver Configuration

Each webserver aggregates data from all nodes into a single web interface. See [Architecture](architecture.md) for the full list of services.

### Host Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `id` | int (u8) | — (required) | Unique numeric ID. By convention, should match the last octet of the WireGuard IP (e.g., `id = 1` with `wireguard.ip = "10.21.1.1"`). Must be unique across all webservers. |
| `arch` | string | `"x86_64-linux"` | Host architecture. |
| `setup` | bool | `false` | Setup mode — skips secret requirements for initial deployment (see [Secrets Management](secrets.md)). |
| `domain` | string | — (required) | Public domain pointing to this server. Used for nginx virtual host and Let's Encrypt certificate. |
| `description` | string | `null` | Optional host description. May be displayed publicly. |
| `wireguard.ip` | string | — (required) | WireGuard VPN address. Use `10.21.1.x` for webservers. |
| `wireguard.pubkey` | string | — (required) | WireGuard public key. |
| `extraConfig` | attrs | `{}` | Additional NixOS configuration (e.g., ACME terms acceptance). |
| `extraModules` | list | `[]` | Additional NixOS modules. |

ACME/Let's Encrypt must be configured in `extraConfig`:

```nix
extraConfig = {
  security.acme.acceptTerms = true;
  security.acme.defaults.email = "you@example.com";
};
```

### Access Control

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `access_DANGER` | enum | `"LIMITED_ACCESS"` | `"LIMITED_ACCESS"` or `"FULL_ACCESS"`. |

`LIMITED_ACCESS` hides data that could reveal node locations (IP addresses, honeypot information). `FULL_ACCESS` exposes everything — if using this mode, place an authentication layer in front of nginx (e.g., basic auth, OAuth proxy, or VPN-only access).

### Prometheus

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `prometheus.retention` | string | `"30d"` | How long to retain scraped metrics. Uses Prometheus duration syntax (e.g., `"30d"`, `"90d"`, `"1y"`). |

### Grafana

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `grafana.admin_user` | string | — (required) | Grafana admin username. |

### fork-observer

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `fork-observer.networkName` | string | `"mainnet"` | Display name for the chain/network. |
| `fork-observer.description` | string | `"fork-observer attached to peer-observer nodes"` | Description text shown in the fork-observer UI. |
| `fork-observer.minForkHeight` | int | `500000` | Minimum block height for fork tracking. |

### Index Page

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `index.limitedAccessNotice` | string | `""` | HTML notice shown at the top of the landing page in `LIMITED_ACCESS` mode. |
| `index.fullAccessNotice` | string | `""` | HTML notice shown at the top of the landing page in `FULL_ACCESS` mode. |

## Custom Bitcoin Core Builds

To run a specific Bitcoin Core version or fork, use `mkCustomBitcoind`:

> **Note**: The eBPF extractor requires **Bitcoin Core v29.0 or newer**. Earlier versions lack the required USDT tracepoints.

```nix
let
  customBitcoind = { system, overrides }:
    (peer-observer-infra-library.lib system).mkCustomBitcoind overrides;
in
{
  nodes = {
    node01 = {
      bitcoind = {
        package = customBitcoind {
          system = "x86_64-linux";
          overrides = {
            gitURL = "https://github.com/bitcoin/bitcoin.git";
            gitBranch = "v29.0";
            gitCommit = "f490f5562d4b20857ef8d042c050763795fd43da";
          };
        };
      };
    };
  };
}
```

### Available Overrides

See [pkgs/bitcoind/default.nix](https://github.com/peer-observer/infra-library/blob/master/pkgs/bitcoind/default.nix) for all options:

| Override | Default | Description |
|----------|---------|-------------|
| `gitURL` | `"https://github.com/bitcoin/bitcoin.git"` | Repository URL |
| `gitBranch` | `"master"` | Branch name |
| `gitCommit` | *(pinned)* | Full commit hash |
| `fakeVersionMajor` | `null` | Fake the major version number to avoid detection of honeypot nodes |
| `fakeVersionMinor` | `null` | Fake the minor version number |
| `sanitizersAddressUndefined` | `false` | Enable address + undefined behavior sanitizers (mutually exclusive with thread sanitizer) |
| `sanitizersThread` | `false` | Enable thread sanitizer (mutually exclusive with address sanitizer) |

## WireGuard IP Addressing

| Host Type | IP Range |
|-----------|----------|
| Nodes | `10.21.0.x` |
| Webservers | `10.21.1.x` |

The `id` field determines the last octet: node with `id = 1` gets `10.21.0.1`. All IPs and public keys must be unique across the deployment. See [Secrets Management](secrets.md) for WireGuard key generation and encryption.
