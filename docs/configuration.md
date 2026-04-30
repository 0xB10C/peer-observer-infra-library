# Configuration Concepts

This page describes the conceptual structure and behaviour of `infra.nix` configuration. For a complete, always-up-to-date option reference (types, defaults, examples), see the **[auto-generated option reference](https://peer-observer.github.io/infra-library)**.

For a guided deployment walkthrough, see the [Quick Start Guide](quickstart.md).

---

## Global Configuration

Global settings (`infra.global.*` and `infra.agenixSecretsDir`) apply to every host in the deployment - both nodes and webservers. See the [auto-generated reference](https://peer-observer.github.io/infra-library/#_infra_global) for full option details.

---

## Node Configuration

Each node runs a Bitcoin Core instance, the peer-observer extractors and tools, and a NATS message broker.

### Setup mode

The `setup` flag skips secret requirements during initial deployment with `nixos-anywhere`. Set it to `true` for first-time provisioning, then set it back to `false` once secrets are in place (see [Secrets Management](secrets.md)).

### Bitcoin Core

The `bitcoind` block controls the Bitcoin Core instance on each node.

`bitcoind.prune` sets the pruning target in MiB. Set to `0` for a full (non-pruned) node. Defaults to 4000 MiB.

`bitcoind.chain` selects the network. One of `main`, `test`, `testnet4`, `signet`, `regtest`. Defaults to `main`.

`bitcoind.dataDir` defaults to `/var/lib/bitcoind-mainnet/` regardless of chain (the service is named `mainnet` for backwards compatibility). Override this if your data lives on a separately mounted drive.

`bitcoind.customPort` overrides the default P2P port. Defaults to the chain standard (8333 main, 18333 test/testnet3, 48333 testnet4, 38333 signet, 18444 regtest).

`bitcoind.extraConfig` appends lines to `bitcoin.conf` directly. Use standard `bitcoin.conf` key-value syntax.

`bitcoind.banlistScript` runs a shell script after `bitcoind` starts. The `RPC_BAN_USER` and `RPC_BAN_PW` environment variables are available for making RPC calls:

```nix
bitcoind.banlistScript = ''
  bitcoin-cli -rpcuser=$RPC_BAN_USER -rpcpassword=$RPC_BAN_PW \
    setban 192.168.1.0/24 add 31536000
'';
```

### Network Connectivity

The `bitcoind.net` options enable alternative network transports. Each adds an inbound listener for that transport.

`bitcoind.net.useTor` enables Tor connectivity and inbound Tor connections.

`bitcoind.net.useI2P` enables I2P connectivity and inbound I2P connections.

`bitcoind.net.useCJDNS` enables CJDNS connectivity and inbound CJDNS connections.

`bitcoind.net.useASMap` loads a recent ASMap file for improved peer diversity across autonomous systems (see [asmap.org](https://asmap.org)).

### Detailed Logging

`bitcoind.detailedLogging.enable` turns on verbose Bitcoin Core debug log categories (`net`, `mempoolrej`, and others). Logs are rotated daily and compressed. Enabled by default.

`bitcoind.detailedLogging.logsToKeep` controls how many rotated log files are retained before deletion (maps to logrotate's `rotate` setting). Since logs rotate daily, this is effectively a retention period in days. Defaults to `4`.

`bitcoind.detailedLogging.printToConsole` mirrors debug logs to the systemd journal. Disabled by default - useful for testing, noisy in production.

### Observer Integration

These options control which webserver services a node participates in. Enabling `fork-observer.enable` or `addrman-observer.enable` binds the Bitcoin Core RPC port to the WireGuard interface so the webserver can query it. Both default to `true`. See [Security Boundaries](architecture.md#security-boundaries) for details.

`peer-observer.addrLookup` enables the address connectivity lookup tool. **Important:** this tool actively connects to IP addresses received via `addr(v2)` messages and may leak the node's IP to the network. Disabled by default.

---

## Webserver Configuration

Each webserver aggregates data from all nodes into a single web interface.

### Domain and ACME

`domain` sets the public domain for the webserver. nginx uses it for virtual host matching and Let's Encrypt certificate requests. ACME must be configured in `extraConfig`:

```nix
extraConfig = {
  security.acme.acceptTerms = true;
  security.acme.defaults.email = "you@example.com";
};
```

### Access Control

`access_DANGER` is the most consequential webserver option. It controls what data nginx exposes publicly.

- `LIMITED_ACCESS` - hides data that could reveal node locations (IP addresses, honeypot details). Safe for public-facing deployments.
- `FULL_ACCESS` - exposes all data including raw peer addresses. If using this mode, place an authentication layer in front of nginx (basic auth, OAuth proxy, or restrict to a VPN).

The name is deliberately prominent - this is a security-relevant decision.

### Prometheus

`prometheus.retention` controls how long scraped metrics are kept. Uses Prometheus duration syntax. Defaults to `30d`. Increase if you need longer historical data for analysis (e.g. `90d`, `1y`).

### Grafana

`grafana.admin_user` sets the Grafana admin username. The password is managed via agenix (see [Secrets Management](secrets.md)).

### fork-observer

`fork-observer.minForkHeight` sets the minimum block height from which fork-observer tracks forks. The default of `500000` works well for mainnet but will not work for other chains. Set to `0` for regtest or signet.

### Index Page

`index.limitedAccessNotice` accepts an HTML string displayed at the top of the landing page in `LIMITED_ACCESS` mode. Bootstrap classes are available for styling.

`index.fullAccessNotice` accepts an HTML string displayed at the top of the landing page in `FULL_ACCESS` mode. Bootstrap classes are available for styling.

---

## Custom Bitcoin Core Builds

To run a specific Bitcoin Core version, branch, or fork, use `mkCustomBitcoind`:

> **Note:** The eBPF extractor requires **Bitcoin Core v29.0 or newer**. Earlier versions lack the required USDT tracepoints.

```nix
let
  customBitcoind = { system, overrides }:
    (peer-observer-infra-library.lib system).mkCustomBitcoind overrides;
in
{
  nodes = {
    node01 = {
      bitcoind.package = customBitcoind {
        system = "x86_64-linux";
        overrides = {
          gitURL = "https://github.com/bitcoin/bitcoin.git";
          gitBranch = "v29.0";
          gitCommit = "f490f5562d4b20857ef8d042c050763795fd43da";
        };
      };
    };
  };
}
```

All available overrides are defined in [`pkgs/bitcoind/default.nix`](https://github.com/peer-observer/infra-library/blob/master/pkgs/bitcoind/default.nix).

`gitURL`, `gitBranch`, and `gitCommit` select the source to build from.

`fakeVersionMajor` and `fakeVersionMinor` fake the reported version to avoid detection of honeypot nodes.

`sanitizersAddressUndefined` enables address and undefined behaviour sanitizers. Mutually exclusive with the thread sanitizer.

`sanitizersThread` enables the thread sanitizer. Mutually exclusive with the address and undefined behaviour sanitizers.

---

## WireGuard IP Addressing

The WireGuard VPN ties all hosts together. IP addresses are assigned by convention based on host type and `id`:

| Host type | IP range | Example |
|---|---|---|
| Nodes | `10.21.0.x` | `id = 1` → `10.21.0.1` |
| Webservers | `10.21.1.x` | `id = 1` → `10.21.1.1` |

The `id` field determines the last octet. All IDs and public keys must be unique within each host category. See [Secrets Management](secrets.md) for WireGuard key generation and encryption with agenix.
