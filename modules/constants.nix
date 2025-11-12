{
  PEER_OBSERVER_TOOL_METRICS_PORT = 8282;
  PEER_OBSERVER_TOOL_METRICS_COMPRESSED_PORT = 18282;
  PEER_OBSERVER_TOOL_WEBSOCKET_PORT = 8284;
  PEER_OBSERVER_TOOL_ADDRCONNECTIVITY_PORT = 8283;

  PEER_OBSERVER_EXTRACTOR_P2P_PORT = 28213;

  BITCOIND_RPC_PORT = 8332;
  BITCOIND_P2P_PORT_BY_CHAIN = {
    "main" = 8333;
    "test" = 18333;
    "testnet4" = 48333;
    "signet" = 38333;
    "regtest" = 18444;
  };

  PEER_OBSERVER_EXTRACTOR_P2P_NETWORK_NAME_MAP = {
    "main" = "mainnet";
    "test" = "testnet3";
    "testnet4" = "testnet4";
    "signet" = "signet";
    "regtest" = "regtest";
  };

  # nginx serves old debug logs to webservers over this port.
  DEBUG_LOGS_PORT = 38821;
  # Place where logrotate should put the debug.log's
  DEBUG_LOGS_DIR = "/data/debug-logs";

  # A UDP port exposed by the web hosts for nodes to connect to them.
  WIREGUARD_INTERFACE_PORT = 51820;
  # Namse of the wireguard interface that connects the nodes to the web hosts.
  WIREGUARD_INTERFACE_NAME = "wg-peerobserver";

  DETAILED_DEBUG_LOG_CATEGORIES = [
    "net"
    "addrman"
    "cmpctblock"
    "mempoolrej"
    "validation"
    "bench"
    "txpackages"
    "mempool" # since 2024-05-04
  ];

  FORK_OBSERVER_PORT = 2839;
  # This 'password' is hardcoded and public and that's fine here, as
  # the password is not meant to secure the RPC interface.
  # The RPC interface is only reachable via the wireguard interface.
  FORK_OBSERVER_RPC_PASSWORD = "ezei7aizaYuwooP3aeDiaPeix4chukoh";
  FORK_OBSERVER_RPC_AUTH = "4850150e041cfa78ee08e2cb72e3da1e$5e5ecbd3bc4612df5cfaf38f88f3773b6f63d94339468309fde09d995f8f2a06";

  ADDRMAN_OBSERVER_PORT = 2838;
  # This 'password' is hardcoded and public and that's fine here, as
  # the password is not meant to secure the RPC interface.
  # The RPC interface is only reachable via the wireguard interface.
  ADDRMAN_OBSERVER_RPC_PASSWORD = "Cfu2snzcHV0UwQVm4GJBKTc1IwcGfUy";
  ADDRMAN_OBSERVER_RPC_AUTH = "9dd80ae69e6ca55be09527025b2aab09$9e906b04b71de8faf735d213b60c3417303504879d851d160e5d3c791d0a8a16";

  # This 'password' is hardcoded and public and that's fine here, as
  # the password is not meant to secure the RPC interface.
  # The RPC interface is only reachable via the wireguard interface.
  RPC_EXTRACTOR_RPC_PASSWORD = "ENXKcSOReOd0KQASDPDai1V8CPYumAVN8dmt6BTW5e";
  RPC_EXTRACTOR_RPC_AUTH = "a6c2c24a5d63c3d2949b42e1c74f9d5c$edf1e4f4273baf087c0704d3fde5fa6a97701a179a9966ea1dabbb3f135e1f82";

  # This 'password' is hardcoded and public and that's fine here, as
  # the password is not meant to secure the RPC interface.
  # The RPC interface is only reachable via the wireguard interface.
  BANLIST_RPC_PASSWORD = "eQu4Iqu3aid8Bujool0xioj2auM0leeGh9voekei";
  BANLIST_RPC_RPC_AUTH = "a2c604d2857fbc90e92996c75fbf9647$90a59f24f29c744ca4487ee9d61047f52657f54849cab6da4a55510cd58d3d73";

  GRAFANA_PORT = 9321;

  # Port for the nginx server that provides full access to
  # peer-observer tools and data.
  NGINX_INTERNAL_LIMITED_ACCESS_PORT = 8001;
  NGINX_INTERNAL_LIMITED_ACCESS_NAME = "LIMITED_ACCESS";
  # Port for the nginx server that provides full access to
  # peer-observer tools and data.
  NGINX_INTERNAL_FULL_ACCESS_PORT = 8002;
  NGINX_INTERNAL_FULL_ACCESS_NAME = "FULL_ACCESS";
}
