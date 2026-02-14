{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.services.parca.server;
in

{
  options.services.parca.server = {
    enable = mkEnableOption "parca-server service";

    package = mkPackageOption pkgs "parca" { };

    listenAddress = mkOption {
      type = types.str;
      default = "127.0.0.1:7070";
      description = "Address the Parca server listens on (i.e. --http-address).";
    };

    storage = {
      indexOnDisk = mkOption {
        type = types.bool;
        default = true;
        example = false;
        description = "Whether to store the index on disk instead of in memory. Useful to reduce the memory footprint of the store.";
      };

      activeMemory = mkOption {
        type = types.int;
        default = 134217728; # 128 MB
        example = 536870912; # 512 MB
        description = "Amount of memory to use for active storage.";
      };
    };

    config = mkOption {
      type = types.attrs;
      default = {
        object_storage = {
          bucket = {
            type = "FILESYSTEM";
            config = {
              directory = "/var/lib/parca-server";
            };
          };
        };
      };
      example = {
        object_storage = {
          bucket = {
            type = "FILESYSTEM";
            config = {
              directory = "/var/lib/parca-server";
            };
          };
        };
      };
      description = "parca server configuration file that will be mapped into YAML.";
    };

    extraArgs = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Extra arguments passed to parca-server.";
    };
  };

  config = mkIf cfg.enable {

    users = {
      users.parca-server = {
        isSystemUser = true;
        group = "parca-server";
      };
      groups.parca-server = { };
    };

    # Clean files older than 7 days
    systemd.tmpfiles.rules = [
      "d /var/lib/parca-server 1777 parca-server parca-server 7d"
    ];

    systemd.services.parca-server =
      let
        configFile = pkgs.writeText "parca.yaml" (builtins.toJSON cfg.config);
      in
      {
        description = "Parca Server";
        wantedBy = [ "multi-user.target" ];
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        serviceConfig = {
          ExecStart = ''
            ${cfg.package}/bin/parca \
              --http-address ${cfg.listenAddress} \
              --config-path ${configFile} \
              --storage-active-memory=${toString cfg.storage.activeMemory} \
              ${lib.optionalString cfg.storage.indexOnDisk "--storage-index-on-disk"} \
              ${lib.concatStringsSep " " cfg.extraArgs}
          '';
          RestartSec = 30;
          StartLimitBurst = 3;
          StateDirectory = "parca-server"; # /var/lib/parca-server
          DynamicUser = true;
          User = config.users.users.parca-server.name;
          Group = config.users.groups.parca-server.name;

          PrivateTmp = "true";
          ProtectSystem = "strict";
          ProtectHome = "true";
          NoNewPrivileges = "true";
          PrivateDevices = "true";
          MemoryDenyWriteExecute = "true";
          ProtectKernelTunables = "true";
          ProtectKernelModules = "true";
          ProtectKernelLogs = "true";
          ProtectClock = "true";
          ProtectProc = "invisible";
          ProcSubset = "pid";
          ProtectControlGroups = "true";
          RestrictNamespaces = "true";
          LockPersonality = "true";
          IPAddressDeny = "any";
          PrivateUsers = "true";
          RestrictSUIDSGID = "true";
          RemoveIPC = "true";
          RestrictRealtime = "true";
          ProtectHostname = "true";
          CapabilityBoundingSet = "";
          # @system-service whitelist and docker seccomp blacklist (except for "clone"
          # which is a core requirement for systemd services)
          # @system-service is defined in src/shared/seccomp-util.c (systemd source)
          SystemCallFilter = [
            "@system-service"
            "~add_key get_mempolicy kcmp keyctl mbind move_pages name_to_handle_at personality process_vm_readv process_vm_writev request_key set_mempolicy setns unshare userfaultfd"
            "clone3"
          ];
          SystemCallArchitectures = "native";
          IPAddressAllow = [
            "127.0.0.1/32"
            "::1/128"
            "169.254.0.0/16"
          ];
        };

      };
  };
}
