{
  nixpkgs,
  peer-observer-infra-library,
  system,
  ...
}:

let

  pkgs = import nixpkgs { inherit system; };
  lib = pkgs.lib;

  CONSTANTS = peer-observer-infra-library.constants;

  infraConfig = import ./test-infra.nix { inherit system peer-observer-infra-library; };

  nodeMachines = lib.mapAttrs (name: nodeConfig: {
    imports = peer-observer-infra-library.mkModules nodeConfig.extraModules;
    config = peer-observer-infra-library.mkNodeConfig name nodeConfig infraConfig;
  }) infraConfig.nodes;

  webserverMachines = lib.mapAttrs (name: webConfig: {
    imports = peer-observer-infra-library.mkModules webConfig.extraModules;
    config = peer-observer-infra-library.mkWebConfig name webConfig infraConfig;
  }) infraConfig.webservers;

  allMachines = nodeMachines // webserverMachines;

in

pkgs.testers.runNixOSTest {
  name = "test";

  nodes = allMachines;

  testScript = ''
    import time
    import json

    def assert_log(expected, output, negated=False):
      print(f"asserting that '{expected}' is in output..")
      print(f"output: {output}")
      result = expected in output
      if negated:
        result = not result
      if not result:
        print(f"ASSERT: expected is {"" if negated else "not "}in output!")
      assert result

    def check_bitcoind_rpc_connectivity():
      print("check that the Bitcoin RPC port is NOT reachable")
      node1.wait_for_closed_port(${toString CONSTANTS.BITCOIND_RPC_PORT}, addr="node1", timeout=10)
      node2.wait_for_closed_port(${toString CONSTANTS.BITCOIND_RPC_PORT}, addr="node2", timeout=10)

      print("check that web1 can reach the bitcoind RPC on node1 via wireguard")
      command = "curl ${infraConfig.nodes.node1.wireguard.ip}:${toString CONSTANTS.NODE_TO_WEBSERVER_PORT}${CONSTANTS.NODE_TO_WEBSERVER_PATH_BITCOIND_RPC}"
      output = web1.succeed(command)
      print(f"{command}: {output}")
      assert_log("JSONRPC server handles only POST requests", output)

    def check_peer_observer_metrics_tool():
      # Give the metrics tool a few seconds to start up
      time.sleep(4)

      print("check peer-observer-metrics-tool metrics")
      # fetching node2 here since it has an inbound connection from node1
      command = "curl ${infraConfig.nodes.node2.wireguard.ip}:${toString CONSTANTS.NODE_TO_WEBSERVER_PORT}${CONSTANTS.NODE_TO_WEBSERVER_PATH_PEER_OBSERVER_METRICS_TOOL}"
      output = web1.succeed(command)
      print(f"{command}: {output}")

      assert_log("peerobserver_runtime_start_timestamp ", output)
      assert_log("peerobserver_runtime_start_timestamp 0", output, negated=True)

      print("check that the ebpf-extractor works..")
      assert_log("peerobserver_validation_block_connected_latest_height 20", output)

      print("check that the rpc-extractor works..")
      assert_log("peerobserver_rpc_blockchaininfo_pruned 1", output)
      assert_log("peerobserver_rpc_peer_info_num_peers 1", output)

      print("check that the ipc-extractor works..")
      assert_log("peerobserver_ipc_block_tip_height 20", output)

    def check_fork_observer():
      web1.wait_for_unit("fork-observer.service")
      print("wait for fork-observer to do its first getchaintips query..")
      # It first tries to fetch the version 5x and waits 10s...
      # See https://github.com/0xB10C/fork-observer/issues/107
      time.sleep(60)
      print("check for limited (public) fork-observer on web1")
      command = "curl 127.0.0.1:${toString CONSTANTS.NGINX_INTERNAL_LIMITED_ACCESS_PORT}/forks/api/networks.json"
      output = web1.succeed(command)
      print(f"{command}: {output}")
      assert_log('{"networks":[{"id":1,"name":"regtest","slug":"regtest","description":"  fork-observer attached to peer-observer nodes"}]}', output)
      command = "curl 127.0.0.1:${toString CONSTANTS.NGINX_INTERNAL_LIMITED_ACCESS_PORT}/forks/api/1/data.json"
      output = web1.succeed(command)
      print(f"{command}: {output}")
      assert_log("0fc83a94-3eee-44c2-87b4-441638dd75ac", output)
      assert_log("09b318bd-fb84-48b3-9984-5f60ebddf864", output)
      assert_log('"status":"active","height":20', output)

    def check_for_wireguard():
      print("waiting for wireguard-${CONSTANTS.WIREGUARD_INTERFACE_NAME}.service on node1, node2, web1")
      node1.wait_for_unit("wireguard-${CONSTANTS.WIREGUARD_INTERFACE_NAME}.service")
      node2.wait_for_unit("wireguard-${CONSTANTS.WIREGUARD_INTERFACE_NAME}.service")
      web1.wait_for_unit("wireguard-${CONSTANTS.WIREGUARD_INTERFACE_NAME}.service")
      # web2 doesn't have a wireguard interface as it's "setup = true;"

    def check_for_index_on_webserver():
      print("check for index.html.nix on web1")
      web1.wait_for_unit("nginx.service")
      command = "curl 127.0.0.1:${toString CONSTANTS.NGINX_INTERNAL_FULL_ACCESS_PORT}"
      output = web1.succeed(command)
      print(f"{command}: {output}")
      assert_log("""${infraConfig.nodes.node1.description}""", output)
      assert_log("""${infraConfig.nodes.node2.description}""", output)

    def check_for_addrman_observer_on_webserver():
      # without trailing slash
      command = "curl 127.0.0.1:${toString CONSTANTS.NGINX_INTERNAL_FULL_ACCESS_PORT}/addrman"
      output = web1.succeed(command)
      print(f"{command}: {output}")
      assert_log("302 Found", output)

      # with trailing slash
      command = "curl 127.0.0.1:${toString CONSTANTS.NGINX_INTERNAL_FULL_ACCESS_PORT}/addrman/"
      output = web1.succeed(command)
      print(f"{command}: {output}")
      assert_log("addrman-observer", output)

    def wait_until_nodes_connected():
      bitcoin_cli = "${pkgs.bitcoind}/bin/bitcoin-cli -rpcport=${toString CONSTANTS.BITCOIND_RPC_PORT} -datadir=/var/lib/bitcoind-mainnet/regtest"
      print("wait until the two nodes are connected")
      command = bitcoin_cli + " getpeerinfo | jq 'select(. | length >= 1) // error(\"Array length is not >= 1\")'"
      node2.wait_until_succeeds(command, 70)

      command = bitcoin_cli + " getpeerinfo | jq '. | length'"
      peers = node2.succeed(command)
      print(f"node2 has {peers} peer(s)")

      print("mine a few blocks on node2")
      command = bitcoin_cli + " generatetoaddress 20 bcrt1qs758ursh4q9z627kt3pp5yysm78ddny6txaqgw"
      node2.succeed(command)

      # give nodes a bit of time to sync
      time.sleep(4)

    def check_bitcoind_p2p_port_reachable():
      print("from node1, check if node2's Bitcoin node P2P port is reachable and vice-versa")
      node1.wait_for_open_port(${toString infraConfig.nodes.node2.bitcoind.customPort}, addr="node2", timeout=60);
      node2.wait_for_open_port(${
        toString CONSTANTS.BITCOIND_P2P_PORT_BY_CHAIN."${infraConfig.nodes.node1.bitcoind.chain}"
      }, addr="node1", timeout=60);

    def check_node_webserver_interface():
      # create a fake log file on both nodes so that the nginx returns something
      node1.succeed("mkdir -p ${CONSTANTS.DEBUG_LOGS_DIR}")
      node1.succeed("touch ${CONSTANTS.DEBUG_LOGS_DIR}/fake-log.debug.gz")
      node2.succeed("mkdir -p ${CONSTANTS.DEBUG_LOGS_DIR}")
      node2.succeed("touch ${CONSTANTS.DEBUG_LOGS_DIR}/fake-log.debug.gz")

      print("check that web1 can access the exposed webserver paths on the nodes")
      for node in ["${infraConfig.nodes.node1.wireguard.ip}", "${infraConfig.nodes.node2.wireguard.ip}"]:
        web1.wait_for_open_port(${toString CONSTANTS.NODE_TO_WEBSERVER_PORT}, addr=node, timeout=10);
        paths = ${builtins.toJSON CONSTANTS.NODE_TO_WEBSERVER_PATHS}
        for path in paths:
          print(f"checking path={path} on node={node}")
          extra_args = ""
          if path == "${CONSTANTS.NODE_TO_WEBSERVER_PATH_PEER_OBSERVER_WEBSOCKET_TOOL}":
            extra_args = "-H 'Connection: upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Key: peerobservertest' -H 'Sec-WebSocket-Version: 13'"
          command = f"curl -s -I -X GET {extra_args} {node}:${toString CONSTANTS.NODE_TO_WEBSERVER_PORT}{path} || true"

          output = web1.succeed(command)
          print(f"{command}: {output}")
          match path:
            case "${CONSTANTS.NODE_TO_WEBSERVER_PATH_PEER_OBSERVER_WEBSOCKET_TOOL}":
              assert_log("HTTP/1.1 101 Switching Protocols", output)
            case "${CONSTANTS.NODE_TO_WEBSERVER_PATH_BITCOIND_RPC}":
              # Bitcoin Core RPC doesn't like HEAD requests, but that's fine as it means: Bitcoin Core is reachable
              assert_log("HTTP/1.1 405 Method Not Allowed", output)
            case _:
              assert_log("HTTP/1.1 200 OK", output)

    def check_samply_continuous_profiling():
      print("waiting for bitcoind-profiling.service on node1")
      node1.wait_for_unit("bitcoind-profiling.service")

      print("waiting for samply to produce a profile file in /data/profiling on node1")
      # node1's extraConfig overrides the capture duration to 5s, so the first
      # file should land within a few seconds of the service starting.
      node1.wait_until_succeeds(
        "ls /data/profiling/bitcoind-*-node1.json.gz",
        timeout=120,
      )

      output = node1.succeed("ls -la /data/profiling/")
      print(f"profile dir contents: {output}")

      filename = node1.succeed(
        "ls /data/profiling/bitcoind-*-node1.json.gz | head -1"
      ).strip()
      print(f"checking that {filename} is non-empty")
      size = int(node1.succeed(f"stat -c '%s' {filename}").strip())
      print(f"profile file size: {size} bytes")
      assert size > 0, f"profile file {filename} is empty"

      print("verifying filename format: bitcoind-YYYYMMDD-HHMMSS-node1.json.gz")
      import re
      basename = filename.split("/")[-1]
      assert re.match(r"^bitcoind-\d{8}-\d{6}-node1\.json\.gz$", basename), \
        f"unexpected profile filename: {basename}"

      print("verifying node2 (samply-continuous-profiling=false) has no profile files")
      node2.fail("ls /data/profiling/bitcoind-*.json.gz")

      print("checking webserver can fetch a profile file from node1 via wireguard")
      profile_name = node1.succeed(
        "ls /data/profiling/bitcoind-*-node1.json.gz | head -1 | xargs basename"
      ).strip()
      command = f"curl -s -I ${infraConfig.nodes.node1.wireguard.ip}:${toString CONSTANTS.NODE_TO_WEBSERVER_PORT}${CONSTANTS.NODE_TO_WEBSERVER_PATH_PROFILING}{profile_name}"
      output = web1.succeed(command)
      print(f"{command}: {output}")
      assert_log("HTTP/1.1 200 OK", output)

      print("triggering bitcoind-profiling-cleanup.service on node1")
      node1.succeed("systemctl start bitcoind-profiling-cleanup.service")

    def check_debug_log_rotation():
      """Tests the hourly SIGHUP-based debug.log rotation: each run renames the
      live log aside, has bitcoind reopen a fresh one via SIGHUP, and appends the
      compressed chunk to a per-day gzip archive staged next to debug.log in the
      bitcoind data dir. A day's archive is only published to the served/rcloned
      DEBUG_LOGS_DIR once it is finalized (we've rolled into the next day), so a
      half-finished day is never exposed. node1 has detailedLogging enabled
      (logsToKeep=2) and runs on regtest, so debug.log lives in the regtest/
      subdir."""
      import re

      # In-progress archives are staged next to debug.log in the data dir.
      staging = "/var/lib/bitcoind-mainnet/regtest"
      served = "${CONSTANTS.DEBUG_LOGS_DIR}"
      debug_log = f"{staging}/debug.log"
      bitcoin_cli = "${pkgs.bitcoind}/bin/bitcoin-cli -rpcport=${toString CONSTANTS.BITCOIND_RPC_PORT} -datadir=/var/lib/bitcoind-mainnet/regtest"
      gzip = "${pkgs.gzip}/bin/gzip"
      zcat = "${pkgs.gzip}/bin/zcat"
      # Mining forces bitcoind to emit log lines (so debug.log has content and
      # bitcoind acts on a pending SIGHUP reopen). Runs after the height-
      # sensitive checks, so extra blocks here are harmless.
      mine = bitcoin_cli + " generatetoaddress 1 bcrt1qs758ursh4q9z627kt3pp5yysm78ddny6txaqgw"
      rotate = "systemctl start bitcoind-debug-log-rotate.service"

      print("checking the hourly rotation timer is active on node1")
      node1.wait_for_unit("bitcoind-debug-log-rotate.timer")

      print("verifying the log-extractor fifo pipe follows with `tail -F` (rotation-safe)")
      execstart = node1.succeed(
        "systemctl show peer-observer-log-extractor-fifo-pipe.service --property=ExecStart"
      )
      print(execstart)
      assert_log("tail -F", execstart)
      assert "tail -f " not in execstart, "fifo pipe still uses inode-following `tail -f`"

      print("waiting for bitcoind's debug.log to exist on node1")
      node1.wait_until_succeeds(f"test -f {debug_log}", timeout=60)
      node1.succeed(mine)
      old_inode = node1.succeed(f"stat -c %i {debug_log}").strip()
      print(f"debug.log inode before rotation: {old_inode}")

      print("triggering bitcoind-debug-log-rotate.service (first run)")
      node1.succeed(rotate)

      print("checking the current day's chunk lands in STAGING, not the served dir")
      staged = node1.succeed(f"ls {staging}/debug.log-*-node1.gz | head -1").strip()
      basename = staged.split("/")[-1]
      print(f"staged archive: {basename}")
      assert re.match(r"^debug\.log-\d{8}-node1\.gz$", basename), \
        f"unexpected archive name: {basename}"
      # The archive is dated with `date -d '1 hour ago'`, which is always today
      # or yesterday; this locks in the day-boundary-safe naming (a 00:00 run
      # files the previous day's lines under the previous day).
      file_date = basename[len("debug.log-"):len("debug.log-") + 8]
      today = node1.succeed("date +%Y%m%d").strip()
      yesterday = node1.succeed("date -d yesterday +%Y%m%d").strip()
      assert file_date in (today, yesterday), \
        f"archive date {file_date} is neither today {today} nor yesterday {yesterday}"
      print("checking the unfinished current day is NOT yet in the served/rcloned dir")
      node1.fail(f"ls {served}/debug.log-*-node1.gz")

      print("checking the staged archive is a valid gzip and decompresses to log content")
      node1.succeed(f"{gzip} -t {staged}")
      contents = node1.succeed(f"{zcat} {staged}")
      assert len(contents) > 0, "staged archive decompressed to empty output"

      print("checking bitcoind reopened a fresh debug.log after SIGHUP (new inode)")
      node1.succeed(mine)
      node1.wait_until_succeeds(f"test -f {debug_log}", timeout=30)
      new_inode = node1.succeed(f"stat -c %i {debug_log}").strip()
      print(f"debug.log inode after rotation: {new_inode}")
      assert new_inode != old_inode, \
        f"debug.log inode unchanged ({old_inode}); bitcoind did not reopen after SIGHUP"

      print("second rotation appends another gzip member to the same staged day file")
      size1 = int(node1.succeed(f"stat -c %s {staged}").strip())
      node1.succeed(mine)
      node1.succeed(rotate)
      node1.succeed(f"{gzip} -t {staged}")  # still valid as a multi-member gzip
      size2 = int(node1.succeed(f"stat -c %s {staged}").strip())
      assert size2 > size1, \
        f"staged archive did not grow on the second rotation ({size1} -> {size2}); append/concat broken"
      print("checking the current day is still NOT published to the served dir")
      node1.fail(f"ls {served}/debug.log-*-node1.gz")

      print("checking a completed (older) day gets finalized to the served dir")
      # Stage a file for an earlier day; the next run's accumulating day differs
      # from it, so it must be published to the served/rcloned dir and removed
      # from staging, while the current day's file stays put.
      finalized = f"{served}/debug.log-20200101-node1.gz"
      old_staged = f"{staging}/debug.log-20200101-node1.gz"
      node1.succeed(f"install -m644 {staged} {old_staged}")
      node1.succeed(mine)
      node1.succeed(rotate)
      node1.succeed(f"test -f {finalized}")            # published
      node1.fail(f"test -e {old_staged}")              # removed from staging
      node1.succeed(f"test -f {staged}")               # current day still staged
      node1.succeed(f"{gzip} -t {finalized}")          # published file is a valid gzip

      print("checking retention deletes published archives older than logsToKeep (2) days")
      old_archive = f"{served}/debug.log-20200102-node1.gz"
      node1.succeed(f"install -m644 {staged} {old_archive}")
      node1.succeed(f"touch -d '30 days ago' {old_archive}")
      node1.succeed(mine)
      node1.succeed(rotate)
      node1.fail(f"test -e {old_archive}")
      print("checking the freshly-finalized archive survived retention")
      node1.succeed(f"test -f {finalized}")

      print("checking the log-extractor kept following the rotated log")
      node1.succeed("systemctl is-active peer-observer-log-extractor-fifo-pipe.service")
      node1.succeed("systemctl is-active peer-observer-log-extractor.service")

    def check_bitcoind_no_restart_on_crash():
      """Regression test for infra-library issue #190: after a crash/OOM-kill
      bitcoind must NOT be automatically restarted, and the samply
      bitcoind-profiling unit must not resurrect it via a requirement
      dependency. node1 has samply-continuous-profiling enabled (the case that
      regressed); node2 does not. This is destructive to bitcoind on node1, so
      it runs last."""
      import time

      print("verifying bitcoind-mainnet has Restart=no on node1 and node2")
      for node in [node1, node2]:
        restart = node.succeed(
          "systemctl show bitcoind-mainnet.service --property=Restart --value"
        ).strip()
        assert restart == "no", f"expected bitcoind-mainnet Restart=no, got {restart!r}"

      print("verifying bitcoind-profiling has no upward (pull-up) dependency on bitcoind on node1")
      # After/PartOf/Requisite are fine (no upward activation). Requires/BindsTo/
      # Wants would let the profiler's Restart=always cycle start a stopped
      # bitcoind back up and defeat Restart=no.
      for prop in ["Requires", "BindsTo", "Wants"]:
        deps = node1.succeed(
          f"systemctl show bitcoind-profiling.service --property={prop} --value"
        ).strip()
        assert "bitcoind-mainnet.service" not in deps, \
          f"bitcoind-profiling {prop} must not contain bitcoind-mainnet.service, got: {deps!r}"

      node1.wait_for_unit("bitcoind-profiling.service")

      print("simulating an OOM-kill of bitcoind on node1 (SIGKILL of the whole unit)")
      node1.succeed("systemctl kill --signal=SIGKILL bitcoind-mainnet.service")

      print("waiting for bitcoind-mainnet to leave the active state on node1")
      node1.wait_until_fails("systemctl is-active bitcoind-mainnet.service")

      print("giving bitcoind-profiling's Restart=always (RestartSec=10s) a chance to resurrect it")
      time.sleep(30)

      print("verifying bitcoind-mainnet stayed down (was NOT auto-restarted)")
      node1.fail("systemctl is-active bitcoind-mainnet.service")

      print("verifying bitcoind can still be started manually again on node1")
      node1.succeed("systemctl start bitcoind-mainnet.service")
      node1.wait_for_unit("bitcoind-mainnet.service")

    def check_prometheus_scrape_config():
      """Verify each remote-node Prometheus scrape job uses the correct URL path
      from CONSTANTS. Catches bugs where the wrong metrics_path or port
      constant is used in the scrape config."""

      print("checking Prometheus scrape configuration for remote node jobs...")
      web1.wait_for_open_port(9090, timeout=60)
      command = "curl -sf 'http://127.0.0.1:9090/api/v1/targets?state=active'"
      output = web1.wait_until_succeeds(command, timeout=60)
      data = json.loads(output)

      # Map: job_name -> expected path substring in scrapeUrl
      # Uses the same CONSTANTS as the scrape config in web.nix
      expected_paths = {
        "node": "${CONSTANTS.NODE_TO_WEBSERVER_PATH_PROMETHEUS_EXPORTER_NODE}",
        "wireguard": "${CONSTANTS.NODE_TO_WEBSERVER_PATH_PROMETHEUS_EXPORTER_WIREGUARD}",
        "process-exporter": "${CONSTANTS.NODE_TO_WEBSERVER_PATH_PROMETHEUS_EXPORTER_PROCESS}",
        "peer-observer-metrics": "${CONSTANTS.NODE_TO_WEBSERVER_PATH_PEER_OBSERVER_METRICS_TOOL}",
        "peer-observer-addr-connectivity": "${CONSTANTS.NODE_TO_WEBSERVER_PATH_PEER_OBSERVER_ADDRESSCONNECTIVITY_TOOL}",
      }

      targets_by_job = {}
      for target in data["data"]["activeTargets"]:
        job = target["labels"]["job"]
        targets_by_job.setdefault(job, []).append(target)

      for job, expected_path in expected_paths.items():
        print(f"  checking job '{job}'...")
        assert job in targets_by_job, \
          f"No targets found for Prometheus job '{job}'"
        for target in targets_by_job[job]:
          url = target["scrapeUrl"]
          health = target["health"]
          print(f"    url='{url}' health='{health}'")
          assert expected_path in url, \
            f"Job '{job}' scrapes '{url}' but expected path containing '{expected_path}'"

      print("all Prometheus remote-node scrape jobs correctly configured!")

    def check_grafana_image_renderer():
      """Regression test: `services.grafana-image-renderer.settings` is a
      freeform option that nixpkgs turns into CLI flags verbatim, so an option
      name that upstream has since renamed still evaluates and still builds, and
      only fails once the service starts. Checks that the renderer actually
      comes up."""

      addr = "127.0.0.1:${toString CONSTANTS.GRAFANA_IMAGE_RENDERER_PORT}"

      print("waiting for grafana-image-renderer.service on web1")
      web1.wait_for_unit("grafana-image-renderer.service")
      web1.wait_for_open_port(${toString CONSTANTS.GRAFANA_IMAGE_RENDERER_PORT}, timeout=60)

      print("checking the renderer serves on the address we configured")
      output = web1.succeed(f"curl -sf http://{addr}/healthz")
      assert_log("OK", output)

    def check_addrman_snapshots():
      print("triggering addrman-snapshot.service on node1")
      node1.succeed("systemctl start addrman-snapshot.service")

      print("checking that a snapshot file was created in ${CONSTANTS.ADDRMAN_SNAPSHOTS_DIR}")
      output = node1.succeed("ls ${CONSTANTS.ADDRMAN_SNAPSHOTS_DIR}/addrman-*.json.zst")
      print(f"snapshot files: {output}")

      print("checking snapshot decompresses to valid addrman JSON (new/tried tables)")
      output = node1.succeed(
        "${pkgs.zstd}/bin/zstd -d -c $(ls ${CONSTANTS.ADDRMAN_SNAPSHOTS_DIR}/addrman-*.json.zst | head -1)"
      )
      assert_log('"new"', output)
      assert_log('"tried"', output)

      print("checking webserver can fetch an addrman snapshot from node1 via wireguard")
      snapshot_name = node1.succeed(
        "ls ${CONSTANTS.ADDRMAN_SNAPSHOTS_DIR}/addrman-*.json.zst | head -1 | xargs basename"
      ).strip()
      command = f"curl -s -I ${infraConfig.nodes.node1.wireguard.ip}:${toString CONSTANTS.NODE_TO_WEBSERVER_PORT}${CONSTANTS.NODE_TO_WEBSERVER_PATH_ADDRMAN_SNAPSHOTS}{snapshot_name}"
      output = web1.succeed(command)
      print(f"{command}: {output}")
      assert_log("HTTP/1.1 200 OK", output)

      print("checking the FULL_ACCESS frontend serves the addrman-snapshots index page")
      # without trailing slash
      command = "curl 127.0.0.1:${toString CONSTANTS.NGINX_INTERNAL_FULL_ACCESS_PORT}/addrman-snapshots"
      output = web1.succeed(command)
      print(f"{command}: {output}")
      assert_log("302 Found", output)

      # with trailing slash, the combined index page lists the nodes and
      # links to both the getrawaddrman and peers.dat snapshots per node.
      command = "curl 127.0.0.1:${toString CONSTANTS.NGINX_INTERNAL_FULL_ACCESS_PORT}/addrman-snapshots/"
      output = web1.succeed(command)
      print(f"{command}: {output}")
      assert_log("peer-observer addrman snapshots", output)
      assert_log("/addrman-snapshots/node1/", output)
      assert_log("/peers-dat-snapshots/node1/", output)

      print("checking the FULL_ACCESS frontend proxies a snapshot from node1")
      command = f"curl -s -I 127.0.0.1:${toString CONSTANTS.NGINX_INTERNAL_FULL_ACCESS_PORT}/addrman-snapshots/node1/{snapshot_name}"
      output = web1.succeed(command)
      print(f"{command}: {output}")
      assert_log("HTTP/1.1 200 OK", output)

    def check_peers_dat_snapshots():
      print("triggering peers-dat-snapshot.service on node1")
      node1.succeed("systemctl start peers-dat-snapshot.service")

      print("checking that a snapshot file was created in ${CONSTANTS.PEERS_DAT_SNAPSHOTS_DIR}")
      output = node1.succeed("ls ${CONSTANTS.PEERS_DAT_SNAPSHOTS_DIR}/peers-*.dat.zst")
      print(f"snapshot files: {output}")

      print("checking snapshot decompresses to a peers.dat with the regtest network magic")
      node1.succeed(
        "${pkgs.zstd}/bin/zstd -d -c $(ls ${CONSTANTS.PEERS_DAT_SNAPSHOTS_DIR}/peers-*.dat.zst | head -1) > /tmp/peers-snapshot.dat"
      )
      output = node1.succeed("od -An -tx1 -N4 /tmp/peers-snapshot.dat | tr -d ' '")
      assert_log("fabfb5da", output)

      print("checking webserver can fetch a peers.dat snapshot from node1 via wireguard")
      snapshot_name = node1.succeed(
        "ls ${CONSTANTS.PEERS_DAT_SNAPSHOTS_DIR}/peers-*.dat.zst | head -1 | xargs basename"
      ).strip()
      command = f"curl -s -I ${infraConfig.nodes.node1.wireguard.ip}:${toString CONSTANTS.NODE_TO_WEBSERVER_PORT}${CONSTANTS.NODE_TO_WEBSERVER_PATH_PEERS_DAT_SNAPSHOTS}{snapshot_name}"
      output = web1.succeed(command)
      print(f"{command}: {output}")
      assert_log("HTTP/1.1 200 OK", output)

      # peers.dat snapshots are listed on the combined addrman-snapshots index
      # page (see check_addrman_snapshots); here we only check that the
      # FULL_ACCESS frontend proxies an actual peers.dat snapshot from node1.
      print("checking the FULL_ACCESS frontend proxies a peers.dat snapshot from node1")
      command = f"curl -s -I 127.0.0.1:${toString CONSTANTS.NGINX_INTERNAL_FULL_ACCESS_PORT}/peers-dat-snapshots/node1/{snapshot_name}"
      output = web1.succeed(command)
      print(f"{command}: {output}")
      assert_log("HTTP/1.1 200 OK", output)


    def check_peerinfo_snapshots():
      print("triggering peerinfo-snapshot.service on node1")
      node1.succeed("systemctl start peerinfo-snapshot.service")

      print("checking that a snapshot file was created in ${CONSTANTS.PEERINFO_SNAPSHOTS_DIR}")
      output = node1.succeed("ls ${CONSTANTS.PEERINFO_SNAPSHOTS_DIR}/peerinfo-*.json.zst")
      print(f"snapshot files: {output}")

      # wait_until_nodes_connected() ran before this check, so node1 has at
      # least one peer and getpeerinfo can't be an empty array.
      print("checking snapshot decompresses to a non-empty getpeerinfo JSON array")
      output = node1.succeed(
        "${pkgs.zstd}/bin/zstd -d -c $(ls ${CONSTANTS.PEERINFO_SNAPSHOTS_DIR}/peerinfo-*.json.zst | head -1)"
      )
      assert_log('"subver"', output)
      assert_log('"conntime"', output)
      assert_log('"inbound"', output)

      print("checking webserver can fetch a getpeerinfo snapshot from node1 via wireguard")
      snapshot_name = node1.succeed(
        "ls ${CONSTANTS.PEERINFO_SNAPSHOTS_DIR}/peerinfo-*.json.zst | head -1 | xargs basename"
      ).strip()
      command = f"curl -s -I ${infraConfig.nodes.node1.wireguard.ip}:${toString CONSTANTS.NODE_TO_WEBSERVER_PORT}${CONSTANTS.NODE_TO_WEBSERVER_PATH_PEERINFO_SNAPSHOTS}{snapshot_name}"
      output = web1.succeed(command)
      print(f"{command}: {output}")
      assert_log("HTTP/1.1 200 OK", output)

      print("checking the FULL_ACCESS frontend serves the peerinfo-snapshots index page")
      # without trailing slash
      command = "curl 127.0.0.1:${toString CONSTANTS.NGINX_INTERNAL_FULL_ACCESS_PORT}/peerinfo-snapshots"
      output = web1.succeed(command)
      print(f"{command}: {output}")
      assert_log("302 Found", output)

      # with trailing slash, the index page lists the nodes with snapshots
      command = "curl 127.0.0.1:${toString CONSTANTS.NGINX_INTERNAL_FULL_ACCESS_PORT}/peerinfo-snapshots/"
      output = web1.succeed(command)
      print(f"{command}: {output}")
      assert_log("peer-observer getpeerinfo snapshots", output)
      assert_log("/peerinfo-snapshots/node1/", output)
      assert_log("/peerinfo-snapshots/node2/", output)

      print("checking the FULL_ACCESS frontend proxies a snapshot from node1")
      command = f"curl -s -I 127.0.0.1:${toString CONSTANTS.NGINX_INTERNAL_FULL_ACCESS_PORT}/peerinfo-snapshots/node1/{snapshot_name}"
      output = web1.succeed(command)
      print(f"{command}: {output}")
      assert_log("HTTP/1.1 200 OK", output)

    def check_sanitizer_suppressions():
      print("checking sanitizer env vars are set on node1 bitcoind (sanitizersAddressUndefined=true)")
      output = node1.succeed("systemctl show bitcoind-mainnet.service --property=Environment")
      assert_log("ASAN_OPTIONS=", output)
      assert_log("LSAN_OPTIONS=", output)
      assert_log("UBSAN_OPTIONS=", output)
      assert_log("halt_on_error=1", output)
      assert_log("print_stacktrace=1", output)
      assert_log("abort_on_error=1", output)
      assert_log("TSAN_OPTIONS=", output, negated=True)

      print("checking LimitCORE=infinity is set on node1 bitcoind (sanitizersAddressUndefined=true)")
      output = node1.succeed("systemctl show bitcoind-mainnet.service --property=LimitCORE")
      assert_log("LimitCORE=infinity", output)

      print("checking no sanitizer env vars are set on node2 bitcoind (no sanitizers)")
      output = node2.succeed("systemctl show bitcoind-mainnet.service --property=Environment")
      assert_log("ASAN_OPTIONS=", output, negated=True)
      assert_log("LSAN_OPTIONS=", output, negated=True)
      assert_log("UBSAN_OPTIONS=", output, negated=True)
      assert_log("TSAN_OPTIONS=", output, negated=True)

    start_all()

    check_for_wireguard()

    node1.wait_for_unit("multi-user.target")
    node2.wait_for_unit("multi-user.target")
    web1.wait_for_unit("multi-user.target")
    web2.wait_for_unit("multi-user.target")

    check_samply_continuous_profiling()

    check_sanitizer_suppressions()


    check_node_webserver_interface()

    web1.wait_for_unit("grafana.service")
    web1.wait_for_unit("prometheus.service")

    check_for_index_on_webserver()

    check_for_addrman_observer_on_webserver()

    node1.wait_for_unit("bitcoind-mainnet.service")
    node2.wait_for_unit("bitcoind-mainnet.service")

    print("verifying sanitizer env vars are present in the running bitcoind process on node1")
    pid = node1.succeed("systemctl show bitcoind-mainnet.service --property=MainPID --value").strip()
    environ = node1.succeed(f"cat /proc/{pid}/environ | tr '\\0' '\\n'")
    assert_log("ASAN_OPTIONS=", environ)
    assert_log("LSAN_OPTIONS=", environ)
    assert_log("UBSAN_OPTIONS=", environ)

    check_bitcoind_p2p_port_reachable()

    node1.wait_for_unit("nats.service")
    node1.wait_for_open_port(4222)
    node2.wait_for_unit("nats.service")
    node2.wait_for_open_port(4222)

    node1.wait_for_unit("peer-observer-ebpf-extractor.service")
    node2.wait_for_unit("peer-observer-ebpf-extractor.service")

    node1.wait_for_unit("peer-observer-rpc-extractor.service")
    node1.wait_for_open_port(${toString CONSTANTS.PEER_OBSERVER_TOOL_RPC_METRICS_PORT})
    node2.wait_for_unit("peer-observer-rpc-extractor.service")
    node2.wait_for_open_port(${toString CONSTANTS.PEER_OBSERVER_TOOL_RPC_METRICS_PORT})

    node1.wait_for_unit("peer-observer-p2p-extractor.service")
    node1.wait_for_open_port(${toString CONSTANTS.PEER_OBSERVER_EXTRACTOR_P2P_PORT})
    node2.wait_for_unit("peer-observer-p2p-extractor.service")
    node2.wait_for_open_port(${toString CONSTANTS.PEER_OBSERVER_EXTRACTOR_P2P_PORT})

    node1.wait_for_unit("peer-observer-ipc-extractor.service")
    node1.wait_for_open_port(${toString CONSTANTS.PEER_OBSERVER_TOOL_IPC_METRICS_PORT})
    node2.wait_for_unit("peer-observer-ipc-extractor.service")
    node2.wait_for_open_port(${toString CONSTANTS.PEER_OBSERVER_TOOL_IPC_METRICS_PORT})

    node1.wait_for_unit("peer-observer-tool-metrics.service")
    node2.wait_for_unit("peer-observer-tool-metrics.service")

    node1.wait_for_unit("peer-observer-tool-websocket.service")
    node2.wait_for_unit("peer-observer-tool-websocket.service")

    node1.wait_for_unit("peer-observer-tool-alerts.service")
    node2.wait_for_unit("peer-observer-tool-alerts.service")

    node1.wait_for_unit("peer-observer-tool-archiver.service")

    wait_until_nodes_connected()

    check_addrman_snapshots()

    check_peers_dat_snapshots()

    check_peerinfo_snapshots()

    check_bitcoind_rpc_connectivity()

    check_peer_observer_metrics_tool()

    check_fork_observer()

    check_prometheus_scrape_config()

    check_grafana_image_renderer()

    check_debug_log_rotation()

    # Runs last: it kills bitcoind on node1 to assert it is not auto-restarted.
    check_bitcoind_no_restart_on_crash()

    # TODO: test addrLookup
    # TODO: check web1 paths existing and reachable
    # TODO: check websockets tool
    # TODO: check banlist script successful
  '';
}
