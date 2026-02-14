{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.services.parca.agent;
in

{
  options.services.parca.agent = {
    enable = mkEnableOption "parca-agent service";

    package = mkPackageOption pkgs "parca-agent" { };

    server = mkOption {
      type = types.str;
      default = "127.0.0.1:7070";
      description = "Address of the Parca server (i.e. --remote-store-address).";
    };

    config = mkOption {
      type = types.str;
      default = ''
        relabel_configs:
          - action: keep
            source_labels: ["__meta_process_executable_name"]
            regex: "^(bitcoind|websocket|metrics|p2p-extractor|ebpf-extractor|rpc-extractor|.*-extractor)$"
      '';
      description = "parca agent configuration file in yaml";
    };

    extraArgs = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Extra arguments passed to parca-agent.";
    };
  };

  config = mkIf cfg.enable {
    systemd.services.parca-agent =
      let
        configFile = pkgs.writeText "parca-agent.yaml" cfg.config;
      in
      {
        description = "Parca Agent";
        wantedBy = [ "multi-user.target" ];
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        serviceConfig = {
          ExecStart = ''
            ${cfg.package}/bin/parca-agent \
              --config-path ${configFile} \
              --remote-store-address=${cfg.server} \
              --remote-store-insecure \
              ${lib.concatStringsSep " " cfg.extraArgs}
          '';
          RestartSec = 30;
          StartLimitBurst = 3;

          # Parca does not work with these hardening features enabled:
          # ProtectKernelLogs = "true";
          # ProtectKernelTunables = "true";
          # ProcSubset = "pid";
          # PrivateUsers = "true";

          LockPersonality = "true";
          IPAddressDeny = "any";
          ProtectControlGroups = "true";
          RestrictNamespaces = "true";
          ProtectKernelModules = "true";
          ProtectClock = "true";
          MemoryDenyWriteExecute = "true";
          PrivateTmp = "true";
          ProtectSystem = "strict";
          ProtectHome = "true";
          NoNewPrivileges = "true";
          PrivateDevices = "true";
          ProtectProc = "invisible";
          RestrictSUIDSGID = "true";
          RemoveIPC = "true";
          RestrictRealtime = "true";
          ProtectHostname = "true";
          SystemCallArchitectures = "native";

          # @system-service whitelist and docker seccomp blacklist (except for "clone"
          # which is a core requirement for systemd services)
          # @system-service is defined in src/shared/seccomp-util.c (systemd source)
          SystemCallFilter = [
            "@system-service"
            "~add_key get_mempolicy kcmp keyctl mbind move_pages name_to_handle_at personality process_vm_readv process_vm_writev request_key set_mempolicy setns unshare userfaultfd"
            "clone3"
            # these are needed by parca-agent:
            "bpf"
            "perf_event_open"
            "process_vm_readv"
          ];

          # allow localhost communication
          IPAddressAllow = [
            "127.0.0.1/32"
            "::1/128"
            "169.254.0.0/16"
          ];

          # We run parca-agent as root for it to have full access to the system for all
          # profiling needs it has. This also means, parca-agent needs to be optional
          # and defaults to off.
          User = "root";
          Group = "root";
        };
      };
  };
}
