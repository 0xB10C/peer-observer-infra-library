{
  config,
  lib,
  pkgs,
  ...
}:
let
  CONSTANTS = import ../constants.nix;
  baseOptions = (import ../base/base.nix { inherit config lib pkgs; }).options;

  indexPageLimitedAccess = (
    pkgs.callPackage ./index.html.nix {
      inherit config;
      limited = true;
    }
  );
  indexPageFullAccess = (
    pkgs.callPackage ./index.html.nix {
      inherit config;
      limited = false;
    }
  );

  debugLogPage = (pkgs.callPackage ./debug-logs.html.nix) { inherit config; };

  mkForkObserverNode = name: host: {
    inherit (host) id description;
    inherit name;
    rpcHost = (host.wireguard.ip);
    rpcPort = 8332;
    rpcUser = "forkobserver";
    rpcPassword = CONSTANTS.FORK_OBSERVER_RPC_PASSWORD;
  };

  mkAddrmanObserverNode = name: host: {
    inherit (host) id;
    inherit name;
    rpc = {
      host = host.wireguard.ip;
      port = 8332;
      user = "addrmanobserver";
      password = CONSTANTS.ADDRMAN_OBSERVER_RPC_PASSWORD;
    };
  };

  mkWebsocketJsonEntry = name: (''"${name}": "/websocket/${name}/"'');
  mkWebsocketJson = names: (lib.concatMapStringsSep ", " (name: (mkWebsocketJsonEntry name)) names);
  mkWebsocketLocation =
    name: host:
    (lib.nameValuePair ("/websocket/${name}/") ({
      proxyPass = "http://${host.wireguard.ip}:${toString CONSTANTS.PEER_OBSERVER_TOOL_WEBSOCKET_PORT}/";
      proxyWebsockets = true;
    }));

  mkDebugLogLocation =
    name: host:
    (lib.nameValuePair ("/debug-logs/${name}/") ({
      proxyPass = "http://${host.wireguard.ip}:${toString CONSTANTS.DEBUG_LOGS_PORT}/";
      extraConfig = ''
        limit_rate 500k; # kB/s
      '';
    }));

  mkScrapeConfigs =
    hosts: port:
    (lib.mapAttrsToList (name: host: {
      targets = [ "${host.wireguard.ip}:${toString port}" ];
      labels = {
        host = name;
      };
    }) hosts);

in
{

  options = {
    enable = lib.mkEnableOption "this host is a web server";

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

    domain = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "peer-observer.example.com";
      description = "The domain pointing to the IP address of this `web` host. This needs to be set.";
    };

    access_DANGER = lib.mkOption {
      type = lib.types.enum [
        CONSTANTS.NGINX_INTERNAL_LIMITED_ACCESS_NAME
        CONSTANTS.NGINX_INTERNAL_FULL_ACCESS_NAME
      ];
      default = CONSTANTS.NGINX_INTERNAL_LIMITED_ACCESS_NAME;
      example = CONSTANTS.NGINX_INTERNAL_FULL_ACCESS_NAME;
      description = ''
        Choose if the `${CONSTANTS.NGINX_INTERNAL_LIMITED_ACCESS_NAME}` or
        `${CONSTANTS.NGINX_INTERNAL_FULL_ACCESS_NAME}` peer-observer tools
        and data should be exposed. `${CONSTANTS.NGINX_INTERNAL_FULL_ACCESS_NAME}`
        is only intended for demo setups and SHOULD NOT be used for production
        setups. ${CONSTANTS.NGINX_INTERNAL_FULL_ACCESS_NAME} allows finding out
        the IP addresses of the honeypot nodes.
      '';
    };

    prometheus = {
      retention = lib.mkOption {
        type = lib.types.str;
        default = "30d";
        description = "How long the prometheus metrics should be kept.";
      };
    };

    grafana = {
      admin_user = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "The username of the Grafana admin user.";
      };
    };

    index = {
      notice = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "A notice to include at the top of the index.html page. Can contain HTML (styled with bootstrap).";
      };
    };

    fork-observer = {
      networkName = lib.mkOption {
        type = lib.types.str;
        default = "mainnet";
        description = "Name of the chain / network of the peer-observer nodes.";
      };

      description = lib.mkOption {
        type = lib.types.str;
        default = "fork-observer attached to peer-observer nodes";
        description = "Description of the network and nodes.";
      };

      minForkHeight = lib.mkOption {
        type = lib.types.int;
        default = 500000;
        example = 0;
        description = "Height at which fork-observer should start to consider forks. The default works well for mainnet, but will not work for other chains/networks.";
      };
    };

  };

  config = lib.mkIf (config.peer-observer.web.enable && !config.peer-observer.base.setup) {

    assertions = [
      {
        assertion = config.peer-observer.web.domain != null;
        message = "`services.peer-observer-web.domain` must be set.";
      }
      {
        assertion = config.peer-observer.web.grafana.admin_user != null;
        message = "`services.peer-observer-web.grafana.admin_user` must be set.";
      }
    ];

    services.nginx = {
      enable = true;

      recommendedGzipSettings = true;
      recommendedOptimisation = true;
      recommendedProxySettings = true;
      recommendedTlsSettings = true;

      upstreams = {
        LIMITED_ACCESS.servers = {
          "127.0.0.1:${toString CONSTANTS.NGINX_INTERNAL_LIMITED_ACCESS_PORT}" = { };
        };
        FULL_ACCESS.servers = {
          "127.0.0.1:${toString CONSTANTS.NGINX_INTERNAL_FULL_ACCESS_PORT}" = { };
        };
      };

      appendHttpConfig = ''
        limit_req_zone $binary_remote_addr zone=ratelimit:10m rate=1r/s;
      '';

      virtualHosts = {
        # The internal endpoint that provides LIMITED peer-observer data.
        # The data accessible here is suitable for public vistors without
        # leaking information about the honeypot nodes.
        "LIMITED_ACCESS" = {
          listen = [
            {
              addr = "127.0.0.1";
              port = CONSTANTS.NGINX_INTERNAL_LIMITED_ACCESS_PORT;
            }
          ];
          locations = {
            "/" = {
              alias = "${indexPageLimitedAccess}/";
              extraConfig = ''
                default_type text/html;
              '';
            };

            "/forks" = {
              return = "301 /forks/";
            };
            "/forks/" = {
              proxyPass = "http://${config.services.fork-observer.address}/";
              proxyWebsockets = true;
              extraConfig = ''
                proxy_set_header Host $host;
                rewrite /forks/(.*) /$1  break;
              '';
            };
          };
        };

        # The internal endpoint that provides the FULL peer-observer data.
        # The data accessible here allows to find out the IP addresses of
        # the honeypot nodes. In a production setup, all access to this
        # should be restricted.
        "FULL_ACCESS" = {
          listen = [
            {
              addr = "127.0.0.1";
              port = CONSTANTS.NGINX_INTERNAL_FULL_ACCESS_PORT;
            }
          ];
          locations = {
            "/" = {
              alias = "${indexPageFullAccess}/";
              extraConfig = ''
                default_type text/html;
              '';
            };

            "/forks" = {
              extraConfig = "rewrite /forks /forks/ redirect;";
            };
            "/forks/" = {
              proxyPass = "http://${config.services.fork-observer.address}/";
              proxyWebsockets = true;
              extraConfig = ''
                proxy_set_header Host $host;
                rewrite /forks/(.*) /$1  break;
                add_header 'Access-Control-Allow-Origin' https://${config.peer-observer.web.domain};
              '';
            };

            "/monitoring" = {
              proxyPass = "http://127.0.0.1:${toString CONSTANTS.GRAFANA_PORT}";
              proxyWebsockets = true;
            };

            "/addrman" = {
              extraConfig = "rewrite /addrman /addrman/ redirect;";
            };
            "/addrman/" = {
              proxyPass = "http://${config.services.addrman-observer-proxy.address}/";
              extraConfig = ''
                proxy_set_header Host $host;
                rewrite /addrman/(.*) /$1  break;
              '';
            };

            "/debug-logs" = {
              extraConfig = "rewrite /debug-logs /debug-logs/ redirect;";
            };
            "/debug-logs/" = {
              root = "${debugLogPage}";
              index = "index.html";
              tryFiles = "$uri $uri/index.html $uri/ =404";
              extraConfig = ''
                default_type text/html;
                rewrite /debug-logs/(.*) /$1  break;
              '';
            };

            "/websocket" = {
              extraConfig = "rewrite /websocket /websocket/ redirect;";
            };
            "/websocket/" = {
              root = "${config.peer-observer.base.b10c-pkgs.peer-observer}/websocket-www/";
              index = "index.html";
              tryFiles = "$uri $uri/index.html $uri/ =404";
              extraConfig = ''
                autoindex on;
                default_type text/html;
                rewrite /websocket/(.*) /$1  break;
              '';
            };
            "/websocket/websockets.json".extraConfig = ''
              add_header Content-Type application/json;
              add_header Access-Control-Allow-Origin *;
              return 200 '{ ${mkWebsocketJson (lib.attrNames config.infra.nodes)} }';
            '';
          }
          // (lib.mapAttrs' mkWebsocketLocation (config.infra.nodes))
          // (lib.mapAttrs' mkDebugLogLocation (config.infra.nodes));
        };

        # Users can and should overwrite this, if they want to e.g. put FULL_ACCESS
        # behind authentification.
        "${config.peer-observer.web.domain}" = lib.mkDefault {
          enableACME = lib.mkDefault true;
          forceSSL = lib.mkDefault true;
          locations = lib.mkDefault {
            "/" = lib.mkDefault {
              proxyPass = "http://${config.peer-observer.web.access_DANGER}/";
              # needed for peer-observer websocket tool and Grafana!
              proxyWebsockets = true;
            };
          };
        };
      };
    };

    networking = {
      wireguard.interfaces.${CONSTANTS.WIREGUARD_INTERFACE_NAME} = {
        # the remainder of this interface is defined in base.nix

        # A web host is connected to all node hosts. The node hosts initiate
        # the wireguard connection to the web host, so node hosts don't
        # need to be reachable from the public internet. The Web host needs
        # to be reachable.
        listenPort = CONSTANTS.WIREGUARD_INTERFACE_PORT;
        peers = map (host: {
          allowedIPs = [ "${host.wireguard.ip}/32" ];
          publicKey = host.wireguard.pubkey;
          persistentKeepalive = 25;
        }) (lib.attrValues (lib.attrsets.filterAttrs (name: host: !host.setup) config.infra.nodes));
      };
      firewall = {
        # allow nginx ports on web hosts
        allowedTCPPorts = [
          80
          443
        ];
        # allow wireguard port on web hosts for nodes to connect to them
        allowedUDPPorts = [
          CONSTANTS.WIREGUARD_INTERFACE_PORT
        ];
      };
    };

    services.addrman-observer-proxy = {
      enable = true;
      address = "127.0.0.1:${toString CONSTANTS.ADDRMAN_OBSERVER_PORT}";
      nodes = lib.attrValues (lib.mapAttrs mkAddrmanObserverNode config.infra.nodes);
    };

    services.fork-observer = {
      enable = true;
      address = "127.0.0.1:${toString CONSTANTS.FORK_OBSERVER_PORT}";
      rss_base_url = "https://${config.peer-observer.web.domain}/forks";
      footer = ''
        <div class="my-2">
          <div>
            fork-observer attached to ${config.peer-observer.web.domain} nodes
          </div>
        </div>
      '';
      networks = [
        {
          id = 1;
          name = config.peer-observer.web.fork-observer.networkName;
          description = config.peer-observer.web.fork-observer.description;
          minForkHeight = config.peer-observer.web.fork-observer.minForkHeight;
          poolIdentification.enable = true;
          nodes = lib.attrValues (lib.mapAttrs mkForkObserverNode config.infra.nodes);
        }
      ];
    };

    age.secrets.grafana-admin-password = {
      file = /${config.infra.agenixSecretsDir}/grafana-admin-password-${config.peer-observer.base.name}.age;
      mode = "0440";
      owner = config.users.users.grafana.name;
      group = config.users.users.grafana.group;
    };

    services.grafana-image-renderer = {
      enable = true;
      verbose = true;
      # We manually provision the grafana side.
      # (see "rendering" below)
      provisionGrafana = false;
    };

    services.grafana = {
      enable = true;
      package = pkgs.grafana;
      settings = {
        server = {
          http_port = CONSTANTS.GRAFANA_PORT;
          http_addr = "127.0.0.1";
          serve_from_sub_path = true;
          enable_gzip = true;
          domain = config.peer-observer.web.domain;
          root_url = "https://${config.peer-observer.web.domain}/monitoring";
          enforce_domain = false;
        };
        security = {
          admin_password = "$__file{${config.age.secrets.grafana-admin-password.path}}";
          admin_user = config.peer-observer.web.grafana.admin_user;
          cookie_secure = true;
        };
        # https://github.com/grafana/grafana/issues/54974#issuecomment-1787591644
        rbac = {
          permission_validation_enabled = false;
        };
        "auth.anonymous" = {
          enabled = true;
          org_role = "Viewer";
        };
        analytics.reporting_enabled = false;
        "unified_alerting.screenshots" = {
          capture = true;
        };
        rendering = {
          # callback_url needs the "/monitoring" subpath!
          callback_url = "http://127.0.0.1:${toString CONSTANTS.GRAFANA_PORT}/monitoring";
          server_url = "http://127.0.0.1:${toString config.services.grafana-image-renderer.settings.service.port}/render";
        };
      };
      provision = {
        enable = true;
        datasources.settings.datasources = [
          {
            name = "prometheus";
            type = "prometheus";
            url = "http://127.0.0.1:${toString config.services.prometheus.port}";
            isDefault = true;
          }
        ];
        dashboards.settings.providers = [
          {
            # dashboards shipped with the NixOS flake
            name = "peer-observer-flake";
            updateIntervalSeconds = 999999;
            options.path = (./dashboards);
            options.foldersFromFilesStructure = true;
          }
          {
            # dashboards shipped with the peer-observer metrics tool
            name = "peer-observer-metrics-tool";
            updateIntervalSeconds = 999999;
            options.path = "${config.peer-observer.base.b10c-pkgs.peer-observer}/dashboards";
            options.foldersFromFilesStructure = true;
          }
          # TODO: allow to supply extra dashboards
        ];
      };
    };

    services.prometheus =
      let
        addrConnectivityNodes = lib.attrsets.filterAttrs (
          name: host: host.peer-observer.addrLookup
        ) config.infra.nodes;
      in
      {
        enable = true;
        retentionTime = config.peer-observer.web.prometheus.retention;
        scrapeConfigs = [
          # node scrape config
          {
            job_name = "node";
            scrape_interval = "15s";
            static_configs = [
              {
                # the config for the current web host
                targets = [ "127.0.0.1:${toString config.services.prometheus.exporters.node.port}" ];
                labels = {
                  host = config.peer-observer.base.name;
                };
              }
            ]
            ++ (mkScrapeConfigs config.infra.nodes config.services.prometheus.exporters.node.port);
          }
          # wireguard scrape config
          {
            job_name = "wireguard";
            scrape_interval = "30s";
            static_configs = [
              {
                # the config for the current web host
                targets = [ "127.0.0.1:${toString config.services.prometheus.exporters.wireguard.port}" ];
                labels = {
                  host = config.peer-observer.base.name;
                };
              }
            ]
            ++ (mkScrapeConfigs config.infra.nodes config.services.prometheus.exporters.wireguard.port);
          }
          # peer-observer-metrics scrape config
          {
            job_name = "peer-observer-metrics";
            fallback_scrape_protocol = "PrometheusText0.0.4";
            scrape_interval = "15s";
            scrape_timeout = "14s";
            static_configs = (
              mkScrapeConfigs config.infra.nodes CONSTANTS.PEER_OBSERVER_TOOL_METRICS_COMPRESSED_PORT
            );
          }
          # addrConnectivityLookup scrape config
          {
            job_name = "peer-observer-addr-connectivity";
            scrape_interval = "15s";
            fallback_scrape_protocol = "PrometheusText0.0.4";
            static_configs = (
              mkScrapeConfigs addrConnectivityNodes CONSTANTS.PEER_OBSERVER_TOOL_ADDRCONNECTIVITY_PORT
            );
          }
          # bitcoind process exporter scrape config
          {
            job_name = "process-exporter";
            scrape_interval = "30s";
            static_configs = (
              mkScrapeConfigs config.infra.nodes config.services.prometheus.exporters.process.port
            );
          }
        ];
      };
  };
}
