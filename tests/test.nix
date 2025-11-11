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

    def assert_log(expected, output, negated=False):
      print(f"asserting that '{expected}' is in output..")
      print(f"output: {output}")
      result = expected in output
      if negated:
        result = not result
      if not result:
        print(f"ASSERT: expected is {"" if negated else "not "}in output!")
      assert result

    start_all()

    print("waiting for wireguard-${CONSTANTS.WIREGUARD_INTERFACE_NAME}.service on node1, node2, web1")
    node1.wait_for_unit("wireguard-${CONSTANTS.WIREGUARD_INTERFACE_NAME}.service")
    node2.wait_for_unit("wireguard-${CONSTANTS.WIREGUARD_INTERFACE_NAME}.service")
    web1.wait_for_unit("wireguard-${CONSTANTS.WIREGUARD_INTERFACE_NAME}.service")
    # web2 doesn't have a wireguard interface as it's "setup = true;"

    node1.wait_for_unit("multi-user.target")
    node2.wait_for_unit("multi-user.target")
    web1.wait_for_unit("multi-user.target")
    web2.wait_for_unit("multi-user.target")

    print("check for index.html.nix on web1")
    web1.wait_for_unit("nginx.service")
    command = "curl 127.0.0.1:${toString CONSTANTS.NGINX_INTERNAL_FULL_ACCESS_PORT}"
    output = web1.succeed(command)
    print(f"{command}: {output}")
    assert_log("""${infraConfig.nodes.node1.description}""", output)
    assert_log("""${infraConfig.nodes.node2.description}""", output)

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

    node1.wait_for_unit("bitcoind-mainnet.service")
    node2.wait_for_unit("bitcoind-mainnet.service")

    print("from node1, check if node2's Bitcoin node port is reachable and vice-versa")
    node1.wait_for_open_port(${
      toString CONSTANTS.BITCOIND_P2P_PORT_BY_CHAIN."${infraConfig.nodes.node2.bitcoind.chain}"
    }, addr="node2");
    node2.wait_for_open_port(${
      toString CONSTANTS.BITCOIND_P2P_PORT_BY_CHAIN."${infraConfig.nodes.node1.bitcoind.chain}"
    }, addr="node1");

    node1.wait_for_unit("nats.service")
    node2.wait_for_unit("nats.service")

    node1.wait_for_unit("peer-observer-ebpf-extractor.service")
    node2.wait_for_unit("peer-observer-ebpf-extractor.service")

    node1.wait_for_unit("peer-observer-rpc-extractor.service")
    node2.wait_for_unit("peer-observer-rpc-extractor.service")

    node1.wait_for_unit("peer-observer-p2p-extractor.service")
    node2.wait_for_unit("peer-observer-p2p-extractor.service")

    node1.wait_for_unit("peer-observer-tool-metrics.service")
    node2.wait_for_unit("peer-observer-tool-metrics.service")

    node1.wait_for_unit("peer-observer-tool-websocket.service")
    node2.wait_for_unit("peer-observer-tool-websocket.service")

    bitcoin_cli = "${pkgs.bitcoind}/bin/bitcoin-cli -rpcport=${toString CONSTANTS.BITCOIND_RPC_PORT} -datadir=/var/lib/bitcoind-mainnet/regtest"

    print("connect bitcoind's: node1 to node2")
    command = bitcoin_cli + " addnode node2:${
      toString CONSTANTS.BITCOIND_P2P_PORT_BY_CHAIN."${infraConfig.nodes.node1.bitcoind.chain}"
    } add"
    node1.succeed(command)

    print("wait until the two nodes are connected")
    command = bitcoin_cli + " getpeerinfo | jq 'select(. | length >= 1) // error(\"Array length is not >= 1\")'"
    node2.wait_until_succeeds(command, 70)

    command = bitcoin_cli + " getpeerinfo | jq '. | length'"
    peers = node2.succeed(command)
    print(f"node2 has {peers} peer(s)")

    print("mine a few blocks on node2")
    command = bitcoin_cli + " generatetoaddress 500 bcrt1qs758ursh4q9z627kt3pp5yysm78ddny6txaqgw"
    node2.succeed(command)

    # give nodes a bit of time to sync
    time.sleep(4)

    print("check that the Bitcoin RPC port is NOT reachable")
    node1.wait_for_closed_port(${toString CONSTANTS.BITCOIND_RPC_PORT}, addr="node1", timeout=10)
    node2.wait_for_closed_port(${toString CONSTANTS.BITCOIND_RPC_PORT}, addr="node2", timeout=10)

    print("check that web1 can reach the bitcoind RPC on node1 via wireguard")
    command = "curl ${infraConfig.nodes.node1.wireguard.ip}:${toString CONSTANTS.BITCOIND_RPC_PORT}"
    output = web1.succeed(command)
    print(f"{command}: {output}")
    assert_log("JSONRPC server handles only POST requests", output)

    web1.wait_for_unit("grafana.service")
    web1.wait_for_unit("prometheus.service")

    # Give the metrics tool a few seconds to start up
    time.sleep(4)

    print("check peer-observer-metrics-tool metrics")
    # fetching node2 here since it has an inbound connection from node1
    command = "curl ${infraConfig.nodes.node2.wireguard.ip}:${toString CONSTANTS.PEER_OBSERVER_TOOL_METRICS_COMPRESSED_PORT}"
    output = web1.succeed(command)
    print(f"{command}: {output}")

    assert_log("peerobserver_runtime_start_timestamp ", output)
    assert_log("peerobserver_runtime_start_timestamp 0", output, negated=True)

    print("check that the ebpf-extractor works..")
    assert_log("peerobserver_validation_block_connected_latest_height 500", output)

    print("check that the rpc-extractor works..")
    assert_log("peerobserver_rpc_mempoolinfo_memory_max 300000000", output)
    assert_log("peerobserver_rpc_peer_info_num_peers 1", output)

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
    assert_log('"status":"active","height":500', output)

    # TODO: test addrLookup
    # TODO: test logrotate (logrotate currently might only work on mainnet..)
    # TODO: check web1 paths existing and reachable
    # TODO: check websockets tool
    # TODO: check banlist script successful
  '';
}
