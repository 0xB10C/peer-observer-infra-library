{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.services.bitcoind-profiling;
in
{
  options.services.bitcoind-profiling = {
    enable = mkEnableOption "24h-long samply CPU sampling of the bitcoind process";

    package = mkOption {
      type = types.package;
      description = "The samply package to use.";
    };

    nodeName = mkOption {
      type = types.str;
      description = "Node name used as part of the output filename.";
    };

    outputDir = mkOption {
      type = types.str;
      default = "/data/profiling";
      description = "Directory the profile files are written to.";
    };

    rate = mkOption {
      type = types.ints.positive;
      default = 53;
      description = "Sampling rate in Hz passed to `samply record --rate`.";
    };

    duration = mkOption {
      type = types.ints.positive;
      default = 24 * 60 * 60;
      description = "Recording duration in seconds (default: 24h).";
    };

    bitcoindService = mkOption {
      type = types.str;
      default = "bitcoind-mainnet.service";
      description = "The bitcoind systemd service the profiler attaches to.";
    };

    bitcoindPidFile = mkOption {
      type = types.str;
      default = "/run/bitcoind-mainnet/bitcoind.pid";
      description = "Path to the bitcoind PID file.";
    };
  };

  config = mkIf cfg.enable {
    systemd.tmpfiles.rules = [
      "d ${cfg.outputDir} 0755 root root -"
    ];

    systemd.services.bitcoind-profiling = {
      description = "samply CPU profiling of bitcoind (${toString cfg.duration}s captures at ${toString cfg.rate}Hz)";
      wantedBy = [ "multi-user.target" ];
      after = [ cfg.bitcoindService ];
      bindsTo = [ cfg.bitcoindService ];

      serviceConfig = {
        Type = "simple";
        Restart = "always";
        RestartSec = "10s";
        TimeoutStopSec = "60s";
        User = "root";
        Group = "root";
      };

      script = ''
        set -eu
        PID="$(cat ${cfg.bitcoindPidFile})"
        DATE="$(date +%Y%m%d-%H%M%S)"
        OUTPUT="${cfg.outputDir}/bitcoind-''${DATE}-${cfg.nodeName}.json.gz"
        echo "Profiling bitcoind PID=$PID at ${toString cfg.rate}Hz for ${toString cfg.duration}s -> $OUTPUT"
        exec ${cfg.package}/bin/samply record \
          --rate ${toString cfg.rate} \
          --duration ${toString cfg.duration} \
          --pid "$PID" \
          --save-only \
          --no-open \
          --presymbolicate \
          --output "$OUTPUT"
      '';
    };
  };
}
