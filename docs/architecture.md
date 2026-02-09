# Architecture

This document describes the peer-observer infrastructure architecture for a typical, multi-node deployment.

## Typical Deployment (multi-node)

![Peer Observer multi-node architecture](images/multi-node-deployment-illustration.png)

## Components Overview

### Admin Workstation

The admin workstation is where you manage your infrastructure configuration and deployment. It includes:
- Nix dev shell - provides shell functions (`deploy`, `build-vm`), tools (`agenix`, `nixos-rebuild`, `nixos-anywhere`), and `just` recipes
- age keys - for encrypting secrets that nodes can decrypt
- `nixos-anywhere` - for initial deployment to fresh servers
- `nixos-rebuild` - for subsequent configuration updates

Configuration files (`flake.nix`, `infra.nix`) live on your workstation and are pushed to nodes during deployment. See [Secrets Management](secrets.md) for how `agenix` handles encryption and decryption.

### Peer Observer Nodes

Each node is a self-contained monitoring unit running:

#### Bitcoin Core

Instrumented Bitcoin Core node that connects to the Bitcoin P2P network as a passive observer.
- Port 8333 P2P (public) — accepts inbound connections from the Bitcoin network
- Port 8332 RPC (localhost) — bound to `127.0.0.1` by default; additionally bound to the WireGuard interface when fork-observer or addrman-observer need remote RPC access (see [Configuration Reference](configuration.md))
- Built with USDT tracepoints enabled for eBPF monitoring
- Pruned by default (4000 MB, ~4GB of recent blocks)

#### Extractors

Extractors extract events from a Bitcoin Core node and publish them to the connected NATS server.

| Extractor | Method | Data Collected |
|-----------|--------|----------------|
| [eBPF](https://github.com/peer-observer/peer-observer/tree/master/extractors/ebpf) | USDT tracepoints | Low-level events (connections, messages, validation) |
| [RPC](https://github.com/peer-observer/peer-observer/tree/master/extractors/rpc) | JSON-RPC polling | Chain state, mempool, peer info |
| [P2P](https://github.com/peer-observer/peer-observer/tree/master/extractors/p2p) | Network tap | Raw P2P message traffic |
| [Log](https://github.com/peer-observer/peer-observer/tree/master/extractors/log) | Log parsing | Debug log events (disabled by default) |

> **Note**: The eBPF extractor requires Bitcoin Core v29.0 or newer for USDT tracepoint support.

#### NATS Server

Message broker that connects extractors to tools via event streaming.
- Port 4222 (localhost) — bound to `127.0.0.1`, no network exposure
- Extractors publish protobuf-serialized data
- Tools subscribe to relevant event streams

#### Tools

Tools connect and subscribe to the NATS server to learn about new events. Each tool uses the events differently:

| Tool | Description |
|------|-------------|
| [metrics](https://github.com/peer-observer/peer-observer/tree/master/tools/metrics) | Produces Prometheus metrics from events. |
| [websocket](https://github.com/peer-observer/peer-observer/tree/master/tools/websocket) | Publishes events into a WebSocket as JSON. |
| [connectivity-check](https://github.com/peer-observer/peer-observer/tree/master/tools/connectivity-check) | Connects to IP addresses received via `addr(v2)` messages and records the result. |
| [logger](https://github.com/peer-observer/peer-observer/tree/master/tools/logger) | Logs events to stdout with optional filtering. CLI debugging tool, not a background service. |

#### Prometheus Scrape Targets

Each host exposes Prometheus-compatible metrics endpoints over the WireGuard VPN only — firewall rules restrict all exporter ports to the WireGuard interface. The webserver runs the Node and WireGuard exporters too, but nodes additionally expose peer-observer-specific metrics:

| Exporter | Port | Exposure | Description |
|----------|------|----------|-------------|
| Node exporter | 9100 | WireGuard | System metrics (CPU, memory, disk). |
| WireGuard exporter | 9586 | WireGuard | VPN tunnel metrics. |
| Process exporter | 9256 | WireGuard | Per-process resource usage (`bitcoind`). |
| Peer-observer metrics | 8282 → 18282 | localhost → WireGuard | Custom metrics from Bitcoin node events. Bound to localhost, gzip-proxied on 18282 via the WireGuard interface. |
| Peer-observer addr connectivity | 8283 | WireGuard | Address connectivity check results (when `addrLookup` enabled). |

### Central Webserver

Aggregates data from all peer-observer nodes into a single interface.

#### nginx

Reverse proxy with Let's Encrypt TLS that routes requests to internal services.
- Ports 80/443 (public) — the only public-facing web ports
- All backend services bind to localhost and are accessed exclusively through nginx

#### Services

All services bind to localhost and are proxied through nginx. See [Configuration Reference](configuration.md) for webserver options.

| Service | Port | Description |
|---------|------|-------------|
| Prometheus | 9090 (localhost) | Scrapes [metrics endpoints](#prometheus-scrape-targets) from all nodes via WireGuard. |
| Grafana | 9321 (localhost) | Dashboards of Prometheus data. See [dashboards](https://github.com/peer-observer/peer-observer/tree/master/tools/metrics/dashboards). |
| [fork-observer](https://github.com/0xB10C/fork-observer) | 2839 (localhost) | Tracks chain tips across all nodes, detects forks and stale blocks, identifies mining pools. Uses node RPC via WireGuard. |
| [addrman-observer](https://github.com/0xB10C/addrman-observer) | 2838 (localhost) | Visualizes the address manager state across all nodes via `getrawaddrman` RPC over WireGuard. |
| Debug log viewer | — | Proxies rotated Bitcoin Core debug logs from each node (fetched from node port 38821 over WireGuard). Served via nginx at `/debug-logs/<node>/`. |

### Network Connectivity

#### WireGuard VPN

Encrypted VPN where each node peers with the webserver(s), but nodes do not peer with each other. See [Secrets Management](secrets.md) for WireGuard key setup.
- Port UDP 51820 (public) — must be reachable for tunnel establishment
- IP addressing: nodes `10.21.0.x`, webservers `10.21.1.x`
- All inter-host communication (Prometheus scraping, RPC for fork-observer/addrman-observer, debug log proxying) runs over this tunnel
- Serves as the primary security boundary: all node metrics and RPC ports are firewalled to the WireGuard interface only

#### Bitcoin P2P

Each node connects to the Bitcoin network independently.
- Port TCP 8333 (public, mainnet default) — the only other public-facing port on nodes besides WireGuard. Port varies by network: 18333 (testnet3), 48333 (testnet4), 38333 (signet), 18444 (regtest)
- Optionally routes through Tor, I2P, or CJDNS for anonymous connections (see [Configuration Reference](configuration.md))

## Security Boundaries

The infrastructure uses three network zones. No metrics, RPC, or internal service port is ever exposed to the public internet.

**Public (internet-facing):**

| Port | Protocol | Host | Purpose |
|------|----------|------|---------|
| 8333 | TCP | Nodes | Bitcoin P2P — required for network participation |
| 51820 | UDP | All hosts | WireGuard tunnel establishment |
| 80, 443 | TCP | Webserver | nginx reverse proxy with TLS |

**WireGuard VPN only (`10.21.x.x`):**

All monitoring data flows over the encrypted WireGuard tunnel. Firewall rules on each node restrict these ports to the WireGuard interface — they are unreachable from the public internet even though some exporters bind to all interfaces by default.

| Port | Host | Purpose |
|------|------|---------|
| 9100 | All hosts | Node exporter (system metrics) |
| 9586 | All hosts | WireGuard exporter |
| 9256 | Nodes | Process exporter (`bitcoind`) |
| 18282 | Nodes | Peer-observer metrics (gzip-compressed proxy) |
| 8283 | Nodes | Address connectivity metrics (when enabled) |
| 8284 | Nodes | WebSocket tool |
| 38821 | Nodes | Debug log proxy (bandwidth-limited) |
| 8332 | Nodes | Bitcoin Core RPC (only when fork-observer or addrman-observer is enabled) |

**Localhost only (`127.0.0.1`):**

These services never accept network connections. On the webserver, nginx proxies external requests to them. On nodes, they communicate only with co-located processes.

| Port | Host | Purpose |
|------|------|---------|
| 4222 | Nodes | NATS server |
| 8282 | Nodes | Peer-observer metrics (pre-compression) |
| 9090 | Webserver | Prometheus |
| 9321 | Webserver | Grafana |
| 2839 | Webserver | fork-observer |
| 2838 | Webserver | addrman-observer |

## Fault Tolerance

Nodes are fully self-contained — each runs its own NATS server, extractors, and tools with no cross-node dependencies. If a node goes down, the others are unaffected. The webserver only aggregates; it does not coordinate. 

If the webserver goes down, nodes continue collecting data independently — the only impact is loss of the aggregated view until it recovers.

Prometheus tolerates unavailable scrape targets and Grafana shows data gaps rather than failing. See [Troubleshooting](troubleshooting.md) for diagnosing common failures.
