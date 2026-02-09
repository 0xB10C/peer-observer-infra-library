# Troubleshooting

Common issues and solutions for peer-observer infrastructure.

## Quick Reference

| Issue | Solution |
|-------|----------|
| Services won't start | Check `ls secrets/*.age` — ensure all secrets exist |
| WireGuard issues | `sudo wg show` — verify pubkeys match infra.nix |
| WireGuard peer fails | Set up DNS before redeploying nodes |
| eBPF extractor fails | Check logs; some VPS providers restrict eBPF |
| Permission denied | Ensure SSH key in `global.admin.sshPubKeys` |
| Root SSH disabled | Enable root login on cloud VPS before nixos-anywhere |
| Host key changed | `ssh-keygen -R <ip>` then update secrets.nix and `just rekey` |
| Grafana 404 | `LIMITED_ACCESS` mode — use SSH tunnel to localhost:9321 |
| Grafana wrong port | Grafana runs on 9321, not default 3000 |
| HTTPS not working | Trigger ACME manually: `systemctl start acme-<domain>.service` |
| Ubuntu SSH restart fails | Use `ssh` not `sshd`: `systemctl restart ssh` |
| UEFI vs BIOS boot | Check firmware, not OS: `[ -d /sys/firmware/efi ] && echo UEFI` |
| ssh-keyscan fails | Ignores SSH config — use raw IP and `-p <port>` |
| DNS not resolving | Flush local cache (see DNS section below) |

## Deployment Issues

### "Permission denied" During Deploy

1. Check your SSH key is in `global.admin.sshPubKeys`:
   ```nix
   global.admin.sshPubKeys = [
     "ssh-ed25519 AAAA... your-key"
   ];
   ```

2. Test SSH access manually:
   ```bash
   ssh <username>@<host-ip>
   ```

3. For initial deployment, ensure root SSH access to the server.

### Root SSH Disabled (Cloud Providers)

Some cloud providers (OVH, Hetzner, etc.) provision servers without root SSH access. Before running `nixos-anywhere`, you need to enable it:

```bash
# SSH as the provisioned user (e.g., ubuntu, debian)
ssh ubuntu@<server-ip>

# Enable root login
sudo passwd root
sudo mkdir -p /root/.ssh
sudo cp ~/.ssh/authorized_keys /root/.ssh/authorized_keys
sudo chmod 700 /root/.ssh
sudo chmod 600 /root/.ssh/authorized_keys
sudo sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
sudo systemctl restart ssh  # Use 'sshd' on non-Debian/Ubuntu systems
```

Verify with `ssh root@<server-ip>` before running nixos-anywhere.

### Services Not Starting (setup = false)

When `setup = false`, secrets are required. Check:

```bash
ls -la secrets/*.age
```

You should see:
- `wireguard-private-key-<hostname>.age` for each host
- `grafana-admin-password-<hostname>.age` for webservers

If missing, see [Secrets Management](secrets.md).

### Deploy Command Not Found

From the dev shell, use justfile or shell function:

```bash
nix develop
just deploy node01  # or: deploy node01
```

Or use the direct command:
```bash
nixos-rebuild switch --flake .#node01 --target-host node01 --build-host node01 --sudo
```

### Host Key Changed After Reinstall

When you reinstall the OS (via cloud provider or nixos-anywhere), the host SSH key changes. You'll see:

```text
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
```

Remove the old key and reconnect:

```bash
ssh-keygen -R <host-ip>
ssh root@<host-ip>  # Accept the new key
```

After accepting the new key, update `secrets/secrets.nix` with the new host SSH public key:

```bash
ssh-keyscan <host-ip> 2>/dev/null
```

Then re-encrypt secrets: `just rekey`

### UEFI vs BIOS Boot Mode

When configuring `disko.nix` for a new host, you must know whether the server uses UEFI or BIOS boot. **Don't trust the OS — check the firmware.**

The installed OS may show `/boot/efi` mounted or have UEFI-labeled partitions, but the actual VM firmware could be BIOS (SeaBIOS). If you configure disko for UEFI when the firmware is BIOS, the install completes but the VM won't boot.

**Check boot mode from inside Linux:**
```bash
[ -d /sys/firmware/efi ] && echo UEFI || echo BIOS
```

**Check from VPS console:** Look for "SeaBIOS" (BIOS) vs "OVMF"/"TianoCore" (UEFI) during boot.

**Disko configuration:**
- **BIOS boot**: Use `type = "EF02"` partition (1MB BIOS boot)
- **UEFI boot**: Use `type = "EF00"` partition (512MB ESP at `/boot`)

### ssh-keyscan Ignores SSH Config

`ssh-keyscan` does not read `~/.ssh/config` — it ignores hostname aliases, custom ports, and identity files. You must specify the raw IP and port explicitly:

```bash
# Wrong — uses default port 22 even if config says otherwise
ssh-keyscan node01

# Correct — specify port and raw IP
ssh-keyscan -p <port> <ip-address> 2>/dev/null
```

### VPS Recovery After Failed Install

If nixos-anywhere fails (e.g., wrong boot mode), you may need to reinstall the base OS via your cloud provider's control panel or CLI. Most providers offer a "reinstall" or "rescue" option that lets you start fresh with a standard Linux image.

After reinstalling, the host SSH key will change — see "Host Key Changed After Reinstall" above. You'll also need to re-enable root SSH access before running nixos-anywhere again.

## Network Issues

### WireGuard Connection Problems

Check WireGuard status on both ends:

```bash
sudo wg show
```

Verify:
1. Public keys in `infra.nix` match the encrypted private keys
2. IP addresses are correct (nodes: `10.21.0.x`, webservers: `10.21.1.x`)
3. UDP port 51820 is open on firewall (see [`modules/constants.nix`](../modules/constants.nix))

### WireGuard Peer Fails After Adding Webserver

When you add a webserver, nodes need to be redeployed so they learn about the new WireGuard peer. If the webserver uses a domain name as its endpoint (e.g., `peer.example.com:51820`), **DNS must be configured before redeploying nodes** — otherwise the WireGuard service can't resolve the endpoint and deployment fails.

Order of operations:
1. Deploy webserver
2. Create DNS A record pointing to webserver IP
3. Verify DNS resolution: `dig +short peer.example.com`
4. Redeploy nodes: `just deploy node01`

### Can't Access Grafana Dashboard

> **Note:** The infra-library runs Grafana on port **9321**, not the default 3000. SSH tunnels and URLs should use 9321. See [`modules/constants.nix`](../modules/constants.nix) for port definitions.

1. **Check if using LIMITED_ACCESS mode**: In `LIMITED_ACCESS` mode (set via `access_DANGER` in `infra.nix`), Grafana is not exposed publicly. The index page hides links to monitoring, addrman-observer, debug logs, and websocket entirely, and `/monitoring/` returns 404. This is intentional — use an SSH tunnel to access Grafana:
   ```bash
   ssh -L 9321:localhost:9321 <webserver>
   # Then open http://localhost:9321/monitoring/login
   ```

2. **Check nginx**:
   ```bash
   systemctl status nginx
   journalctl -u nginx -f
   ```

3. **Check ACME/Let's Encrypt**: The initial deploy uses a self-signed certificate so nginx can start. The real Let's Encrypt certificate is fetched by a timer that may not run for hours. To get the certificate immediately after DNS is configured:
   ```bash
   sudo systemctl start acme-<domain>.service
   sudo systemctl reload nginx
   ```

   Check certificate status:
   ```bash
   systemctl status acme-<domain>
   ls -la /var/lib/acme/<domain>/
   ```

4. **Check DNS** points to webserver IP:
   ```bash
   dig +short peer.example.com
   ```

5. **Stale DNS cache**: If you tried resolving the domain before the A record existed, your system may have cached the "not found" response. Flush the cache:
   ```bash
   # macOS
   sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder

   # Linux (systemd-resolved)
   sudo systemd-resolve --flush-caches
   ```

   Verify the record is live upstream:
   ```bash
   dig peer.example.com @1.1.1.1 +short
   ```

## Service Issues

### eBPF Extractor Failing

The eBPF extractor requires kernel support for tracing. The peer-observer NixOS module configures the necessary capabilities (`CAP_BPF`, `CAP_PERFMON`, `CAP_SYS_RESOURCE`) automatically via systemd.

1. **Check extractor logs**:
   ```bash
   journalctl -u peer-observer-ebpf-extractor -f
   ```
   Look for capability or permission errors.

2. **After restarting Bitcoin Core**: The eBPF extractor attaches to the bitcoind process by PID. If you restart Bitcoin Core, restart the eBPF extractor too:
   ```bash
   sudo systemctl restart peer-observer-ebpf-extractor
   ```

3. **Idle exit behavior**: The eBPF extractor automatically exits after 180 seconds of inactivity (no events from tracepoints). This is by design — systemd will restart it automatically. If you see repeated restarts, check that Bitcoin Core is actively processing transactions and connections.

4. **Check if hosting provider restricts eBPF**:
   Some VPS providers (especially shared hosting) restrict eBPF at the kernel level. Try a dedicated server or different provider.

### Bitcoin Core USDT Tracepoints Not Working

1. **Check Bitcoin Core version**: The eBPF extractor requires **Bitcoin Core v29.0 or newer**. The infra-library builds from master by default (which includes v29+ tracepoints). If using a custom `bitcoind.package`, ensure it's v29.0+.

2. **Check the eBPF extractor can attach**:
   ```bash
   journalctl -u peer-observer-ebpf-extractor | grep -i attach
   ```
   Successful attachment shows messages like `Attached to tracepoint...`

3. **Verify Bitcoin Core was built with tracepoints**:
   The infra-library builds Bitcoin Core with `-DWITH_USDT=ON`. If using a custom build, ensure tracepoints are enabled.

### NATS Not Running

```bash
systemctl status nats
journalctl -u nats -f
```

Check if another service is using port 4222.

### NATS "Maximum Payload Violation"

If you see errors like:
```text
Maximum Payload Violation on connection [12]
ERROR [extractor] could not publish message: Connection reset by peer
```

The infra-library configures NATS with `max_payload = 5242880` (5 MB) to handle large P2P messages. If you see this error, NATS may have been configured separately or the setting was overridden. Check the NATS configuration includes the increased payload limit.

### RPC Extractor Not Working

The RPC extractor queries Bitcoin Core's RPC endpoint every 10 seconds.

1. **Check extractor logs**:
   ```bash
   journalctl -u peer-observer-rpc-extractor -f
   ```

2. **Verify RPC connectivity**: The infra-library configures RPC credentials automatically (see [`modules/constants.nix`](../modules/constants.nix)). If you see authentication errors, check that bitcoind is running and the RPC port (8332) is accessible on localhost.

## Secrets Issues

### "no secret key" During Deployment

The host can't decrypt its secrets.

1. **Verify host SSH key** in `secrets/secrets.nix`:
   ```bash
   ssh-keyscan <host-ip> 2>/dev/null
   ```
   Compare with key in `secrets.nix`.

2. **Re-encrypt secrets**:
   ```bash
   just rekey
   # Or manually: cd secrets && agenix -r
   ```

### Can't Edit Secrets Locally

Your age key isn't listed as a recipient.

1. Check your age public key is in `secrets.nix`:
   ```nix
   let
     user = "age1...";  # Your key
   in {
     "some-secret.age".publicKeys = [ host user ];  # Must include 'user'
   }
   ```

2. Re-encrypt:
   ```bash
   just rekey
   ```

## Checking Service Status

### All Services at Once

```bash
systemctl list-units --type=service | grep -E "(bitcoin|peer-observer|nats|grafana|prometheus|fork-observer|nginx)"
```

### Individual Services

```bash
# Node services
systemctl status bitcoind-mainnet
systemctl status nats
systemctl status peer-observer-ebpf-extractor
systemctl status peer-observer-rpc-extractor
systemctl status peer-observer-p2p-extractor
systemctl status peer-observer-tool-metrics
systemctl status peer-observer-tool-websocket

# Webserver services
systemctl status nginx
systemctl status grafana
systemctl status prometheus
systemctl status fork-observer
```

### Logs

```bash
# Follow logs for a service
journalctl -u <service-name> -f

# Last 100 lines
journalctl -u <service-name> -n 100

# Since boot
journalctl -u <service-name> -b
```

## Getting Help

If you're still stuck:

1. Check the [peer-observer repository](https://github.com/peer-observer/peer-observer) for issues
2. Open an issue at [infra-library](https://github.com/peer-observer/infra-library/issues)
3. Include relevant logs and your (sanitized) configuration
