{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  CONSTANTS = import ../constants.nix;
  baseOptions = (import ../base/base.nix { inherit config lib pkgs; }).options;
  NATS_PORT = 4222;
in
{
  options = {
    enable = lib.mkEnableOption "this host is a Bitcoin node";

    inherit (baseOptions)
      id
      name
      description
      wireguard
      setup
      arch
      extraConfig
      extraModules
      ;

    bitcoind = {
      prune = lib.mkOption {
        type = lib.types.int;
        default = 4000;
        description = "The prune parameter for Bitcoin Core. 0 turns pruning off.";
      };

      package = lib.mkOption {
        type = lib.types.package;
        # this is the default package without overrides
        default = (pkgs.callPackage ../../pkgs/bitcoind/default.nix { }) { };
        description = "The bitcoind package to run on this node.";
      };

      chain = lib.mkOption {
        type = types.enum [
          "main"
          "test"
          "testnet4"
          "signet"
          "regtest"
        ];
        default = "main";
        description = "The chain / network the node should run.";
      };

      customPort = lib.mkOption {
        type = types.nullOr types.port;
        default = null;
        description = "A custom port the Bitcoin node should use for the P2P network. If unset, the default port is used.";
        example = 12345;
      };

      extraConfig = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Extra configuration passed to bitcoind in the 'bitcoin.conf' format.";
      };

      net = {
        useASMap = lib.mkEnableOption "using a recent ASMap file with this node. See https://asmap.org for more information.";

        useTor = lib.mkEnableOption "Tor with this node and accept connections from Tor.";

        useI2P = lib.mkEnableOption "i2p with this node and accept connections from i2p.";

        useCJDNS = lib.mkEnableOption "CJDNS with this node and accept connections from CJDNS.";
      };

      dataDir = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "The data directory of the node. By default, this is /var/lib/bitcoind-*/. Setting this can be useful if there's a bigger drive mounted somewhere else.";
      };

      banlistScript = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        description = "A banlist script. Has access to the 'RPC_BAN_USER' and 'RPC_BAN_PW' env variables";
        default = null;
      };

      detailedLogging = {
        enable = lib.mkOption {
          type = lib.types.bool;
          description = "If enabled, turn on potentially spammy debug log categories like `net` and `mempoolrej`. Logs are rotated daily and compressed.";
          default = true;
        };
        logsToKeep = lib.mkOption {
          type = lib.types.ints.u16;
          description = "Logs to keep on the server before deleting them (maps to logrotates 'rotate' setting). Logs are rotated daily, so keeping two logs means keeping two days worth of logs.";
          default = 4;
          example = 2;
        };
        printToConsole = lib.mkEnableOption "Wether to print the debug logs to console (i.e. systemd) too. Disabled by default, but can be useful for testing.";
      };
    };

    fork-observer = {
      enable = lib.mkEnableOption "this node for use in a fork-observer instance." // {
        default = true;
      };
    };

    addrman-observer = {
      enable = lib.mkEnableOption "this node for use in a addrman-observer instance." // {
        default = true;
      };
    };

    peer-observer = {
      addrLookup = lib.mkEnableOption "the peer-observer address-connectivity lookup tool. This reaches out to nodes on the network and might leak IP addresses.";
    };
  };

  config = lib.mkIf (config.peer-observer.node.enable && !config.peer-observer.base.setup) {

    # A NATS server that the peer-observer and
    services.nats = {
      enable = true;
      settings = {
        listen = "127.0.0.1:${toString NATS_PORT}";
        http = "127.0.0.1:8222";
        # See https://github.com/0xB10C/peer-observer/blob/master/extractors/ebpf/README.md#nats-settings
        max_payload = 5242880; # 5MB
      };
    };

    # HACK: restart peer-observer-tool-metrics every 48h
    # TODO: fix peer-observer metrics to not grow on RAM too much.
    # systemd.services."peer-observer-tool-metrics".serviceConfig.RuntimeMaxSec = "48h";

    # To be sure to notice a crashed Bitcoin node, we configure the NixOS systemd service to
    # NOT restart the node. This must be done manually (either systemctl restart bitcoind-mainnet
    # or restarting the whole host). Calling the "stop" RPC also causes the node to be NOT restarted.
    # See https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html#Restart=
    systemd.services.bitcoind-mainnet.serviceConfig.Restart = lib.mkForce "no";

    # for backwards compatability reasons, this is called "mainnet" and has to stay this way for now.
    # Even if we run a signet/testnet/regtest node..
    services.bitcoind."mainnet" = {
      enable = true;
      package = config.peer-observer.node.bitcoind.package;
      dataDir = mkIf (
        config.peer-observer.node.bitcoind.dataDir != null
      ) config.peer-observer.node.bitcoind.dataDir;
      rpc.port = CONSTANTS.BITCOIND_RPC_PORT;
      prune = config.peer-observer.node.bitcoind.prune;
      # needs to be "/run/bitcoind-<name>/bitcoind.pid"
      pidFile = "/run/bitcoind-mainnet/bitcoind.pid";
      extraConfig = ''

        chain=${config.peer-observer.node.bitcoind.chain}
        [${config.peer-observer.node.bitcoind.chain}]

        port=${
          toString (
            if config.peer-observer.node.bitcoind.customPort != null then
              config.peer-observer.node.bitcoind.customPort
            else
              CONSTANTS.BITCOIND_P2P_PORT_BY_CHAIN."${config.peer-observer.node.bitcoind.chain}"
          )
        }

        # disabled, as it has gotten quite spammy in
        # https://github.com/bitcoin/bitcoin/pull/32604/commits/d541409a64c60d127ff912dad9dea949d45dbd8c
        logsourcelocations=0
        logips=1
        logthreadnames=1
        logtimemicros=1
        server=1
        rpcbind=127.0.0.1
        rpcallowip=127.0.0.1
        rpcwhitelistdefault=0

        ${optionalString (config.services.peer-observer.extractors.p2p.enable) ''
          addnode=${config.services.peer-observer.extractors.p2p.p2pAddress}
        ''}
        ${optionalString (config.services.peer-observer.extractors.rpc.enable) ''
          server=1

          # rpc-extractor (peer-observer) user
          rpcwhitelist=rpc-extractor:getpeerinfo,getmempoolinfo
          rpcauth=rpc-extractor:${CONSTANTS.RPC_EXTRACTOR_RPC_AUTH}
        ''}
        ${optionalString (config.peer-observer.node.bitcoind.banlistScript != null) ''
          server=1

          # banlist user
          rpcwhitelist=ban:clearbanned,listbanned,setban
          rpcauth=ban:${CONSTANTS.BANLIST_RPC_RPC_AUTH}
        ''}
        ${optionalString (config.peer-observer.node.fork-observer.enable) ''
          server=1
          rest=1

          # forkobserver user
          # Don't allow getnetworkinfo even if fork-observer tires to use it to fetch the version
          # Otherwise, fork-observer will show the version, which can be a honeypot leak.
          rpcwhitelist=forkobserver:getchaintips,getblockhash,getblockheader,getblock
          rpcauth=forkobserver:${CONSTANTS.FORK_OBSERVER_RPC_AUTH}
        ''}
        ${optionalString (config.peer-observer.node.addrman-observer.enable) ''
          server=1

          # addrmanobserver user
          rpcwhitelist=addrmanobserver:getrawaddrman
          rpcauth=addrmanobserver:${CONSTANTS.ADDRMAN_OBSERVER_RPC_AUTH}
        ''}
        ${optionalString
          (
            config.peer-observer.node.fork-observer.enable || config.peer-observer.node.addrman-observer.enable
          )
          ''
            rpcbind=${config.peer-observer.base.wireguard.ip}
            # allow rpc connections from web hosts
            ${builtins.concatStringsSep "\n" (
              map (host: "rpcallowip=" + host.wireguard.ip) (lib.attrValues config.infra.webservers)
            )}
          ''
        }
        ${optionalString config.peer-observer.node.bitcoind.net.useTor "debug=tor"}
        ${optionalString config.peer-observer.node.bitcoind.net.useI2P ''
          debug=i2p
          i2pacceptincoming=1
          i2psam=${config.services.i2pd.proto.sam.address}:${toString config.services.i2pd.proto.sam.port}
        ''}
        ${optionalString config.peer-observer.node.bitcoind.net.useCJDNS ''
          cjdnsreachable=1
        ''}
        ${optionalString config.peer-observer.node.bitcoind.net.useASMap ''
          asmap=${config.peer-observer.base.b10c-pkgs.asmap-data}
        ''}
        ${optionalString config.peer-observer.node.bitcoind.detailedLogging.enable ''
          ${lib.concatStrings (map (cat: "debug=${cat}\n") CONSTANTS.DETAILED_DEBUG_LOG_CATEGORIES)}
          printtoconsole=${
            if config.peer-observer.node.bitcoind.detailedLogging.printToConsole then "1" else "0"
          }
        ''}
      ''
      + config.peer-observer.node.bitcoind.extraConfig;
    };

    networking = {
      wireguard.interfaces.${CONSTANTS.WIREGUARD_INTERFACE_NAME} = {
        # the remainder of this interface is defined in base.nix

        # node hosts are connected to web hosts. The node hosts initiate
        # the wireguard connection to the web hosts, so node hosts don't
        # need to be reachable from the public internet. Web hosts need
        # to be reachable.
        listenPort = null;
        peers = map (webserver: {
          allowedIPs = [ "${webserver.wireguard.ip}/32" ];
          endpoint = "${webserver.domain}:${toString CONSTANTS.WIREGUARD_INTERFACE_PORT}";
          publicKey = webserver.wireguard.pubkey;
          persistentKeepalive = 25;
        }) (lib.attrValues (lib.attrsets.filterAttrs (name: host: !host.setup) config.infra.webservers));
      };
      firewall = {
        allowedTCPPorts = [
          (
            if config.peer-observer.node.bitcoind.customPort != null then
              config.peer-observer.node.bitcoind.customPort
            else
              CONSTANTS.BITCOIND_P2P_PORT_BY_CHAIN."${config.peer-observer.node.bitcoind.chain}"
          )
        ];
        interfaces.${CONSTANTS.WIREGUARD_INTERFACE_NAME}.allowedTCPPorts = [
          # on node hosts:
          # - open the prometheus exporter ports to the wireguard interface
          config.services.prometheus.exporters.node.port
          config.services.prometheus.exporters.wireguard.port
          config.services.prometheus.exporters.process.port
          # - open the peer-observer tooling ports to the wireguard interface
          CONSTANTS.PEER_OBSERVER_TOOL_ADDRCONNECTIVITY_PORT
          CONSTANTS.PEER_OBSERVER_TOOL_WEBSOCKET_PORT
          # PEER_OBSERVER_TOOL_METRICS_PORT is only used on localhost, as the metrics are proxied
          # and compressed via nginx.
          CONSTANTS.PEER_OBSERVER_TOOL_METRICS_COMPRESSED_PORT
          # nginx serves old debug logs to webservers over this port.
          CONSTANTS.DEBUG_LOGS_PORT
          # - open the Bitcoin node RPC port to the wireguard interface
          # for fork-observer and addrman-observer
          config.services.bitcoind.mainnet.rpc.port
        ];
      };
    };

    services.tor = {
      enable = config.peer-observer.node.bitcoind.net.useTor;
      client.enable = true;
      settings.ControlPort = [ { port = 9051; } ];
    };

    services.i2pd = {
      enable = config.peer-observer.node.bitcoind.net.useI2P;
      proto.sam.enable = true;
    };

    services.cjdns = {
      enable = config.peer-observer.node.bitcoind.net.useCJDNS;
      UDPInterface = {
        bind = "0.0.0.0:36468";
        # These are CJNDS peers I found to be working. However,
        # they might not be needed anymore with newer CJDNS versions..
        # due to better peer finding. If that's true, these can be removed.
        connectTo = {
          "107.170.57.34:63472" = {
            login = "public-peer";
            password = "ppm6j89mgvss7uvtntcd9scy6166mwb";
            peerName = "cord.ventricle.us";
            publicKey = "1xkf13m9r9h502yuffsq1cg13s5648bpxrtf2c3xcq1mlj893s90.k";
          };
          "81.6.2.165:56879" = {
            login = "theswissbay-peering-login";
            password = "rr1lsx8vvxq7m5107gvsn98gc2h2l54";
            peerName = "theswissbay.ch";
            publicKey = "nuvtkly8swgkwsyyjrv89f4y4y0w3x17w61twgsfh9zv1r87h060.k";
          };
        };
      };
    };

    services.peer-observer = {
      natsAddress = "127.0.0.1:${toString NATS_PORT}";

      extractors = {
        dependOn = "bitcoind-mainnet";
        ebpf = {
          enable = true;
          bitcoindPIDFile = config.services.bitcoind.mainnet.pidFile;
          bitcoindPath = "${config.services.bitcoind.mainnet.package}/bin/bitcoind";
        };
        rpc = {
          enable = true;
          rpcHost = "127.0.0.1:${toString config.services.bitcoind.mainnet.rpc.port}";
          rpcUser = "rpc-extractor";
          rpcPass = CONSTANTS.RPC_EXTRACTOR_RPC_PASSWORD;
        };
        p2p = {
          enable = true;
          p2pAddress = "127.0.0.1:${toString CONSTANTS.PEER_OBSERVER_EXTRACTOR_P2P_PORT}";
          network =
            CONSTANTS.PEER_OBSERVER_EXTRACTOR_P2P_NETWORK_NAME_MAP."${config.peer-observer.node.bitcoind.chain
            }";
        };
        log = {
          enable = true;
          debugLog = "/var/lib/bitcoind-mainnet/debug.log";
        };
      };

      tools = {
        metrics = {
          enable = true;
          # This is only listening on 127.0.0.1 as it's proxied through nginx to
          # have compression.
          metricsAddress = "127.0.0.1:${toString CONSTANTS.PEER_OBSERVER_TOOL_METRICS_PORT}";
        };

        addrConnectivity = {
          enable = config.peer-observer.node.peer-observer.addrLookup;
          metricsAddress = "${config.peer-observer.base.wireguard.ip}:${toString CONSTANTS.PEER_OBSERVER_TOOL_ADDRCONNECTIVITY_PORT}";
        };

        websocket = {
          enable = true;
          websocketAddress = "${config.peer-observer.base.wireguard.ip}:${toString CONSTANTS.PEER_OBSERVER_TOOL_WEBSOCKET_PORT}";
        };
      };
    };

    systemd.services."bitcoind-banlist" =
      mkIf (config.peer-observer.node.bitcoind.banlistScript != null)
        {
          after = [ "bitcoind-mainnet.service" ];
          wantedBy = [ "multi-user.target" ];
          script = ''
            set -e
            shopt -s expand_aliases
            alias bitcoin-cli="${
              config.services.bitcoind."mainnet".package
            }/bin/bitcoin-cli -rpcuser=$RPC_BAN_USER -rpcpassword=$RPC_BAN_PW"
            echo "Banlist script started"
            echo "Waiting for bitcoind to come online"
            sleep 30


            echo "Currently banned IPs/Subnets:"
            bitcoin-cli listbanned
            echo ""

            echo "Clearing banned IPs/Subnets.."
            bitcoin-cli clearbanned
            echo ""

            echo "Banning IPs/Subnets.."
            ${config.peer-observer.node.bitcoind.banlistScript}

            echo "Now banned IPs/Subnets:"
            bitcoin-cli listbanned
            echo ""

            echo "Done"
          '';
          serviceConfig = {
            Type = "oneshot";
            Environment = "RPC_BAN_USER=ban RPC_BAN_PW=${CONSTANTS.BANLIST_RPC_PASSWORD}";
          };
        };
    systemd.services."mkdir-data-debug-logs" = {
      wantedBy = [
        "logrotate.service"
        "logrotate-checkconf.service"
      ];
      before = [
        "logrotate.service"
        "logrotate-checkconf.service"
      ];
      script = ''
        mkdir -p ${CONSTANTS.DEBUG_LOGS_DIR}
        chown ${config.services.bitcoind.mainnet.user}:${config.services.bitcoind.mainnet.group} ${CONSTANTS.DEBUG_LOGS_DIR}
        chmod -R 775 ${CONSTANTS.DEBUG_LOGS_DIR}
      '';
      serviceConfig.Type = "oneshot";
    };

    services.logrotate = {
      settings = {
        "${config.services.bitcoind."mainnet".dataDir}/debug.log" =
          mkIf config.peer-observer.node.bitcoind.detailedLogging.enable
            {
              frequency = "daily";
              dateext = "dateformat -%Y%m%d-${config.peer-observer.base.name}";
              compress = true;
              datehourago = true;
              copytruncate = true;
              olddir = CONSTANTS.DEBUG_LOGS_DIR;
              rotate = config.peer-observer.node.bitcoind.detailedLogging.logsToKeep;
              su = "${config.services.bitcoind.mainnet.user} ${config.services.bitcoind.mainnet.group}";
            };
      };
    };

    services.nginx = {
      enable = true;
      recommendedGzipSettings = true;
      recommendedOptimisation = true;

      # Since the peer-observer-metrics-tool output can grow quite large and is
      # it's not compressed, serve it via nginx that has compression turned on.
      # This reduces bandwidth (and prometheus scrape timings) by a lot!
      virtualHosts."compressed-peer-observer-metrics" = {
        listen = [
          {
            addr = "${config.peer-observer.base.wireguard.ip}";
            port = CONSTANTS.PEER_OBSERVER_TOOL_METRICS_COMPRESSED_PORT;
          }
        ];
        locations."/" = {
          proxyPass = "http://127.0.0.1:8282";
        };
      };

      virtualHosts."old-debug-logs" = {
        listen = [
          {
            addr = "${config.peer-observer.base.wireguard.ip}";
            port = CONSTANTS.DEBUG_LOGS_PORT;
          }
        ];
        locations."/" = {
          root = CONSTANTS.DEBUG_LOGS_DIR;
          extraConfig = ''
            autoindex on;
            autoindex_exact_size off;
            # Limit the download bandwidth here, so everyone accessing it via
            # the webserver is limited. This helps against a bandwidth DoS on the node.
            limit_rate 500k; # kB/s
          '';
        };
      };
    };

    # A process exporter for bitcoind. Exports the time spent in the different bitcoind threads.
    services.prometheus.exporters.process = {
      enable = true;
      settings.process_names = [
        # Remove nix store path from process name
        {
          comm = [ "bitcoind" ];
          name = "{{.Matches.Wrapped}} {{ .Matches.Args }}";
          cmdline = [ "^/nix/store[^ ]*/(?P<Wrapped>[^ /]*) (?P<Args>.*)" ];
        }
      ];
    };

    # The "root" user can use bitcoin-cli directly.
    programs.bash.shellAliases = {
      "bitcoin-cli" =
        "${config.services.bitcoind.mainnet.package}/bin/bitcoin-cli -rpccookiefile=${config.services.bitcoind.mainnet.dataDir}/.cookie";
    };

    environment.systemPackages = [
      # the peer-observer tools and extractors as packages
      # e.g. `$ logger`
      config.peer-observer.base.b10c-pkgs.peer-observer
      # useful to see NATS server load
      pkgs.nats-top
    ];

  };

}
