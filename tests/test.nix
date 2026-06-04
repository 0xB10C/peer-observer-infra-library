{
  nixpkgs,
  peer-observer-infra-library,
  system,
  ...
}:

let

  pkgs = import nixpkgs { inherit system; };
  lib = pkgs.lib;

  CONSTANTS = import ../modules/constants.nix;

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
      assert_log('{"networks":[{"id":1,"name":"regtest","description":"  fork-observer attached to peer-observer nodes"}]}', output)
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

    check_bitcoind_rpc_connectivity()

    check_peer_observer_metrics_tool()

    check_fork_observer()

    check_prometheus_scrape_config()

    # TODO: test addrLookup
    # TODO: test logrotate (logrotate currently might only work on mainnet..)
    # TODO: check web1 paths existing and reachable
    # TODO: check websockets tool
    # TODO: check banlist script successful
  '';
}
